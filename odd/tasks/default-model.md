# default-model — Ctrl+S sets the model a fresh session starts on

The slice the user asked for after matching `/model`'s look to pi's: pi's picker
offers `Ctrl+S to set as default` and badges that row with ` · default`, and
neopi's picker has neither. The user's call: "está bien, hagamos ctrl s".

## Specs

- **S1** (the request, verbatim): "está bien, hagamos ctrl s y dejemos el
  thinking para después (anotalo en roadmap)" — the thinking's own colour token
  goes to the ROADMAP (item 34), this slice is the default model.
- **S2** (the gap it closes, the user's own words from the look review):
  "(también nos faltó el ctrl+s para default)".
- **S3** (pi's shape, read with codegraph: the authority for the design):
  - the default lives in the SETTINGS: `defaultModel: Type.Optional(Type.String())`
    (`packages/coding-agent/src/core/settings-schema.ts:216`), read by
    `settingsManager.getDefaultModel()` (`settings-manager.ts:713`) and written
    by `setDefaultModel` (`:723`), with a GLOBAL and a project scope
    (`this.globalSettings.defaultModel` vs `this.settings.defaultModel`);
  - it is shown as `"${defaultProvider}/${defaultModelId}"`
    (`interactive-mode.ts:5093-5094`);
  - the row that holds it carries ` · default`, in `muted`
    (`components/model-selector.ts:332`);
  - the keys line names the key: `Enter to select · Ctrl+S to set as default ·
    Escape/Ctrl+C to cancel` (`:146`).

## Verified basis — what neopi has today

- **The settings store exists and is the global one**: `$NEOPI_CONFIG_DIR/settings.json`
  (`~/.neopi/settings.json`) is where #32 put the thinking preference, through
  `neopi/settings.nim`. Read that module first: its loader VALIDATES a value's
  type and a malformed file is REPORTED, never rewritten or clobbered (the #32
  verification found the opposite and it was fixed) — this slice's new key has
  to inherit that discipline, not bypass it.
- **The picker's key map is the app's** (`wireApp`, the `menuOpen and
  menuKind == mkModel` branch): arrows and Enter reach `screen.menu`, Esc closes
  through `closeMenu`. `Ctrl+S` is not claimed by anything today.
- **The row already carries a description** (`[provider]`, muted) and the block
  is `Picker` + `Menu` in the fork, so ` · default` joins the row's description
  rather than inventing a second place for it.
- **A session starts on the CLI's `--provider`/`--model`** and `initTuiState`
  takes them; today there is no stored default behind them.
- **`/model`'s rows come from `catalog.nim`** (`ListedModel{provider,id,name}`),
  so the badge and the Ctrl+S handler both have the provider and the id of the
  row under the cursor without parsing a label (the rule from R3b).

## Design

- **The store**: `settings.json` gains `defaultModel`, a `"<provider>/<modelId>"`
  string in pi's shape (one string, not two keys, so it cannot go half-written).
  `neopi/settings.nim` grows `loadDefaultModel`/`saveDefaultModel` with the same
  read-modify-write and the same validation the thinking preference earned: a
  value of the WRONG TYPE is reported, and the file is never clobbered.
  The global scope is the only one neopi has; pi's project scope is a later
  question and is NOT invented here.
- **The pick**: `Ctrl+S` in the model picker sets the default to the row under
  the cursor — the `ListedModel` the pick already resolves by index — and saves
  it. It does NOT change the live model (that is Enter's job) and it does not
  close the picker: pi keeps the list up so a second key can pick.
- **The badge**: the row that holds the default shows ` · default` in `muted`,
  appended to its description (`[provider] · default`), so the accent label and
  the muted badge stay exactly where R3b put them.
- **The keys line**: the block's keys field becomes
  `Enter to select · Ctrl+S to set as default · Escape/Ctrl+C to cancel` —
  pi's own wording, with the key named as pi names it.
- **A fresh session honours it**: the start resolves the model in pi's order —
  the CLI's explicit `--model`/`--provider` first, then the stored default, then
  today's fallback — so the setting is not write-only. `/model` and the footer
  show what is actually live.
- **Out of scope**: a project-scoped default, a "recently used" list, and the
  thinking's colour token (ROADMAP #34).

## Tasks

| ID | What | Specs | Route | Commit |
|---|---|---|---|---|
| P1 | `settings.nim` grows `defaultModel` with the thinking preference's validation and read-modify-write, plus its tests (a wrong-typed value reported, the file left byte-identical) | S3 | inline, RED→GREEN | `feat(settings): Ctrl+S sets the default model, and a run starts on it` — `08bb1d7` |
| P2 | The picker's `Ctrl+S` sets the default from the row under the cursor; the badge ` · default` (muted) joins the row's description; the keys line names it | S2, S3 | inline, RED→GREEN | ↑ `08bb1d7` |
| P3 | A run starts on the stored default when the CLI does not say otherwise (`resolveStartModel`, extracted so the rule is testable) | S3 | inline, RED→GREEN | ↑ `08bb1d7` |
| P4 | README + the ROADMAP row + this record's Evidence and close | S1-S3 | inline | the commit that carries this section |

## Evidence

The gate ran with `PATH="$HOME/.local/share/grabnim/current/bin:$PATH"` and
`TMPDIR="$HOME/tmp-nim"`.

- **P1** — the RED was the compile error `undeclared identifier:
  'loadDefaultModel'`, and it is an honest gap in this record: the test and the
  module landed in the SAME edit, so the first observable run is the GREEN —
  **7/7** in the settings suite (the 5 that were there plus the two this slice
  added).
- **P2/P3** — the first gate run went RED on two of my OWN oversights, and both
  are the kind an extracted rule pays for: `DefaultModel` was a PRIVATE const
  the new start test could not name (it belongs to the start's contract, so it
  is exported now), and an older assertion still demanded `Ctrl+S notin
  ...keys` while the hint had just earned the key. The retry: the start's rule
  **6/6**, the TUI file **105/105**, the whole suite **284/284** (275 + the 2
  settings tests + the 6 start tests + the Ctrl+S test), busted **22 successes
  / 0 failures**, exit 0 in all four.
- The new tests ARE the slice's rules: the settings round-trip plus its two
  malformed cases (a wrong TYPE, and a string that is not `provider/model` —
  with the file byte-identical after every refused write, and the write
  refusing to CREATE one it could not read back); the six start cases (the CLI
  wins, `<ID>_MODEL` next, the stored pair next, a named provider does NOT
  borrow another provider's default, an unknown stored provider is skipped
  instead of fatal, and no settings at all falls through to the built-in); and
  the picker's Ctrl+S (the default moves, the LIVE model does not, the picker
  stays open, the badge lands on that row and only that one, and the hint names
  the key).

## Log

- **L1** (the request, verbatim): "está bien, hagamos ctrl s y dejemos el
  thinking para después (anotalo en roadmap). ¿Crees que podríamos lanzar
  nuestra primera release?, por una parte ya es un agente funcional pero por la
  otra lo que lo diferencia que es la extensión por lua deja mucho que desear,
  aparte creo que a lo largo del desarrollo del proyecto hemos omitido muchas
  cosas y cometido malas decisiones"
- **L2** (the gap, from the look review, verbatim): "(también nos faltó el
  ctrl+s para default)"
