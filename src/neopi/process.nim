## Spawn-per-call process primitive for neopi's extensibility.
##
## The `neopi.process` table gives extension scripts a `run(cmd)` primitive:
## it fires the `process_run` hook before executing (block or rewrite via the
## hook bus's emit, injected as a closure so this module stays cycle-free),
## then runs the command in the workspace root and returns
## `{output = <stdout>, code = <exitCode>}`.
##
## Trust model: scripts are trusted code. With no emit wired, `run` executes
## freely; the harness-level approval gate is a later concern. When an emit
## is wired, the `process_run` hook can block a command (its reason becomes a
## Lua error) or rewrite it before execution.

import std/[json, osproc]
import neopi/lua
from neopi/hooks import HookOutcome, lua_error

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
    ## workspace root and the injected emit closure. Created once with
    ## `create`; the ORC refcounts of its string and closure fields are never
    ## released (the GC does not know the raw allocation), so both stay alive
    ## as long as the closure does.
    workspaceRoot: string
    emit: proc (event: string, payload: JsonNode): HookOutcome {.closure.}

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
    let outcome = execCmdEx(command, workingDir = context.workspaceRoot)
    output = outcome.output
    code = outcome.exitCode
  except OSError, ValueError:
    failure = "process.run failed: " & getCurrentExceptionMsg()
  if failure.len > 0:
    raiseLuaError(L, failure)
  lua_createtable(L, 0, 2)
  pushString(L, output)
  lua_setfield(L, -2, "output")
  lua_pushinteger(L, code.lua_Integer)
  lua_setfield(L, -2, "code")
  result = 1

proc exposeProcess*(L: LuaState, workspaceRoot: string,
    emit: proc (event: string, payload: JsonNode): HookOutcome {.closure.} = nil) =
  ## Expose the `neopi.process` table inside the existing `neopi` table with
  ## the `run` op. The context (workspace root + emit) travels as the
  ## closure's upvalue. With no `emit` wired, `run` executes freely — the
  ## trusted-code model. Requires `neopi` to exist (newHookBus creates it).
  let context = create(ProcessContext)
  context.workspaceRoot = workspaceRoot
  context.emit = emit
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
{.pop.}
