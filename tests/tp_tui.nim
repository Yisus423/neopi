## Tests for the TUI's pure render layer: the transcript's line building,
## text wrapping, the composer's editing state, the footer, and the scroll
## window — all without a terminal.
import std/[json, options, os, strutils, times]
import illwill
import neopi/[extensibility, lua, provider, session]
import neopi/tui
import unittest2

# Same file-scope typedef as lua.nim and the bridge modules: this module's
# generated C calls into the Lua state directly (the sink tests), and no C
# headers exist to declare the type.
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

suite "wrapLine":
  test "short lines pass through":
    check wrapLine("hello", 80) == @["hello"]

  test "empty line":
    check wrapLine("", 40) == @[""]

  test "width below 1 returns the line unwrapped":
    check wrapLine("hello world", 0) == @["hello world"]
    check wrapLine("hello world", -3) == @["hello world"]

  test "word wrap breaks on the last space before the limit":
    check wrapLine("alpha beta gamma", 9) == @["alpha", "beta", "gamma"]

  test "hard break mid-word when there is no space":
    check wrapLine("abcdefghijkl", 5) == @["abcde", "fghij", "kl"]

  test "the break space is consumed":
    check wrapLine("aaa bbb", 4) == @["aaa", "bbb"]

suite "transcriptLines":
  test "the kind prefixes":
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
    check transcriptLines(entries) == @[
      "you: hello",
      "assistant: hi",
      "tool read: content",
      "tool bash (error): boom",
      "-- compaction: the summary",
    ]

  test "newlines split into separate lines":
    let entries = @[SessionEntry(kind: ekUser, text: "line one\nline two")]
    check transcriptLines(entries) == @["you: line one", "line two"]

  test "aborted assistant turns mark their partial text":
    let entries = @[SessionEntry(kind: ekAssistant, text: "partial",
      model: "m", provider: "p", stopReason: "aborted")]
    check transcriptLines(entries) == @["assistant: partial (aborted)"]

suite "lineColor":
  test "the prefix decides":
    check lineColor("you: hello") == fgGreen
    check lineColor("assistant: hi") == fgNone
    check lineColor("tool read: content") == fgCyan
    check lineColor("tool bash (error): boom") == fgRed
    check lineColor("-- compaction: the summary") == fgMagenta
    check lineColor("anything else") == fgNone

suite "streamingLines":
  test "the assistant prefix with the in-flight text":
    check streamingLines("delta text") == @["assistant: delta text"]

suite "usageTotals":
  test "the cumulative sums over the assistant entries":
    let entries = @[
      SessionEntry(kind: ekUser, text: "q"),
      SessionEntry(kind: ekAssistant, text: "a", model: "m", provider: "p",
        usageInput: 12, usageOutput: 34),
      SessionEntry(kind: ekAssistant, text: "b", model: "m", provider: "p",
        usageInput: 5, usageOutput: 7),
      SessionEntry(kind: ekToolResult, toolCallId: "c", toolName: "read",
        output: "x", isError: false),
    ]
    let (tokensIn, tokensOut) = usageTotals(entries)
    check tokensIn == 17
    check tokensOut == 41

suite "footerLine":
  test "the format":
    check footerLine("openrouter", "m1", 17, 41) ==
      "openrouter/m1 | in 17 | out 41"

suite "visibleRange":
  test "offset 0 follows the bottom":
    let r = visibleRange(20, 5, 0)
    check r.a == 15
    check r.b == 19

  test "larger offsets scroll toward the top and clamp":
    check visibleRange(20, 5, 10).a == 5
    check visibleRange(20, 5, 10).b == 9
    check visibleRange(20, 5, 999).a == 0
    check visibleRange(20, 5, 999).b == 4

  test "empty ranges":
    check visibleRange(0, 5, 0).b < visibleRange(0, 5, 0).a
    check visibleRange(20, 0, 0).b < visibleRange(20, 0, 0).a

suite "composer state":
  test "insert at the cursor moves the cursor past it":
    var c = ComposerState()
    composerInsert(c, "hel")
    composerInsert(c, "lo")
    check c.text == "hello"
    check c.cursor == 5

  test "insert mid-string":
    var c = ComposerState(text: "helo", cursor: 3)
    composerInsert(c, "l")
    check c.text == "hello"
    check c.cursor == 4

  test "backspace deletes before the cursor":
    var c = ComposerState(text: "hello", cursor: 5)
    composerBackspace(c)
    check c.text == "hell"
    check c.cursor == 4

  test "backspace at the start is a no-op":
    var c = ComposerState(text: "hi", cursor: 0)
    composerBackspace(c)
    check c.text == "hi"
    check c.cursor == 0

  test "left and right move the cursor within bounds":
    var c = ComposerState(text: "abc", cursor: 0)
    composerLeft(c)
    check c.cursor == 0
    composerRight(c)
    check c.cursor == 1
    composerRight(c)
    composerRight(c)
    check c.cursor == 3
    composerRight(c)
    check c.cursor == 3

  test "clear resets both":
    var c = ComposerState(text: "text", cursor: 4)
    composerClear(c)
    check c.text == ""
    check c.cursor == 0

suite "handleKey":
  test "Esc clears the composer":
    var st = initTuiState("p", "m", nil)
    st.composer = ComposerState(text: "text", cursor: 4)
    handleKey(st, Key.Escape, 24)
    check st.composer.text == ""

  test "printable keys insert":
    var st = initTuiState("p", "m", nil)
    handleKey(st, Key(104), 24)
    handleKey(st, Key(105), 24)
    check st.composer.text == "hi"

  test "the scroll keys move the offset":
    var st = initTuiState("p", "m", nil)
    handleKey(st, Key.PageUp, 24)
    check st.scrollOffset == pageStep(24)
    handleKey(st, Key.PageDown, 24)
    check st.scrollOffset == 0
    handleKey(st, Key.Up, 24)
    check st.scrollOffset == 1
    handleKey(st, Key.Down, 24)
    check st.scrollOffset == 0
    handleKey(st, Key.Down, 24)
    check st.scrollOffset == 0

  test "Enter and CtrlC are not handled here":
    var st = initTuiState("p", "m", nil)
    handleKey(st, Key.Enter, 24)
    handleKey(st, Key.CtrlC, 24)
    check st.composer.text == ""
    check st.scrollOffset == 0

proc freshWorkspace(name: string): string =
  ## A fresh subdirectory of the temp dir as a workspace root (the sink
  ## tests need the extensibility's Lua state).
  result = getTempDir() / name
  createDir(result)

proc freshSessionPath(name: string): string =
  ## A fresh temp session file path per test.
  result = getTempDir() / ("neopi-tp-tui-" & name & ".jsonl")
  removeFile(result)

proc escapeLua(s: string): string =
  ## Escape a string for a single-quoted Lua literal: only the quote and the
  ## backslash need escaping there (the tp_register pattern).
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
  ## entry (init.lua), which registers the command registry on the neopi
  ## table (the tp_register pattern).
  let dir = runtimeDir()
  runScript(L, "package.path = '" &
    escapeLua(dir / "?.lua;" & dir / "?/init.lua") & ";' .. package.path")
  runScript(L, "agent = require('agent')")
  runScript(L, "require('init')")

suite "the stream sink":
  test "cancels when the abort flag is set":
    let root = freshWorkspace("neopi-tp-tui-sink")
    let path = freshSessionPath("sink1")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess)
      st.abortRequested = true
      exposeTuiSink(L, addr st, "scripted")
      runScript(L, "neopi.provider.setScripted({{text = 'partial text'}})")
      let response = evalJson(L, """
        return neopi.provider.stream({
          model = "scripted",
          messages = {{role = "user", text = "go"}},
        }, neopi._tuiOnEvent)
      """)
      # The abort flag (the async timer set it) cancels the stream: the
      # partial response with the delta the sink had already rendered; no
      # Lua error. The flag survives until sendTurn resets it.
      check response["text"].getStr == "partial text"
      check response["stopReason"].getStr == "aborted"
      check st.abortRequested
    finally:
      removeDir(root)
      removeFile(path)

suite "the async timer's key handling":
  test "sets the abort flag on Esc":
    let root = freshWorkspace("neopi-tp-tui-timer")
    let path = freshSessionPath("timer1")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      var st = initTuiState("p", "m", sess)
      var polls = 0
      st.keyPoller = proc (): Key =
        inc polls
        if polls == 1: Key.Escape else: Key.None
      check pollTimerKeys(addr st)
      check st.abortRequested
    finally:
      removeDir(root)
      removeFile(path)

  test "sets the abort flag on Ctrl+C":
    let root = freshWorkspace("neopi-tp-tui-timer2")
    let path = freshSessionPath("timer2")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      var st = initTuiState("p", "m", sess)
      var polls = 0
      st.keyPoller = proc (): Key =
        inc polls
        if polls == 1: Key.CtrlC else: Key.None
      check pollTimerKeys(addr st)
      check st.abortRequested
    finally:
      removeDir(root)
      removeFile(path)

  test "queues the steering draft on Enter":
    let root = freshWorkspace("neopi-tp-tui-timer3")
    let path = freshSessionPath("timer3")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess)
      st.composer = ComposerState(text: "check the file", cursor: 14)
      var polls = 0
      st.keyPoller = proc (): Key =
        inc polls
        if polls == 1: Key.Enter else: Key.None
      exposeTuiSink(L, addr st, "scripted")
      check not pollTimerKeys(addr st)
      # Enter queued the draft into the steering queue (via the state's
      # interpreter) and cleared the composer; no abort.
      let queued = evalJson(L, "return neopi.steeringQueue")
      check queued.len == 1
      check queued[0].getStr == "check the file"
      check st.composer.text == ""
      check not st.abortRequested
    finally:
      removeDir(root)
      removeFile(path)

  test "edits the draft on printable keys":
    let root = freshWorkspace("neopi-tp-tui-timer4")
    let path = freshSessionPath("timer4")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      var st = initTuiState("p", "m", sess)
      var polls = 0
      st.keyPoller = proc (): Key =
        inc polls
        if polls == 1: Key(104) else: Key.None
      check not pollTimerKeys(addr st)
      # The printable key edited the draft (the composer); no abort.
      check st.composer.text == "h"
      check not st.abortRequested
    finally:
      removeDir(root)
      removeFile(path)

suite "the neopi.ui primitives":
  test "status sets the line and re-renders":
    let root = freshWorkspace("neopi-tp-tui-ui")
    let path = freshSessionPath("ui1")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess)
      exposeUi(L)
      exposeTuiSink(L, addr st, "scripted")
      discard evalJson(L, "return neopi.ui.status('indexing notes')")
      check st.statusLine == "indexing notes"
    finally:
      removeDir(root)
      removeFile(path)

  test "widget sets and updates by name":
    let root = freshWorkspace("neopi-tp-tui-ui2")
    let path = freshSessionPath("ui2")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess)
      exposeUi(L)
      exposeTuiSink(L, addr st, "scripted")
      discard evalJson(L, "return neopi.ui.widget('tests', '2 passing')")
      discard evalJson(L, "return neopi.ui.widget('tests', '3 passing')")
      discard evalJson(L, "return neopi.ui.widget('build', 'ok')")
      check st.widgets == @[("tests", "3 passing"), ("build", "ok")]
    finally:
      removeDir(root)
      removeFile(path)

  test "no-ops without the TUI":
    let root = freshWorkspace("neopi-tp-tui-ui3")
    let path = freshSessionPath("ui3")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      exposeUi(L)
      # Without exposeTuiSink the registry pointer stays nil: the
      # primitives return nil (no-ops) and raise no error.
      discard evalJson(L, "return neopi.ui.status('ignored')")
      discard evalJson(L, "return neopi.ui.widget('w', 'ignored')")
    finally:
      removeDir(root)
      removeFile(path)

  test "status rejects non-string arguments":
    let root = freshWorkspace("neopi-tp-tui-ui4")
    let path = freshSessionPath("ui4")
    try:
      let ext = newExtensibility(root, none(Provider), newSession(path))
      let L = ext.bus.state
      exposeUi(L)
      expect LuaError:
        discard evalJson(L, "return neopi.ui.status(123)")
      expect LuaError:
        discard evalJson(L, "return neopi.ui.widget('w')")
    finally:
      removeDir(root)
      removeFile(path)

suite "the composer's / dispatch":
  test "a /-prefixed input runs the command and renders the status":
    let root = freshWorkspace("neopi-tp-tui-cmd")
    let path = freshSessionPath("cmd")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess)
      exposeUi(L)
      exposeTuiSink(L, addr st, "scripted")
      loadRuntime(L)
      runScript(L, """
        neopi.registerCommand('echo', 'echo the args', function(args)
          return 'echoed: ' .. args
        end)
      """)
      st.composer = ComposerState(text: "/echo hi", cursor: 8)
      var loopError = ""
      sendTurn(addr st, L, loopError)
      # The command ran: the output renders as the status line, the
      # composer cleared, and NO user entry entered the session (the
      # command's input never becomes a prompt).
      check loopError == ""
      check st.statusLine == "echoed: hi"
      check st.composer.text == ""
      check sess.history().len == 0
    finally:
      removeDir(root)
      removeFile(path)

  test "an unknown command renders the error as the status":
    let root = freshWorkspace("neopi-tp-tui-cmd2")
    let path = freshSessionPath("cmd2")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess)
      exposeUi(L)
      exposeTuiSink(L, addr st, "scripted")
      loadRuntime(L)
      st.composer = ComposerState(text: "/nosuch", cursor: 7)
      var loopError = ""
      sendTurn(addr st, L, loopError)
      # A command failure is feedback, not a fatal loop error: the TUI
      # survives, the status carries the message, no user entry landed.
      check loopError == ""
      check st.quit == false
      check st.statusLine == "unknown command /nosuch"
      check sess.history().len == 0
    finally:
      removeDir(root)
      removeFile(path)

suite "the sessions list":
  test "listSessions sorts the newest first and labels with the first user entry":
    let root = freshWorkspace("neopi-tp-tui-sessions")
    try:
      createDir(root / ".neopi" / "sessions")
      let old = root / ".neopi" / "sessions" / "run-1.jsonl"
      let new = root / ".neopi" / "sessions" / "run-2.jsonl"
      writeFile(old, """{"type":"user","id":1,"text":"the old prompt"}""")
      writeFile(new, """{"type":"user","id":1,"text":"the new prompt"}""")
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

suite "selectMove":
  test "the cursor moves and clamps":
    var s = initSelectState(@[("a", "a"), ("b", "b"), ("c", "c")])
    selectMove(s, 1)
    check s.selected == 1
    selectMove(s, 10)
    check s.selected == 2
    selectMove(s, -10)
    check s.selected == 0

  test "an empty list is a no-op":
    var s = initSelectState(@[])
    selectMove(s, 1)
    check s.selected == 0

suite "selectLines":
  test "the window shows maxVisible with the selected prefix":
    var s = initSelectState(@[("a", "a"), ("b", "b"), ("c", "c"), ("d", "d"),
      ("e", "e"), ("f", "f"), ("g", "g")])
    let lines = selectLines(s, 80)
    check lines[0] == "resume a session:"
    check lines.len == 6
    check lines[1] == "> a"
    check lines[5] == "  e"

  test "the window follows the selection":
    var s = initSelectState(@[("a", "a"), ("b", "b"), ("c", "c"), ("d", "d"),
      ("e", "e"), ("f", "f"), ("g", "g")])
    selectMove(s, 6)
    let lines = selectLines(s, 80)
    check lines[1] == "  c"
    check lines[5] == "> g"

  test "a closed or empty list renders nothing":
    var s = initSelectState(@[("a", "a")])
    selectClose(s)
    check selectLines(s, 80).len == 0

suite "the /resume builtin":
  test "sendTurn with /resume opens the select overlay":
    let root = freshWorkspace("neopi-tp-tui-resume")
    let path = freshSessionPath("resume")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      var st = initTuiState("p", "m", sess, root)
      createDir(root / ".neopi" / "sessions")
      let old = root / ".neopi" / "sessions" / "run-1.jsonl"
      writeFile(old, """{"type":"user","id":1,"text":"an old session"}""")
      st.composer = ComposerState(text: "/resume", cursor: 7)
      var loopError = ""
      sendTurn(addr st, ext.bus.state, loopError)
      # The builtin opened the overlay with the workspace's sessions; the
      # input never entered the session.
      check loopError == ""
      check st.select.open
      check st.select.items.len == 1
      check st.composer.text == ""
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
      st.select = initSelectState(@[(picked, "run-9 — the picked prompt")])
      resumeSession(addr st, L, picked)
      # The swap: the state's session is the picked one (the cfunctions read
      # the pointer dynamically), the select closed.
      check not st.select.open
      check st.select.items.len == 0
      check st.sess.history().len == 1
      check st.sess.entries[0].text == "the picked prompt"
      check evalJson(L, "return #neopi.session:history()").getInt == 1
    finally:
      removeDir(root)
      removeFile(path)
