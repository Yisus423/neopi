# TUI migration: illwill → nimterm

## Goal

The TUI moves from illwill (the hand-rolled render/key/stream plumbing) to
nimterm (the local framework nimlet runs in production): the unicode width
(unicodedb), the markdown renderer, the agent-agnostic transcript, event
sources for the streaming, integrated timers, SIGWINCH, and the widget
tree. The asyncdispatch timer hack (the "maraña asincrona") goes away —
nimterm's App is the loop owner.

## Decision (2026-10-02 — the user's call)

The user regrets illwill (the unicode widths, the markdown gap) and named
nimterm (the deleted-repo checkout at ~/proyectos/nimterm, MIT — the fork
seed pattern, like nimgent). The TUI/interface work comes before the
extensions. The .tape files are view-only (not a test surface).

## Verified basis (2026-10-02)

- nimterm (~/proyectos/nimterm, 2697 lines, MIT, compiles, its tests pass):
  the widget tree (panel/column/card/input/markdown/transcript/menu/
  question/scroll), text_width (unicodedb: combining→0, wide→2, else→1),
  the EventQueue + EventSource (method poll), integrated timers, SIGWINCH,
  the PosixBackend (raw mode, alternate screen, the input decoder),
  app.nim (the loop owner: pollIntervalMs 16, minFrameIntervalMs).
- nimlet runs it in production: nimterm_adapter (~30 lines: the agent
  events → the UI events), nimterm_screen (748) + nimterm_controller (548).
- THE INTEGRATION PATTERN (nimterm_controller.nim:22-43): NimletTurnSource
  (an EventSource): poll() pumps the async dispatch (asyncdispatch.poll(0),
  non-blocking) and checks the turn's Future; needsPolling: only while a
  turn is active. The agent is async; nimterm's App loop is the owner.
- neopi's provider is async inside already (nimgent's streamText = waitFor
  streamTextAsync) — the waitFor pumps the dispatch while a turn runs.
- neopi's agent loop is SYNCHRONOUS Lua (the engine stays Lua — the nvim
  decision). The chunk blocks; the deltas reach the sink during the
  waitFor.

## The plan (two slices)

### Slice A — the backend swap (this slice)

- nimterm as a local dependency (nim.cfg: --path:../nimterm/src — the
  nimgent pattern).
- The TuiState's render/key plumbing replaced by nimterm's App + widgets:
  the transcript widget (the transcript model: the entries applied via the
  adapter), newInput (the composer), the footer (a themed line), the
  markdown for the assistant text.
- The stream: the sink applies the deltas to nimterm's transcript and
  flushes the frame — live during the waitFor, NO asyncdispatch timer
  (the timer, pollTimerKeys, abortRequested flag, and the keyPoller go
  away).
- The keys: nimterm's input handles the editing; the app's onAction/onEvent
  handles Enter/Esc/Ctrl+C/Up/Down.
- The pure layer: the parts nimterm owns (wrapLine, lineColor on
  transcript items, usageTotals/footerLine, selectLines) shrink or move;
  the tests follow.
- The commands (/) and /resume: the dispatch and the select overlay keep
  their logic; the picker moves to nimterm's menu when it fits, else stays.
- Exit criteria: the same TUI behaviors verified by the pty harness (the
  draft renders, the stream renders live, Esc aborts, Ctrl+C exits,
  /resume loads) + nimble test green.

### Slice B — the loop driver + the abort/steering (this slice)

- agent.runTurn (one turn per call — the loop body extracted: request →
  stream/generate → assistant append → drainSteering → tools + compaction
  when continuing) and agent.run as the driver over it (print mode and the
  scripted tests keep the same contract; maxSteps/stepLimit stay headless).
- The TUI drives: one evalJson per turn, the continue decision between
  turns (the engine's continueLoop flag, or steering queued in the gap),
  the transcript rebuilt per turn (the tool results render live).
- The between-turns gap: feedKeys — Esc aborts the drive, Enter queues the
  steering (pi's model: the next turn's drainSteering delivers it), and
  the editing keys forward to the input (nimlet's composer-alive pattern:
  the draft builds during the run, so steering is typable at all).
- No step cap in the TUI drive (nimlet's while-true): the user steers and
  aborts; the headless run keeps the cap.
- The abort during a stream: the cancel through the sink (the flag the
  sink checks per delta) — the same contract, unchanged. Tool execution
  stays frozen during a run (the threads/async gap pi and nimlet solve —
  deferred).

## Non-goals (both slices)

- The engine stays Lua (the nvim decision); no agent rewrite.
- No theming work beyond nimterm's default theme.
- The .tape files stay view-only.
- neopi.ui.select, lazy.npi: unchanged (deferred).

## Tasks (slice A)

- [x] 1. nimterm as a local dependency (nim.cfg) + the hello-app spike
      compiles and runs in the pty
- [x] 2. The transcript adapter (the session entries → nimterm's
      TranscriptItems) + the markdown for the assistant text
- [x] 3. The App wiring: the input widget, the footer, the keys (Enter
      sends / Esc aborts / Ctrl+C exits), the send path (the same
      agent.run chunk), the stream sink → the transcript + flush
- [x] 4. /commands + /resume on the new plumbing (the dispatch, the
      select/menu, the swap)
- [x] 5. The old plumbing out: the asyncdispatch timer, pollTimerKeys,
      abortRequested, the keyPoller, the illwill dependency
- [x] 6. The tests: the pure layer follows (the adapter, the label
      helpers); nimble test green; the pty harness end-to-end (the same
      exit criteria as the illwill TUI)
- [x] 7. Work-unit commit on main; record evidence here

## Tasks (slice B)

- [x] 1. The busted spec first (RED): agent.runTurn's contract — one turn
      per call (the toolUse response continues: the tools execute, the
      steering drains, compaction triggers), the stop response returns
      (continueLoop false, no tools), agent.run's contract unchanged
- [x] 2. The engine (GREEN): agent.runTurn + agent.run as the driver over
      it (the loop body extracted; continueLoop on the response)
- [x] 3. The pure continue decision: turnContinues(response, steered)
      extracted from sendTurn + the tp_tui test (RED → GREEN)
- [x] 4. The TUI drive: sendTurn runs one evalJson per turn, the gap
      between turns (feedKeys + the transcript rebuild per turn)
- [x] 5. feedKeys forwards the editing keys to the input (the draft
      builds during the run — the steering path alive)
- [x] 6. Verify: nimble test green; the pty harness end-to-end (the draft
      builds during the stream, Esc aborts the drive between turns, the
      steering delivered in the next turn, Ctrl+C exits)
- [x] 7. Work-unit commits on main; record evidence here

## Evidence

- The parent implemented the slice inline (the writers stall systematically
  — the established lesson).
- The hello-app spike first: nimterm's widgets (card/markdown/input) + the
  focus + the submit action verified in the pty before the port ("You
  entered: hello spike", exit 0).
- The port: tui.nim rewritten over nimterm (the backup of the illwill
  version at /tmp/tui-illwill-backup.nim); the NeopiScreen root widget
  (the nimlet nimterm_screen pattern): the dynamic children (the menu
  joins between the transcript and the input while it has items) + the
  paint with the fixed bottom rows (the rule, the input, the footer) —
  copied from nimlet's paint.
- The streaming WITHOUT the async tangle (the user's intuition
  confirmed): the sink applies the deltas to nimterm's transcript and
  flushes the frame directly (same thread — the turn's waitFor pumps the
  dispatch); feedKeys drains the backend's key events from the sink
  (backend.readEvent(0)) so Esc still aborts mid-stream — the
  asyncdispatch timer, pollTimerKeys, abortRequested, the keyPoller, and
  illwill are GONE (760 → ~540 lines).
- The /resume menu: nimterm's newMenu (MenuItem label/description) floats
  above the input; Enter picks, Esc dismisses; the swap rebinds the
  registry pointer (unchanged from the illwill version).
- nimble test verbatim: "[Summary] 81 tests run (2.12s): 81 OK, 0 FAILED,
  0 SKIPPED" + busted "10 successes" — the tests follow the port: the
  adapter (the kind mapping + the case-object field discipline — a
  FieldDefect caught by the tests: the kind-specific fields only in their
  branch), the sessions list/labels, the /resume builtin (the menu), the
  swap (the registry pointer: `neopi.session:history()` returns the loaded
  session's entries — the COLON call; a DOT call omits self).
- The vhs GIF (the visual verification): the transcript with nimterm's
  rail + the themed user line (cyan bold), the markdown rendered (¡Hola,
  hola!), the rule above the input, the footer with the tokens updated
  (out 322). The TUI looks substantially closer to pi than the illwill
  version.
- nimCheckFile unavailable mid-slice (the MCP connection dropped — the
  fallback per the skill's availability rule): the compiler clean (0
  errors/warnings after dropping the unused strformat import).
- Known limits: the abort during a thinking pause waits for the next delta
  (the sink's feedKeys runs per delta); the widget primitives render to
  status rows (no named replacement yet); the scroll is the transcript's
  viewport (the keys for scrolling: pending).
- Post-slice cleanup (2026-10-04, 71d88dd): illwill out of neopi.nimble
  (no module imports it since the port); the dead exitHook proc removed
  from tui.nim (the illwill-era SIGINT handler — nimterm's backend
  installs its own and the registration never came back); AGENTS.md
  refreshed (the nimterm build recipe + the sibling-checkout nim.cfg path
  + 81 tests) and ARCHITECTURE.md de-staled (rule 6: the asyncdispatch
  timer → the sink's nimterm transcript flush; rule 9: the illwill
  raw-mode note → the nimterm key events). nimble test verbatim: "[Summary]
  81 tests run (2.56s): 81 OK, 0 FAILED, 0 SKIPPED" + busted "10
  successes"; the binary compiles clean (4.1M).

## Evidence (slice B, 2026-10-04)

- The parent implemented the slice inline (the writers stall
  systematically — the established lesson). The design verified against
  nimlet first (the user's call — nimlet is the production consumer):
  nimterm_controller's turn source (the Future + the app loop alive), the
  abort as flags checked by delta, the steering queue drained at the turn
  boundary — adapted to neopi's synchronous Lua engine (no engine rewrite).
- The engine (ac4f180): the loop body extracted into agent.runTurn (one
  turn: request → stream/generate → assistant append → drainSteering →
  tools + compaction when continuing) with continueLoop on the response;
  agent.run drives it headless (maxSteps/stepLimit unchanged). Test-first:
  the busted spec RED (attempt to call field 'runTurn' (a nil value)) then
  GREEN.
- The TUI drive (7e6dbd5): sendTurn runs one evalJson per turn, the gap
  between turns (drainGapKeys: feedKeys + flush + the steered flag), the
  transcript rebuilt per turn (the tool results render live), no step cap
  (nimlet's while-true — the user steers and aborts). feedKeys forwards
  the editing keys to the input (the draft builds during the run — before
  this, the letters were dropped and the steering queue was unreachable
  from the TUI) and guards appReady (the headless tests drain nothing).
- Tests: turnContinues (the pure continue decision) + the drive test (the
  scripted provider end-to-end through the sink) — both RED (the compile
  failure + the first run's 1 entry: without exposeTuiSink the chunk's
  model was nil) then GREEN. nimble test verbatim: "[Summary] 83 tests run
  (3.04s): 83 OK, 0 FAILED, 0 SKIPPED" + busted "13 successes".
- The pty harness E2E (/tmp/tui_test_drive.py — the harness the crash
  ate, rewritten; the scripted provider injected via .neopi/init.lua —
  the setScripted surface is production-exposed): phase 1 (scripted): the
  drive ran 3 turns (user, assistant, toolResult, assistant, toolResult,
  assistant), the tools executed inside their turns, the final text
  rendered, the second send works, Ctrl+C exit 0. Phase 2a (real, ling
  flash): the draft builds during the stream ("abc" typed mid-stream
  renders), the steering user entry landed mid-run and an assistant entry
  follows it (the next turn delivered it), Ctrl+C exit 0. Phase 2b: the
  Esc abort recorded (stop=aborted), Ctrl+C exit 0.
- The harness lessons (extended): the per-cell diff presents the cursor
  cell after each typed char — the draft check strips the cursor marks
  ("abc", not "a▌b▌c▌"), the tui-async lesson extended; the thinking
  pause renders nothing (the deltas drive everything) — the harness waits
  for the text before typing; the E2E must run the freshly built binary
  (the stale build/neopi from the cleanup ran the pre-slice behavior and
  failed the draft check silently).
- Known limits (unchanged + new): the abort during a thinking pause waits
  for the next delta (the deltas drive everything); the tool execution
  stays frozen during a run (the threads/async gap pi and nimlet solve —
  the ROADMAP's #14); the scroll keys pending (the ROADMAP's #11); the
  between-turns abort is exercised by the unit contract (turnContinues)
  and not pinned by the E2E (the scripted runs are instant — the gap is
  milliseconds).
