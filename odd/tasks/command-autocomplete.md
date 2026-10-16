# The command autocompletion: /commands as you type, the way pi has it

ROADMAP #22. The composer completes `/commands` as they are typed, with their
descriptions, sourced from the runtime's command registry and drawn with
nimterm's `Menu`. The outside view is pi: the same shape its slash-command
completion has, with the key map its editor binds.

## Specs

- **S1** (the roadmap item, verbatim): "The command autocompletion, the way
  pi has it | The composer completes `/commands` as you type, with their
  descriptions: `neopi.registeredCommands` is already the source and
  nimterm's `Menu` is built for exactly that list. pi's
  `github-issue-autocomplete` is the same shape seen from the extension
  side"
- **S2** (the request, verbatim): "arranquemos con el 22 del roadmap"
- **S3** (the keys, the user's choice, verbatim): "Como pi: Tab completa;
  Enter completa y envía" — "Tab acepta el resaltado y deja el texto listo
  (no ejecuta); Enter lo acepta y lo ejecuta en el mismo golpe."
- **S4** (the builtins, the user's choice, verbatim): "Sí: registry +
  builtins en una sola lista" — "/resume aparece como un comando más, con su
  descripción; la fuente sigue siendo neopi.registeredCommands + el aporte
  del core."
- **S5** (the correction, verbatim): "podias haber usado codegraph o
  nimlangserver para tu exploracion"

## Verified basis (2026-10-15)

pi's shape, read from `~/proyectos/pi/packages/tui/src`:

- `autocomplete.ts:338-369` — the command branch: it triggers only while the
  text before the cursor starts with `/` and contains no space; each item is
  `{value: name, label: name, description}`; the returned `prefix` is the
  whole `/token`; no matches → no menu.
- `autocomplete.ts:431-441` — the slash insertion: `beforePrefix + "/" +
  item.value + " " + afterCursor`, i.e. the name and a trailing space.
- `editor.ts:758-806` — the key map over the open menu: Esc cancels the
  autocomplete ALONE (it does not touch the text); Up/Down move the
  selection; Tab applies the completion and returns (no submit); Enter
  applies it and, when the prefix starts with `/`, falls through to submit.
- `github-issue-autocomplete.ts:13-20,60-70` — the extension-side shape the
  roadmap names: a provider yields `{value, label, description}` items.

neopi's hooks, read with codegraph (`codegraph explore`) and nimlangserver
(`nimCheckFile src/neopi/tui.nim` → 0 diagnostics, the baseline):

- `src/neopi/tui.nim:814` `runCommand` — the `/`-dispatch: `text ==
  "/resume"` opens the picker; everything else goes to `neopi.runCommand`.
- `src/neopi/tui.nim:872` `sendTurn` — the `/`-prefixed text never enters the
  session; `:924` `handleTuiAction` owns `submit`.
- `src/neopi/tui.nim:1275` `wireApp` — the one event/action wiring, where the
  precedence lives (the question, the abort, the resume menu, Esc, the
  transcript's page keys).
- `src/neopi/tui.nim:726-735` `openResume` — the existing `Menu` use: items
  `{label: the session label, description: the path}`.
- `src/neopi/tui.nim:251,262` — `children`/`paint`: the menu joins the tree
  while it has items and floats above the composer.
- `runtime/init.lua:78` `neopi.registeredCommands()` — the registry, in
  registration order; entries are `{name, description, execute}`.
- nimterm `widgets/input.nim:379` — the InputWidget emits
  `actionHandled("change", text)` after every edit, and `app.nim:149-152`
  (`applyResponse`) calls `app.onAction` for it. That is the hook: the
  completion is recomputed on the change, with no polling and no work inside
  `paint`.
- nimterm `widgets/menu.nim:19-27,81-110` — `MenuItem{label, description}`,
  and `Menu.handle`: Up/Down/PageUp/PageDown move the selection, Enter emits
  the `select` action.

## Design (the decisions)

- **D1 the source** (S1, S4): the Lua registry projected to
  `{name, description}` — a projection chunk, because the registry entries
  carry functions and the raw table is not JSON-encodable — plus the core
  builtin `/resume`, appended in the same list. Builtins first, then the
  registry in registration order.
- **D2 the trigger**: the InputWidget's `change` action recomputes the menu.
  It opens while the text starts with `/`, has no space or newline, the
  cursor sits at the end, and at least one command matches; anything else
  closes it.
- **D3 the matching**: case-insensitive prefix on the name, so `/` alone
  lists everything. Documented deviation: pi fuzzy-matches (`fuzzy.ts`);
  neopi has no fuzzy matcher, and the filter is one pure proc, so replacing
  it later is a local change.
- **D4 the keys** (S3): Up/Down navigate; **Tab** applies (the composer gets
  `/name ` with the cursor at the end), closes the menu and submits nothing;
  **Enter** applies and submits in the same keystroke (pi's fall-through);
  **Esc** closes the menu and leaves the composer alone.
- **D5 the render**: the same floating slot the resume menu uses —
  `label = name`, `description` = the command's description. The state
  carries which menu is open (`menuKind`), because the key maps differ: Tab
  applies a completion, Enter resumes a session.
- **D6 the builtin runs when chosen** (S4): the applied text is `/resume `
  (with the trailing space), so `runCommand` must compare the trimmed text —
  otherwise the picker's own command falls into the Lua registry and comes
  back as "unknown command /resume".

## Known limits (honest)

- No argument completions (pi's `getArgumentCompletions`): only the name.
- Prefix matching, not fuzzy (D3).
- The completion fires only with the cursor at the end of a single-line
  `/token`; a cursor in the middle closes the menu instead of completing
  around it.
- The registry is re-read on every matching keystroke: no cache, no
  invalidation. Tens of commands make it free; a provider-shaped surface for
  extensions stays out of scope (ROADMAP #19).

## Tasks

- [x] T1. The source and the matching (S1, S2, S5): `commandItems(L)` (the
      registry projection + the `/resume` builtin) and `completionMatches`
      as pure procs + their tests — inline, commits `b6667d7` (the record)
      and `c91d389` (the code + the 4 tests, 39 OK)
- [x] T2. The wiring (S3): the `change` action, the key map (Tab/Enter/Esc/
      arrows), the state's `menuKind` + the render slot + the tests through
      the fake app — inline, commit `c197113` (45 OK)
- [x] T3. The builtin runs when chosen (S4, D6): the trimmed comparison in
      `runCommand` + the test that `/resume ` (completion-applied) opens the
      picker — inline, commit `f4ac13b` (46 OK)
- [x] T4. The docs and the record: the README key list + the API table row,
      the evidence here, the ROADMAP tick — inline

### The bugs the user hit (2026-10-15, after the slice landed)

- [x] F1. The picker's Esc freed the widget but not the state: `menuKind`
      stayed `mkResume`, and since the change action asks the kind for
      permission before completing, every later keystroke met a resume menu
      that was no longer on screen and the completion stayed silent for the
      rest of the session. `closeResume` closes the slot and the kind
      together (what `resumeSession` was already doing by hand).
- [x] F2. Tab in the composer was unhandled, so nimterm's dispatch handed the
      keys to the next focusable widget — the transcript — where the composer
      receives nothing at all (the reported "the TUI stops capturing keys",
      and the reason Shift+Tab appeared to fix it: the focus cycled back).
      The composer owns Tab now and pins the focus back, which also makes Tab
      the way out of a focus already lost that way.
- [x] F3 (found while reproducing, and the assertion would have caught it
      anyway): the open menu blanked the composer's rule. The menu is painted
      after the composer and fills every cell of its rectangle, and that
      rectangle ended on the rule's own row — the one right above the input.
      The menu ends one row higher now; the dialog keeps its geometry, since
      it is modal and owns the screen while it is up.
- Commits: `59754ec` (F1 + F2) and `27518e6` (F3).

### The /quit builtin (2026-10-15, the session's last ask)

- [x] F4. `/quit` ends the session from the composer: `quitTui` stops the
      app's loop (what Ctrl+C does) and the state carries the fact; the
      completion lists it with the other core builtins, and it answers for the
      completed text too (`/quit ` with the insertion's trailing space) — the
      same trimmed comparison `/resume` needed. Commit `bef2ece`.
      RED first: five focused failures, every one of them "quit is missing".

## Evidence

- **The gate** (`nimble test`, verbatim): "[Summary] 148 tests run (2.81s):
  148 OK, 0 FAILED, 0 SKIPPED" and the busted runner: "19 successes / 0
  failures / 0 errors / 0 pending". The suite went in at 137; the 11 new
  tests are this slice's own — 4 for the source and the rule, 6 for the keys
  and the render, 1 for the builtin the completion produces.
- **The focused loop**: `nim c -r --hints:off --threads:on --mm:orc
  -o:build/tp_tui_focus tests/tp_tui.nim` (35 tests at the baseline, 46
  after). Every task went RED first, and the three REDs were the ones this
  record predicted: `undeclared identifier: 'commandItems'`, `undeclared
  field: 'menuKind'`, and the builtin's `st.menuKind was mkNone` — the
  completed `/resume ` falling into the runtime's registry as "unknown
  command /resume".
- **nimlangserver**: `nimCheckFile src/neopi/tui.nim` → 0 diagnostics, at
  the baseline this slice opened with and after every edit.
- **codegraph**: `explore` for the call path — `wireApp` → `handleTuiAction`
  → `sendTurn` → `runCommand`, with `openResume`/`paint` for the menu slot —
  and the blast radius confirmed the touched procs have no callers outside
  the TUI and `tests/tp_tui.nim`.
- **The commits**: `b6667d7` (the record), `c91d389` (T1), `c197113` (T2),
  `f4ac13b` (T3), plus T4's docs commit. The work ran inline (one file plus
  its suite): no writer was launched, and the repo's own history says why —
  the writers of this runtime stall.
- **The render gate** (`nimble bench`, the standing regression harness):
  `render_median_ms` 6.974 (50 entries) / 6.991 (500) / 6.996 (5000) — flat,
  and the same numbers the previous slice left (the frame was 46.7 ms at 5000
  before that slice's fix). `delta_median_ms` 12.888 at 5000 is the stream
  apply path this diff does not touch. The completion adds no per-frame work:
  it is recomputed on the editor's change action and the menu joins the tree
  only while it is open.
- **Known limits** (the list above, unchanged by the implementation): no
  argument completions, a prefix match instead of pi's fuzzy one, the
  completion only with the cursor at the end of a single-line token, the
  registry re-read on every matching keystroke, and `setText` dropping the
  composer's undo history when a completion is applied.
- **The bug-fix arc** (F1–F3, L4/L5): the three bugs went RED first — the
  focused loop 46 → 49 and the two key tests printed exactly the reported
  symptom (`st.menuKind was mkResume` after the picker's Esc; the focus on the
  transcript after a Tab, with the next character eaten). The gate after them:
  `nimble test` → "[Summary] 151 tests run (3.14s): 151 OK, 0 FAILED, 0
  SKIPPED" and the busted runner's "19 successes / 0 failures / 0 errors / 0
  pending". nimlangserver stayed at 0 diagnostics. Commits `59754ec` and
  `27518e6`, one per work unit, each green on its own.
- **The last ask** (`/quit`, F4): the focused loop 49 → 50, and the gate after
  it — `nimble test` → "[Summary] 152 tests run (3.08s): 152 OK, 0 FAILED, 0
  SKIPPED" with the busted runner's "19 successes / 0 failures / 0 errors / 0
  pending". Commit `bef2ece`.

## Log

- **L1** (2026-10-15, verbatim): "arranquemos con el 22 del roadmap"
- **L2** (2026-10-15, verbatim): "podias haber usado codegraph o
  nimlangserver para tu exploracion" — the exploration for this slice ran on
  `read`/`grep` first; codegraph (`explore`, the blast radius of `wireApp`/
  `sendTurn`/`runCommand`) and nimlangserver (`nimCheckFile`) were used
  afterwards and are the baseline recorded above.
- **L3** (2026-10-15, the two decisions, verbatim): S3 and S4 — Tab completes
  without sending and Enter completes and sends; the builtins join the
  registry in one list.
- **L4** (2026-10-15, the bug report, verbatim): "encontré un pequeño bug, al
  hacer /resume, abrir su menu y luego cerrarlo con esc ya no me salen el
  composer ni funcionan las completions. Otro bug pero no sé sí tenga que ver
  con esto: al presionar tab mientras escribo, la tui deja de captar las
  teclas"
- **L5** (2026-10-15, the fix arc): the two reports reproduce in the harness
  and each has its own root cause — the RED printed `st.menuKind was mkResume`
  after the picker's Esc, and after a Tab the focus was the transcript with
  `st.inputW.text was hola` (the next character was eaten; the Shift+Tab that
  followed brought the focus back and the one after it landed). Reproducing
  them also cost the third bug: with the completion open, `"─" in
  canvas.plainText` was false — the menu's rectangle reached the rule's row.
  What the report described as the composer not showing up is the completion
  going silent (the menu never opened) — the composer itself kept rendering,
  which the F1 test pins.
- **L6** (2026-10-15, verbatim): "dale, ya está bien, agrega un /quit para salir
  y estaría lista está sesión, ¿que seguiría?" — the /quit request and the
  session's close; the next slice stays the user's call (#21 was their plan).
