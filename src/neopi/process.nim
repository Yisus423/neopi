## Spawn-per-call process primitive for neopi's extensibility.
##
## The `neopi.process` table gives extension scripts a `run(cmd)` primitive:
## it fires the `process_run` hook before executing (block or rewrite via the
## hook bus's emit, injected as a closure so this module stays cycle-free),
## then runs the command in the workspace root and returns
## `{output = <combined stdout/stderr>, code = <exitCode>}`.
##
## Trust model: scripts are trusted code. With no emit wired, `run` executes
## freely; the harness-level approval gate is a later concern. When an emit
## is wired, the `process_run` hook can block a command (its reason becomes a
## Lua error) or rewrite it before execution.

import std/[json, os, osproc]
import neopi/lua
import neopi/pump
from neopi/hooks import HookOutcome, lua_error

when defined(posix):
  import std/posix as posix

# Same file-scope typedef as lua.nim/hooks.nim: this module's generated C
# calls into the Lua state directly, and no C headers exist to declare the
# opaque state type.
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

# stacktrace off: lua_error longjmps out of the Nim C-callback frames below;
# with frames on it skips the frame pops and corrupts the runtime frame
# stack (the next nimFrame call segfaults). These bridge modules are thin —
# the loss of in-module stack traces is the price of the containment.
{.push stacktrace: off.}

proc raiseLuaError(L: LuaState, message: string) {.noreturn.} =
  ## Push `message` and raise it as a Lua error; lua_error longjmps to the
  ## enclosing pcall, so control never returns here.
  lua_pushstring(L, message)
  discard lua_error(L)

type
  ProcessContext = object
    ## Per-interpreter context carried as the `run` closure's upvalue: the
    ## workspace root and the injected emit and pump closures. Created once
    ## with `create`; the ORC refcounts of its string and closure fields are
    ## never released (the GC does not know the raw allocation), so they stay
    ## alive as long as the closure does.
    workspaceRoot: string
    emit: proc (event: string, payload: JsonNode): HookOutcome {.closure.}
    pump: Pump

const
  PollTimeoutMs = 5
  AbortGraceMs = 100
  MaxBytesPerTurn = 64 * 1024

func normalizeOutput(output: string): string =
  ## Match `execCmdEx`'s line-oriented output: CRLF becomes LF and a final
  ## unterminated line still ends with LF.
  var line = ""
  for character in output:
    if character == '\n':
      if line.len > 0 and line[^1] == '\r':
        line.setLen(line.len - 1)
      result.add(line)
      result.add('\n')
      line.setLen(0)
    else:
      line.add(character)
  if line.len > 0:
    result.add(line)
    result.add('\n')

when defined(posix):
  proc setNonBlocking(fd: FileHandle) =
    ## Make the child's output pipe readable without waiting for more bytes.
    let flags = posix.fcntl(fd, posix.F_GETFL)
    if flags < 0:
      raiseOSError(osLastError())
    if posix.fcntl(fd, posix.F_SETFL, flags or posix.O_NONBLOCK) < 0:
      raiseOSError(osLastError())

  proc readAvailable(fd: FileHandle, output: var string): bool =
    ## Read the bytes currently available, up to one turn's bounded budget.
    ## Returns true when the pipe reached EOF.
    var buffer: array[8192, char]
    var total = 0
    while total < MaxBytesPerTurn:
      let count = posix.read(fd, addr buffer[0], buffer.len)
      if count > 0:
        let chunk = newString(count)
        copyMem(addr chunk[0], addr buffer[0], count)
        output.add(chunk)
        total += count
      elif count == 0:
        return true
      else:
        let error = osLastError()
        if error == OSErrorCode(posix.EAGAIN) or
            error == OSErrorCode(posix.EWOULDBLOCK) or
            error == OSErrorCode(posix.EINTR):
          return false
        raiseOSError(error)
    result = false

  proc waitForReadable(fd: FileHandle) =
    ## Wait a bounded few milliseconds for the child's output pipe.
    var descriptors: posix.TFdSet = default(posix.TFdSet)
    posix.FD_ZERO(descriptors)
    posix.FD_SET(fd, descriptors)
    var timeout = posix.Timeval(tv_sec: posix.Time(0),
      tv_usec: posix.Suseconds(PollTimeoutMs * 1000))
    let ready = posix.select(cint(fd) + 1, addr descriptors, nil, nil, addr timeout)
    if ready < 0:
      let error = osLastError()
      if error != OSErrorCode(posix.EINTR):
        raiseOSError(error)

  proc establishProcessGroup(pid: posix.Pid): posix.Pid =
    ## Return the child's own process-group id, or zero when it could not be
    ## isolated. `poDaemon` creates the group atomically on POSIX; `setpgid`
    ## covers POSIX builds that use the fork path.
    if posix.getpgid(pid) == pid:
      return pid
    if posix.setpgid(pid, pid) == 0 and posix.getpgid(pid) == pid:
      return pid
    result = 0

  proc signalProcessGroup(pgid: posix.Pid, signalNumber: cint): bool =
    ## Signal the child's process group, ignoring an already-empty group.
    if pgid == 0:
      return false
    if posix.killpg(pgid, signalNumber) == 0:
      return true
    result = false

  proc signalProcess(pid: posix.Pid, signalNumber: cint): bool =
    ## Signal the shell itself as a fallback for the process-group signal.
    if posix.kill(pid, signalNumber) == 0:
      return true
    result = false

  proc terminateProcessTree(child: Process, pgid: posix.Pid): int =
    ## Stop the child group with SIGTERM, allow a short grace period, then
    ## force the group and shell with SIGKILL. Return the shell's exit code.
    let pid = posix.Pid(child.processID())
    discard signalProcessGroup(pgid, posix.SIGTERM)
    discard signalProcess(pid, posix.SIGTERM)
    os.sleep(AbortGraceMs)
    discard signalProcessGroup(pgid, posix.SIGKILL)
    discard signalProcess(pid, posix.SIGKILL)
    result = child.peekExitCode()
    while result == -1:
      os.sleep(PollTimeoutMs)
      result = child.peekExitCode()

proc runCommand*(command: string, workspaceRoot: string,
    pump: Pump = nil): tuple[output: string, code: int, aborted: bool] =
  ## Run `command` through `sh -c` in `workspaceRoot` without blocking the
  ## caller. The pump is consulted between output polls; an abort kills the
  ## child's process group and returns the partial output with `aborted = true`.
  ## A normal result carries the combined stdout/stderr and the exit code.
  result = (output: "", code: -1, aborted: false)
  when defined(posix):
    let child = startProcess(command, workingDir = workspaceRoot,
      options = {poEvalCommand, poStdErrToStdOut, poUsePath, poDaemon})
    try:
      let fd = child.outputHandle
      setNonBlocking(fd)
      let pgid = establishProcessGroup(posix.Pid(child.processID()))
      var eof = false
      var exited = false
      while true:
        if not eof:
          eof = readAvailable(fd, result.output)
        if not exited:
          let code = child.peekExitCode()
          if code != -1:
            exited = true
            result.code = code
        let abortRequested = pumpAbort(pump)
        if abortRequested and not exited:
          result.aborted = true
          result.code = terminateProcessTree(child, pgid)
          discard readAvailable(fd, result.output)
          break
        if eof and exited:
          break
        if eof:
          os.sleep(PollTimeoutMs)
        else:
          waitForReadable(fd)
    finally:
      child.close()
    if not result.aborted:
      result.output = normalizeOutput(result.output)
  else:
    let outcome = execCmdEx(command, workingDir = workspaceRoot)
    result.output = outcome.output
    result.code = outcome.exitCode

proc luaRun(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.process.run(cmd)`: fire the `process_run` hook, then
  ## execute the (possibly rewritten) command in the workspace root and push
  ## `{output = <stdout>, code = <exitCode>}`.
  let context = cast[ptr ProcessContext](lua_touserdata(L, luaUpvalueIndex(1)))
  if lua_gettop(L) != 1 or lua_type(L, 1) != luaTString:
    raiseLuaError(L, "neopi.process.run expects (cmd: string)")
  var command = $lua_tolstring(L, 1, nil)
  if not context.emit.isNil:
    let verdict = context.emit("process_run", %*{"cmd": command})
    if not verdict.allowed:
      raiseLuaError(L, verdict.reason)
    # Only a string rewrite applies; anything else runs the original command.
    if verdict.patched and not verdict.payload.isNil and
        verdict.payload.hasKey("cmd") and
        verdict.payload["cmd"].kind == JString:
      command = verdict.payload["cmd"].getStr
  var output = ""
  var code = -1
  var failure = ""
  try:
    let outcome = runCommand(command, context.workspaceRoot, context.pump)
    if outcome.aborted:
      # An abort is an error — the loop must not read a killed command as a
      # success — and the partial output is the only result that command ever
      # produced: it travels INSIDE the message instead of being dropped at this
      # boundary, which is what the record's abort semantics promise.
      failure = "process.run aborted"
      if outcome.output.len > 0:
        failure.add "\n" & outcome.output
    else:
      output = outcome.output
      code = outcome.code
  except OSError, IOError, ValueError:
    failure = "process.run failed: " & getCurrentExceptionMsg()
  if failure.len > 0:
    raiseLuaError(L, failure)
  lua_createtable(L, 0, 2)
  pushString(L, output)
  lua_setfield(L, -2, "output")
  lua_pushinteger(L, code.lua_Integer)
  lua_setfield(L, -2, "code")
  result = 1

const processRegistryKey = "neopi.process"

proc exposeProcess*(L: LuaState, workspaceRoot: string,
    emit: proc (event: string, payload: JsonNode): HookOutcome {.closure.} = nil,
    pump: Pump = nil) =
  ## Expose the `neopi.process` table inside the existing `neopi` table with
  ## the `run` op. The context (workspace root + emit + pump) travels as the
  ## closure's upvalue. With no `emit` wired, `run` executes freely — the
  ## trusted-code model. The optional pump is consulted between child-output
  ## polls. Requires `neopi` to exist (newHookBus creates it).
  let context = create(ProcessContext)
  context.workspaceRoot = workspaceRoot
  context.emit = emit
  context.pump = pump
  # The same holder in two places: the closure's upvalue (what `run` reads on
  # every call) and the Lua registry (what `setProcessPump` finds once the owner
  # of the frame exists, which is later than this assembly). One context, so a
  # pump installed afterwards reaches the op.
  setRegistryPointer(L, processRegistryKey, cast[pointer](context))
  lua_getfield(L, luaGlobalsIndex, "neopi")
  if lua_type(L, -1) != luaTTable:
    lua_pop(L, 1)
    raise LuaError.newException(
      "exposeProcess requires the neopi table (call newHookBus first)")
  lua_createtable(L, 0, 1)
  lua_pushlightuserdata(L, cast[pointer](context))
  lua_pushcclosure(L, luaRun, 1)
  lua_setfield(L, -2, "run")
  lua_setfield(L, -2, "process")
  lua_pop(L, 1)

proc setProcessPump*(L: LuaState, pump: Pump) =
  ## Install the pump the command runner hands control to between child-output
  ## polls. A no-op (never a crash) when the exposure never ran or the workspace
  ## root was empty, which is what the headless tests and print mode rely on.
  let context = cast[ptr ProcessContext](
    getRegistryPointer(L, processRegistryKey))
  if context.isNil:
    return
  context.pump = pump
{.pop.}
