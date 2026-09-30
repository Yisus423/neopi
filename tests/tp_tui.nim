## Tests for the TUI's pure render layer: the transcript's line building,
## text wrapping, the composer's editing state, the footer, and the scroll
## window — all without a terminal.
import std/[json, options, os]
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

suite "the stream sink":
  test "queues the steering draft on Enter":
    let root = freshWorkspace("neopi-tp-tui-sink")
    let path = freshSessionPath("sink1")
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
      runScript(L, "neopi.provider.setScripted({{text = 'x'}})")
      discard evalJson(L, """
        return neopi.provider.stream({
          model = "scripted",
          messages = {{role = "user", text = "go"}},
        }, neopi._tuiOnEvent)
      """)
      # Enter queued the draft into the steering queue and cleared the
      # composer.
      let queued = evalJson(L, "return neopi.steeringQueue")
      check queued.len == 1
      check queued[0].getStr == "check the file"
      check st.composer.text == ""
    finally:
      removeDir(root)
      removeFile(path)

  test "aborts on Ctrl+C":
    let root = freshWorkspace("neopi-tp-tui-sink2")
    let path = freshSessionPath("sink2")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess)
      var polls = 0
      st.keyPoller = proc (): Key =
        inc polls
        if polls == 1: Key.CtrlC else: Key.None
      exposeTuiSink(L, addr st, "scripted")
      runScript(L, "neopi.provider.setScripted({{text = 'partial text'}})")
      let response = evalJson(L, """
        return neopi.provider.stream({
          model = "scripted",
          messages = {{role = "user", text = "go"}},
        }, neopi._tuiOnEvent)
      """)
      # Ctrl+C aborted the stream: the partial response with the delta the
      # sink had already rendered; no Lua error.
      check response["text"].getStr == "partial text"
      check response["stopReason"].getStr == "aborted"
    finally:
      removeDir(root)
      removeFile(path)

  test "aborts on Esc":
    let root = freshWorkspace("neopi-tp-tui-sink4")
    let path = freshSessionPath("sink4")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess)
      var polls = 0
      st.keyPoller = proc (): Key =
        inc polls
        if polls == 1: Key.Escape else: Key.None
      exposeTuiSink(L, addr st, "scripted")
      runScript(L, "neopi.provider.setScripted({{text = 'partial text'}})")
      let response = evalJson(L, """
        return neopi.provider.stream({
          model = "scripted",
          messages = {{role = "user", text = "go"}},
        }, neopi._tuiOnEvent)
      """)
      # Esc aborted the stream: the partial response, no Lua error. The
      # draft stays for the recovered composer.
      check response["text"].getStr == "partial text"
      check response["stopReason"].getStr == "aborted"
      check st.composer.text == ""
    finally:
      removeDir(root)
      removeFile(path)

  test "edits the draft on printable keys":
    let root = freshWorkspace("neopi-tp-tui-sink3")
    let path = freshSessionPath("sink3")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess)
      var polls = 0
      st.keyPoller = proc (): Key =
        inc polls
        if polls == 1: Key(104) else: Key.None
      exposeTuiSink(L, addr st, "scripted")
      runScript(L, "neopi.provider.setScripted({{text = 'x'}})")
      discard evalJson(L, """
        return neopi.provider.stream({
          model = "scripted",
          messages = {{role = "user", text = "go"}},
        }, neopi._tuiOnEvent)
      """)
      # The printable key edited the draft (the composer).
      check st.composer.text == "h"
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
