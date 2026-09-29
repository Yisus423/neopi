## Tests for the TUI's pure render layer: the transcript's line building,
## text wrapping, the composer's editing state, the footer, and the scroll
## window — all without a terminal.
import illwill
import neopi/session
import neopi/tui
import unittest2

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
