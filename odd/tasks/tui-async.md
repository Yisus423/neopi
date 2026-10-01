# TUI async: the timer-driven responsiveness (no threading)

## Goal

The TUI stays responsive during the stream — including the thinking pauses
(the freeze the user feels). The mechanism: an asyncdispatch timer the TUI
schedules; the timers fire DURING the stream's waitFor (the event loop
pumps), so the keys poll and the render runs in the gaps between deltas —
no threading, no races (the async dispatch runs on the main thread).

## Decision (2026-09-30 — the user's call)

The order: **async first** (the freeze is the functional pain; the risk
surfaces early), then the polish visual. The mechanism: the timer (not
threading — YAGNI held; the timer achieves the same with zero races).

## Verified basis (2026-09-30)

- nimgent is async inside: `streamText` = `waitFor streamTextAsync` (the
  user's SIGINT traceback showed the epoll). The waitFor PUMPS the event
  loop: the deltas fire the sink during the stream.
- asyncdispatch.addTimer(timeout: int, oneshot: bool, cb: Callback) exists
  (asyncdispatch.nim:1059, the epoll branch); Callback = proc (fd: AsyncFD):
  bool {.closure, gcsafe.}; oneshot = false is periodic.
- processTimers/processTimersBeforePoll run inside poll/runOnce — the
  timers fire during waitFor ✓.
- The async dispatch is single-threaded (the main thread) — the timer's
  callback and the sink interleave on the same thread: no races, no locks.
- The current sink polls keys per delta (the workaround): works for the
  deltas, dead during the thinking pauses. The timer (every 50ms) is more
  uniform — the sink's key polling can GO (simplification).
- The idle loop (getKey + sleep) does not pump the event loop — the timer
  only fires during the streams (harmless there).
- Known risk: the timer's cb requires gcsafe — with --threads:on the
  analysis is strict; the TUI state (a ptr with strings) may not pass the
  check. Mitigation: the callback runs on the main thread (safe in
  reality); a documented gcsafe cast if the compiler insists.

## Design

- **TuiState** gains:
  - `abortRequested*: bool` — the timer sets it on Esc/Ctrl+C; the sink
    checks it per event and cancels the stream (return false → the partial
    response); sendTurn resets it after the run.
  - `lua*: LuaState` — the interpreter, bound in exposeTuiSink (the state +
    the interpreter bind together; the timer's ENTER needs it for the
    steering's queueSteering).
- **pollTimerKeys(state): bool** (exported, testable with the keyPoller
  injection — the established pattern): the timer's key handling — drain
  the input buffer, apply the keys (the composer's editing, the steering's
  Enter → queueSteering with state[].lua, the scroll), set the abort flag
  on Esc/Ctrl+C. Returns whether the abort was requested.
- **The timer** (tuiLoop, before the loop): addTimer(50, false, ...) — the
  callback: pollTimerKeys(state) + requestRender(state) + true (keep).
  Fires only during the waitFor streams.
- **The sink** (tuiOnEventCB): the key polling REMOVED — the delta →
  streaming.add + the abortRequested check (→ cancel) + requestRender.
  Simpler than today.
- **The keys**: unchanged from the user's view: Enter sends (idle) /
  steers (during a run, via the timer); Esc aborts (during a run) / clears
  (idle); Ctrl+C exits gracefully.
- **The tests** (tp_tui): the timer's key handling (pollTimerKeys with the
  injected poller: the abort flag, the steering queue via state[].lua, the
  draft editing); the sink's abortRequested path (the flag → the cancel →
  the partial response); the reset after the run.
- **Non-goals**: threading (YAGNI — the timer covers it); the async API for
  Lua extensions (coroutines — post-MVP); the polish visual (the next
  slice); the abort during a thinking pause waits for the next delta (the
  flag lands then — the same limit as today, noted).

## Tasks

- [x] 1. TuiState: abortRequested + lua (bound in exposeTuiSink)
- [x] 2. pollTimerKeys (the timer's key handling, exported) + the sink's
      simplification (the polling out, the abort check in)
- [x] 3. The timer in tuiLoop (addTimer 50ms periodic)
- [x] 4. The tests: tp_tui (the timer's paths + the sink's abortRequested)
- [x] 5. Work-unit commit on main; record evidence here

## Evidence

- The parent implemented the slice inline (the writers stall systematically
  — the established lesson).
- nimble test verbatim: "[Summary] 108 tests run (1.91s): 108 OK, 0 FAILED,
  0 SKIPPED" + busted "10 successes" — the timer's key handling (the abort
  flag on Esc and Ctrl+C, the steering queue via the state's interpreter,
  the draft editing — all with the injected keyPoller) and the sink's
  abortRequested path (the flag → the cancel → the partial response; the
  flag survives until sendTurn resets it) pass.
- nimlangserver nimCheckFile: 0 diagnostics on tui.nim; the production
  binary builds clean (3.4M).
- THE GCSAFE CHAIN (the compile risk materialized and resolved): the
  compiler's strict check with --threads:on flagged the closure three
  times: (1) "Annotate the proc with {.gcsafe.}" → the annotation on the
  closure was NOT enough — (2) "pollTimerKeys is not GC-safe as it performs
  an indirect call" → the check is on the proc TYPE: the keyPoller field
  needed {.closure, gcsafe.} — (3) the chain resolved: the field's type
  gcsafe + getKey's closure passes. The lesson: a gcsafe closure's indirect
  calls are only safe when the CALLED TYPE is gcsafe; the annotation on
  the caller does not cover the callee's type.
- The design change: the sink's key polling REMOVED (the timer covers it —
  every 50ms vs per delta, more uniform); the abort flows via the
  abortRequested flag (the timer sets it; the sink checks it per event);
  the TuiState gained lua (bound in exposeTuiSink — the timer's steering
  needs the interpreter).
- Known limits: the abort during a thinking pause waits for the next delta
  (the flag lands then — the deltas are the long part but a long pause
  delays the cancel); the timer only fires during the waitFor streams (the
  idle loop has its own polling); no dirty tracking beyond illwill's
  displayDiff.
