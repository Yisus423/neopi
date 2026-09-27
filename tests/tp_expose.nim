## Tests for the exposure: the Lua-callable neopi.provider and neopi.session
## tables on the extensibility's state. No API key or network: the provider
## tests use the scripted swap (the nimgent scriptedModel pattern).
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
  result = getTempDir() / ("neopi-tp-expose-" & name & ".jsonl")
  removeFile(result)

suite "exposure provider":
  test "generate surfaces the scripted response and the tool calls":
    let root = freshWorkspace("neopi-tp-expose-provider")
    let path = freshSessionPath("provider")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      runScript(L, """
        neopi.provider.setScripted({
          {toolCalls = {{id = "call-1", name = "echo", args = {a = 1}}}},
          {text = "done"},
        })
      """)
      let response = evalJson(L, """
        return neopi.provider.generate({
          model = "scripted",
          messages = {{role = "user", text = "go"}},
          tools = {{name = "echo", description = "echo",
            schema = {type = "object", properties = {}},
            execute = function(args) return tostring(args.a) end}},
        })
      """)
      # One generate call is one model turn: the scripted provider answers
      # the first request with its tool call and the second with its text.
      check response["stopReason"].getStr == "toolUse"
      check response["text"].getStr == ""
      check response["toolCalls"].len == 1
      check response["toolCalls"][0]["id"].getStr == "call-1"
      check response["provider"].getStr == "fake"
      let second = evalJson(L, """
        return neopi.provider.generate({
          model = "scripted",
          messages = {{role = "user", text = "go"}},
        })
      """)
      check second["text"].getStr == "done"
      check second["stopReason"].getStr == "stop"
      check second["toolCalls"].len == 0
      check second["usage"]["input"].getInt == 0
      check second["usage"]["output"].getInt == 0
    finally:
      removeDir(root)
      removeFile(path)

  test "generate surfaces a tool-call response with stopReason toolUse":
    let root = freshWorkspace("neopi-tp-expose-toolcall")
    let path = freshSessionPath("toolcall")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      runScript(L, """
        neopi.provider.setScripted({
          {toolCalls = {{id = "call-1", name = "echo",
            args = {a = 1, note = "hi"}}}},
        })
      """)
      let response = evalJson(L, """
        return neopi.provider.generate({
          model = "scripted",
          messages = {{role = "user", text = "go"}},
          tools = {{name = "echo", description = "echo",
            schema = {type = "object", properties = {}},
            execute = function(args) return "unused" end}},
        })
      """)
      check response["stopReason"].getStr == "toolUse"
      check response["text"].getStr == ""
      let calls = response["toolCalls"]
      check calls.len == 1
      check calls[0]["id"].getStr == "call-1"
      check calls[0]["name"].getStr == "echo"
      check calls[0]["args"]["a"].getInt == 1
      check calls[0]["args"]["note"].getStr == "hi"
    finally:
      removeDir(root)
      removeFile(path)

  test "generate without a backing raises a lua error":
    let ext = newExtensibility("")
    expect LuaError:
      runScript(ext.bus.state,
        "return neopi.provider.generate({model = 'm', messages = {}})")

  test "generate with an invalid config raises a lua error":
    let root = freshWorkspace("neopi-tp-expose-badconfig")
    let path = freshSessionPath("badconfig")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      runScript(L, "neopi.provider.setScripted({{text = 'done'}})")
      expect LuaError:
        runScript(L, "return neopi.provider.generate({messages = {}})")
      expect LuaError:
        runScript(L, "return neopi.provider.generate({model = 'm'})")
      expect LuaError:
        runScript(L, "return neopi.provider.generate({model = 'm', " &
          "messages = {{role = 'bogus', text = 'x'}}})")
    finally:
      removeDir(root)
      removeFile(path)

suite "exposure session":
  test "session wrap: append, history, and navigate":
    let root = freshWorkspace("neopi-tp-expose-session")
    let path = freshSessionPath("session")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      runScript(L, """
        neopi.session:append("user", {text = "hello"})
        neopi.session:append("assistant", {text = "hi", model = "m1",
          provider = "p1", usageInput = 1, usageOutput = 2,
          stopReason = "endTurn"})
        neopi.session:navigate(1)
        neopi.session:append("user", {text = "retry"})
      """)
      let history = evalJson(L, "return neopi.session:history()")
      check history.len == 2
      check history[0]["type"].getStr == "user"
      check history[0]["text"].getStr == "hello"
      check history[1]["type"].getStr == "user"
      check history[1]["text"].getStr == "retry"
      # The wrapped session persists: the file reloads with all three entries
      # and the active branch is the navigated path.
      let reopened = newSession(path)
      check reopened.entries.len == 3
      check reopened.entries[1].model == "m1"
      check reopened.entries[1].provider == "p1"
      check reopened.entries[1].usageInput == 1
      check reopened.entries[1].usageOutput == 2
      check reopened.entries[1].stopReason == "endTurn"
      check reopened.currentId == 3
      check reopened.history().len == 2
      check reopened.history()[1].text == "retry"
    finally:
      removeDir(root)
      removeFile(path)

  test "session append validates the kind and the payload":
    let root = freshWorkspace("neopi-tp-expose-append")
    let path = freshSessionPath("append")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      expect LuaError:
        runScript(L, "neopi.session:append('bogus', {})")
      expect LuaError:
        runScript(L, "neopi.session:append('user', {})")
      expect LuaError:
        runScript(L, "neopi.session:append('toolResult', {toolCallId = 'c'})")
      # The valid kinds append and land in the session.
      runScript(L, """
        neopi.session:append("toolResult", {toolCallId = "call-1",
          toolName = "bash", output = "out", isError = true})
      """)
      let history = evalJson(L, "return neopi.session:history()")
      check history.len == 1
      check history[0]["type"].getStr == "toolResult"
      check history[0]["isError"].getBool
    finally:
      removeDir(root)
      removeFile(path)

  test "session navigate to an unknown id raises a lua error":
    let root = freshWorkspace("neopi-tp-expose-navigate")
    let path = freshSessionPath("navigate")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      runScript(L, "neopi.session:append('user', {text = 'only'})")
      expect LuaError:
        runScript(L, "neopi.session:navigate(9)")
    finally:
      removeDir(root)
      removeFile(path)
