# Session resume: the /resume builtin + the select overlay

## Goal

The user resumes a session: /resume opens the select overlay (the sessions
list), Up/Down move, Enter loads the picked session, Esc cancels. The load
swaps the live session (the registry pointer) and the transcript re-renders.

## Decision (2026-10-01 — the user's call)

The scope: **the /resume builtin only** (the overlay + the load as part of
the dispatch). neopi.ui.select (the dialogs API — the commands ask the TUI
for a selection, pi's ExtensionUIDialogs) is deferred until an extension
needs it (YAGNI).

## Verified basis (2026-10-01)

- pi's SelectList (packages/tui/src/components/select-list.ts:40, 42
  callers): items + selectedIndex + maxVisible (5) + render(width) → the
  lines (the no-match message, the visible window with the scroll, the
  selected one themed); onSelect/onCancel callbacks.
- neopi's transcriptLines + visibleRange: the same pattern already exists
  (the window + the clamp) — the select list reuses it.
- The session swap: exposeSession binds the registry pointer (the
  "neopi.session" key) + the table (append/history/navigate cfunctions);
  the cfunctions read the POINTER dynamically (getRegistryPointer per
  call) — the swap is a setRegistryPointer update; the table stays intact.
- newSession(path) loads an existing JSONL (verified in tp_session).
- neopi.fs.list (fs.nim:136): the dir listing inside the workspace root —
  the TUI can use Nim's walkDir directly (no confinement needed: the TUI
  is the interface, not an extension).

## Design

- **SelectState** (the select list, pi's pattern):
  - `SelectState* = object`: items (seq[(value, label)]), selected (int),
    open (bool).
  - `selectMove*(s, delta)`: the cursor moves, clamped to the list.
  - `selectClose*(s)`: closes (open false, items empty, selected 0).
  - `selectLines*(s, width)`: the display lines: the header + the window of
    maxVisible (5) items around the selection (clamped), the selected one
    prefixed with "> ". Pure, testable.
- **TuiState** gains `select*: SelectState` (initTuiState: closed, empty).
- **The sessions**:
  - `listSessions*(root): seq[(value, label)]` — .neopi/sessions/*.jsonl
    sorted by mtime descending (the newest first); value = the path,
    label = the file name + the first user entry's text (truncated).
  - `sessionLabel(path, mtime)` — the label helper (the JSONL's first
    user entry; unreadable/empty: the file name alone).
- **The /resume builtin** (runCommand's "/" path, before the dispatcher):
  "/resume" → openResume(state): the sessions list into state.select +
  requestRender. The command's input never enters the session (already
  true for commands).
- **resumeSession*(state, L, path)**: newSession(path) → the swap
  (state.sess + setRegistryPointer("neopi.session", fresh)) → the select
  closes, the streaming/scroll reset, re-render. A failure: the status
  line carries it (feedback, not fatal — the command path's model).
- **The keys** (the overlay is the composer's controller while open):
  - handleKey: select.open → Up/Down (selectMove), Esc (selectClose);
    the composer's editing is inert while the overlay is open.
  - pollTimerKeys: the same handling via the state's interpreter for Enter
    (resumeSession); Esc closes the overlay (not the abort) while open.
  - The key loop: Enter with the overlay open loads the picked session;
    sends otherwise.
- **drawScreen**: select.open → the list replaces the transcript while the
  overlay is open (the composer + the footer stay).
- **The tests** (tp_tui): listSessions (the order + the labels),
  selectMove (the clamp), selectLines (the window + the selected prefix),
  the /resume builtin (the overlay opens with the sessions), resumeSession
  (the swap: the state's sess + the registry pointer + the select closed).
- **Non-goals**: neopi.ui.select (the dialogs API — deferred); the filter /
  autocomplete (pi's getArgumentCompletions — post-MVP); the mouse; the
  session deletion; the global ~/.neopi sessions.

## Tasks

- [x] 1. SelectState + the pure ops (selectMove/selectClose/selectLines)
- [x] 2. listSessions + sessionLabel (the sessions listing)
- [x] 3. TuiState.select + the /resume builtin (the dispatch + openResume)
- [x] 4. resumeSession (the swap + the registry pointer)
- [x] 5. The keys (handleKey/pollTimerKeys: the overlay's controller) +
      drawScreen's overlay
- [x] 6. The tests: tp_tui (the select + the sessions + the swap)
- [x] 7. Work-unit commit on main; record evidence here

## Evidence

- The parent implemented the slice inline (the writers stall systematically
  — the established lesson).
- nimble test verbatim: "[Summary] 119 tests run (3.01s): 119 OK, 0 FAILED,
  0 SKIPPED" + busted "10 successes" — the sessions list (the newest first,
  the labels with the first user entry, the truncation, the fallback),
  selectMove (the clamp + the empty no-op), selectLines (the window of 5,
  the selected prefix, the follows-selection), the /resume builtin (the
  overlay opens with the workspace's sessions, the input never enters the
  session), and the swap (the state's session rebinds + the registry
  pointer: the cfunctions read it dynamically — `neopi.session:history()`
  returns the loaded session's entries) pass.
- nimlangserver nimCheckFile: 0 diagnostics on tui.nim; the production
  binary builds clean (3.4M).
- THE PTY E2E (the TUI tested by the agent itself — the harness's third
  round): the workspace with a resumable session + the repo's .env copied
  (a missing .env fatals the TUI at startup — the pty echoes the keys of a
  dead process, which is the harness's tell, not a TUI bug); /resume opens
  the overlay (the list renders), Down clamps correctly (one item → no
  movement → a 0-byte diff), Enter LOADS the picked session (the
  transcript shows `you: the resumed prompt`), Esc cancels, Ctrl+C exits
  with code 0.
- The harness's diff-reading lesson (repeated): the displayDiff writes only
  the CHANGED cells — the draft check must match the changed content
  ("abc"), not the full line ("> abc" — the "> " was already on screen);
  and the strip_ansi removes spaces in runs, so prefix checks need the
  exact plain text.
- The compile loop caught by the compiler (the compile-fresh discipline):
  getLastModificationTime (os) returns times.Time (needs `import times`);
  toUnix (int64, not float — no toUnixFloat in 2.2); sort (std/algorithm);
  the declaration order (resumeSession/openResume before their callers);
  the cfunctions need the COLON call (`neopi.session:history()` — a DOT
  call omits self, gettop 0 != 1).
- The workspace root now travels on the TuiState (root, the tuiLoop param,
  runTui passes it) — openResume uses state.root, NOT getCurrentDir (the
  test runner's cwd would leak the repo's 45 sessions into the test).
- Known limits: one session file with the same mtime sorts arbitrarily;
  no /resume <n> argument form (the overlay is the only picker); the
  overlay is inert while a stream runs (the keys still abort); no session
  deletion; no global ~/.neopi sessions.
