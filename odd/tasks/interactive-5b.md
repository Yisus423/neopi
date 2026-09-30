# Interactive 5b: the queues + neopi.ui.*

## Goal

The TUI becomes truly interactive: the abort (Ctrl+C stops the current run's
stream and returns to the composer — no threading, YAGNI per the user) and
the steering queue (the messages typed during a run enter after the current
turn, pi's model). Then the UI primitives for extensions (neopi.ui.*).

The session resume / the session selection: DEFERRED until the agent has
commands (a /resume and the session choice need in-agent commands first —
the user's call, 2026-09-29).

## Verified basis (2026-09-29)

- nimgent: the StreamCallback's false return cancels the run —
  `raiseCancelledError` (default msg "aborted", providers/provider.nim:786)
  → neopi's stream re-raises `CancelledError` (translate, provider.nim).
  The `AbortCheck` (checked before each attempt and tool call) is a second
  mechanism — not needed for the MVP.
- TODAY: the abort would surface as a Lua error (the exposure's
  `except CatchableError` → raiseLuaError) → the loop propagates it → the
  TUI exits — NOT the desired abort.
- illwill: `getKey()` is NON-BLOCKING (Key.None when the buffer is empty);
  the sink polls keys during the stream (per TEXT delta — makeLuaStreamEvent
  only forwards seTextDelta to the Lua onEvent; the tool call deltas and
  seFinished do not fire it).
- neopi's FinishReason enum (provider.nim:55): frUnknown, frEndTurn,
  frToolUse, frMaxTokens, frStop, frStepLimit — NO frCancelled.
- `stopReasonOf` (expose.nim:95): "toolUse" when toolCalls.len > 0, else the
  finish reason's string; the loop keys on `~= "toolUse"`.
- The response shape (luaProviderStream): {text, stopReason,
  usage = {input, output}, toolCalls, provider}.
- The test pattern: tp_expose's stream tests (freshWorkspace +
  newExtensibility(none(Provider), ...) + setScripted + onEvent + evalJson +
  the deltas check). The scripted stream fires ONE delta with the whole
  text.

## Design

### 5b-1: the queues (abort + steering, no threading)

- **The abort**: the exposure's luaProviderStream wraps the sink with a
  delta accumulator (a local `var acc` + a wrapper callback: add the delta
  BEFORE calling the Lua onEvent — the rendered text equals the session's
  partial text); on CancelledError it returns the PARTIAL response
  {text = acc, stopReason = "aborted", usage = {input: 0, output: 0},
  toolCalls = {}, provider = ...} instead of raising — the loop ends the
  turn gracefully (stopReason ~= "toolUse") and the TUI regains control.
- **frCancelled** joins the neopi FinishReason enum; stopReasonOf maps it
  to "aborted".
- **The steering**: the TUI's sink (tuiOnEventCB) polls keys during the
  stream (per text delta): printable → the steering draft (the composer's
  text, visible via requestRender), Enter → the draft queues into
  neopi.steeringQueue (a Lua array table the TUI creates in exposeTuiSink),
  Esc → clears the draft, Ctrl+C → return false (the abort). The key
  polling is injectable for testability: the TuiState gains
  `keyPoller: proc (): Key` (initTuiState defaults it to illwill's getKey;
  the tests inject a stub — no terminal needed).
- **The loop drain** (agent.lua): after the assistant entry lands, before
  the stopReason check — `drainSteering(session)` appends each queued
  message as a user entry and returns whether any appended; the continue
  condition becomes `stopReason ~= "toolUse" and not hadQueued`. Print
  mode: the queue never exists → the drain is a no-op → no behavior change.
  After the run (any exit path), the queue is empty (drained each
  iteration).
- **The follow-up queue**: DEFERRED — the steering/follow-up distinction is
  meaningless when the tool calls are local (milliseconds); one queue
  covers it. Noted as a known limit.
- **The keys**: Enter sends (idle) / queues the draft (during a run); Esc
  clears; Ctrl+C aborts the stream (during a run) / exits (idle).

### 5b-2: neopi.ui.* (the Lua UI primitives)

- `neopi.ui.status(text)` and `neopi.ui.widget(name, text)`: the extensions
  set the status line and the widget lines; the TUI renders them (the
  widgets above the footer, pi-style).
- The bridge: the C callbacks read the TUI state pointer from the registry
  (the "neopi.tui.state" key — the session's registry-pointer pattern; nil
  → no-op); set the state's fields + requestRender.
- Exposed ALWAYS (once, at extensibility time): without the TUI (print
  mode) the primitives are no-ops. exposeTuiSink sets the registry pointer.
- Non-goals: the full component API (the extensions ADD components is
  post-MVP), the mouse.

## Tasks

- [x] 1. The abort: the exposure's cancel handling (the accumulator + the
      partial response) + frCancelled + stopReasonOf
- [x] 2. The steering: the sink's key polling + neopi.steeringQueue + the
      keyPoller injection
- [x] 3. The loop (agent.lua): the drain between turns
- [x] 4. The tests: tp_expose (the abort: the partial response + the
      deltas) + tp_tui (the sink's key paths with the injected poller) +
      the busted spec (the drain)
- [x] 5. Work-unit commit (5b-1) on main; record evidence here
- [x] 6. neopi.ui.status + neopi.ui.widget: the primitives + the TUI's
      render (the widgets above the footer)
- [x] 7. The ui tests + the busted spec
- [x] 8. Work-unit commit (5b-2) on main; record evidence here

## Evidence

### 5b-1 evidence (the queues, done)

- `19aa9bd` — feat: the queues - the abort returns the partial response and
  the steering enters between turns (8 files, 393 insertions: the
  exposure's cancel handling + frCancelled + the sink's key polling +
  neopi.steeringQueue + the loop's drain + the tests + this task file)
- nimble test verbatim: "[Summary] 96 tests run (2.78s): 96 OK, 0 FAILED,
  0 SKIPPED" + busted "5 successes" — the abort test (the partial response
  with the accumulated delta + "aborted"), the 3 sink tests (the draft
  queues on Enter, the Ctrl+C abort, the printable edit — all with the
  injected keyPoller), and the busted drain test (the steering enters after
  the assistant turn and asks for another turn) pass.
- nimlangserver nimCheckFile: 0 diagnostics on tui.nim and provider.nim; a
  pre-existing dead const (providerRegistryKey) found and removed.
- TWO defects caught by the tests:
  1. The sink's requestRender defected in a non-tty (the tests):
     terminalHeight() returns 0 without a terminal and illwill's
     newTerminalBuffer → clear raises a RangeDefect — a Defect is NOT
     catchable by except IllwillError. Fixed: drawScreen clamps the buffer
     dimensions to at least 1. AND requestRender catches IllwillError: the
     sink runs inside the Lua boundary and must never raise across it
     (a Nim exception crossing the C boundary is undefined behavior).
  2. The busted specs share ONE live session (neopi.session) — the drain
     test's history check assumed a fresh session (9 previous entries + 4
     mine = 13). Fixed: tail-based checks (the last four entries).
- The delegation: the writer stalled (4 min after a bash, zero edits — the
  third stall in two slices); the parent implemented 5b-1 inline from the
  task file's contracts.
- Known limits: the follow-up queue deferred (the steering/follow-up
  distinction is meaningless when the tool calls are local); the abort only
  interrupts the stream (the tool calls block briefly; the deltas are the
  long part); no abort marker in the transcript (polish); the key polling
  during the stream happens per text delta (a thinking pause delays it).

### 5b-2 evidence (neopi.ui.*, done)

- `7f1bc9a` — feat: neopi.ui.status and neopi.ui.widget - extensions drive
  the TUI's status and widget lines (5 files, 198 insertions: the ui
  primitives + the TUI's render (the widgets above the footer, the status
  line above them) + the tp_tui ui suite + the busted ui_spec + the
  busted_main's exposeUi)
- nimble test verbatim: "[Summary] 100 tests run (2.48s): 100 OK, 0 FAILED,
  0 SKIPPED" + busted "7 successes" — the ui suite (status sets + re-renders,
  widget sets and updates by name, no-ops without the TUI, the type-check
  errors) and the busted ui_spec (the no-ops + the type errors) pass.
- nimlangserver nimCheckFile: 0 diagnostics on tui.nim, neopi.nim, and
  busted_main.nim; the production binary builds clean (3.4M).
- A SEGFAULT found and fixed (gdb backtrace): the ui callbacks' type-check
  errors longjmp (lua_error) out of their Nim frames — with stacktrace ON
  the abandoned frames corrupt the runtime frame stack and the next
  auxWriteStackTrace segfaults (exit 139, consistent). The four existing
  bridge modules already carry `{.push stacktrace: off.}` for exactly this
  (their comment documents the segfault); tui.nim was missing it. Fixed with
  the pragma scoped to the bridge procs only (raiseLuaError + the ui
  callbacks) — tui.nim is not thin like the others, so the TUI's own procs
  keep their stack traces.
- The exposure: neopi.ui exists ALWAYS (exposed at extensibility time —
  runPrint/runTui/busted_main call exposeUi after newExtensibility); the
  callbacks read the TUI state pointer from the registry ("neopi.tui.state"
  — the session's pattern; nil without the TUI → no-ops); exposeTuiSink
  binds the pointer when the TUI runs. First test attempt: ui1/ui2 forgot
  exposeUi ("attempt to index field 'ui' (a nil value)") — the extensibility
  tests must call exposeUi explicitly (they do not go through neopi.nim).
- The render: the layout is transcript, widgets (one line each, first-set
  order), status line, composer, footer; the transcript height accounts for
  the bottom lines; the scroll step stays approximate (pageStep unchanged).
- Known limits: no widget removal primitive (set-only); the widgets are
  plain text lines (no colors — polish); the full component API (the
  extensions ADD components) is post-MVP.

### Follow-up fix: the abort key is Esc (Ctrl+C's SIGINT reality)

- The user ran the TUI for real: Ctrl+C during a run KILLED the process
  (SIGINT traceback: the death inside asyncdispatch's epoll poll). Root
  cause: illwillInit does NOT enable raw mode or install a SIGINT handler
  on Linux — Ctrl+C is the terminal's INTR character (ISIG on), so the OS
  delivers SIGINT and kills the process before any key loop sees it;
  Key.CtrlC never reaches the buffer, and the death leaves the terminal in
  the alternate screen and raw attributes.
- The fix (the user's call): **Esc aborts the stream** (the sink's Esc case
  → cancel → the partial response → the loop ends the turn → the TUI
  recovers with the draft intact — pi's model). Ctrl+C is now the graceful
  exit: a setControlCHook (the SIGINT handler, the illwill doc's pattern —
  setControlCHook comes from system, not std/terminal) restores the
  terminal (illwillDeinit + showCursor) and quits, tolerating the
  non-initialized illwill (the SIGINT can arrive before init).
- The keys now: Enter sends (idle) / queues the draft (during a run); Esc
  aborts the stream (during a run) / clears the composer (idle); Ctrl+C
  exits gracefully (the OS SIGINT path).
- Verification: nimble test verbatim "[Summary] 101 tests run (2.64s):
  101 OK, 0 FAILED, 0 SKIPPED" + busted "7 successes"; nimCheckFile 0
  diagnostics on tui.nim; the production binary builds clean.
