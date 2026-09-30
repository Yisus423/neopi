## The neopi TUI: the transcript, the composer, and the footer over a thin
## illwill loop.
##
## The design separates the pure render logic (the transcript's line
## building, text wrapping, the composer's editing state, the footer, the
## scroll window) from the terminal I/O, so the pure layer is testable
## without a terminal. The interface drives the engine — the loop
## (runtime/agent.lua) and the session tree do not change: the composer
## sends through the same agent.run chunk the print mode uses, the stream
## deltas render live through the onEvent sink, and the session persists
## through the same append path.

import std/[json, os, strutils]
import illwill
import neopi/lua
import neopi/session
from neopi/hooks import lua_error

# setControlCHook comes from system (no import needed): the SIGINT hook is
# the user's job — illwill does not install one.

# Same file-scope typedef as lua.nim and the bridge modules: no C headers
# exist to declare the opaque state type, and this file's generated C
# prototypes take it (the stream sink's C callback).
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

# stacktrace off around the bridge procs whose frames a lua_error longjmp
# abandons: with frames on it skips the frame pops and corrupts the runtime
# frame stack (the next nimFrame call segfaults). The TUI's own procs keep
# their stack traces — only the bridge procs pay the containment's price.
{.push stacktrace: off.}

proc raiseLuaError(L: LuaState, message: string) {.noreturn.} =
  ## Push `message` and raise it as a Lua error; lua_error longjmps to the
  ## enclosing pcall, so control never returns here. The file-scope copy the
  ## other bridge modules carry (fs, process, hooks, expose).
  lua_pushstring(L, message)
  discard lua_error(L)

{.pop.}

type
  ComposerState* = object
    ## The editable input line: the text with the cursor index into it
    ## (0 ..< len).
    text*: string
    cursor*: int

  TuiState* = object
    ## The mutable TUI state the key loop and the stream sink drive: the
    ## footer labels, the session (borrowed from the caller), the composer,
    ## the transcript's scroll offset, the in-flight stream text, the exit
    ## flag, the injected key poller (the tests swap it; the sink polls
    ## the stream-time keys through it), and the extension UI (the status
    ## line and the widget lines the neopi.ui primitives set).
    provider*: string
    model*: string
    sess*: Session
    composer*: ComposerState
    scrollOffset*: int
    streaming*: string
    quit*: bool
    keyPoller*: proc (): Key {.closure.}
    statusLine*: string
    widgets*: seq[tuple[name, text: string]]

const tuiStateRegistryKey = "neopi.tui.state"

proc initTuiState*(provider, model: string, sess: Session): TuiState =
  ## Constructor: a fresh TUI state — the composer empty, the view following
  ## the bottom, nothing in flight, the key poller on illwill's getKey, no
  ## extension UI.
  TuiState(provider: provider, model: model, sess: sess,
    composer: ComposerState(), scrollOffset: 0, streaming: "", quit: false,
    keyPoller: proc (): Key = getKey(), statusLine: "", widgets: @[])

proc wrapLine*(s: string, width: int): seq[string] =
  ## Word-wrap `s` so each returned line is at most `width` columns: the
  ## break lands on the last space before the limit, hard mid-word when
  ## there is none, and one break space is consumed. Width below 1 returns
  ## the line unwrapped.
  result = newSeq[string]()
  if width < 1:
    result.add s
    return
  if s.len == 0:
    result.add ""
    return
  var pos = 0
  while pos < s.len:
    if s.len - pos <= width:
      result.add s[pos ..< s.len]
      pos = s.len
    else:
      var take = width
      var i = pos + width - 1
      while i > pos and s[i] != ' ':
        dec i
      if i > pos:
        take = i - pos
      result.add s[pos ..< pos + take].strip(leading = false)
      pos += take
      if pos < s.len and s[pos] == ' ':
        inc pos

proc transcriptLines*(entries: seq[SessionEntry]): seq[string] =
  ## The display lines for the session entries in order: the kind prefix per
  ## entry (user, assistant, toolResult with its error marker, compaction's
  ## summary), already split on newlines — wrapping to the terminal width
  ## happens at render time.
  var prefixed: seq[string] = @[]
  for entry in entries:
    case entry.kind
    of ekUser:
      prefixed.add "you: " & entry.text
    of ekAssistant:
      prefixed.add "assistant: " & entry.text
    of ekToolResult:
      if entry.isError:
        prefixed.add "tool " & entry.toolName & " (error): " & entry.output
      else:
        prefixed.add "tool " & entry.toolName & ": " & entry.output
    of ekCompaction:
      prefixed.add "-- compaction: " & entry.summary
  result = newSeq[string]()
  for line in prefixed:
    for piece in line.splitLines():
      result.add piece

proc streamingLines*(text: string): seq[string] =
  ## The display lines for the in-flight assistant text: the same prefix the
  ## completed assistant entry renders with, split on newlines.
  result = newSeq[string]()
  for piece in ("assistant: " & text).splitLines():
    result.add piece

proc usageTotals*(entries: seq[SessionEntry]): tuple[tokensIn, tokensOut: int] =
  ## The cumulative token usage across the assistant entries — the footer's
  ## numbers.
  result = (tokensIn: 0, tokensOut: 0)
  for entry in entries:
    if entry.kind == ekAssistant:
      result.tokensIn += entry.usageInput
      result.tokensOut += entry.usageOutput

proc footerLine*(provider, model: string, tokensIn, tokensOut: int): string =
  ## The footer status line: the provider and model with the session's
  ## cumulative token usage.
  return provider & "/" & model & " | in " & $tokensIn & " | out " & $tokensOut

proc visibleRange*(totalLines, visibleLines, scrollOffset: int): Slice[int] =
  ## The slice of transcript lines on screen: offset 0 follows the bottom
  ## (the newest lines), larger offsets scroll toward the top and clamp at
  ## the first line.
  if visibleLines < 1 or totalLines < 1:
    return 0 ..< 0
  let maxOffset = max(0, totalLines - visibleLines)
  let offset = max(0, min(scrollOffset, maxOffset))
  let first = max(0, totalLines - visibleLines - offset)
  let last = min(totalLines - 1, first + visibleLines - 1)
  result = first .. last

proc composerInsert*(c: var ComposerState, s: string) =
  ## Insert `s` at the cursor and move the cursor past it.
  let head = c.text[0 ..< c.cursor]
  let tail = if c.cursor < c.text.len: c.text[c.cursor ..^ 1] else: ""
  c.text = head & s & tail
  c.cursor += s.len

proc composerBackspace*(c: var ComposerState) =
  ## Delete the character before the cursor; a no-op at the start.
  if c.cursor > 0:
    let head = c.text[0 ..< c.cursor - 1]
    let tail = if c.cursor < c.text.len: c.text[c.cursor ..^ 1] else: ""
    c.text = head & tail
    dec c.cursor

proc composerLeft*(c: var ComposerState) =
  ## Move the cursor one character left; a no-op at the start.
  if c.cursor > 0:
    dec c.cursor

proc composerRight*(c: var ComposerState) =
  ## Move the cursor one character right; a no-op at the end.
  if c.cursor < c.text.len:
    inc c.cursor

proc composerClear*(c: var ComposerState) =
  ## Clear the text and reset the cursor (the Esc behavior).
  c.text = ""
  c.cursor = 0

proc clip(s: string, width: int): string =
  ## Truncate a single-line string to `width` columns: the composer and the
  ## footer do not wrap.
  if s.len <= width:
    result = s
  else:
    result = s[0 ..< width]

proc drawScreen(state: ptr TuiState) =
  ## Render the whole frame into a fresh buffer and flush it: the transcript
  ## (the scroll window over the wrapped lines), the in-flight stream text,
  ## the composer, and the footer. A fresh buffer per frame is the component
  ## model's invalidate step. The dimensions clamp to at least 1: a 0-sized
  ## terminal (a non-tty, as in the tests) would defect inside illwill's
  ## clear.
  let width = max(1, int(terminalWidth()))
  let height = max(1, int(terminalHeight()))
  var tb = newTerminalBuffer(width, height)
  var entries: seq[SessionEntry] = @[]
  if not state[].sess.isNil:
    entries = state[].sess.history()
  var logical: seq[string] = @[]
  for line in transcriptLines(entries):
    logical.add line
  if state[].streaming.len > 0:
    for line in streamingLines(state[].streaming):
      logical.add line
  var wrapped: seq[string] = @[]
  for line in logical:
    for piece in wrapLine(line, width):
      wrapped.add piece
  let transcriptHeight = max(1, height - 2 - state[].widgets.len -
    (if state[].statusLine.len > 0: 1 else: 0))
  let visible = visibleRange(wrapped.len, transcriptHeight,
    state[].scrollOffset)
  var row = 0
  for i in visible:
    tb.write(0, row, wrapped[i])
    inc row
  for w in state[].widgets:
    tb.write(0, row, clip(w.text, width))
    inc row
  if state[].statusLine.len > 0:
    tb.write(0, row, clip(state[].statusLine, width))
    inc row
  tb.write(0, max(0, height - 2), clip("> " & state[].composer.text, width))
  let totals = usageTotals(entries)
  tb.write(0, max(0, height - 1),
    clip(footerLine(state[].provider, state[].model, totals.tokensIn,
    totals.tokensOut), width))
  tb.display()

proc requestRender*(state: ptr TuiState) =
  ## The component model's invalidate + re-render + flush: rebuild the whole
  ## frame from the current state and flush it. The key loop and the stream
  ## sink drive it on the input change, the stream deltas, the new entries,
  ## and the resize. An IllwillError (the terminal unavailable — the module
  ## not initialised, as in the tests) is swallowed: the sink runs inside
  ## the Lua boundary and must never raise across it.
  try:
    drawScreen(state)
  except IllwillError:
    discard

proc pageStep*(height: int): int =
  ## Half the transcript area: the PgUp/PgDn scroll step.
  max(1, max(1, height - 2) div 2)

proc handleKey*(state: var TuiState, key: Key, height: int) =
  ## Apply one key press to the TUI state: the composer's editing (printable
  ## insert, Backspace, Left/Right), Esc's clear, and the transcript's
  ## scroll (PageUp/PageDown a page, Up/Down a line). Enter and Ctrl+C are
  ## the loop's decisions (send and exit), not handled here.
  case key
  of Key.Escape:
    composerClear(state.composer)
  of Key.Backspace:
    composerBackspace(state.composer)
  of Key.Left:
    composerLeft(state.composer)
  of Key.Right:
    composerRight(state.composer)
  of Key.PageUp:
    state.scrollOffset += pageStep(height)
  of Key.PageDown:
    state.scrollOffset = max(0, state.scrollOffset - pageStep(height))
  of Key.Up:
    inc state.scrollOffset
  of Key.Down:
    if state.scrollOffset > 0:
      dec state.scrollOffset
  else:
    let code = ord(key)
    if code >= 32 and code <= 126:
      composerInsert(state.composer, $chr(code))

proc queueSteering(L: LuaState, text: string) =
  ## Append the draft text to neopi.steeringQueue (the Lua array table the
  ## loop drains between turns — pi's model). Requires neopi and the queue
  ## to exist (exposeTuiSink creates both).
  lua_getfield(L, luaGlobalsIndex, "neopi")
  lua_getfield(L, -1, "steeringQueue")
  let n = cint(lua_objlen(L, -1))
  pushString(L, text)
  lua_rawseti(L, -2, n + 1)
  lua_pop(L, 2)

proc tuiOnEventCB(L: LuaState): cint {.cdecl.} =
  ## The stream sink's C callback: the first upvalue is the TUI state
  ## pointer; read the {text = delta} event table, append the delta to the
  ## in-flight text, poll the stream-time keys (the steering draft, Enter
  ## queues it, Ctrl+C aborts), render the frame live, and return false only
  ## when the user aborted (the stream's cancel).
  let state = cast[ptr TuiState](lua_touserdata(L, luaUpvalueIndex(1)))
  let event = jsonOfStack(L, 1)
  if event.kind == JObject and event.hasKey("text"):
    state[].streaming.add event["text"].getStr("")
  var cancel = false
  while true:
    let key = state[].keyPoller()
    if key == Key.None:
      break
    if key == Key.CtrlC or key == Key.Escape:
      # Esc aborts the stream (pi's model); the draft stays for the
      # recovered composer. Ctrl+C is the OS SIGINT path and never reaches
      # the buffer in cooked mode — the case stays for a raw-mode future.
      cancel = true
    elif key == Key.Enter:
      let draft = state[].composer.text
      if draft.len > 0:
        queueSteering(L, draft)
        composerClear(state[].composer)
    else:
      handleKey(state[], key, terminalHeight())
  requestRender(state)
  lua_pushboolean(L, cint(ord(not cancel)))
  result = 1

proc exposeTuiSink*(L: LuaState, state: ptr TuiState, model: string) =
  ## Expose the TUI's stream sink and the model on the `neopi` table, where
  ## the loop's chunk references them: `_tuiOnEvent` is the Lua function
  ## carrying the TUI state pointer as its first upvalue (the
  ## luaProviderStream pattern — it appends the deltas and renders live) and
  ## `_tuiModel` is the model as a Lua string (so the chunk needs no
  ## escaping). Also binds the TUI state pointer in the registry (the
  ## "neopi.tui.state" key) so the neopi.ui primitives drive the live TUI,
  ## and creates the steering queue: the Lua array table the sink fills
  ## (Enter during a run) and the loop drains between turns (pi's model).
  ## Requires `neopi` to exist (newHookBus creates it).
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

# stacktrace off: the ui callbacks' frames a lua_error longjmp abandons
# (the type-check errors); with frames on it corrupts the runtime frame
# stack (see the note at the file top).
{.push stacktrace: off.}

proc luaUiStatus(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.ui.status(text)`: set the extension status line (one
  ## line above the footer) and re-render. A no-op without the TUI (the
  ## registry pointer is nil — the print mode and the headless specs).
  let state = cast[ptr TuiState](getRegistryPointer(L, tuiStateRegistryKey))
  if lua_gettop(L) != 1 or lua_type(L, 1) != luaTString:
    raiseLuaError(L, "neopi.ui.status expects (text: string)")
  if state.isNil:
    lua_pushnil(L)
    return 1
  state[].statusLine = $lua_tolstring(L, 1, nil)
  requestRender(state)
  lua_pushnil(L)
  result = 1

proc luaUiWidget(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.ui.widget(name, text)`: set or update the named widget
  ## line (one line above the status, in first-set order) and re-render.
  ## A no-op without the TUI.
  let state = cast[ptr TuiState](getRegistryPointer(L, tuiStateRegistryKey))
  if lua_gettop(L) != 2 or lua_type(L, 1) != luaTString or
      lua_type(L, 2) != luaTString:
    raiseLuaError(L, "neopi.ui.widget expects (name: string, text: string)")
  if state.isNil:
    lua_pushnil(L)
    return 1
  let name = $lua_tolstring(L, 1, nil)
  let text = $lua_tolstring(L, 2, nil)
  var idx = -1
  for i, w in state[].widgets:
    if w.name == name:
      idx = i
      break
  if idx >= 0:
    state[].widgets[idx].text = text
  else:
    state[].widgets.add (name: name, text: text)
  requestRender(state)
  lua_pushnil(L)
  result = 1

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

{.pop.}


proc runCommand(state: ptr TuiState, L: LuaState, text: string) =
  ## Dispatch a /-prefixed composer input to the runtime's command registry
  ## (the nvim model — the runtime owns the registry and the dispatch): the
  ## input travels on the neopi table (no escaping needed), and the
  ## returned output renders as the status line. A command failure (an
  ## unknown command, a command error) is FEEDBACK, not a fatal loop error:
  ## it renders in the status line too — the TUI survives a typo /unknown.
  composerClear(state[].composer)
  lua_getfield(L, luaGlobalsIndex, "neopi")
  pushString(L, text)
  lua_setfield(L, -2, "_tuiCommandInput")
  lua_pop(L, 1)
  try:
    let output = evalJson(L,
      "return neopi.runCommand(neopi._tuiCommandInput)")
    if output.kind == JString and output.getStr.len > 0:
      state[].statusLine = output.getStr
    else:
      state[].statusLine = ""
  except LuaError as e:
    state[].statusLine = e.msg
  requestRender(state)

proc sendTurn*(state: ptr TuiState, L: LuaState, loopError: var string) =
  ## Send the composer's text as a user entry and run the loop's chunk with
  ## the stream sink: the assistant entry lands through the engine's append
  ## path and the deltas rendered live through the sink. A composer input
  ## starting with "/" dispatches to the runtime's command registry instead
  ## (pi's model: the command runs immediately, its input never enters the
  ## session). A failure (append or Lua) records the message in `loopError`
  ## and exits the loop; the terminal restores through the caller's deinit.
  let text = state[].composer.text
  if text.len == 0:
    return
  if text.startsWith("/"):
    runCommand(state, L, text)
    return
  try:
    state[].sess.append(SessionEntry(kind: ekUser, text: text))
  except CatchableError as e:
    loopError = "cannot append the user entry: " & e.msg
    state[].quit = true
    return
  composerClear(state[].composer)
  state[].streaming = ""
  state[].scrollOffset = 0
  requestRender(state)
  # The loop: agent.run(neopi.session, {model = ..., onEvent = <the sink>}) —
  # the sink and the model come off the neopi table; the response's text and
  # usage land in the session through the engine's append.
  let chunk = "local agent = require('agent'); " &
    "return agent.run(neopi.session, " &
    "{model = neopi._tuiModel, onEvent = neopi._tuiOnEvent})"
  try:
    discard evalJson(L, chunk)
  except LuaError as e:
    loopError = e.msg
    state[].quit = true
    return
  state[].streaming = ""
  requestRender(state)

proc exitHook() {.noconv.} =
  ## The SIGINT handler: restore the terminal and exit gracefully. Ctrl+C is
  ## the terminal's INTR character (ISIG stays on — illwill does not enable
  ## raw mode), so the OS delivers SIGINT and kills the process before any
  ## key loop sees it; without this hook the death leaves the terminal in
  ## the alternate screen and raw attributes. Tolerates the
  ## non-initialized illwill (the SIGINT can arrive before init).
  try:
    illwillDeinit()
  except IllwillError:
    discard
  showCursor()
  quit(0)

proc tuiLoop*(sess: Session, L: LuaState, provider, model: string): string =
  ## Run the TUI: illwill's init, the key dispatch, the send path (the
  ## agent.run chunk with the stream sink — the deltas render live through
  ## it), and the per-frame redraw. Returns "" on a clean exit (Ctrl+C) or
  ## the loop's failure message; illwill's deinit always restores the
  ## terminal. The session persists through the same append path the engine
  ## uses.
  var state = initTuiState(provider, model, sess)
  # The SIGINT hook before init: the Ctrl+C death restores the terminal
  # (the illwill doc's pattern).
  setControlCHook(exitHook)
  illwillInit(fullScreen = true)
  defer: illwillDeinit()
  exposeTuiSink(L, addr state, model)
  var trackedWidth = int(terminalWidth())
  var trackedHeight = int(terminalHeight())
  requestRender(addr state)
  var loopError = ""
  while not state.quit:
    let key = getKey()
    case key
    of Key.None:
      # The resize trigger: the frame rebuilds on the terminal's new size;
      # otherwise idle with a short sleep (getKey is non-blocking).
      if terminalWidth() != trackedWidth or terminalHeight() != trackedHeight:
        trackedWidth = int(terminalWidth())
        trackedHeight = int(terminalHeight())
        requestRender(addr state)
      else:
        sleep(10)
    of Key.CtrlC:
      state.quit = true
    of Key.Enter:
      sendTurn(addr state, L, loopError)
    else:
      handleKey(state, key, terminalHeight())
      requestRender(addr state)
  return loopError
