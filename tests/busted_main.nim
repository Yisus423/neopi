## The test-only busted runner: runs the Lua specs inside a live Lua state
## with the core exposed (the nvim pattern: the specs run in the host). This
## binary is built and invoked by the test infrastructure (neopi.nimble's
## test task); the production binary (src/neopi.nim) never ships a spec mode.
## The state assembles unhardened here — busted's runner needs io, os, debug,
## and the ffi preload; the production posture stays hardened.
## Usage: ./build/busted_main <spec file or directory>
import std/[options, os, strutils, times]
import neopi/[extensibility, lua, provider, session]

# Same file-scope typedef as lua.nim and the bridge modules: no C headers
# exist to declare the opaque state type, and this file's generated C
# prototypes take it.
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

func escapeLua(s: string): string =
  ## Escape a string for a single-quoted Lua literal: only the quote and the
  ## backslash need escaping there.
  result = ""
  for c in s:
    case c
    of '\'', '\\': result.add "\\" & c
    else: result.add c

proc runtimeDir(): string =
  ## The Lua runtime directory: $NEOPI_RUNTIME_DIR when set, else
  ## <binary dir>/../runtime (a build from the repo), else ./runtime.
  let env = getEnv("NEOPI_RUNTIME_DIR")
  if env.len > 0:
    return env
  let fromBinary = getAppDir() / ".." / "runtime"
  if dirExists(fromBinary):
    return fromBinary
  result = "runtime"

proc loadRuntime(L: LuaState) =
  ## Extend package.path with the runtime directory and load the runtime
  ## entry.
  let dir = runtimeDir()
  if not fileExists(dir / "init.lua"):
    stderr.writeLine("busted_main: runtime entry not found: " &
      dir / "init.lua" & " (set NEOPI_RUNTIME_DIR)")
    quit(1)
  let chunk = "package.path = '" &
    escapeLua(dir / "?.lua;" & dir / "?/init.lua") & ";' .. package.path"
  try:
    runScript(L, chunk, "runtime-path")
  except LuaError as e:
    stderr.writeLine("busted_main: cannot extend the lua paths: " & e.msg)
    quit(1)
  var source = ""
  try:
    source = readFile(dir / "init.lua")
  except OSError, IOError:
    stderr.writeLine("busted_main: cannot read " & dir / "init.lua")
    quit(1)
  try:
    runScript(L, source, "runtime/init.lua")
  except LuaError as e:
    stderr.writeLine("busted_main: the runtime failed to load: " & e.msg)
    quit(1)

proc main() =
  let specs = block:
    let params = commandLineParams()
    if params.len == 0:
      stderr.writeLine("Usage: ./build/busted_main <spec file or directory>")
      quit(1)
    params[0]
  let stamp = ($epochTime()).replace(".", "-")
  let workspace = getTempDir() / ("neopi-spec-" & stamp)
  try:
    createDir(workspace)
  except OSError, IOError:
    stderr.writeLine("busted_main: cannot create the workspace: " &
      getCurrentExceptionMsg())
    quit(1)
  let sessionPath = workspace / "session.jsonl"
  let s = try: newSession(sessionPath)
    except CatchableError as e:
      stderr.writeLine("busted_main: cannot open the spec session: " & e.msg)
      quit(1)
  let ext = newExtensibility(workspace, none(Provider), s, hardened = false)
  let L = ext.bus.state
  # Extend package.path/cpath with the runtime directory and the luarocks
  # local tree (the standard luarock layout: pure-Lua modules under
  # ~/.luarocks/share/lua/5.1, C modules under ~/.luarocks/lib/lua/5.1).
  let share = getHomeDir() / ".luarocks" / "share" / "lua" / "5.1"
  let lib = getHomeDir() / ".luarocks" / "lib" / "lua" / "5.1"
  let pathChunk = "package.path = '" &
    escapeLua(runtimeDir() / "?.lua;" & runtimeDir() / "?/init.lua" & ";" &
      share / "?.lua;" & share / "?/init.lua") & ";' .. package.path"
  let cpathChunk = "package.cpath = '" &
    escapeLua(lib / "?.so") & ";' .. package.cpath"
  try:
    runScript(L, pathChunk, "runtime-path")
    runScript(L, cpathChunk, "runtime-cpath")
    runScript(L, "arg = {'busted', '" & escapeLua(specs) & "'}", "spec-args")
  except LuaError as e:
    stderr.writeLine("busted_main: cannot prepare the spec environment: " & e.msg)
    quit(1)
  loadRuntime(L)
  # busted's standalone runner exits the process with its own code —
  # standalone = false would raise a Lua error instead (Lua 5.1's os.exit
  # cannot force), which the containment catches and a success exit would
  # mask spec failures.
  try:
    runScript(L, "require('busted.runner')({ standalone = true })", "spec-runner")
  except LuaError as e:
    stderr.writeLine("busted_main: the spec runner failed: " & e.msg)
    quit(1)
  # Control returns only when busted did not exit the process; treat the
  # non-exit path as success.
  try:
    removeDir(workspace)
  except OSError:
    discard

when isMainModule:
  main()
