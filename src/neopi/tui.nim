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

import std/[algorithm, json, os, strutils, syncio, tables, times]
import nimterm
import nimterm/[events as ntevents, term, transcript as nttranscript]
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
  WidgetPlacement* = enum
    ## Where a placed widget's rows sit relative to the composer.
    wpAboveEditor, wpBelowEditor

  WidgetSlot* = object
    ## One placed widget block: its lines and the side it hugs.
    placement*: WidgetPlacement
    lines*: seq[string]

  NotifyLevel* = enum
    ## The severity of a `ui.notify` line. It is not decoration: the row is
    ## painted with the theme token the level names.
    nlInfo, nlWarning, nlError

  Chrome* = ref object
    ## The extension-filled chrome: the header rows, the keyed status rows and
    ## the placed widget blocks. It is held by reference and shared between the
    ## TUI state and the root widget, the way the nimterm widgets already
    ## travel. The insertion order is kept explicitly — a Table alone would
    ## render in a different order every run — so what the user sees is
    ## deterministic.
    header: seq[string]
    statusOrder: seq[string]
    statusRows: Table[string, string]
    widgetOrder: seq[string]
    widgetSlots: Table[string, WidgetSlot]
    notifyText: string
    notifyLevel: NotifyLevel

  TuiLayout* = object
    ## The rows each block of the screen owns, as `tuiLayout` computes them.
    headerRows*, transcriptRows*, aboveRows*, notifyRows*, statusRows*,
      belowRows*, footerRows*, inputRows*: int

  NeopiScreen* = ref object of Widget
    ## The TUI's root widget (the nimlet pattern — nimterm_screen): the paint
    ## lays the blocks out through `tuiLayout` (the header, the transcript,
    ## the placed widgets, the composer, the status rows and the footer) and
    ## floats the resume menu above the input while it is open; the children
    ## stay dynamic for the focus routing.
    chrome*: Chrome
    transcriptW*: TranscriptWidget
    inputW*: InputWidget
    footerW*: TextWidget
    menu*: Menu

const composerRows* = 2
  ## The rule and the input, the fixed pair the composer occupies.

proc newChrome*(): Chrome =
  ## An empty chrome: no header, no status rows, no placed widgets.
  Chrome(statusRows: initTable[string, string](),
    widgetSlots: initTable[string, WidgetSlot]())

proc dropFromOrder(order: var seq[string], key: string) =
  ## Remove `key` from an insertion order, keeping the rest in place.
  var kept: seq[string]
  for other in order:
    if other != key:
      kept.add other
  order = kept

proc setHeader*(chrome: Chrome, lines: seq[string]) =
  ## Replace the header block. An empty list removes it (its rows go back to
  ## the transcript).
  chrome.header = lines

proc setStatus*(chrome: Chrome, key, text: string) =
  ## Set one status row. The insertion order is the render order and a key
  ## that already exists keeps its place, so updating a row never reshuffles
  ## the bar.
  if not chrome.statusRows.hasKey(key):
    chrome.statusOrder.add key
  chrome.statusRows[key] = text

proc clearStatus*(chrome: Chrome, key: string) =
  ## Drop one status row and give its row back to the transcript.
  if chrome.statusRows.hasKey(key):
    chrome.statusRows.del key
    dropFromOrder(chrome.statusOrder, key)

proc statusKeys*(chrome: Chrome): seq[string] =
  ## The live status keys, in insertion order.
  chrome.statusOrder

proc statusText*(chrome: Chrome, key: string): string =
  ## The text of one status row (empty when the key is not set).
  chrome.statusRows.getOrDefault(key)

proc setNotify*(chrome: Chrome, text: string, level: NotifyLevel) =
  ## Show one transient line. It is not a status key because its lifetime is
  ## the action, not the session: the core clears it on the next submit.
  chrome.notifyText = text
  chrome.notifyLevel = level

proc clearNotify*(chrome: Chrome) =
  ## Drop the transient line.
  chrome.notifyText = ""

proc notifyLine*(chrome: Chrome): string =
  ## The transient line's text (empty when there is none).
  if chrome.isNil: "" else: chrome.notifyText

proc notifySeverity*(chrome: Chrome): NotifyLevel =
  ## The transient line's severity, which picks its theme token.
  if chrome.isNil: nlInfo else: chrome.notifyLevel

proc notifyStyle*(level: NotifyLevel): Style =
  ## The theme token one severity paints with. The level exists so the row can
  ## say how bad it is, not only what it says — and so the token comes from the
  ## active theme instead of a hardcoded color.
  case level
  of nlInfo: currentTheme.text
  of nlWarning: currentTheme.warning
  of nlError: currentTheme.error

proc setWidget*(chrome: Chrome, key: string, lines: seq[string],
                placement: WidgetPlacement) =
  ## Set one placed block. The placement is part of the slot, so moving a
  ## widget between sides moves its rows instead of leaving a stale copy.
  if not chrome.widgetSlots.hasKey(key):
    chrome.widgetOrder.add key
  chrome.widgetSlots[key] = WidgetSlot(placement: placement, lines: lines)

proc clearWidget*(chrome: Chrome, key: string) =
  ## Drop one placed block.
  if chrome.widgetSlots.hasKey(key):
    chrome.widgetSlots.del key
    dropFromOrder(chrome.widgetOrder, key)

proc widgetKeys*(chrome: Chrome): seq[string] =
  ## The live widget keys, in insertion order.
  chrome.widgetOrder

proc widgetLines*(chrome: Chrome, placement: WidgetPlacement): seq[string] =
  ## The lines of the widgets hugging one side, in insertion order.
  if chrome.isNil:
    return
  for key in chrome.widgetOrder:
    if chrome.widgetSlots[key].placement == placement:
      result.add chrome.widgetSlots[key].lines

proc tuiLayout*(chrome: Chrome, height: int): TuiLayout =
  ## Split the screen's rows between the chrome's blocks. Every fixed block
  ## takes exactly what its content needs — the header rows, the placed widget
  ## lines, one row per live status key, the composer's rule and input, the
  ## footer's own line — and the transcript keeps the rest. It never drops
  ## below one row: a screen too short for its chrome keeps the transcript and
  ## lets the blocks clip.
  result.headerRows = if chrome.isNil: 0 else: chrome.header.len
  result.aboveRows =
    if chrome.isNil: 0 else: chrome.widgetLines(wpAboveEditor).len
  result.belowRows =
    if chrome.isNil: 0 else: chrome.widgetLines(wpBelowEditor).len
  result.statusRows = if chrome.isNil: 0 else: chrome.statusOrder.len
  result.notifyRows =
    if chrome.isNil or chrome.notifyText.len == 0: 0 else: 1
  result.footerRows = 1
  result.inputRows = composerRows
  let fixed = result.headerRows + result.aboveRows + result.belowRows +
    result.notifyRows + result.statusRows + result.footerRows +
    result.inputRows
  result.transcriptRows = max(1, height - fixed)

method children*(screen: NeopiScreen): seq[Widget] =
  ## The dynamic tree: the menu joins between the transcript and the input
  ## only while it has items (the nimlet pattern).
  result = @[Widget(screen.transcriptW)]
  if not screen.menu.isNil and screen.menu.items.len > 0:
    result.add Widget(screen.menu)
  result.add Widget(screen.inputW)
  result.add Widget(screen.footerW)

method paint*(screen: NeopiScreen, canvas: var Canvas) =
  ## The layout the core owns, top to bottom: the header rows, the transcript
  ## (which keeps whatever the fixed blocks leave), the widgets placed above
  ## the composer, the rule and the input, the widgets placed below, one row
  ## per live status key, and the footer's line. The resume menu floats above
  ## the input while it is open.
  let h = screen.area.h
  let w = screen.area.w
  if h <= 0 or w <= 0: return
  let layout = tuiLayout(screen.chrome, h)
  let chrome = screen.chrome
  var row = 0
  if not chrome.isNil:
    for line in chrome.header:
      canvas.writeAnsiText(0, row, line, defaultStyle(), w)
      inc row
  screen.transcriptW.render(canvas, rect(0, row, w, layout.transcriptRows))
  inc row, layout.transcriptRows
  if not chrome.isNil:
    for line in chrome.widgetLines(wpAboveEditor):
      canvas.writeAnsiText(0, row, line, defaultStyle(), w)
      inc row
  let inputTop = row + 1  # the rule takes the row before the input
  canvas.writeText(0, row, "─".repeat(w), defaultStyle(), w)
  inc row
  screen.inputW.render(canvas, rect(0, row, w, 1))
  inc row
  if not chrome.isNil:
    for line in chrome.widgetLines(wpBelowEditor):
      canvas.writeAnsiText(0, row, line, defaultStyle(), w)
      inc row
    if chrome.notifyLine().len > 0:
      canvas.writeAnsiText(0, row, chrome.notifyLine(),
        notifyStyle(chrome.notifySeverity()), w)
      inc row
    for key in chrome.statusKeys():
      canvas.writeAnsiText(0, row, chrome.statusText(key), defaultStyle(), w)
      inc row
  canvas.writeAnsiText(0, row, screen.footerW.text, defaultStyle(), w)
  if not screen.menu.isNil and screen.menu.items.len > 0:
    let menuRows = min(7, screen.menu.items.len) + 2
    screen.menu.render(canvas, rect(0, max(0, inputTop - menuRows), w, menuRows))

type
  FooterTokens = object
    ## The memoized branch-scoped token totals behind the footer. The key is
    ## everything `footerText` reads from the session: its identity (a
    ## `/resume` swap rebinds it), the active branch's tip and the total entry
    ## count. Every way usage arrives in this codebase changes one of them
    ## (`append` grows the count, `navigateTo` moves the tip, entries are
    ## never edited in place), so a matching key means the totals stand.
    sess: pointer
    tip: int
    entries: int
    tokensIn: int
    tokensOut: int

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
    chrome*: Chrome
      ## The extension-filled chrome (the header rows, the keyed status rows and
      ## the placed blocks), shared by reference with the root widget.
    workingText*: string
      ## The extension's override for the footer's working token
      ## (`ui.working`); empty means the default.
    title*: string
      ## The last title `ui.title` set, kept so the state can be read back.
    titleWriter*: proc (text: string)
      ## Where `ui.title` writes. `initTuiState` points it at the terminal's
      ## OSC 2 and the specs replace it, so the title is observable without an
      ## escape sequence reaching the test's stdout.
    working*: bool
      ## Whether the turn drive is running. The footer's working token reads it
      ## and it decides that a submit is steering rather than another turn —
      ## and note that until this slice nothing ever set it, so the indicator
      ## never reached a frame.
    syncedId*: int
      ## How far the transcript has been brought up to the session: the highest
      ## entry id it already shows. It tracks what is *displayed*, whoever put
      ## it there — the sync appends only what is past it, and the turn's own
      ## user line advances it so the same entry is never added twice.
    abortRequested*: bool
      ## The Esc/Ctrl+C the app answered while the turn ran: the sink reads it
      ## and cancels the stream, so the abort is a fact of the state instead of
      ## a value travelling out of a key loop.
    clipboard*: proc (text: string)
      ## Where the transcript's `copy` action lands. `initTuiState` points it
      ## at the terminal's clipboard and the specs replace it, so the copy is
      ## observable without an escape sequence reaching stdout.
    footerTokens: FooterTokens
    quit*: bool
    appReady*: bool
    screen*: NeopiScreen

proc terminalTitleWriter(text: string) =
  ## The default title sink: OSC 2, the sequence a terminal reads to name its
  ## window. nimterm owns the terminal, so this writes through its writer and
  ## only while the screen is up — the escape must not land in the print mode's
  ## stdout, where it would be noise in a pipe.
  if not gTermActive:
    return
  termWrite("\e]2;" & text & "\a")
  stdout.flushFile()

proc setWorking*(state: ptr TuiState, text: string) =
  ## Replace the token the footer appends while the stream is in flight; an
  ## empty text restores the default. The footer's line itself stays the
  ## core's, so an extension can name the work but not take the line over.
  state[].workingText = text

proc setTitle*(state: ptr TuiState, text: string) =
  ## Name the terminal window and remember it; an empty text hands the title
  ## back to the terminal. The write goes through the state's writer, which the
  ## specs replace — that is what keeps an escape out of their output, and what
  ## makes the title observable at all.
  state[].title = text
  if not state[].titleWriter.isNil:
    state[].titleWriter(text)

proc initTuiState*(provider, model: string, sess: Session,
                   root = ""): TuiState =
  ## Constructor: the widgets assembled but not yet running (the app wires
  ## in tuiLoop).
  let transcriptW = newTranscriptWidget()
  let inputW = newInput(prefix = "> ")
  let footerW = newText("")
  result = TuiState(provider: provider, model: model, sess: sess, lua: nil,
    root: root, transcriptW: transcriptW, inputW: inputW, footerW: footerW,
    quit: false, clipboard: copyToClipboard,
    workingText: "", title: "", titleWriter: terminalTitleWriter,
    working: false, abortRequested: false,
    syncedId: 0,
    chrome: newChrome())

proc transcriptRoutedKey*(key: Key): bool =
  ## Whether a key belongs to the transcript while the editor keeps focus:
  ## Page Up/Page Down scroll its viewport (the mouse wheel does it too,
  ## through the hit path) and Ctrl-O toggles the compact and expanded forms.
  ## The editor's own cursor keys — home, end, Ctrl-B, Ctrl-F — are
  ## deliberately absent: nimterm's InputWidget binds all four for text
  ## navigation, so routing them here would break editing to fix scrolling,
  ## and pi keeps them with the editor for the same reason.
  result = key in {keyPageUp, keyPageDown, keyCtrlO}

proc routeTranscriptKey*(state: ptr TuiState, event: UiEvent): bool =
  ## Give a transcript-owned key to the transcript before the focused editor
  ## sees it, so paging and the expand toggle answer while the composer keeps
  ## focus. The verdict is the predicate above and NEVER the widget's
  ## response: nimterm's TranscriptWidget scrolls on the page keys and still
  ## answers `eventIgnored` (its scroll branches carry no `return`), so a
  ## caller that trusted `handled` would let the editor consume the key as
  ## well. Both key paths share this rule — the app's global `onEvent` and the
  ## app's own dispatch, which is what pumps the keys while the turn runs.
  if event.kind != uiKey or not transcriptRoutedKey(event.key):
    return false
  if state[].transcriptW.isNil:
    return false
  discard state[].transcriptW.handle(event)
  true

proc branchTokens(sess: Session): tuple[tokensIn, tokensOut: int] =
  ## The active branch's cumulative token usage: the honest walk over the
  ## history. `refreshFooter` memoizes this; the pure `footerText` calls it.
  if not sess.isNil:
    for entry in sess.history():
      if entry.kind == ekAssistant:
        result.tokensIn += entry.usageInput
        result.tokensOut += entry.usageOutput

proc footerTokens(state: ptr TuiState): tuple[tokensIn, tokensOut: int] =
  ## The memoized branch totals. The walk is O(entries) and this runs on
  ## every frame, which made the FRAME itself grow with the transcript (7.6 ms
  ## at 50 entries to 47.7 ms at 5000 — bench/tui_bench.nim); the memo is
  ## O(1) while the key holds, which is every frame of a stream (the deltas
  ## touch the transcript, not the session's entries).
  let key = if state[].sess.isNil: nil else: cast[pointer](state[].sess)
  let tip = if state[].sess.isNil: 0 else: state[].sess.currentId
  let count = if state[].sess.isNil: 0 else: state[].sess.entries.len
  if state[].footerTokens.sess == key and state[].footerTokens.tip == tip and
      state[].footerTokens.entries == count:
    return (state[].footerTokens.tokensIn, state[].footerTokens.tokensOut)
  let totals = branchTokens(state[].sess)
  state[].footerTokens = FooterTokens(sess: key, tip: tip, entries: count,
    tokensIn: totals.tokensIn, tokensOut: totals.tokensOut)
  totals

proc footerLine(provider, model: string,
                totals: tuple[tokensIn, tokensOut: int],
                working: bool, workingText = ""): string =
  ## The footer's text: the provider, model, and the cumulative token usage;
  ## `working` appends the stream's flight indicator (pi's), whose text
  ## `ui.working` may replace.
  result = provider & "/" & model & " | in " & $totals.tokensIn &
    " | out " & $totals.tokensOut
  if working:
    result &= " | " & (if workingText.len > 0: workingText else: "working")

proc footerText*(state: TuiState, working: bool): string =
  ## The footer's text from a state value (the pure path: it always walks).
  footerLine(state.provider, state.model, branchTokens(state.sess), working,
    state.workingText)

proc refreshFooter*(state: ptr TuiState) =
  ## Redraw the footer line (the nimlet pattern: the footer refreshes on the
  ## state changes, not on a timer), through the memoized totals.
  let working = state[].working
  state[].footerW.text = footerLine(state[].provider, state[].model,
    footerTokens(state), working, state[].workingText)

proc seedTranscript*(state: ptr TuiState) =
  ## Rebuild the transcript from the session and remember how far it goes. This
  ## is the full path, for a fresh screen and for a branch change — a session
  ## swap or a `navigateTo` — where the entries are not a continuation of what
  ## is rendered.
  if state[].sess.isNil:
    state[].syncedId = 0
    return
  let entries = state[].sess.history()
  applySession(state[].transcriptW.transcript, entries)
  state[].transcriptW.invalidateLines()
  state[].syncedId = 0
  for entry in entries:
    if entry.id > state[].syncedId:
      state[].syncedId = entry.id

proc syncTranscript*(state: ptr TuiState) =
  ## Bring the transcript up to the session by appending only what the session
  ## gained, so the items already rendered keep everything they carry: a tool
  ## the user expanded, an approval waiting for an answer, the selection. The
  ## turn used to run a full rebuild, which replaced every item and so threw
  ## all of that away (measured by the test that pins the premise).
  ##
  ## A branch that moved back is not a continuation, so it takes the full path:
  ## `navigateTo`, and a session swap whose ids start below the watermark.
  if state[].sess.isNil:
    return
  if state[].sess.currentId < state[].syncedId:
    seedTranscript(state)
    return
  for entry in state[].sess.history():
    if entry.id > state[].syncedId:
      state[].transcriptW.appendItem(adapterItem(entry))
      state[].syncedId = entry.id

proc buildScreen*(state: ptr TuiState): Widget =
  ## The widget tree: the transcript (its own scroll viewport follows the
  ## tail), the input, and the footer. The screen is wired into the state on
  ## the way out: `presentApp` draws through `state.screen`, so a builder that
  ## left the state unwired would present an empty frame — the measurement
  ## harness's own self-check caught exactly that.
  state[].transcriptW = newTranscriptWidget()
  seedTranscript(state)
  let screen = NeopiScreen(transcriptW: state[].transcriptW,
    inputW: state[].inputW, footerW: state[].footerW, menu: nil,
    chrome: state[].chrome)
  state[].screen = screen
  result = Widget(screen)

const tuiStateRegistryKey = "neopi.tui.state"

proc appendUserLine*(state: ptr TuiState, text: string) =
  ## Append a user entry to the transcript widget and mark the lines stale.
  state[].transcriptW.appendUser(text)

proc appendStatusLine*(state: ptr TuiState, text: string) =
  ## Append an informational status line to the transcript widget.
  state[].transcriptW.appendStatus(text)

const coreStatusKey* = "neopi"
  ## The status key the core's own messages use (the resume feedback). It is a
  ## row like any other: the user sees it, and the next submit clears it.

proc setCoreStatus*(state: ptr TuiState, text: string) =
  ## Show (or, with an empty text, clear) the core's own status message. The
  ## resume paths report here: they used to write a field nothing read, so both
  ## messages were silently lost.
  if state[].chrome.isNil:
    return
  if text.len == 0:
    state[].chrome.clearStatus(coreStatusKey)
  else:
    state[].chrome.setStatus(coreStatusKey, text)

proc clearTransient*(state: ptr TuiState) =
  ## Drop the messages that belong to the last action: the core's own status
  ## and the extension's transient line. The next submit starts from a clean
  ## chrome, so nothing stale outlives the action it reported.
  setCoreStatus(state, "")
  if not state[].chrome.isNil:
    state[].chrome.clearNotify()

proc queueSteering(L: LuaState, text: string) =
  ## Append the draft text to neopi.steeringQueue (the Lua array table the
  ## loop drains between turns — pi's model).
  lua_getfield(L, luaGlobalsIndex, "neopi")
  lua_getfield(L, -1, "steeringQueue")
  let n = cint(lua_objlen(L, -1))
  pushString(L, text)
  lua_rawseti(L, -2, n + 1)
  lua_pop(L, 2)

proc postDelta*(state: ptr TuiState, text: string) =
  ## Hand one streamed delta to the app's queue as an agent event. The app owns
  ## the transcript update and the frame: this only says what happened. Going
  ## through the queue instead of drawing here is what gives the render path a
  ## single owner, and the widget's `apply` keeps the per-item line caches
  ## (the model's apply plus `invalidateLines` was the sledgehammer that reset
  ## every cache revision and re-wrapped the whole transcript per token: 6.6 s
  ## at 5000 entries, the number bench/tui_bench.nim measured).
  if not state[].appReady:
    return
  state[].app.post(agentEvent(AgentUiEvent(kind: ueTextDelta, text: text)))

proc pumpApp*(state: ptr TuiState): bool =
  ## Drain everything pending through the app's own dispatch — the keys, the
  ## resume menu, the transcript's keys and the agent events all take the one
  ## path — and report whether the user asked to abort the turn. The app
  ## renders as it goes (a key forces a frame, the rest wait for the frame
  ## budget), so this is the whole loop and not half of it.
  if not state[].appReady:
    return state[].abortRequested
  while state[].app.step(0):
    discard
  state[].abortRequested

proc presentApp*(state: ptr TuiState) =
  ## Present the frame through the app, which owns the canvas, the dirty flag
  ## and the frame budget. The stream sink used to clear, render and present by
  ## hand, which is how it could present a frame nothing had invalidated.
  refreshFooter(state)
  if not state[].appReady:
    return
  state[].app.invalidate()
  state[].app.flush()


proc postRunFinished*(state: ptr TuiState) =
  ## Close the streamed run in the widget. The deltas were provisional — the
  ## session carries the entry they belong to — and a run that never ends would
  ## leave its pending item behind, so the sync would append the real entry
  ## beside it and the same text would show twice. The event goes through the
  ## queue like every other one, and the pump right after is what settles the
  ## widget state before the sync reads it.
  if not state[].appReady:
    return
  state[].app.post(agentEvent(AgentUiEvent(kind: ueRunFinished)))
  discard pumpApp(state)

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
    setCoreStatus(state, "no sessions to resume")
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
    setCoreStatus(state, "cannot resume " & path & ": " & e.msg)
    state[].menu = nil
    if not state[].screen.isNil: state[].screen.menu = nil
    return
  state[].menu = nil
  if not state[].screen.isNil: state[].screen.menu = nil
  state[].working = false
  setCoreStatus(state, "")
  # The loaded session is a new tree: rebuild and re-watermark.
  seedTranscript(state)
  refreshFooter(state)

# stacktrace off: the ui/sink callbacks' frames a lua_error longjmp abandons
# (see the note at the file top).
{.push stacktrace: off.}

proc tuiOnEventCB(L: LuaState): cint {.cdecl.} =
  ## The stream sink's C callback: the first upvalue is the TUI state pointer.
  ## It hands the delta to the app as an agent event, lets the app dispatch —
  ## which is what drains the keys and renders — and answers false when the
  ## user asked to abort, the stream's cancel contract (the same as ever).
  let state = cast[ptr TuiState](lua_touserdata(L, luaUpvalueIndex(1)))
  let event = jsonOfStack(L, 1)
  if event.kind == JObject and event.hasKey("text"):
    postDelta(state, event["text"].getStr(""))
  let abort = pumpApp(state)
  presentApp(state)
  lua_pushboolean(L, cint(ord(not abort)))
  result = 1

{.pop.}

proc exposeTuiSink*(L: LuaState, state: ptr TuiState, model: string) =
  ## Expose the TUI's stream sink and the model on the `neopi` table, where
  ## the loop's chunk references them: `_tuiOnEvent` is the Lua function
  ## carrying the TUI state pointer as its first upvalue (it hands the deltas
  ## to the app as agent events, lets the app dispatch and render, and answers
  ## the abort) and `_tuiModel` is the model as a Lua string. Also
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
  # The TUI is up: this is the flag headless modes read as false.
  lua_pushboolean(L, 1)
  lua_setfield(L, -2, "hasUI")
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

proc turnContinues*(response: JsonNode, steered: bool): bool =
  ## Whether the drive runs another turn after one turn's response: the
  ## engine's continueLoop flag (the model asked for tools, or the steering
  ## drained after the assistant entry), or steering queued in the gap. No
  ## step cap in the TUI drive (nimlet's while-true): the user steers and
  ## aborts.
  let continues = response.kind == JObject and
    response.hasKey("continueLoop") and response["continueLoop"].getBool(false)
  result = continues or steered

proc steeringQueueLen(L: LuaState): int =
  ## The steering queue's length (0 without the table — the headless state
  ## has no queue until the sink binds it).
  result = 0
  lua_getfield(L, luaGlobalsIndex, "neopi")
  if lua_type(L, -1) == luaTTable:
    lua_getfield(L, -1, "steeringQueue")
    if lua_type(L, -1) == luaTTable:
      result = int(lua_objlen(L, -1))
    lua_pop(L, 1)
  lua_pop(L, 1)

proc drainGapKeys(state: ptr TuiState, L: LuaState): bool =
  ## The between-turns gap: let the app drain the pending keys (Esc asks for
  ## the abort, Enter queues steering, the editing keys build the draft) and
  ## present the frame, then report whether steering was queued — it asks for
  ## another turn, pi's model, and the next turn's drainSteering delivers it.
  let before = steeringQueueLen(L)
  discard pumpApp(state)
  presentApp(state)
  result = steeringQueueLen(L) > before

proc sendTurn*(state: ptr TuiState, L: LuaState) =
  ## Dispatch the input's text: /resume opens the menu, other /-prefixed
  ## inputs run through the runtime's registry, and plain text becomes a
  ## user entry + the turn drive: one turn per evalJson, with the app draining
  ## keys and events between turns (nimlet's while-true — no step cap: the user
  ## steers and aborts).
  let text = state[].inputW.text
  if text.len == 0:
    return
  clearTransient(state)
  if text.startsWith("/"):
    runCommand(state, L, text)
    return
  try:
    state[].sess.append(SessionEntry(kind: ekUser, text: text))
  except CatchableError as e:
    appendStatusLine(state, "cannot append: " & e.msg)
    return
  appendUserLine(state, text)
  # The widget already shows this entry, so the watermark moves with it: it
  # tracks what the transcript displays, whoever put it there.
  state[].syncedId = state[].sess.currentId
  state[].inputW.clear()
  # The turn drive: agent.runTurn(neopi.session, {model, onEvent}) — one
  # call per turn. `working` is up for the whole drive, which is what the
  # footer's token reads and what makes a submit steer instead of recursing.
  let chunk = "local agent = require('agent'); " &
    "return agent.runTurn(neopi.session, " &
    "{model = neopi._tuiModel, onEvent = neopi._tuiOnEvent})"
  state[].working = true
  state[].abortRequested = false
  while true:
    var response: JsonNode
    try:
      response = evalJson(L, chunk)
    except LuaError as e:
      appendStatusLine(state, "the loop failed: " & e.msg)
      break
    # The turn's run is over: the streamed text was provisional and the session
    # now carries the entry it belongs to. Closing the run in the widget first
    # is what lets the sync append the real entry instead of leaving both.
    postRunFinished(state)
    syncTranscript(state)
    # The gap between turns: the app drains the keys and presents.
    let steered = drainGapKeys(state, L)
    if state[].abortRequested or not turnContinues(response, steered):
      break
  state[].working = false
  postRunFinished(state)
  syncTranscript(state)
  presentApp(state)

proc handleTuiAction*(state: ptr TuiState, L: LuaState,
                      action: UiAction): bool =
  ## Dispatch one widget action, returning whether the TUI owns it. `submit`
  ## sends the composer's text through the turn drive (the commands,
  ## /resume, or the turn) and `copy` lands the transcript's drag selection
  ## on the clipboard — nimterm emits `copy` when a selection is released,
  ## and the action callback used to drop every kind but `submit`. Anything
  ## else is not ours, so the caller can leave it alone.
  case action.kind
  of "submit":
    sendTurn(state, L)
    true
  of "copy":
    if not state[].clipboard.isNil:
      state[].clipboard(action.value)
    true
  else:
    false

# stacktrace off: the ui callbacks' frames a lua_error longjmp abandons (see
# the note at the file top).
{.push stacktrace: off.}

proc readLevel(L: LuaState, index: cint): NotifyLevel =
  ## Read the notify level, defaulting to info. An unknown level is refused: a
  ## typo that quietly fell back to "info" would hide the severity the
  ## extension meant to show.
  if lua_type(L, index) == luaTNil:
    return nlInfo
  if lua_type(L, index) != luaTString:
    raiseLuaError(L,
      "the notify level must be \"info\", \"warning\" or \"error\"")
  case $lua_tolstring(L, index, nil)
  of "info": nlInfo
  of "warning": nlWarning
  of "error": nlError
  else:
    raiseLuaError(L,
      "the notify level must be \"info\", \"warning\" or \"error\"")

proc luaUiNotify(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.ui.notify(text, level)`: show one transient line, painted
  ## with the level's theme token. The core clears it on the next submit, and a
  ## nil or empty text clears it now. A no-op without the TUI.
  let state = cast[ptr TuiState](getRegistryPointer(L, tuiStateRegistryKey))
  let shape = "neopi.ui.notify expects (text: string|nil, level?: string)"
  if lua_gettop(L) > 2:
    raiseLuaError(L, shape)
  var text = ""
  if lua_gettop(L) >= 1 and lua_type(L, 1) != luaTNil:
    if lua_type(L, 1) != luaTString:
      raiseLuaError(L, shape)
    text = $lua_tolstring(L, 1, nil)
  var level = nlInfo
  if lua_gettop(L) >= 2:
    level = readLevel(L, 2)
  if not state.isNil and not state[].chrome.isNil:
    if text.len == 0:
      state[].chrome.clearNotify()
    else:
      state[].chrome.setNotify(text, level)
  lua_pushnil(L)
  result = 1

proc luaUiWorking(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.ui.working(text)`: replace the token the footer appends
  ## while the stream is in flight; nil or an empty text restores "working". A
  ## no-op without the TUI.
  let state = cast[ptr TuiState](getRegistryPointer(L, tuiStateRegistryKey))
  if lua_gettop(L) > 1:
    raiseLuaError(L, "neopi.ui.working expects (text: string|nil)")
  var text = ""
  if lua_gettop(L) == 1 and lua_type(L, 1) != luaTNil:
    if lua_type(L, 1) != luaTString:
      raiseLuaError(L, "neopi.ui.working expects (text: string|nil)")
    text = $lua_tolstring(L, 1, nil)
  if not state.isNil:
    setWorking(state, text)
  lua_pushnil(L)
  result = 1

proc luaUiTitle(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.ui.title(text)`: name the terminal window (OSC 2); nil or
  ## an empty text hands the title back to the terminal. A no-op without the
  ## TUI, where no writer is bound and the state only records it.
  let state = cast[ptr TuiState](getRegistryPointer(L, tuiStateRegistryKey))
  if lua_gettop(L) > 1:
    raiseLuaError(L, "neopi.ui.title expects (text: string|nil)")
  var text = ""
  if lua_gettop(L) == 1 and lua_type(L, 1) != luaTNil:
    if lua_type(L, 1) != luaTString:
      raiseLuaError(L, "neopi.ui.title expects (text: string|nil)")
    text = $lua_tolstring(L, 1, nil)
  if not state.isNil:
    setTitle(state, text)
  lua_pushnil(L)
  result = 1

proc readLineList(L: LuaState, index: cint, what: string): seq[string] =
  ## Read a line list off the stack: a string is one line and a table is its
  ## array part, every element a string. Anything else raises the Lua error
  ## naming `what`, so an extension's own pcall turns a malformed call into a
  ## load failure instead of a silent no-op.
  case lua_type(L, index)
  of luaTString:
    result = @[$lua_tolstring(L, index, nil)]
  of luaTTable:
    for i in 1 .. cint(lua_objlen(L, index)):
      lua_rawgeti(L, index, i)
      if lua_type(L, -1) != luaTString:
        lua_pop(L, 1)
        raiseLuaError(L, what)
      result.add $lua_tolstring(L, -1, nil)
      lua_pop(L, 1)
  else:
    raiseLuaError(L, what)

proc readPlacement(L: LuaState, index: cint): WidgetPlacement =
  ## Read the only option the widget slot takes, refusing anything else: a typo
  ## that quietly falls back to the default is a mystery, not a convenience.
  var placement = wpAboveEditor
  lua_pushnil(L)
  while lua_next(L, index) != 0:
    if lua_type(L, -2) != luaTString or
        $lua_tolstring(L, -2, nil) != "placement" or
        lua_type(L, -1) != luaTString:
      lua_pop(L, 2)
      raiseLuaError(L, "the widget options take only placement")
    let value = $lua_tolstring(L, -1, nil)
    lua_pop(L, 1)
    case value
    of "aboveEditor": placement = wpAboveEditor
    of "belowEditor": placement = wpBelowEditor
    else:
      raiseLuaError(L,
        "the placement must be \"aboveEditor\" or \"belowEditor\"")

proc luaUiHeader(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.ui.header(lines)`: replace the header block with one line
  ## (a string) or several (an array of strings); with no argument, or nil, the
  ## header goes away and its rows go back to the transcript. A no-op without
  ## the TUI (the registry pointer is nil — the print mode and the specs).
  let state = cast[ptr TuiState](getRegistryPointer(L, tuiStateRegistryKey))
  if lua_gettop(L) > 1:
    raiseLuaError(L, "neopi.ui.header expects (lines: string|array|nil)")
  var lines: seq[string]
  if lua_gettop(L) == 1 and lua_type(L, 1) != luaTNil:
    lines = readLineList(L, 1,
      "neopi.ui.header expects (lines: string|array|nil)")
  if not state.isNil and not state[].chrome.isNil:
    state[].chrome.setHeader(lines)
  lua_pushnil(L)
  result = 1

proc luaUiStatus(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.ui.status(key, text)`: set one status row; a nil or empty
  ## text clears that key. The key is required — the unkeyed form this replaces
  ## could be neither updated nor cleared.
  let state = cast[ptr TuiState](getRegistryPointer(L, tuiStateRegistryKey))
  if lua_gettop(L) < 1 or lua_type(L, 1) != luaTString:
    raiseLuaError(L, "neopi.ui.status expects (key: string, text: string|nil)")
  var text = ""
  if lua_gettop(L) >= 2 and lua_type(L, 2) != luaTNil:
    if lua_type(L, 2) != luaTString:
      raiseLuaError(L,
        "neopi.ui.status expects (key: string, text: string|nil)")
    text = $lua_tolstring(L, 2, nil)
  if not state.isNil and not state[].chrome.isNil:
    let key = $lua_tolstring(L, 1, nil)
    if text.len == 0:
      state[].chrome.clearStatus(key)
    else:
      state[].chrome.setStatus(key, text)
  lua_pushnil(L)
  result = 1

proc luaUiWidget(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.ui.widget(key, lines, opts)`: set one placed block. `lines`
  ## is a string or an array of strings, `opts.placement` is "aboveEditor" (the
  ## default) or "belowEditor", and a nil `lines` clears that key. An unknown
  ## option is refused. A no-op without the TUI.
  let state = cast[ptr TuiState](getRegistryPointer(L, tuiStateRegistryKey))
  let shape = "neopi.ui.widget expects (key: string, lines: string|array|nil, " &
    "opts?: table)"
  if lua_gettop(L) < 1 or lua_type(L, 1) != luaTString:
    raiseLuaError(L, shape)
  if lua_gettop(L) >= 3 and lua_type(L, 3) != luaTNil and
      lua_type(L, 3) != luaTTable:
    raiseLuaError(L, shape)
  var lines: seq[string]
  if lua_gettop(L) >= 2 and lua_type(L, 2) != luaTNil:
    lines = readLineList(L, 2,
      "the widget lines must be a string or an array of strings")
  var placement = wpAboveEditor
  if lua_gettop(L) >= 3 and lua_type(L, 3) == luaTTable:
    placement = readPlacement(L, 3)
  if not state.isNil and not state[].chrome.isNil:
    let key = $lua_tolstring(L, 1, nil)
    if lines.len == 0:
      state[].chrome.clearWidget(key)
    else:
      state[].chrome.setWidget(key, lines, placement)
  lua_pushnil(L)
  result = 1

{.pop.}

proc exposeUi*(L: LuaState) =
  ## Expose the `neopi.ui` table inside the existing `neopi` table: header,
  ## status and widget, the Lua UI primitives for extensions. The callbacks
  ## read the TUI state pointer from the registry (nil without the TUI — the
  ## print mode and the headless specs), so they are no-ops there; the TUI
  ## binds the pointer in exposeTuiSink. Requires `neopi` to exist
  ## (newHookBus creates it).
  lua_getfield(L, luaGlobalsIndex, "neopi")
  if lua_type(L, -1) != luaTTable:
    lua_pop(L, 1)
    raise newException(LuaError,
      "the ui primitives require the neopi table (call newHookBus first)")
  lua_createtable(L, 0, 7)
  lua_pushcfunction(L, luaUiHeader)
  lua_setfield(L, -2, "header")
  lua_pushcfunction(L, luaUiStatus)
  lua_setfield(L, -2, "status")
  lua_pushcfunction(L, luaUiWidget)
  lua_setfield(L, -2, "widget")
  lua_pushcfunction(L, luaUiNotify)
  lua_setfield(L, -2, "notify")
  lua_pushcfunction(L, luaUiWorking)
  lua_setfield(L, -2, "working")
  lua_pushcfunction(L, luaUiTitle)
  lua_setfield(L, -2, "title")
  lua_setfield(L, -2, "ui")
  # The guard extensions need to skip UI work instead of calling a no-op: the
  # TUI flips it in exposeTuiSink, and it is the one read a headless mode can
  # act on. It belongs to `neopi` (the mode), not inside `neopi.ui` — setting
  # it before the `ui` field landed put it on the wrong table.
  lua_pushboolean(L, 0)
  lua_setfield(L, -2, "hasUI")
  lua_pop(L, 1)

proc installTuiTheme*(requested: string, depth: ColorDepth): Theme =
  ## Resolve and install the theme the TUI paints with, returning what was
  ## installed. `requested` names a builtin theme ("dark" or "light",
  ## trimmed and case-insensitive); anything else — empty or unknown alike —
  ## resolves exactly like unset, so nimterm's auto policy decides the
  ## background (COLORFGBG) and `depth` decides the color encoding. The
  ## normalization is not cosmetic: `compileBuiltinTheme` answers
  ## `ok = false` for a name that is not a builtin, and installing that
  ## would wipe the colors instead of falling back.
  var name = requested.strip.toLowerAscii
  if name != "dark" and name != "light":
    name = "auto"
  let (ok, theme) = compileBuiltinTheme(name, depth)
  if ok:
    setTheme(theme)
    return theme
  currentTheme

proc wireApp*(state: ptr TuiState, L: LuaState, app: var App) =
  ## Attach the TUI's app callbacks, in one place, so the keys, the agent
  ## events and the widget actions all take the path the app owns — and so the
  ## wiring is testable without a terminal, which the loop itself could not be.
  ##
  ## The precedence, in order: the agent events from the stream land in the
  ## transcript; while the turn runs Esc and Ctrl+C are the abort request, which
  ## is what cancels the stream (exiting there would drop the partial turn);
  ## Ctrl+C alone exits; the resume menu keeps its keys while it is open, paging
  ## included; Esc with nothing running clears the composer, which is what the
  ## README promises; and the transcript owns its page keys before the focused
  ## editor sees them.
  app.onEvent = proc (app: var App, event: UiEvent): EventResponse =
    if event.kind == uiAgent:
      state[].transcriptW.apply(event.agent)
      app.invalidate()
      return eventHandled
    if event.kind != uiKey:
      return eventIgnored
    if state[].working and
        (event.key == keyEscape or event.key == keyCtrlC):
      state[].abortRequested = true
      return eventHandled
    if event.key == keyCtrlC:
      app.running = false
      return eventHandled
    if not state[].screen.isNil and not state[].screen.menu.isNil and
        state[].screen.menu.items.len > 0:
      case event.key
      of keyUp, keyDown, keyPageUp, keyPageDown:
        let response = state[].screen.menu.handle(event)
        app.invalidate()
        if response.handled: return response
      of keyEnter:
        let menu = state[].screen.menu
        if menu.items.len > 0:
          let picked = menu.items[menu.selected]
          resumeSession(state, L, picked.description)
        return eventHandled
      of keyEscape:
        state[].screen.menu = nil
        state[].menu = nil
        app.invalidate()
        return eventHandled
      else:
        discard
    if event.key == keyEscape:
      state[].inputW.clear()
      app.invalidate()
      return eventHandled
    if routeTranscriptKey(state, event):
      app.invalidate()
      return eventHandled
    eventIgnored

  app.onAction = proc (app: var App, action: UiAction) =
    ## A submit while the turn runs is steering, not another turn: the drive is
    ## already inside `evalJson` and a nested turn would recurse into it. The
    ## rest goes to the shared action dispatch.
    if action.kind == "submit" and state[].working:
      let draft = state[].inputW.text
      if draft.len > 0 and not L.isNil:
        queueSteering(L, draft)
      state[].inputW.clear()
      app.invalidate()
      return
    discard handleTuiAction(state, L, action)

proc tuiLoop*(sess: Session, L: LuaState, provider, model: string,
              root = ""): string =
  ## Run the TUI: nimterm's App is the loop owner; the send path runs the
  ## same agent.run chunk the print mode uses, and the stream sink hands the
  ## app its events and lets it dispatch and present while the turn's waitFor
  ## pumps it. Returns "" on a clean exit or the loop's failure message.
  # The theme goes in before anything renders: nimterm's module default is
  # the dark 256 palette unconditionally, so without this the TUI ignores a
  # light background, a color-less terminal and a truecolor one alike.
  discard installTuiTheme(getEnv("NEOPI_THEME"), detectDepth())
  var state = initTuiState(provider, model, sess, root)
  exposeTuiSink(L, addr state, model)
  let screenWidget = buildScreen(addr state)
  var app = newApp(newPlatformBackend(fullscreen = true), screenWidget)
  # The app owns the frame from here: the sink hands it events and lets it
  # dispatch and present, and the turn's waitFor is what pumps it.
  state.app = app
  state.appReady = true
  app.focus(Widget(state.inputW))
  refreshFooter(addr state)
  wireApp(addr state, L, app)

  app.run()
  return ""
