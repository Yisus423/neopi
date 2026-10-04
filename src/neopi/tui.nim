## The neopi TUI over nimterm: the widget tree, the agent-event adapter, and
## the thin loop wiring.
##
## The design keeps the interface separate from the engine (the loop in
## runtime/agent.lua does not change): sends go through the same agent.run
## chunk the print mode uses, the stream deltas apply to nimterm's
## transcript through the adapter and flush live during the waitFor, and
## the session swap rebinds the registry pointer the session cfunctions
## read dynamically. illwill's hand-rolled plumbing (the timer, the sink
## key polling, the per-line colors) is replaced by nimterm's event loop,
## widgets, unicodedb widths, and markdown renderer.

import std/[algorithm, json, os, strutils, times]
import nimterm
import nimterm/[events as ntevents, transcript as nttranscript]
import neopi/lua
import neopi/session
from neopi/hooks import lua_error

# Same file-scope typedef as lua.nim and the bridge modules: no C headers
# exist to declare the opaque state type, and this file's generated C
# prototypes take it (the stream sink's C callback).
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

# stacktrace off around the bridge procs whose frames a lua_error longjmp
# abandons: with frames on it skips the frame pops and corrupts the runtime
# frame stack (the next nimFrame call segfaults — the AGENTS.md pattern;
# dropping this pragma in a rewrite is how it comes back). The TUI's own
# procs keep their traces — only the bridge procs pay the containment's
# price.
{.push stacktrace: off.}

proc raiseLuaError(L: LuaState, message: string) {.noreturn.} =
  ## Push `message` and raise it as a Lua error; lua_error longjmps to the
  ## enclosing pcall, so control never returns here. The file-scope copy the
  ## other bridge modules carry (fs, process, hooks, expose).
  lua_pushstring(L, message)
  discard lua_error(L)

{.pop.}

proc entryKindToItemKind(kind: EntryKind): nttranscript.TranscriptItemKind =
  ## Map a session entry kind onto nimterm's transcript item kind: the user
  ## and assistant entries map directly, a tool result maps to the tool item
  ## (the error flag carries to isError), and a compaction maps to status.
  case kind
  of ekUser: nttranscript.tikUser
  of ekAssistant: nttranscript.tikAssistant
  of ekToolResult: nttranscript.tikTool
  of ekCompaction: nttranscript.tikStatus

proc adapterItem*(entry: SessionEntry): nttranscript.TranscriptItem =
  ## Map one session entry onto nimterm's transcript item: the kind mapping
  ## plus the kind-specific fields nimterm renders (the text, the tool name
  ## and output with the error flag, the compaction's summary). The case
  ## object's fields are only valid for their kind, so each branch touches
  ## its own.
  result = nttranscript.TranscriptItem(
    kind: entryKindToItemKind(entry.kind), id: $entry.id, text: entry.text,
    revision: 1)
  case entry.kind
  of ekToolResult:
    result.title = entry.toolName
    result.text = entry.output
    result.isError = entry.isError
  of ekCompaction:
    result.title = "compaction"
    result.text = entry.summary
  else:
    discard

proc applySession*(transcript: var nttranscript.Transcript,
                   entries: seq[SessionEntry]) =
  ## Rebuild nimterm's transcript from the active branch's entries: the
  ## adapter applied per entry, in order.
  transcript.items = @[]
  for entry in entries:
    transcript.items.add adapterItem(entry)

type
  NeopiScreen* = ref object of Widget
    ## The TUI's root widget (the nimlet pattern — nimterm_screen): the
    ## paint lays out the transcript, the resume menu (when open), the
    ## input, and the footer with fixed rows; the children stay dynamic for
    ## the focus routing.
    transcriptW*: TranscriptWidget
    inputW*: InputWidget
    footerW*: TextWidget
    menu*: Menu

method children*(screen: NeopiScreen): seq[Widget] =
  ## The dynamic tree: the menu joins between the transcript and the input
  ## only while it has items (the nimlet pattern).
  result = @[Widget(screen.transcriptW)]
  if not screen.menu.isNil and screen.menu.items.len > 0:
    result.add Widget(screen.menu)
  result.add Widget(screen.inputW)
  result.add Widget(screen.footerW)

method paint*(screen: NeopiScreen, canvas: var Canvas) =
  ## The layout (the nimlet pattern, simplified): the transcript takes the
  ## rows above the input; the menu floats above the input while open; the
  ## rule, the input, and the footer fix the bottom.
  let h = screen.area.h
  let w = screen.area.w
  if h <= 0 or w <= 0: return
  let footerRow = h - 1
  let inputTop = footerRow - 2
  let transcriptHeight = max(1, inputTop)
  screen.transcriptW.render(canvas, rect(0, 0, w, transcriptHeight))
  if not screen.menu.isNil and screen.menu.items.len > 0:
    let menuContentRows = min(7, screen.menu.items.len)
    let menuRows = menuContentRows + 2
    let menuTop = max(0, inputTop - menuRows)
    screen.menu.render(canvas, rect(0, menuTop, w, menuRows))
  canvas.writeText(0, inputTop, "─".repeat(w), defaultStyle(), w)
  screen.inputW.render(canvas, rect(0, inputTop + 1, w, 1))
  canvas.writeAnsiText(0, footerRow, screen.footerW.text, defaultStyle(), w)

type
  TuiState* = object
    ## The TUI's live pieces: the nimterm widgets (the transcript, the input,
    ## the footer), the session and interpreter they bind, and the workspace
    ## root the sessions resolve against.
    provider*: string
    model*: string
    sess*: Session
    lua*: LuaState
    root*: string
    app*: App
    transcriptW*: TranscriptWidget
    inputW*: InputWidget
    footerW*: TextWidget
    menu*: Menu
    statusLine*: string
    streaming*: string
    quit*: bool
    appReady*: bool
    screen*: NeopiScreen

proc initTuiState*(provider, model: string, sess: Session,
                   root = ""): TuiState =
  ## Constructor: the widgets assembled but not yet running (the app wires
  ## in tuiLoop).
  let transcriptW = newTranscriptWidget()
  let inputW = newInput(prefix = "> ")
  let footerW = newText("")
  result = TuiState(provider: provider, model: model, sess: sess, lua: nil,
    root: root, transcriptW: transcriptW, inputW: inputW, footerW: footerW,
    statusLine: "", streaming: "", quit: false)

proc footerText*(state: TuiState, working: bool): string =
  ## The footer's text: the provider, model, and the session's cumulative
  ## token usage; `working` appends the stream's flight indicator (pi's).
  var tokensIn = 0
  var tokensOut = 0
  if not state.sess.isNil:
    for entry in state.sess.history():
      if entry.kind == ekAssistant:
        tokensIn += entry.usageInput
        tokensOut += entry.usageOutput
  result = state.provider & "/" & state.model & " | in " & $tokensIn &
    " | out " & $tokensOut
  if working:
    result &= " | working"

proc refreshFooter*(state: ptr TuiState) =
  ## Redraw the footer line (the nimlet pattern: the footer refreshes on the
  ## state changes, not on a timer). TextWidget exposes the text field.
  let working = state[].streaming.len > 0
  state[].footerW.text = footerText(state[], working)

proc buildScreen*(state: ptr TuiState): Widget =
  ## The widget tree: the transcript (its own scroll viewport follows the
  ## tail), the input, and the footer.
  state[].transcriptW = newTranscriptWidget()
  if not state[].sess.isNil:
    applySession(state[].transcriptW.transcript, state[].sess.history())
    state[].transcriptW.invalidateLines()
  let screen = NeopiScreen(transcriptW: state[].transcriptW,
    inputW: state[].inputW, footerW: state[].footerW, menu: nil)
  result = Widget(screen)

const tuiStateRegistryKey = "neopi.tui.state"
const sessionRegistryKey = "neopi.session"

proc appendUserLine*(state: ptr TuiState, text: string) =
  ## Append a user entry to the transcript widget and mark the lines stale.
  state[].transcriptW.appendUser(text)

proc appendStatusLine*(state: ptr TuiState, text: string) =
  ## Append an informational status line to the transcript widget.
  state[].transcriptW.appendStatus(text)

proc queueSteering(L: LuaState, text: string) =
  ## Append the draft text to neopi.steeringQueue (the Lua array table the
  ## loop drains between turns — pi's model).
  lua_getfield(L, luaGlobalsIndex, "neopi")
  lua_getfield(L, -1, "steeringQueue")
  let n = cint(lua_objlen(L, -1))
  pushString(L, text)
  lua_rawseti(L, -2, n + 1)
  lua_pop(L, 2)

proc feedKeys*(state: ptr TuiState): bool =
  ## Drain the backend's pending key events without blocking (called from
  ## the stream sink while the app loop is inside the turn's waitFor) and
  ## return whether an abort (Esc/Ctrl+C) was seen. This is the piece that
  ## keeps the abort alive without a timer: the waitFor pumps the dispatch,
  ## and the sink polls the keys here.
  result = false
  while true:
    let event = state[].app.backend.readEvent(0)
    if event.kind == uiNone:
      break
    if event.kind == uiKey:
      if event.key == keyEscape or event.key == keyCtrlC:
        return true
      elif event.key == keyEnter:
        # The steering while streaming: queue the input's text.
        let draft = state[].inputW.text
        if draft.len > 0 and not state[].lua.isNil:
          queueSteering(state[].lua, draft)
          state[].inputW.clear()

proc flushFrame*(state: ptr TuiState) =
  ## Present the current frame (the transcript's changes) without the app
  ## loop: the stream sink calls this so the deltas render live during the
  ## turn's waitFor. appReady guards the pre-run frames (the widget tree
  ## renders through the app's canvas only while the app exists).
  refreshFooter(state)
  if state[].appReady:
    state[].app.frame.clear()
    state[].transcriptW.render(state[].app.frame, rect(0, 0,
      state[].app.size.w, state[].app.size.h - 2))
    state[].inputW.render(state[].app.frame, rect(0, state[].app.size.h - 2,
      state[].app.size.w, 1))
    state[].footerW.render(state[].app.frame, rect(0, state[].app.size.h - 1,
      state[].app.size.w, 1))
    state[].app.backend.present(state[].app.frame)


proc sessionLabel*(path: string): string =
  ## The label for one session file: the first user entry's text (truncated
  ## to 40 chars), or the file name when the session has no user entry or
  ## cannot be read.
  let name = path.splitFile.name
  var firstText = ""
  try:
    let content = readFile(path)
    for line in content.splitLines():
      if line.len > 0:
        let parsed = parseJson(line)
        if parsed{"type"}.getStr == "user":
          firstText = parsed{"text"}.getStr
          break
  except JsonParsingError, CatchableError:
    discard
  if firstText.len > 40:
    firstText = firstText[0 ..< 40]
  if firstText.len == 0:
    return name
  return name & " — " & firstText

proc listSessions*(root: string): seq[tuple[value, label: string]] =
  ## The session files of the workspace (the newest first): value = the
  ## path, label = the first user entry's text (or the file name when the
  ## session has none).
  let dir = root / ".neopi" / "sessions"
  if not dirExists(dir):
    return @[]
  result = @[]
  var files: seq[(string, int64)] = @[]
  for entry in walkDir(dir):
    if entry.kind == pcFile and entry.path.endsWith(".jsonl"):
      files.add (entry.path, toUnix(getLastModificationTime(entry.path)))
  files.sort(proc (a, b: (string, int64)): int = cmp(b[1], a[1]))
  for (path, _) in files:
    result.add (value: path, label: sessionLabel(path))

proc openResume*(state: ptr TuiState) =
  ## Open the resume menu with the workspace's sessions (the /resume
  ## builtin). An empty sessions dir reports on the status line instead.
  var items: seq[MenuItem] = @[]
  for (value, label) in listSessions(state[].root):
    items.add MenuItem(label: label, description: value)
  if items.len == 0:
    state[].statusLine = "no sessions to resume"
    refreshFooter(state)
    return
  state[].menu = newMenu(items, title = "resume a session:")
  if not state[].screen.isNil:
    state[].screen.menu = state[].menu

proc resumeSession*(state: ptr TuiState, L: LuaState, path: string) =
  ## Load the session file the user picked (the menu's Enter): newSession
  ## loads the JSONL, the swap rebinds the TUI state's session and the
  ## registry's neopi.session pointer (the session cfunctions read it
  ## dynamically per call), and the transcript re-renders. A failure: the
  ## status line carries it (feedback, not fatal).
  try:
    let fresh = newSession(path)
    state[].sess = fresh
    setRegistryPointer(L, "neopi.session", cast[pointer](fresh))
  except CatchableError as e:
    state[].statusLine = "cannot resume " & path & ": " & e.msg
    state[].menu = nil
    if not state[].screen.isNil: state[].screen.menu = nil
    return
  state[].menu = nil
  if not state[].screen.isNil: state[].screen.menu = nil
  state[].streaming = ""
  # Rebuild the transcript from the loaded session and refresh.
  applySession(state[].transcriptW.transcript, state[].sess.history())
  state[].transcriptW.invalidateLines()
  refreshFooter(state)

# stacktrace off: the ui/sink callbacks' frames a lua_error longjmp abandons
# (see the note at the file top).
{.push stacktrace: off.}

proc tuiOnEventCB(L: LuaState): cint {.cdecl.} =
  ## The stream sink's C callback: the first upvalue is the TUI state
  ## pointer; apply the {text = delta} event to the transcript, feed the
  ## pending keys (the abort check), flush the frame live, and return false
  ## when the user aborted (the stream's cancel — the same contract as
  ## ever).
  let state = cast[ptr TuiState](lua_touserdata(L, luaUpvalueIndex(1)))
  let event = jsonOfStack(L, 1)
  if event.kind == JObject and event.hasKey("text"):
    let delta = event["text"].getStr("")
    state[].transcriptW.transcript.apply(AgentUiEvent(kind: ueTextDelta,
      text: delta))
    state[].transcriptW.invalidateLines()
  let abort = feedKeys(state)
  flushFrame(state)
  lua_pushboolean(L, cint(ord(not abort)))
  result = 1

{.pop.}

proc exposeTuiSink*(L: LuaState, state: ptr TuiState, model: string) =
  ## Expose the TUI's stream sink and the model on the `neopi` table, where
  ## the loop's chunk references them: `_tuiOnEvent` is the Lua function
  ## carrying the TUI state pointer as its first upvalue (it applies the
  ## deltas to the transcript, feeds the keys for the abort, and flushes
  ## the frame live) and `_tuiModel` is the model as a Lua string. Also
  ## binds the TUI state pointer in the registry (the "neopi.tui.state"
  ## key) and creates the steering queue: the Lua array table the sink
  ## fills (Enter while streaming) and the loop drains between turns.
  state[].lua = L
  setRegistryPointer(L, tuiStateRegistryKey, cast[pointer](state))
  lua_getfield(L, luaGlobalsIndex, "neopi")
  if lua_type(L, -1) != luaTTable:
    lua_pop(L, 1)
    raise LuaError.newException(
      "the TUI sink requires the neopi table (call newHookBus first)")
  lua_pushlightuserdata(L, cast[pointer](state))
  lua_pushcclosure(L, tuiOnEventCB, 1)
  lua_setfield(L, -2, "_tuiOnEvent")
  pushString(L, model)
  lua_setfield(L, -2, "_tuiModel")
  lua_createtable(L, 0, 0)
  lua_setfield(L, -2, "steeringQueue")
  lua_pop(L, 1)

proc runCommand(state: ptr TuiState, L: LuaState, text: string) =
  ## Dispatch a /-prefixed composer input: the /resume builtin opens the
  ## sessions menu; everything else goes to the runtime's command registry
  ## (the nvim model — the runtime owns it): the input travels on the neopi
  ## table, the returned output renders as a status line in the transcript,
  ## and a failure is feedback there too — the TUI survives /unknown.
  if text == "/resume":
    state[].inputW.clear()
    openResume(state)
    return
  state[].inputW.clear()
  lua_getfield(L, luaGlobalsIndex, "neopi")
  pushString(L, text)
  lua_setfield(L, -2, "_tuiCommandInput")
  lua_pop(L, 1)
  var feedback = ""
  try:
    let output = evalJson(L,
      "return neopi.runCommand(neopi._tuiCommandInput)")
    if output.kind == JString and output.getStr.len > 0:
      feedback = output.getStr
  except LuaError as e:
    feedback = e.msg
  if feedback.len > 0:
    appendStatusLine(state, feedback)

proc sendTurn*(state: ptr TuiState, L: LuaState) =
  ## Dispatch the input's text: /resume opens the menu, other /-prefixed
  ## inputs run through the runtime's registry, and plain text becomes a
  ## user entry + the loop's chunk (the same agent.run print mode uses).
  let text = state[].inputW.text
  if text.len == 0:
    return
  if text.startsWith("/"):
    runCommand(state, L, text)
    return
  try:
    state[].sess.append(SessionEntry(kind: ekUser, text: text))
  except CatchableError as e:
    appendStatusLine(state, "cannot append: " & e.msg)
    return
  appendUserLine(state, text)
  state[].inputW.clear()
  refreshFooter(state)
  # The loop: agent.run(neopi.session, {model, onEvent}) — the sink and the
  # model come off the neopi table.
  let chunk = "local agent = require('agent'); " &
    "return agent.run(neopi.session, " &
    "{model = neopi._tuiModel, onEvent = neopi._tuiOnEvent})"
  try:
    discard evalJson(L, chunk)
  except LuaError as e:
    appendStatusLine(state, "the loop failed: " & e.msg)
    return
  state[].streaming = ""
  # Rebuild the transcript from the session (the assistant/tool entries the
  # loop appended) and refresh.
  applySession(state[].transcriptW.transcript, state[].sess.history())
  state[].transcriptW.invalidateLines()
  refreshFooter(state)

# stacktrace off: the ui callbacks' frames a lua_error longjmp abandons (see
# the note at the file top).
{.push stacktrace: off.}

proc luaUiStatus(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.ui.status(text)`: set the extension status line (a
  ## transcript status row for the TUI) and re-render. A no-op without the
  ## TUI (the registry pointer is nil — the print mode and the headless
  ## specs).
  let state = cast[ptr TuiState](getRegistryPointer(L, tuiStateRegistryKey))
  if lua_gettop(L) != 1 or lua_type(L, 1) != luaTString:
    raiseLuaError(L, "neopi.ui.status expects (text: string)")
  if state.isNil:
    lua_pushnil(L)
    return 1
  appendStatusLine(state, $lua_tolstring(L, 1, nil))
  lua_pushnil(L)
  result = 1

proc luaUiWidget(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.ui.widget(name, text)`: set or update the named widget
  ## line and re-render. A no-op without the TUI. The widgets live on the
  ## status line's model (a name → text map) rendered above the footer.
  let state = cast[ptr TuiState](getRegistryPointer(L, tuiStateRegistryKey))
  if lua_gettop(L) != 2 or lua_type(L, 1) != luaTString or
      lua_type(L, 2) != luaTString:
    raiseLuaError(L, "neopi.ui.widget expects (name: string, text: string)")
  if state.isNil:
    lua_pushnil(L)
    return 1
  # The MVP keeps the widget map in the transcript's status rows: a widget
  # update replaces the row titled with the name.
  let name = $lua_tolstring(L, 1, nil)
  let text = $lua_tolstring(L, 2, nil)
  appendStatusLine(state, name & ": " & text)
  lua_pushnil(L)
  result = 1

{.pop.}

proc exposeUi*(L: LuaState) =
  ## Expose the `neopi.ui` table inside the existing `neopi` table: status
  ## and widget, the Lua UI primitives for extensions. The callbacks read
  ## the TUI state pointer from the registry (nil without the TUI — the
  ## print mode and the headless specs), so they are no-ops there; the TUI
  ## binds the pointer in exposeTuiSink. Requires `neopi` to exist
  ## (newHookBus creates it).
  lua_getfield(L, luaGlobalsIndex, "neopi")
  if lua_type(L, -1) != luaTTable:
    lua_pop(L, 1)
    raise newException(LuaError,
      "the ui primitives require the neopi table (call newHookBus first)")
  lua_createtable(L, 0, 2)
  lua_pushcfunction(L, luaUiStatus)
  lua_setfield(L, -2, "status")
  lua_pushcfunction(L, luaUiWidget)
  lua_setfield(L, -2, "widget")
  lua_setfield(L, -2, "ui")
  lua_pop(L, 1)

proc tuiLoop*(sess: Session, L: LuaState, provider, model: string,
              root = ""): string =
  ## Run the TUI: nimterm's App is the loop owner; the send path runs the
  ## same agent.run chunk the print mode uses; the sink flushes the frame
  ## live during the turn's waitFor and feeds the keys for the abort.
  ## Returns "" on a clean exit or the loop's failure message.
  var state = initTuiState(provider, model, sess, root)
  exposeTuiSink(L, addr state, model)
  let screenWidget = buildScreen(addr state)
  state.screen = NeopiScreen(screenWidget)
  var app = newApp(newPlatformBackend(fullscreen = true), screenWidget)
  # The sink renders through this copy: the widgets are refs (the same
  # objects), and the backend presents the copied canvas — safe because the
  # sink runs on the same thread (the turn's waitFor pumps the dispatch).
  state.app = app
  state.appReady = true
  app.focus(Widget(state.inputW))
  refreshFooter(addr state)

  app.onEvent = proc (app: var App, event: UiEvent): EventResponse =
    ## The global keys before the widgets: Ctrl+C exits; the select menu
    ## (when open) is the input's controller: Up/Down move, Enter picks
    ## (the swap), Esc closes.
    if event.kind == uiKey:
      if event.key == keyCtrlC:
        app.running = false
        return eventHandled
      if not state.screen.menu.isNil and state.screen.menu.items.len > 0:
        case event.key
        of keyUp, keyDown:
          let response = state.screen.menu.handle(event)
          app.invalidate()
          if response.handled: return response
        of keyEnter:
          let menu = state.screen.menu
          if menu.items.len > 0:
            let picked = menu.items[menu.selected]
            resumeSession(addr state, L, picked.description)
          return eventHandled
        of keyEscape:
          state.screen.menu = nil
          state.menu = nil
          app.invalidate()
          return eventHandled
        else:
          discard
    return eventIgnored

  app.onAction = proc (app: var App, action: UiAction) =
    ## The focused widget's actions: the input's submit dispatches (the
    ## commands, /resume, or the turn).
    if action.kind == "submit":
      sendTurn(addr state, L)

  app.run()
  return ""
