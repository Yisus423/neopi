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

proc loadAgentLoop(L: LuaState) =
  ## Extend package.path with the runtime directory and load the agent loop
  ## into the global `agent` (the runtime layer's loop-in-Lua pattern).
  let dir = runtimeDir()
  runScript(L, "package.path = '" &
    escapeLua(dir / "?.lua;" & dir / "?/init.lua") & ";' .. package.path")
  runScript(L, "agent = require('agent')")

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

  test "setScripted steps carry usage for the compaction trigger":
    let root = freshWorkspace("neopi-tp-expose-usage")
    let path = freshSessionPath("usage")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      runScript(L, """
        neopi.provider.setScripted({
          {text = "big reply", usageInput = 900},
          {toolCalls = {{id = "call-1", name = "echo", args = {a = 1}}},
           usageInput = 500},
          {text = "plain"},
        })
      """)
      let first = evalJson(L, """
        return neopi.provider.generate({model = "scripted",
          messages = {{role = "user", text = "go"}}})
      """)
      check first["text"].getStr == "big reply"
      check first["usage"]["input"].getInt == 900
      let second = evalJson(L, """
        return neopi.provider.generate({model = "scripted",
          messages = {{role = "user", text = "go"}}})
      """)
      check second["stopReason"].getStr == "toolUse"
      check second["usage"]["input"].getInt == 500
      let third = evalJson(L, """
        return neopi.provider.generate({model = "scripted",
          messages = {{role = "user", text = "go"}}})
      """)
      check third["text"].getStr == "plain"
      check third["usage"]["input"].getInt == 0
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

  test "session append compaction kind lands and persists":
    let root = freshWorkspace("neopi-tp-expose-compaction")
    let path = freshSessionPath("compaction")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      # The first-missing contract: a partial payload is rejected.
      expect LuaError:
        runScript(L, "neopi.session:append('compaction', {summary = 's'})")
      runScript(L, """
        neopi.session:append("compaction", {summary = "did stuff",
          firstKeptId = 1, tokensBefore = 900})
      """)
      let history = evalJson(L, "return neopi.session:history()")
      check history.len == 1
      check history[0]["type"].getStr == "compaction"
      check history[0]["summary"].getStr == "did stuff"
      check history[0]["firstKeptId"].getInt == 1
      check history[0]["tokensBefore"].getInt == 900
      # The wrapped session persists: the file reloads with the entry intact.
      let reopened = newSession(path)
      check reopened.entries.len == 1
      check reopened.entries[0].kind == ekCompaction
      check reopened.entries[0].summary == "did stuff"
      check reopened.entries[0].firstKeptId == 1
      check reopened.entries[0].tokensBefore == 900
    finally:
      removeDir(root)
      removeFile(path)

  test "the agent loop compacts with a small scripted window":
    let root = freshWorkspace("neopi-tp-expose-loopcompact")
    let path = freshSessionPath("loopcompact")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      loadAgentLoop(L)
      # The scripted window: the echo tool call reports a large input, so the
      # trigger fires after the first turn's tool results; the summary request
      # consumes the second step and the final turn the third.
      runScript(L, """
        neopi.provider.setScripted({
          {toolCalls = {{id = "call-1", name = "echo", args = {text = "x"}}},
           usageInput = 950},
          {text = "Summary: the user said go; an echo call failed."},
          {text = "done"},
        })
      """)
      runScript(L, "neopi.session:append('user', {text = 'go'})")
      let response = evalJson(L, """
        return agent.run(neopi.session, {model = "scripted",
          contextWindow = 1000, reserveTokens = 100, keepRecentTokens = 200})
      """)
      check response["text"].getStr == "done"
      check response["stopReason"].getStr == "stop"
      # The compaction entry landed after the first turn's tool results: the
      # history holds user, assistant (toolUse), toolResult, compaction,
      # assistant (final text).
      let history = evalJson(L, "return neopi.session:history()")
      check history.len == 5
      check history[3]["type"].getStr == "compaction"
      check history[3]["summary"].getStr ==
        "Summary: the user said go; an echo call failed."
      check history[3]["tokensBefore"].getInt == 950
      # firstKeptId points at a kept entry: the toolUse assistant (id 2).
      check history[3]["firstKeptId"].getInt == 2
      check history[1]["id"].getInt == 2
      check history[1]["type"].getStr == "assistant"
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

  test "stream surfaces the deltas and the response":
    let root = freshWorkspace("neopi-tp-expose-stream")
    let path = freshSessionPath("stream")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      runScript(L, "deltas = {}")
      runScript(L,
        "onEvent = function(e) deltas[#deltas + 1] = e.text; return true end")
      runScript(L, "neopi.provider.setScripted({{text = 'streamed answer'}})")
      let response = evalJson(L, """
        return neopi.provider.stream({
          model = "scripted",
          messages = {{role = "user", text = "go"}},
        }, onEvent)
      """)
      check response["text"].getStr == "streamed answer"
      let landed = evalJson(L, "return deltas")
      check landed.len == 1
      check landed[0].getStr == "streamed answer"
    finally:
      removeDir(root)
      removeFile(path)

  test "stream without onEvent behaves like generate":
    let root = freshWorkspace("neopi-tp-expose-stream2")
    let path = freshSessionPath("stream2")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      runScript(L, "neopi.provider.setScripted({{text = 'plain answer'}})")
      let response = evalJson(L, """
        return neopi.provider.stream({
          model = "scripted",
          messages = {{role = "user", text = "go"}},
        }, function(e) return true end)
      """)
      check response["text"].getStr == "plain answer"
    finally:
      removeDir(root)
      removeFile(path)

  test "stream cancel returns the partial response":
    let root = freshWorkspace("neopi-tp-expose-abort")
    let path = freshSessionPath("abort")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      runScript(L, "deltas = {}")
      runScript(L,
        "onEvent = function(e) deltas[#deltas + 1] = e.text; return false end")
      runScript(L, "neopi.provider.setScripted({{text = 'streamed answer'}})")
      # The onEvent returns false on the first delta: the cancel surfaces as
      # a partial response (the accumulated delta with the aborted stop
      # reason), not as a Lua error.
      let response = evalJson(L, """
        return neopi.provider.stream({
          model = "scripted",
          messages = {{role = "user", text = "go"}},
        }, onEvent)
      """)
      check response["text"].getStr == "streamed answer"
      check response["stopReason"].getStr == "aborted"
      let landed = evalJson(L, "return deltas")
      check landed.len == 1
      check landed[0].getStr == "streamed answer"
    finally:
      removeDir(root)
      removeFile(path)
