## Tests for the TUI over nimterm: the session-to-transcript adapter, the
## sessions listing, the /resume builtin with its menu, the registry swap, and
## the footer's memoized totals. The terminal itself is not tested here — the
## render path is measured headlessly by bench/tui_bench.nim — so these tests
## run without a terminal.
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
  ## A workspace that starts EMPTY: the directory is removed first, because a run
  ## that died mid-test (a crash skips the `finally`) otherwise leaves its
  ## sessions behind for the next one to read — which is how a stale
  ## `run-9.jsonl` turned one run of the /new test into a false failure. The
  ## suite mutates these directories, so isolation has to hold across a killed
  ## process too.
  result = getTempDir() / name
  removeDir(result)
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

type
  TuiFakeBackend = ref object of TerminalBackend
    ## A terminal that replays queued events and keeps every frame it was
    ## presented: the app's wiring is testable without a terminal (the pattern
    ## the measurement harness uses).
    events: seq[UiEvent]
    frames: seq[string]

method size(backend: TuiFakeBackend): Size = size(40, 10)

method readEvent(backend: TuiFakeBackend, timeoutMs: int): UiEvent =
  if backend.events.len == 0:
    return UiEvent(kind: uiNone)
  result = backend.events[0]
  backend.events.delete(0)

method present(backend: TuiFakeBackend, frame: Canvas) =
  backend.frames.add frame.plainText

proc wireFakeApp(state: ptr TuiState): TuiFakeBackend =
  ## Assemble the app the way `tuiLoop` does, on a fake backend: `buildScreen`
  ## wires the state, the input takes the focus (the composer owns the keys at
  ## start, which is what makes a key reach it through the app's dispatch) and
  ## the caller adds the callbacks with `wireApp`. Without production's
  ## assembly there is no queue, no dispatch and no frame.
  result = TuiFakeBackend()
  let screen = buildScreen(state)
  state[].app = newApp(result, screen)
  state[].app.focus(Widget(state[].inputW))
  state[].appReady = true

proc wireCompletionApp(state: ptr TuiState, L: LuaState): TuiFakeBackend =
  ## The app the completion tests drive: the fake backend, the stream sink and
  ## the callbacks, so a typed key travels the production path (the input's
  ## change action is what recomputes the menu).
  result = wireFakeApp(state)
  exposeTuiSink(L, state, "scripted")
  wireApp(state, L, state[].app)

proc typeText(backend: TuiFakeBackend, state: ptr TuiState, text: string) =
  ## Type `text` into the composer one key at a time and let the app dispatch:
  ## the editor applies each character and its change action is what the
  ## completion listens to.
  for c in text:
    backend.events.add UiEvent(kind: uiKey, key: keyChar, text: $c)
  discard pumpApp(state)

proc pressKey(backend: TuiFakeBackend, state: ptr TuiState, key: Key) =
  ## Queue one key and let the app dispatch and present it.
  backend.events.add UiEvent(kind: uiKey, key: key)
  discard pumpApp(state)

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

suite "the command completion":
  test "commandItems lists the core builtin and the runtime's registry":
    let root = freshWorkspace("neopi-tp-tui-complete")
    let path = freshSessionPath("complete")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      exposeUi(L)
      loadRuntimeEntry(L)
      runScript(L, """
        neopi.registerCommand('echo', 'echo the args', function(args)
          return 'echoed: ' .. args
        end)
        neopi.registerCommand('ping', 'return pong', function() end)
      """)
      # The core's own builtins first, then the registry in registration order:
      # /resume, /new, /compact and /quit are commands the user can type, so the
      # completion that lists what can be typed has to carry them too (S4).
      let items = commandItems(L)
      check items.len == 5
      check items[0].label == "resume"
      check items[0].description.len > 0
      check items[1].label == "new"
      check items[2].label == "quit"
      check items[3].label == "echo"
      check items[3].description == "echo the args"
      check items[4].label == "ping"
    finally:
      removeDir(root)
      removeFile(path)

  test "commandItems without the runtime lists only the builtin":
    # The print mode and the headless specs have no registry (the runtime is
    # not loaded); the builtins still stand and the missing registry
    # contributes nothing instead of raising.
    let sess = newSession(freshSessionPath("complete-noruntime"))
    let ext = newExtensibility(freshWorkspace("neopi-tp-tui-nort"),
      none(Provider), sess)
    let L = ext.bus.state
    let items = commandItems(L)
    check items.len == 3
    check items[0].label == "resume"
    check items[1].label == "new"
    check items[2].label == "quit"

  test "the completion prefix is the /token, only at the end of one line":
    check completionPrefix("/", 1) == "/"
    check completionPrefix("/ec", 3) == "/ec"
    # A space ends the name: after it the argument completion's territory
    # starts (pi's spaceIndex rule), and neopi completes no arguments.
    check completionPrefix("/echo hi", 8) == ""
    check completionPrefix("/ec ", 4) == ""
    # The cursor is not at the end: completing would clobber the tail.
    check completionPrefix("/ec", 1) == ""
    check completionPrefix("hola", 4) == ""
    check completionPrefix("/a\nb", 4) == ""
    check completionPrefix("", 0) == ""
    check completionPrefix("/", 0) == ""

  test "the matches are case-insensitive prefixes, and the bare slash lists all":
    let menu = @[MenuItem(label: "resume", description: "the sessions"),
      MenuItem(label: "echo", description: "echo the args"),
      MenuItem(label: "model", description: "show the model")]
    check completionMatches(menu, "/").len == 3
    let onlyResume = completionMatches(menu, "/r")
    check onlyResume.len == 1
    check onlyResume[0].label == "resume"
    check onlyResume[0].description == "the sessions"
    check completionMatches(menu, "/MO").len == 1
    check completionMatches(menu, "/model").len == 1
    check completionMatches(menu, "/zz").len == 0

suite "the completion in the composer":
  test "typing / opens the menu and typing narrows it, and a space closes it":
    let root = freshWorkspace("neopi-tp-tui-comp-open")
    let path = freshSessionPath("comp-open")
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
      let backend = wireCompletionApp(addr st, L)
      typeText(backend, addr st, "/")
      check st.menuKind == mkCompletion
      check not st.screen.menu.isNil
      check st.screen.menu.items.len == 4
      check st.screen.menu.items[0].label == "resume"
      check st.screen.menu.items[1].label == "new"
      check st.screen.menu.items[2].label == "quit"
      check st.screen.menu.items[3].label == "echo"
      check st.screen.menu.items[3].description == "echo the args"
      typeText(backend, addr st, "ec")
      check st.screen.menu.items.len == 1
      check st.screen.menu.items[0].label == "echo"
      # A space ends the name: after it the argument's territory starts, where
      # neopi completes nothing, so the menu goes away.
      typeText(backend, addr st, " ")
      check st.menuKind == mkNone
      check st.menu.isNil
      check st.screen.menu.isNil
    finally:
      removeDir(root)
      removeFile(path)

  test "Tab completes the highlighted command and sends nothing":
    let root = freshWorkspace("neopi-tp-tui-comp-tab")
    let path = freshSessionPath("comp-tab")
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
      let backend = wireCompletionApp(addr st, L)
      typeText(backend, addr st, "/ec")
      check st.screen.menu.items.len == 1
      pressKey(backend, addr st, keyTab)
      # The composer carries the completed name and a trailing space, ready for
      # the arguments; nothing ran and nothing entered the session.
      check st.inputW.text == "/echo "
      check st.menuKind == mkNone
      check st.menu.isNil
      check sess.history().len == 0
      check st.transcriptW.transcript.items.len == 0
      # Tab belonged to the completion: the focus never left the composer (an
      # unhandled Tab moves it in nimterm's dispatch).
      check st.app.focus == Widget(st.inputW)
    finally:
      removeDir(root)
      removeFile(path)

  test "Enter completes and runs the command in the same keystroke":
    let root = freshWorkspace("neopi-tp-tui-comp-enter")
    let path = freshSessionPath("comp-enter")
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
      let backend = wireCompletionApp(addr st, L)
      typeText(backend, addr st, "/ec")
      pressKey(backend, addr st, keyEnter)
      # pi's fall-through: the completion lands and the submit rides with it,
      # so the command actually ran.
      check st.inputW.text == ""
      check st.menuKind == mkNone
      check st.transcriptW.transcript.items.len == 1
      check "echoed: " in st.transcriptW.transcript.items[0].text
      check sess.history().len == 0
    finally:
      removeDir(root)
      removeFile(path)

  test "Esc closes the menu and keeps the draft":
    let root = freshWorkspace("neopi-tp-tui-comp-esc")
    let path = freshSessionPath("comp-esc")
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
      let backend = wireCompletionApp(addr st, L)
      typeText(backend, addr st, "/ec")
      pressKey(backend, addr st, keyEscape)
      # pi cancels the autocomplete alone: the text the user typed survives,
      # which is not what Esc does without a menu (it clears the composer).
      check st.menuKind == mkNone
      check st.menu.isNil
      check st.inputW.text == "/ec"
    finally:
      removeDir(root)
      removeFile(path)

  test "the arrow keys move the selection":
    let root = freshWorkspace("neopi-tp-tui-comp-arrows")
    let path = freshSessionPath("comp-arrows")
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
      let backend = wireCompletionApp(addr st, L)
      typeText(backend, addr st, "/")
      check st.screen.menu.selected == 0
      pressKey(backend, addr st, keyDown)
      check st.screen.menu.selected == 1
      pressKey(backend, addr st, keyUp)
      check st.screen.menu.selected == 0
    finally:
      removeDir(root)
      removeFile(path)

  test "the completed /resume is the builtin, not an unknown command":
    let root = freshWorkspace("neopi-tp-tui-comp-resume")
    let path = freshSessionPath("comp-resume")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess, root)
      exposeUi(L)
      loadRuntimeEntry(L)
      createDir(root / ".neopi" / "sessions")
      writeFile(root / ".neopi" / "sessions" / "run-1.jsonl",
        "{\"type\":\"user\",\"id\":1,\"text\":\"an old session\"}")
      let backend = wireCompletionApp(addr st, L)
      typeText(backend, addr st, "/re")
      check st.screen.menu.items.len == 1
      check st.screen.menu.items[0].label == "resume"
      # Enter completes to "/resume " — the trailing space the insertion leaves
      # for the arguments — and submits. The builtin has to answer for the text
      # the completion actually produced, not only for the bare "/resume" a
      # user types by hand: it is the same command either way.
      pressKey(backend, addr st, keyEnter)
      check st.menuKind == mkResume
      check not st.menu.isNil
      if not st.menu.isNil:
        check st.menu.items.len == 1
      check st.inputW.text == ""
    finally:
      removeDir(root)
      removeFile(path)

  test "the menu renders above the composer, with the descriptions":
    let root = freshWorkspace("neopi-tp-tui-comp-render")
    let path = freshSessionPath("comp-render")
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
      let backend = wireCompletionApp(addr st, L)
      typeText(backend, addr st, "/")
      var canvas = newCanvas(size(60, 12))
      st.screen.render(canvas, rect(0, 0, 60, 12))
      # What the completion shows is the name and the description the
      # extension wrote — the reason the registry is the source.
      check "resume" in canvas.plainText
      check "echo" in canvas.plainText
      check "echo the args" in canvas.plainText
      # And it floats above the composer, so the draft stays visible.
      check "/" in canvas.plainText
    finally:
      removeDir(root)
      removeFile(path)

suite "the composer keeps its keys":
  test "closing the resume picker with Esc gives the completion back":
    let root = freshWorkspace("neopi-tp-tui-bug-resume")
    let path = freshSessionPath("bug-resume")
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
      createDir(root / ".neopi" / "sessions")
      writeFile(root / ".neopi" / "sessions" / "run-1.jsonl",
        "{\"type\":\"user\",\"id\":1,\"text\":\"an old session\"}")
      let backend = wireCompletionApp(addr st, L)
      # The path the bug report walks: /resume, the picker, Esc.
      typeText(backend, addr st, "/resume")
      pressKey(backend, addr st, keyEnter)
      check st.menuKind == mkResume
      check st.menu.items.len == 1
      pressKey(backend, addr st, keyEscape)
      # The picker is gone AND the state stops claiming it: a state that keeps
      # `mkResume` after the menu left makes `updateCompletion` return early
      # forever, which is the completion going silent.
      check st.menuKind == mkNone
      check st.menu.isNil
      check st.screen.menu.isNil
      typeText(backend, addr st, "/")
      check st.menuKind == mkCompletion
      check not st.screen.menu.isNil
      if not st.screen.menu.isNil:
        check st.screen.menu.items.len == 4
      # And the composer is on screen, with the draft in it.
      var canvas = newCanvas(size(60, 12))
      st.screen.render(canvas, rect(0, 0, 60, 12))
      check "/" in canvas.plainText
    finally:
      removeDir(root)
      removeFile(path)

  test "Tab in the composer never hands the keys to the transcript":
    let root = freshWorkspace("neopi-tp-tui-bug-tab")
    let path = freshSessionPath("bug-tab")
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
      let backend = wireCompletionApp(addr st, L)
      typeText(backend, addr st, "hola")
      check st.app.focus == Widget(st.inputW)
      # A Tab the completion does not answer (no menu is open) is spent in the
      # composer. In nimterm's dispatch an unhandled Tab MOVES the focus, and
      # the composer then receives nothing: that is the TUI going deaf.
      pressKey(backend, addr st, keyTab)
      check st.app.focus == Widget(st.inputW)
      typeText(backend, addr st, "!")
      check st.inputW.text == "hola!"
      # Shift+Tab is the same key from the other side.
      pressKey(backend, addr st, keyShiftTab)
      check st.app.focus == Widget(st.inputW)
      typeText(backend, addr st, "?")
      check st.inputW.text == "hola!?"
    finally:
      removeDir(root)
      removeFile(path)

  test "the open menu leaves the composer's rule where it is":
    let root = freshWorkspace("neopi-tp-tui-bug-rule")
    let path = freshSessionPath("bug-rule")
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
      let backend = wireCompletionApp(addr st, L)
      typeText(backend, addr st, "/")
      check not st.screen.menu.isNil
      var canvas = newCanvas(size(60, 12))
      st.screen.render(canvas, rect(0, 0, 60, 12))
      # The menu floats just above the composer, and the rule is the row right
      # above the input: a block whose rectangle reaches that row blanks it
      # (the menu's paint fills every cell of its area), so the composer lost
      # its own line while a menu was up.
      check "─" in canvas.plainText
      check "/" in canvas.plainText
    finally:
      removeDir(root)
      removeFile(path)

suite "the /new builtin":
  test "the /new builtin starts a fresh session and leaves the old one behind":
    let root = freshWorkspace("neopi-tp-tui-new")
    let path = freshSessionPath("new")
    try:
      createDir(root / ".neopi" / "sessions")
      let old = root / ".neopi" / "sessions" / "run-9.jsonl"
      let sess = newSession(old)
      sess.append SessionEntry(kind: ekUser, text: "the old prompt")
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess, root)
      exposeUi(L)
      loadRuntimeEntry(L)
      let backend = wireCompletionApp(addr st, L)
      seedTranscript(addr st)
      refreshFooter(addr st)
      check st.sess.history().len == 1
      typeText(backend, addr st, "/new")
      check st.menuKind == mkCompletion
      check not st.menu.isNil
      if not st.menu.isNil:
        check st.menu.items[0].label == "new"
      pressKey(backend, addr st, keyEnter)
      # A fresh file in the workspace's sessions dir, the same swap `/resume`
      # performs (the state's session and the registry pointer the cfunctions
      # read), and an empty transcript carrying just the report line.
      check st.sess.path != old
      check st.sess.path.startsWith(root / ".neopi" / "sessions")
      check st.sess.history().len == 0
      check evalJson(L, "return #neopi.session:history()").getInt == 0
      check st.transcriptW.transcript.items.len == 1
      check "new session" in st.transcriptW.transcript.items[0].text
      check st.footerW.text.endsWith("| in 0 | out 0")
      # The session left behind is untouched on disk, so /resume brings it back:
      # starting a new one never deletes or rewrites the old.
      var listed: seq[string] = @[]
      for (value, _) in listSessions(root):
        listed.add value
      check old in listed
      check old notin @[st.sess.path]
      check readFile(old).len > 0
    finally:
      removeDir(root)
      removeFile(path)

suite "the /quit builtin":
  test "the /quit builtin stops the TUI's loop":
    let root = freshWorkspace("neopi-tp-tui-quit")
    let path = freshSessionPath("quit")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess, root)
      exposeUi(L)
      loadRuntimeEntry(L)
      let backend = wireCompletionApp(addr st, L)
      # In this harness the state's copy of the app IS the one that steps
      # (`wireFakeApp` assigns it and `pumpApp` drives it), so this test pins
      # the state's fact and the menu listing; the test below pins the
      # production shape, where the loop's app is the local one.
      st.app.running = true
      typeText(backend, addr st, "/quit")
      check st.menuKind == mkCompletion
      check not st.menu.isNil
      if not st.menu.isNil:
        check st.menu.items.len == 1
        check st.menu.items[0].label == "quit"
      # Enter completes to "/quit " — the trailing space the insertion leaves —
      # and submits: the builtin answers for the text the completion produced,
      # and the loop stops with it.
      pressKey(backend, addr st, keyEnter)
      check not st.app.running
      check st.quit
      check st.inputW.text == ""
    finally:
      removeDir(root)
      removeFile(path)

  test "the /quit builtin stops the app the LOOP runs, not the state's copy":
    # The production shape, which the harness above hides: `tuiLoop` holds the
    # app in a local (`var app = newApp(...)`, `app.run()`) and the state keeps
    # a COPY of it, so a write to `state.app.running` reaches nothing that
    # loops. This test assembles that divergence on purpose and drives the
    # loop's own app — the one bug of this shape that the harness would let
    # through, because there the state's copy IS what steps.
    let root = freshWorkspace("neopi-tp-tui-quit-loop")
    let path = freshSessionPath("quit-loop")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess, root)
      exposeUi(L)
      loadRuntimeEntry(L)
      let backend = TuiFakeBackend()
      let screen = buildScreen(addr st)
      var loopApp = newApp(backend, screen)
      st.app = loopApp
      st.appReady = true
      loopApp.focus(Widget(st.inputW))
      exposeTuiSink(L, addr st, "scripted")
      wireApp(addr st, L, loopApp)
      loopApp.running = true
      for c in "/quit":
        backend.events.add UiEvent(kind: uiKey, key: keyChar, text: $c)
      backend.events.add UiEvent(kind: uiKey, key: keyEnter)
      while loopApp.step(0):
        discard
      # The loop's app is the one that has to stop: `app.run()` re-checks
      # `running` after each step, so this flag IS the program's exit.
      check not loopApp.running
      check st.quit
      check st.inputW.text == ""
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
      # (the headless state has no app — pumpApp and presentApp guard it).
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

  test "the notify row is transient and carries its severity":
    let chrome = newChrome()
    check tuiLayout(chrome, 20).notifyRows == 0
    chrome.setNotify("saved", nlWarning)
    check tuiLayout(chrome, 20).notifyRows == 1
    check chrome.notifyLine() == "saved"
    check chrome.notifySeverity() == nlWarning
    chrome.clearNotify()
    check tuiLayout(chrome, 20).notifyRows == 0
    check chrome.notifyLine() == ""

  test "the working indicator text is the extension's when it sets one":
    # The footer's line stays the core's; `ui.working` only replaces the token
    # it appends while the stream is in flight.
    var st = initTuiState("p", "m", nil)
    check footerText(st, true).endsWith("| working")
    setWorking(addr st, "thinking")
    check footerText(st, true).endsWith("| thinking")
    # Not working: the override stays out of the line entirely.
    check not footerText(st, false).contains("thinking")
    setWorking(addr st, "")
    check footerText(st, true).endsWith("| working")

  test "the title goes through the sink and records itself":
    var st = initTuiState("p", "m", nil)
    var written: seq[string]
    st.titleWriter = proc (text: string) =
      written.add text
    setTitle(addr st, "neopi - build")
    check st.title == "neopi - build"
    check written == @["neopi - build"]
    # Clearing is a write too: the terminal needs the empty sequence.
    setTitle(addr st, "")
    check written == @["neopi - build", ""]
    # Without a writer the state still records the title instead of crashing
    # (the print mode and the headless specs have no terminal).
    st.titleWriter = nil
    setTitle(addr st, "headless")
    check st.title == "headless"

  test "the notify row renders above the status keys":
    var st = initTuiState("p", "m", nil)
    let screen = buildScreen(addr st)
    refreshFooter(addr st)
    st.chrome.setStatus("git", "STATUSROW")
    st.chrome.setNotify("NOTIFYROW", nlInfo)
    var canvas = newCanvas(size(40, 12))
    screen.render(canvas, rect(0, 0, 40, 12))
    let text = canvas.plainText
    let notifyAt = text.find("NOTIFYROW")
    check notifyAt >= 0
    check notifyAt < text.find("STATUSROW")

  test "the core clears the transient line on the next submit":
    let root = freshWorkspace("neopi-tp-notify")
    let path = freshSessionPath("notify")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess, root)
      exposeUi(L)
      loadRuntimeEntry(L)
      exposeTuiSink(L, addr st, "scripted")
      runScript(L, """neopi.provider.setScripted({{text = "ok"}})""")
      st.chrome.setNotify("saved", nlInfo)
      check st.chrome.notifyLine() == "saved"
      st.inputW.setText("go")
      sendTurn(addr st, L)
      # The submit drove a turn and the transient line is gone: a stale
      # notification outliving the action it reported would be a lie.
      check sess.history().len >= 2
      check st.chrome.notifyLine() == ""
    finally:
      removeDir(root)
      removeFile(path)

  test "the working indicator reaches a presented frame while the turn runs":
    let root = freshWorkspace("neopi-tp-working")
    let path = freshSessionPath("working")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess, root)
      exposeUi(L)
      loadRuntimeEntry(L)
      let backend = wireFakeApp(addr st)
      exposeTuiSink(L, addr st, "scripted")
      wireApp(addr st, L, st.app)
      runScript(L, """neopi.provider.setScripted({{text = "ok"}})""")
      st.inputW.setText("go")
      sendTurn(addr st, L)
      # The turn holds `working` for its whole drive, so at least one presented
      # frame carried the indicator. It never did before: production wrote the
      # field nowhere and only a test ever set it.
      check backend.frames.len > 0
      var sawWorking = false
      for frame in backend.frames:
        if "| working" in frame: sawWorking = true
      check sawWorking
      # And the flag is down once the drive is over.
      check not st.working
    finally:
      removeDir(root)
      removeFile(path)

  test "Esc clears the composer when idle and asks to abort when the turn runs":
    let root = freshWorkspace("neopi-tp-esc")
    let path = freshSessionPath("esc")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess, root)
      exposeUi(L)
      loadRuntimeEntry(L)
      let backend = wireFakeApp(addr st)
      exposeTuiSink(L, addr st, "scripted")
      wireApp(addr st, L, st.app)
      st.inputW.setText("a draft")
      backend.events.add UiEvent(kind: uiKey, key: keyEscape)
      check not pumpApp(addr st)
      # Nothing was running: the key cleared the composer, which is what the
      # README promises, and it asked to abort nothing.
      check st.inputW.text == ""
      check not st.abortRequested
      # With the turn running, the same key is the abort request.
      st.working = true
      st.inputW.setText("a draft")
      backend.events.add UiEvent(kind: uiKey, key: keyEscape)
      check pumpApp(addr st)
      check st.abortRequested
      # The draft survives an abort: it was not a submit.
      check st.inputW.text == "a draft"
    finally:
      removeDir(root)
      removeFile(path)

  test "a submit while the turn runs queues steering instead of a nested turn":
    let root = freshWorkspace("neopi-tp-steer")
    let path = freshSessionPath("steer")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess, root)
      exposeUi(L)
      loadRuntimeEntry(L)
      let backend = wireFakeApp(addr st)
      exposeTuiSink(L, addr st, "scripted")
      wireApp(addr st, L, st.app)
      st.working = true
      st.inputW.setText("keep going")
      backend.events.add UiEvent(kind: uiKey, key: keyEnter)
      discard pumpApp(addr st)
      # The submit became a steering message: a nested turn would recurse into
      # the drive that is already running.
      check st.inputW.text == ""
      check evalJson(L, "return #neopi.steeringQueue").getInt == 1
    finally:
      removeDir(root)
      removeFile(path)

  test "a posted agent event reaches the transcript and the presented frame":
    var st = initTuiState("p", "m", nil)
    let backend = wireFakeApp(addr st)
    wireApp(addr st, nil, st.app)
    postDelta(addr st, "streamed text")
    discard pumpApp(addr st)
    check st.transcriptW.transcript.items.len == 1
    check st.transcriptW.transcript.items[0].text == "streamed text"
    check backend.frames.len > 0
    check "streamed text" in backend.frames[^1]

  test "a full transcript rebuild discards the view state the items carry":
    # The premise of the incremental sync, verified before building on it: the
    # rebuild replaces every item, so what the user did to them is gone. A
    # collapsed tool comes back collapsed and a pending approval disappears
    # from the UI (and the transcript only answers an approval key for an item
    # that still carries the flag).
    let root = freshWorkspace("neopi-tp-rebuild")
    let path = freshSessionPath("rebuild")
    try:
      let sess = newSession(path)
      sess.append SessionEntry(kind: ekUser, text: "go")
      sess.append SessionEntry(kind: ekAssistant, text: "calling", model: "m",
        provider: "p", stopReason: "toolUse")
      sess.append SessionEntry(kind: ekToolResult, toolCallId: "c1",
        toolName: "read", output: "one\ntwo\nthree\nfour", isError: false)
      var st = initTuiState("p", "m", sess, root)
      discard buildScreen(addr st)
      refreshFooter(addr st)
      # The user expands the tool output with the transcript's own Ctrl-O.
      check st.transcriptW.handle(UiEvent(kind: uiKey, key: keyCtrlO)).handled
      var expanded = 0
      for item in st.transcriptW.transcript.items:
        if item.expanded: inc expanded
      check expanded == 1
      st.transcriptW.transcript.items[^1].approvalRequired = true
      # The full rebuild (what the turn used to run) replaces the items.
      applySession(st.transcriptW.transcript, sess.history())
      st.transcriptW.invalidateLines()
      expanded = 0
      for item in st.transcriptW.transcript.items:
        if item.expanded: inc expanded
      check expanded == 0
      check not st.transcriptW.transcript.items[^1].approvalRequired
    finally:
      removeDir(root)
      removeFile(path)

  test "the incremental sync appends what arrived and keeps the view state":
    let root = freshWorkspace("neopi-tp-sync")
    let path = freshSessionPath("sync")
    try:
      let sess = newSession(path)
      sess.append SessionEntry(kind: ekUser, text: "go")
      sess.append SessionEntry(kind: ekAssistant, text: "calling", model: "m",
        provider: "p", stopReason: "toolUse")
      sess.append SessionEntry(kind: ekToolResult, toolCallId: "c1",
        toolName: "read", output: "one\ntwo\nthree\nfour", isError: false)
      var st = initTuiState("p", "m", sess, root)
      discard buildScreen(addr st)
      refreshFooter(addr st)
      check st.transcriptW.transcript.items.len == 3
      check st.transcriptW.handle(UiEvent(kind: uiKey, key: keyCtrlO)).handled
      st.transcriptW.transcript.items[^1].approvalRequired = true
      # A new entry arrives (the next turn appends it) and the sync brings the
      # transcript up to date without touching what is already rendered.
      sess.append SessionEntry(kind: ekAssistant, text: "done", model: "m",
        provider: "p", stopReason: "stop")
      syncTranscript(addr st)
      check st.transcriptW.transcript.items.len == 4
      check st.transcriptW.transcript.items[^1].text == "done"
      var expanded = 0
      for item in st.transcriptW.transcript.items:
        if item.expanded: inc expanded
      check expanded == 1
      check st.transcriptW.transcript.items[2].approvalRequired
      # Syncing again changes nothing: it appends only what is new.
      syncTranscript(addr st)
      check st.transcriptW.transcript.items.len == 4
    finally:
      removeDir(root)
      removeFile(path)

  test "a branch that moved back is rebuilt instead of appended":
    # `navigateTo` (and a session swap) takes the tip to an earlier entry, so
    # the entries are not a continuation of what is rendered: the sync has to
    # rebuild rather than append onto a branch the user left.
    let root = freshWorkspace("neopi-tp-branch")
    let path = freshSessionPath("branch")
    try:
      let sess = newSession(path)
      sess.append SessionEntry(kind: ekUser, text: "first")
      let firstId = sess.currentId
      sess.append SessionEntry(kind: ekAssistant, text: "second", model: "m",
        provider: "p", stopReason: "stop")
      var st = initTuiState("p", "m", sess, root)
      discard buildScreen(addr st)
      refreshFooter(addr st)
      check st.transcriptW.transcript.items.len == 2
      sess.navigateTo(firstId)
      syncTranscript(addr st)
      check st.transcriptW.transcript.items.len == 1
      check st.transcriptW.transcript.items[0].text == "first"
    finally:
      removeDir(root)
      removeFile(path)

  test "a thinking delta reaches the transcript as a collapsed pi-shaped item":
    let root = freshWorkspace("neopi-tp-thinking")
    let path = freshSessionPath("thinking")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess, root)
      exposeUi(L)
      loadRuntimeEntry(L)
      discard wireFakeApp(addr st)
      exposeTuiSink(L, addr st, "scripted")
      wireApp(addr st, L, st.app)
      # The sink's own contract: the Lua side hands it {thinking = ...} — the
      # shape expose.nim builds for a reasoning event — and it becomes a
      # thinking item in the transcript.
      runScript(L, "return neopi._tuiOnEvent({thinking = 'weighing it'})")
      var found = false
      for item in st.transcriptW.transcript.items:
        if item.kind == tikThinking:
          found = true
          check item.text == "weighing it"
          check not item.expanded
      check found
      # nimterm already renders the collapsed label pi-shaped, which is why the
      # label stays its business and no ui.thinkingLabel slot is needed.
      var canvas = newCanvas(size(40, 8))
      st.screen.render(canvas, rect(0, 0, 40, 8))
      check "Thinking" in canvas.plainText
    finally:
      removeDir(root)
      removeFile(path)

  test "a select asks, renders, and answers through the callback":
    let root = freshWorkspace("neopi-tp-select")
    let path = freshSessionPath("select")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess, root)
      exposeUi(L)
      loadRuntimeEntry(L)
      let backend = wireFakeApp(addr st)
      exposeTuiSink(L, addr st, "scripted")
      wireApp(addr st, L, st.app)
      discard evalJson(L, """
        neopi._answer = "unanswered"
        neopi.ui.select("pick one", {"alpha", "beta"}, function(answer)
          neopi._answer = answer or "cancelled"
        end)
        return true
      """)
      # The handler has already returned and the question is on screen: that is
      # the whole point of the callback shape.
      var canvas = newCanvas(size(40, 12))
      st.screen.render(canvas, rect(0, 0, 40, 12))
      check "pick one" in canvas.plainText
      check "alpha" in canvas.plainText
      check "beta" in canvas.plainText
      # The keys reach it through the app's own dispatch, and the answer fires
      # the callback instead of returning to whoever asked.
      backend.events.add UiEvent(kind: uiKey, key: keyDown)
      backend.events.add UiEvent(kind: uiKey, key: keyEnter)
      discard pumpApp(addr st)
      check evalJson(L, "return neopi._answer").getStr == "beta"
      # The question is gone once answered.
      canvas = newCanvas(size(40, 12))
      st.screen.render(canvas, rect(0, 0, 40, 12))
      check "pick one" notin canvas.plainText
    finally:
      removeDir(root)
      removeFile(path)

  test "a confirm answers a boolean, and Esc answers false":
    let root = freshWorkspace("neopi-tp-confirm")
    let path = freshSessionPath("confirm")
    try:
      let sess = newSession(path)
      let ext = newExtensibility(root, none(Provider), sess)
      let L = ext.bus.state
      var st = initTuiState("p", "m", sess, root)
      exposeUi(L)
      loadRuntimeEntry(L)
      let backend = wireFakeApp(addr st)
      exposeTuiSink(L, addr st, "scripted")
      wireApp(addr st, L, st.app)
      discard evalJson(L, """
        neopi._answer = "unanswered"
        neopi.ui.confirm("delete it?", "The file leaves the branch",
          function(answer) neopi._answer = answer end)
        return true
      """)
      check evalJson(L, "return neopi._answer").getStr == "unanswered"
      backend.events.add UiEvent(kind: uiKey, key: keyEnter)
      discard pumpApp(addr st)
      check evalJson(L, "return neopi._answer").getBool
      # Esc is the cancelling answer, and it is not the same as "no".
      discard evalJson(L, """
        neopi._answer = "unanswered"
        neopi.ui.confirm("delete it?", "The file leaves the branch",
          function(answer) neopi._answer = answer end)
        return true
      """)
      backend.events.add UiEvent(kind: uiKey, key: keyEscape)
      discard pumpApp(addr st)
      check not evalJson(L, "return neopi._answer").getBool
    finally:
      removeDir(root)
      removeFile(path)

suite "the footer":
  test "the totals are the branch's and the memo notices every change":
    # `refreshFooter` memoizes the branch's token totals (the walk is
    # O(entries) and it runs per frame — bench/tui_bench.nim). The pure
    # `footerText` always walks, so it is the reference this test compares
    # against; the interesting case is a NAVIGATE, which moves the branch tip
    # while the entry count stays the same.
    let root = freshWorkspace("neopi-tp-tui-footer")
    let path = freshSessionPath("footer")
    try:
      let sess = newSession(path)
      sess.append SessionEntry(kind: ekUser, text: "one")
      sess.append SessionEntry(kind: ekAssistant, text: "first", model: "m",
        provider: "p", usageInput: 10, usageOutput: 4, stopReason: "stop")
      sess.append SessionEntry(kind: ekToolResult, toolCallId: "c1",
        toolName: "read", output: "x", isError: false)
      sess.append SessionEntry(kind: ekAssistant, text: "second", model: "m",
        provider: "p", usageInput: 20, usageOutput: 6, stopReason: "stop")
      var st = initTuiState("p", "m", sess, root)
      refreshFooter(addr st)
      check st.footerW.text == "p/m | in 30 | out 10"
      check st.footerW.text == footerText(st, false)

      sess.navigateTo(2)
      refreshFooter(addr st)
      check st.footerW.text == "p/m | in 10 | out 4"
      check st.footerW.text == footerText(st, false)

      sess.append SessionEntry(kind: ekAssistant, text: "third", model: "m",
        provider: "p", usageInput: 1, usageOutput: 2, stopReason: "stop")
      refreshFooter(addr st)
      check st.footerW.text == "p/m | in 11 | out 6"
      check st.footerW.text == footerText(st, false)

      st.working = true
      refreshFooter(addr st)
      check st.footerW.text == "p/m | in 11 | out 6 | working"
    finally:
      removeDir(root)
      removeFile(path)

  test "the theme is installed from the request, and a bad request behaves like unset":
    let saved = currentTheme
    try:
      check installTuiTheme("light", cd256).name == "light"
      check currentTheme.name == "light"
      check currentTheme.colors
      # The request is normalized: case and padding do not decide the theme.
      check installTuiTheme(" DARK ", cd256).name == "dark"
      check currentTheme.name == "dark"
      # A name that is not a builtin resolves exactly like an unset one, so
      # nimterm's auto policy (COLORFGBG) still decides.
      check installTuiTheme("banana", cd256).name ==
        installTuiTheme("", cd256).name
      # A terminal without color support gets no colors, whatever the name.
      check not installTuiTheme("light", cdNone).colors
      check not currentTheme.colors
    finally:
      setTheme(saved)

  test "the transcript's keys are exactly the page keys and the expand toggle":
    check transcriptRoutedKey(keyPageUp)
    check transcriptRoutedKey(keyPageDown)
    check transcriptRoutedKey(keyCtrlO)
    # The editor's cursor keys are never stolen: nimterm's InputWidget binds
    # home, end, Ctrl-B and Ctrl-F for text navigation, so routing them to the
    # transcript would break editing to fix scrolling.
    check not transcriptRoutedKey(keyHome)
    check not transcriptRoutedKey(keyEnd)
    check not transcriptRoutedKey(keyCtrlB)
    check not transcriptRoutedKey(keyCtrlF)
    check not transcriptRoutedKey(keyChar)
    check not transcriptRoutedKey(keyEnter)

  test "the widget tree alone never gives the page keys to the transcript":
    # The reason tuiLoop routes them in its global onEvent instead of trusting
    # the tree: nimterm's dispatch walks from the focused widget UP TO ITS
    # PARENTS, and the transcript is a SIBLING of the focused input.
    var st = initTuiState("p", "m", nil)
    let screen = buildScreen(addr st)
    for i in 0 ..< 60:
      st.transcriptW.appendStatus("line " & $i)
    st.transcriptW.invalidateLines()
    var canvas = newCanvas(size(40, 10))
    screen.render(canvas, rect(0, 0, 40, 10))
    var app = newApp(nil, screen)
    app.focus(Widget(st.inputW))
    let tail = st.transcriptW.viewport.offset
    check tail > 0  # otherwise the assertion below would be vacuous
    app.dispatch(UiEvent(kind: uiKey, key: keyPageUp))
    check st.transcriptW.viewport.offset == tail

  test "the routed page key scrolls the transcript while the editor keeps focus":
    var st = initTuiState("p", "m", nil)
    let screen = buildScreen(addr st)
    for i in 0 ..< 60:
      st.transcriptW.appendStatus("line " & $i)
    st.transcriptW.invalidateLines()
    var canvas = newCanvas(size(40, 10))
    screen.render(canvas, rect(0, 0, 40, 10))
    let tail = st.transcriptW.viewport.offset
    check tail > 0
    check routeTranscriptKey(addr st, UiEvent(kind: uiKey, key: keyPageUp))
    check st.transcriptW.viewport.offset < tail
    # A key that belongs to the editor is never claimed by the transcript.
    check not routeTranscriptKey(addr st, UiEvent(kind: uiKey, key: keyHome))

  test "the transcript's copy action reaches the clipboard instead of being dropped":
    var st = initTuiState("p", "m", nil)
    var copied = ""
    st.clipboard = proc (text: string) =
      copied = text
    check handleTuiAction(addr st, nil,
      UiAction(kind: "copy", value: "the selection"))
    check copied == "the selection"
    # An action the TUI does not own is reported as unhandled, and the
    # clipboard stays untouched.
    check not handleTuiAction(addr st, nil,
      UiAction(kind: "select", value: "x"))
    check copied == "the selection"

  test "the layout gives the chrome its rows and the transcript the rest":
    let chrome = newChrome()
    var l = tuiLayout(chrome, 24)
    check l.headerRows == 0
    check l.aboveRows == 0
    check l.statusRows == 0
    check l.belowRows == 0
    check l.footerRows == 1
    check l.transcriptRows == 24 - 1 - 2  # the footer, the rule and the input

    chrome.setHeader(@["a", "b"])
    chrome.setStatus("one", "1")
    chrome.setStatus("two", "2")
    chrome.setWidget("w", @["x", "y", "z"], wpAboveEditor)
    l = tuiLayout(chrome, 24)
    check l.headerRows == 2
    check l.statusRows == 2
    check l.aboveRows == 3
    check l.transcriptRows == 24 - (2 + 3 + 2 + 1 + 2)

    # The transcript never disappears, however greedy the chrome gets.
    chrome.setHeader(@["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"])
    check tuiLayout(chrome, 8).transcriptRows == 1

  test "a status key is one row, in insertion order, and clearing gives it back":
    let chrome = newChrome()
    chrome.setStatus("git", "main")
    chrome.setStatus("model", "sonnet")
    check chrome.statusKeys() == @["git", "model"]
    check tuiLayout(chrome, 20).statusRows == 2
    # Updating a key replaces its row instead of adding one.
    chrome.setStatus("git", "other")
    check chrome.statusKeys() == @["git", "model"]
    check chrome.statusText("git") == "other"
    check tuiLayout(chrome, 20).statusRows == 2
    chrome.clearStatus("git")
    check chrome.statusKeys() == @["model"]
    check tuiLayout(chrome, 20).statusRows == 1

  test "a widget is placed above or below the editor, and cleared by key":
    let chrome = newChrome()
    chrome.setWidget("a", @["one"], wpAboveEditor)
    chrome.setWidget("b", @["two", "three"], wpBelowEditor)
    var l = tuiLayout(chrome, 20)
    check l.aboveRows == 1
    check l.belowRows == 2
    # The placement is part of the slot: moving it moves its rows.
    chrome.setWidget("a", @["one"], wpBelowEditor)
    l = tuiLayout(chrome, 20)
    check l.aboveRows == 0
    check l.belowRows == 3
    chrome.clearWidget("b")
    check tuiLayout(chrome, 20).belowRows == 1
    # An unknown placement is refused, not silently dropped.
    check chrome.widgetKeys() == @["a"]

  test "the chrome renders where the layout says, and the resume feedback lands in it":
    let root = freshWorkspace("neopi-tp-chrome")
    let path = freshSessionPath("chrome")
    try:
      var st = initTuiState("p", "m", nil, root)
      let screen = buildScreen(addr st)
      # The footer's line is the core's and lands through refreshFooter (the
      # production path does this in tuiLoop right after building the screen).
      refreshFooter(addr st)
      st.chrome.setHeader(@["HEADER"])
      st.chrome.setStatus("git", "main")
      st.chrome.setWidget("branch", @["WIDGET"], wpAboveEditor)
      var canvas = newCanvas(size(40, 12))
      screen.render(canvas, rect(0, 0, 40, 12))
      let text = canvas.plainText
      let headerAt = text.find("HEADER")
      let widgetAt = text.find("WIDGET")
      let statusAt = text.find("main")
      let footerAt = text.find("p/m")
      check headerAt >= 0
      check widgetAt > headerAt
      check statusAt > widgetAt
      check footerAt > statusAt

      # The empty sessions dir reports on the status bar instead of dropping
      # the message into a field nobody reads (the write-only statusLine).
      openResume(addr st)
      canvas = newCanvas(size(40, 12))
      screen.render(canvas, rect(0, 0, 40, 12))
      check "no sessions to resume" in canvas.plainText
    finally:
      removeDir(root)
      removeFile(path)
