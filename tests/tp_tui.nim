## Tests for the TUI over nimterm: the session-to-transcript adapter, the
## sessions listing, the /resume builtin with its menu, and the registry
## swap. The terminal itself is not tested here (the pty harness covers it
## end-to-end); these tests run without a terminal.
import std/[json, options, os, strutils, times]
import nimterm
import nimterm/transcript
import neopi/[extensibility, lua, provider, session]
import neopi/tui
import unittest2

# Same file-scope typedef as lua.nim: this module's generated C calls into
# the Lua state directly, and no C headers exist to declare the type.
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

proc freshWorkspace(name: string): string =
  result = getTempDir() / name
  createDir(result)

proc freshSessionPath(name: string): string =
  result = getTempDir() / ("neopi-tp-tui-" & name & ".jsonl")
  removeFile(result)

proc escapeLua(s: string): string =
  result = ""
  for c in s:
    case c
    of '\'', '\\': result.add "\\" & c
    else: result.add c

proc runtimeDir(): string =
  let fromBinary = getAppDir() / ".." / "runtime"
  if dirExists(fromBinary):
    return fromBinary
  result = "runtime"

proc loadRuntimeEntry(L: LuaState) =
  ## Load the runtime entry (init.lua): the command registry lands on the
  ## neopi table (the tp_register pattern). The production order loads the
  ## runtime before the user's config.
  let dir = runtimeDir()
  runScript(L, "package.path = '" &
    escapeLua(dir / "?.lua;" & dir / "?/init.lua") & ";' .. package.path")
  runScript(L, "require('init')")

suite "the transcript adapter":
  test "the session entries map onto nimterm's transcript items":
    let entries = @[
      SessionEntry(kind: ekUser, text: "hello"),
      SessionEntry(kind: ekAssistant, text: "hi", model: "m", provider: "p"),
      SessionEntry(kind: ekToolResult, toolCallId: "c1", toolName: "read",
        output: "content", isError: false),
      SessionEntry(kind: ekToolResult, toolCallId: "c2", toolName: "bash",
        output: "boom", isError: true),
      SessionEntry(kind: ekCompaction, summary: "the summary",
        firstKeptId: 1, tokensBefore: 100),
    ]
    var transcript = newTranscript()
    applySession(transcript, entries)
    check transcript.items.len == 5
    check transcript.items[0].kind == tikUser
    check transcript.items[0].text == "hello"
    check transcript.items[1].kind == tikAssistant
    check transcript.items[1].text == "hi"
    check transcript.items[2].kind == tikTool
    check transcript.items[2].title == "read"
    check transcript.items[2].text == "content"
    check not transcript.items[2].isError
    check transcript.items[3].kind == tikTool
    check transcript.items[3].isError
    check transcript.items[4].kind == tikStatus
    check transcript.items[4].title == "compaction"
    check transcript.items[4].text == "the summary"

  test "the aborted assistant entry maps with its text":
    let entries = @[SessionEntry(kind: ekAssistant, text: "partial",
      model: "m", provider: "p", stopReason: "aborted")]
    var transcript = newTranscript()
    applySession(transcript, entries)
    check transcript.items[0].kind == tikAssistant
    check transcript.items[0].text == "partial"

suite "the sessions list":
  test "listSessions sorts the newest first and labels with the first user entry":
    let root = freshWorkspace("neopi-tp-tui-sessions")
    try:
      createDir(root / ".neopi" / "sessions")
      let old = root / ".neopi" / "sessions" / "run-1.jsonl"
      let new = root / ".neopi" / "sessions" / "run-2.jsonl"
      writeFile(old, "{\"type\":\"user\",\"id\":1,\"text\":\"the old prompt\"}")
      writeFile(new, "{\"type\":\"user\",\"id\":1,\"text\":\"the new prompt\"}")
      setLastModificationTime(old, fromUnix(1000))
      setLastModificationTime(new, fromUnix(2000))
      let sessions = listSessions(root)
      check sessions.len == 2
      check sessions[0].value == new
      check sessions[0].label == "run-2 — the new prompt"
      check sessions[1].value == old
      check sessions[1].label == "run-1 — the old prompt"
    finally:
      removeDir(root)

  test "sessionLabel truncates and falls back to the file name":
    let root = freshWorkspace("neopi-tp-tui-label")
    try:
      createDir(root / ".neopi" / "sessions")
      let path = root / ".neopi" / "sessions" / "run-1.jsonl"
      writeFile(path, "{\"type\":\"user\",\"id\":1,\"text\":\"" & "x".repeat(50) &
        "\"}")
      check sessionLabel(path) == "run-1 — " & "x".repeat(40)
      writeFile(path, "{\"type\":\"assistant\",\"id\":1,\"text\":\"not a user entry\"}")
      check sessionLabel(path) == "run-1"
    finally:
      removeDir(root)

suite "the /resume builtin":
  test "sendTurn with /resume opens the sessions menu":
    let root = freshWorkspace("neopi-tp-tui-resume")
    let path = freshSessionPath("resume")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      var st = initTuiState("p", "m", sess, root)
      createDir(root / ".neopi" / "sessions")
      let old = root / ".neopi" / "sessions" / "run-1.jsonl"
      writeFile(old, "{\"type\":\"user\",\"id\":1,\"text\":\"an old session\"}")
      st.inputW.setText("/resume")
      sendTurn(addr st, ext.bus.state)
      # The builtin opened the menu with the workspace's sessions; the
      # input never entered the session.
      check not st.menu.isNil
      check st.menu.items.len == 1
      check st.inputW.text == ""
    finally:
      removeDir(root)
      removeFile(path)

suite "resumeSession":
  test "the swap rebinds the session and the registry pointer":
    let root = freshWorkspace("neopi-tp-tui-swap")
    let path = freshSessionPath("swap")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess, root)
      createDir(root / ".neopi" / "sessions")
      let picked = root / ".neopi" / "sessions" / "run-9.jsonl"
      writeFile(picked, "{\"type\":\"user\",\"id\":1,\"parentId\":null,\"timestamp\":\"2026-01-01T00:00:00Z\",\"text\":\"the picked prompt\"}")
      resumeSession(addr st, L, picked)
      # The swap: the state's session is the picked one (the cfunctions read
      # the pointer dynamically), the menu closed, the transcript rebuilt.
      check st.menu.isNil
      check st.sess.history().len == 1
      check st.sess.entries[0].text == "the picked prompt"
      check evalJson(L, "return neopi.session:history()").len == 1
    finally:
      removeDir(root)
      removeFile(path)

suite "the / command dispatch":
  test "a registered command runs and its output lands in the transcript":
    let root = freshWorkspace("neopi-tp-tui-cmd")
    let path = freshSessionPath("cmd")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess, root)
      exposeUi(L)
      loadRuntimeEntry(L)
      runScript(L, """
        neopi.registerCommand('echo', 'echo the args', function(args)
          return 'echoed: ' .. args
        end)
      """)
      st.inputW.setText("/echo hi")
      sendTurn(addr st, L)
      # The command ran: its output landed as a status line in the
      # transcript; no user entry landed.
      var texts: seq[string] = @[]
      for item in st.transcriptW.transcript.items:
        texts.add item.text
      check "echoed: hi" in texts
      check st.inputW.text == ""
      check sess.history().len == 0
    finally:
      removeDir(root)
      removeFile(path)

  test "an unknown command is feedback without quitting":
    let root = freshWorkspace("neopi-tp-tui-cmd2")
    let path = freshSessionPath("cmd2")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess, root)
      exposeUi(L)
      loadRuntimeEntry(L)
      st.inputW.setText("/nosuch")
      sendTurn(addr st, L)
      # A command failure is feedback in the transcript, not a crash: the
      # TUI survives, no user entry landed.
      check not st.quit
      check st.transcriptW.transcript.items.len == 1
      check st.transcriptW.transcript.items[0].kind == tikStatus
      check "unknown command /nosuch" in st.transcriptW.transcript.items[0].text
      check sess.history().len == 0
    finally:
      removeDir(root)
      removeFile(path)

suite "the turn drive":
  test "sendTurn drives one turn at a time: the tool result and the final text land":
    let root = freshWorkspace("neopi-tp-tui-drive")
    let path = freshSessionPath("drive")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess, root)
      exposeUi(L)
      loadRuntimeEntry(L)
      exposeTuiSink(L, addr st, "scripted")
      # The scripted provider: the first turn answers with a write tool
      # call, the second with the final text. The TUI drives one turn per
      # evalJson; the sink binds the model and exercises the stream path
      # (the headless state has no app — feedKeys and flushFrame guard it).
      runScript(L, """
        neopi.provider.setScripted({
          {toolCalls = {{id = "call-1", name = "write",
            args = {path = "drive.txt", content = "one"}}}},
          {text = "second turn"},
        })
      """)
      st.inputW.setText("go")
      sendTurn(addr st, L)
      # The drive ran two turns: user, assistant (toolUse), toolResult,
      # assistant (final). The write tool ran through the confined
      # primitives inside the first turn.
      check sess.history().len == 4
      check readFile(root / "drive.txt") == "one"
      # The transcript rebuilt from the session: every entry renders.
      check st.transcriptW.transcript.items.len == 4
    finally:
      removeDir(root)
      removeFile(path)

  test "turnContinues: the engine's continueLoop or steering queued in the gap":
    check turnContinues(parseJson("{\"continueLoop\":true}"), false)
    check not turnContinues(parseJson("{\"continueLoop\":false}"), false)
    check turnContinues(parseJson("{\"continueLoop\":false}"), true)
    check not turnContinues(parseJson("{}"), false)
    check not turnContinues(newJNull(), false)
