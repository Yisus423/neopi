## Tests for the registerTool slice: the runtime registry, the generate
## merge, and the executeCall fallback. No API key or network: the provider
## tests use the scripted swap (the nimgent scriptedModel pattern). The
## runtime entry (init.lua) loads the registry onto the neopi table.
import std/[json, options, os]
import neopi/[extensibility, lua, provider, session]
import unittest2

# Same file-scope typedef as lua.nim: this module's generated C calls into
# the Lua state directly, and no C headers exist to declare the type.
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

proc freshWorkspace(name: string): string =
  ## A fresh subdirectory of the temp dir as a workspace root.
  result = getTempDir() / name
  createDir(result)

proc freshSessionPath(name: string): string =
  ## A fresh temp session file path per test.
  result = getTempDir() / ("neopi-tp-register-" & name & ".jsonl")
  removeFile(result)

proc escapeLua(s: string): string =
  ## Escape a string for a single-quoted Lua literal: only the quote and the
  ## backslash need escaping there.
  result = ""
  for c in s:
    case c
    of '\'', '\\': result.add "\\" & c
    else: result.add c

proc runtimeDir(): string =
  ## The Lua runtime directory: <binary dir>/../runtime (a build from the
  ## repo), else ./runtime.
  let fromBinary = getAppDir() / ".." / "runtime"
  if dirExists(fromBinary):
    return fromBinary
  result = "runtime"

proc loadRuntime(L: LuaState) =
  ## Extend package.path with the runtime directory and load the runtime
  ## entry (init.lua), which requires the agent loop and registers
  ## neopi.registerTool / neopi.registeredTools on the neopi table. The
  ## global `agent` holds the loop for the agent.run calls.
  let dir = runtimeDir()
  runScript(L, "package.path = '" &
    escapeLua(dir / "?.lua;" & dir / "?/init.lua") & ";' .. package.path")
  runScript(L, "agent = require('agent')")
  runScript(L, "require('init')")

proc countRegistryFunctions(L: LuaState): int =
  ## Count the function values stored in the Lua registry (the luaL_ref
  ## slots): the unref's observable. The registry also holds the pointer
  ## keys (lightuserdata values under string keys), which do not count.
  lua_pushnil(L)
  while lua_next(L, luaRegistryIndex) != 0:
    if lua_type(L, -1) == luaTFunction:
      inc result
    lua_pop(L, 1)

suite "registered tools":
  test "registerTool validates its arguments":
    let root = freshWorkspace("neopi-tp-register-validate")
    let path = freshSessionPath("validate")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      loadRuntime(L)
      # A missing argument, a non-function execute, and a non-table schema
      # all raise the clear Lua error.
      expect LuaError:
        runScript(L, "neopi.registerTool('name', 'desc', {})")
      expect LuaError:
        runScript(L, "neopi.registerTool('name', 'desc', {}, 'nope')")
      expect LuaError:
        runScript(L, "neopi.registerTool('name', 'desc', 'schema', " &
          "function() end)")
      # A valid registration lands in the registry with its four fields.
      runScript(L, "neopi.registerTool('ok', 'a tool', {}, " &
        "function() return 'x' end)")
      let tools = evalJson(L, "return neopi.registeredTools()")
      check tools.len == 1
      check tools[0]["name"].getStr == "ok"
      check tools[0]["description"].getStr == "a tool"
    finally:
      removeDir(root)
      removeFile(path)

  test "the generate sees the registered tool and the loop executes it":
    let root = freshWorkspace("neopi-tp-register-generate")
    let path = freshSessionPath("generate")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      loadRuntime(L)
      # The registered tool with a marker: the execute counts its runs in a
      # global the test reads back.
      runScript(L, """
        neopi.registerTool("reg_tool", "a registered tool",
          {type = "object", properties = {}},
          function(args) regRan = (regRan or 0) + 1
            return "registered ran" end)
      """)
      # The generate with NO config tools key: the response's toolCalls
      # reference the registered tool (the scripted provider echoes its
      # step; the merge put the tool in the list the model sees).
      runScript(L, """
        neopi.provider.setScripted({
          {toolCalls = {{id = "call-1", name = "reg_tool", args = {a = 1}}}},
        })
      """)
      let response = evalJson(L, """
        return neopi.provider.generate({
          model = "scripted",
          messages = {{role = "user", text = "go"}},
        })
      """)
      check response["stopReason"].getStr == "toolUse"
      check response["toolCalls"].len == 1
      check response["toolCalls"][0]["name"].getStr == "reg_tool"
      check response["toolCalls"][0]["args"]["a"].getInt == 1
      check evalString(L, "return tostring(regRan)") == "nil"
      # The execution: the loop's fallback runs the registered execute, and
      # the session records the result.
      runScript(L, """
        neopi.provider.setScripted({
          {toolCalls = {{id = "call-2", name = "reg_tool", args = {a = 2}}}},
          {text = "done"},
        })
      """)
      runScript(L, "neopi.session:append('user', {text = 'go'})")
      let final = evalJson(L, """
        return agent.run(neopi.session, {model = "scripted", maxSteps = 4})
      """)
      check final["text"].getStr == "done"
      check evalString(L, "return tostring(regRan)") == "1"
      let history = evalJson(L, "return neopi.session:history()")
      check history.len == 4
      check history[2]["type"].getStr == "toolResult"
      check history[2]["toolName"].getStr == "reg_tool"
      check history[2]["output"].getStr == "registered ran"
      check history[2]["isError"].getBool == false
    finally:
      removeDir(root)
      removeFile(path)

  test "the merge includes the config tools and the registered ones":
    let root = freshWorkspace("neopi-tp-register-merge")
    let path = freshSessionPath("merge")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      loadRuntime(L)
      runScript(L, """
        neopi.registerTool("reg_tool", "a registered tool",
          {type = "object", properties = {}},
          function(args) regRan = (regRan or 0) + 1 return "reg ran" end)
      """)
      # The scripted model calls BOTH a runtime tool and the registered one;
      # the loop executes each through its own path.
      runScript(L, "neopi.fs.write('input.txt', 'the content')")
      runScript(L, """
        neopi.provider.setScripted({
          {toolCalls = {
            {id = "call-1", name = "read", args = {path = "input.txt"}},
            {id = "call-2", name = "reg_tool", args = {}},
          }},
          {text = "done"},
        })
      """)
      runScript(L, "neopi.session:append('user', {text = 'go'})")
      let response = evalJson(L, """
        return agent.run(neopi.session, {model = "scripted", maxSteps = 4})
      """)
      check response["text"].getStr == "done"
      check evalString(L, "return tostring(regRan)") == "1"
      let history = evalJson(L, "return neopi.session:history()")
      check history.len == 5
      check history[2]["toolName"].getStr == "read"
      check history[2]["output"].getStr == "the content"
      check history[3]["toolName"].getStr == "reg_tool"
      check history[3]["output"].getStr == "reg ran"
    finally:
      removeDir(root)
      removeFile(path)

  test "the registry does not grow per generate call":
    let root = freshWorkspace("neopi-tp-register-stable")
    let path = freshSessionPath("stable")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      loadRuntime(L)
      runScript(L, """
        neopi.registerTool("reg_tool", "a registered tool",
          {type = "object", properties = {}},
          function(args) regRan = (regRan or 0) + 1
            return "registered ran" end)
      """)
      # The baseline: the registry's function refs before any generate.
      let baseline = countRegistryFunctions(L)
      for i in 1 .. 2:
        runScript(L, "neopi.provider.setScripted(" &
          "{{toolCalls = {{id = 'c" & $i & "', name = 'reg_tool', " &
          "args = {}}}}, {text = 'done " & $i & "'}})")
        runScript(L, "neopi.session:append('user', {text = 'go'})")
        let response = evalJson(L, """
          return agent.run(neopi.session, {model = "scripted", maxSteps = 4})
        """)
        check response["text"].getStr == "done " & $i
      # Two generate calls: the marker fired once per call and the
      # registry's function refs returned to the baseline (the refs are
      # unref'd after each response).
      check evalString(L, "return tostring(regRan)") == "2"
      check countRegistryFunctions(L) == baseline
    finally:
      removeDir(root)
      removeFile(path)
