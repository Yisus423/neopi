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

- [ ] 1. The abort: the exposure's cancel handling (the accumulator + the
      partial response) + frCancelled + stopReasonOf
- [ ] 2. The steering: the sink's key polling + neopi.steeringQueue + the
      keyPoller injection
- [ ] 3. The loop (agent.lua): the drain between turns
- [ ] 4. The tests: tp_expose (the abort: the partial response + the
      deltas) + tp_tui (the sink's key paths with the injected poller) +
      the busted spec (the drain)
- [ ] 5. Work-unit commit (5b-1) on main; record evidence here
- [ ] 6. neopi.ui.status + neopi.ui.widget: the primitives + the TUI's
      render (the widgets above the footer)
- [ ] 7. The ui tests + the busted spec
- [ ] 8. Work-unit commit (5b-2) on main; record evidence here

## Evidence

(pending)
