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

### Slice B — the loop driver + the abort/steering (the next slice)

- agent.runTurn (one turn per call, the loop's driver in the TUI) so the
  keys are alive between turns: the abort between turns, the steering
  drain between turns — the engine keeps the turn logic (Lua).
- The abort during a stream: the cancel through the sink (the flag the
  sink checks per delta) — the same contract, the new plumbing.

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
  viewport (the keys for scrolling: pending); illwill stays in nimble
  requires (the cleanup pending).
