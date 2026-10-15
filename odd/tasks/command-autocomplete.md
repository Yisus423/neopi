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

- [ ] T1. The source and the matching (S1, S2, S5): `commandItems(L)` (the
      registry projection + the `/resume` builtin) and `completionMatches`
      as pure procs + their tests — inline, commit `feat(tui): ...`
- [ ] T2. The wiring (S3): the `change` action, the key map (Tab/Enter/Esc/
      arrows), the state's `menuKind` + the render slot + the tests through
      the fake app — inline, commit `feat(tui): ...`
- [ ] T3. The builtin runs when chosen (S4, D6): the trimmed comparison in
      `runCommand` + the test that `/resume ` (completion-applied) opens the
      picker — inline, commit `fix(tui): ...`
- [ ] T4. The docs and the record: the README key list + the API table row,
      the evidence here, the ROADMAP tick — inline, commit `docs(tui): ...`

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
