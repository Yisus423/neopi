# model-catalog — /model across the configured providers, with the catalog cache

ROADMAP #28, the slice the user placed right after the provider picker: `/model`
lists every configured provider's models as `<id> [<provider>]`, and the catalog
is cached in `~/.neopi/models-store.json` so the list paints before the network
answers. The refresh itself is non-blocking: #16's pump seam, decided here
because the original deferral ("Dejalo para #16") assumed #16 would bring the
mechanism, and #16 has landed.

## Specs

- **S1** (the original request, verbatim): "debemos hacer que /models soporte y
  muestre todos los modelos de los proveedores activos (cómo se vé en
  ~/Imágenes/01-11-2026-21:30:55.png), en este espacio creo que también
  deberíamos agregar caching de la lista de modelos para que cargue instantaneo
  mientras hace el fecth a la url"
- **S2** (the cache's file name, the user's call, verbatim): "creo que
  deberíamos usar el mismo nombre que pi en vez de catalogs.json" — so
  `~/.neopi/models-store.json`, pi's file name.
- **S3** (the cache's design, verbatim): "me gustaría revisar primero con
  codegraph en ~/proyectos/pi exactamente como lo hace pi" — pi's shape:
  `{models, checkedAt?, etag?, lastModified?}` per provider, restored BEFORE the
  fetch, revalidated with the endpoint's validators, no TTL.
- **S4** (today's decisions, verbatim): the fetch — "Hacerlo no bloqueante con el
  seam de #16"; the footer keys — "solo enter para seleccionar, ctrl s puede ser
  el siguiente slice" (Ctrl+S "set as default" is OUT).
- **S5** (the target shape, the screenshot): the header "Only showing models from
  configured providers. Use /login to add providers.", rows `<id> [<provider>]`,
  the counter `(filtered/total)`, the picked model's display name
  (`Model Name: GLM-5.3`), the refresh notice, and the footer keys minus Ctrl+S.
- **S6** (this session's request, verbatim): "arranquemos con el siguiente
  remaining en el roadmap, #28, primero contextualizate con engram, si vas a
  buscar en el codigo usa codegraph o nimlangserver"
- **S7** (the crash the user hit, verbatim: "tuve ese error de repente mientras
  habría /models pero solo paso una vez") — the screenshot's trace ends in
  `nimterm/widgets/menu.nim(139) paint` → `index -1 not in 0 .. 436
  [IndexDefect]`. The invariant: a Menu that HAS items must never carry a
  negative `selected`, and the widget must not index outside its list for any
  selection it is handed.
- **S8** (the keyless rule, verbatim): "Un error que puede verse en la foto es
  que ollama y llama.cpp intentan actualizarse aunque no esten logueados, creo
  que tiene que ver con que sea keyless, en pi llama.cpp no pide api key pero sí
  pide el server url". The user's call (verbatim): "Mientras tanto excluyamoslo
  pero ponlo al final del roadmap, habría que revisar como lo hace pi cuando se
  haga" — a keyless entry counts as configured only with a stored credential,
  and the server-URL question moves to the END of the ROADMAP.
- **S9** (the presentation, verbatim): "lo que implementamos no se parece en
  nada a el de pi, solo compara a neopi en la izquierda con pi a la derecha" and
  "Aparte capaz eso que hiciste pudo haber sido mejor un patch o nuevo widget en
  nuestro fork de nimterm, así no bloateamos tanto". The user's call (verbatim):
  "Widget nuevo en nuestro fork de nimterm".
- **S10** (the dependencies, verbatim): "Para lo de las copias de chronos
  deberíamos crear un nimble lock" and the question "¿y si cambiaramos los
  commits pinneados por el lock?, así dejaríamos de pinnear cada cambio y solo
  sería regenerar el lock. Esto es un poco discutible".
- **S12** (the list's height, verbatim): "nos falta que solo se vean 10 modelos
  para no llenar la pantalla y ir bajando"
- **S13** (the muted tone, verbatim): "que el texto de cosas como el proveedor,
  model name: ,enter to select... usen ese tono 'muted', habría que revisar con
  codegraph cli si pi usa el mismo que con el thinking"; and the missing key:
  "(también nos faltó el ctrl+s para default)"
- **S14** (the two coloured lines, verbatim): "el only showing debería ser
  amarillo, que el model refreshed esté dentro del componente en verde y no quede
  en el chat cuando se salga"
- **S15** (the selected row, verbatim): "que el modelo sobre el que estás parado
  se resalte con el color del tema como lo hace pi"
- **S16** (the search, verbatim): "aparte el buscador de modelos creo que ya no es
  fuzzy, no me acuerdo si el anterior lo era, creo que el de pi sí"
- **S17** (the counter, verbatim): "cuando se descartan modelos, solo debería
  reducirse el número máximo, ejemplo 1/450 -> luego de buscar -> 1/80, el usuario
  sigue sabiendo en cual esta parado y cuantos hay segun lo que buscó"
- **S11** (the tooling correction, verbatim): "ni siquieras has usado
  nimlangserver con su skill nim mcp tools" — the project's MCP tools are
  available through codemode and own Nim symbol and diagnostic work
  (`nimFindSymbols`, `nimFindReferences`, `nimListSymbols`, `nimCheckFile`,
  `nimCheckProject`), per `.pi/skills/nim-mcp-tools/SKILL.md`.

## Verified basis — the code as it stands (2026-11-09, mapped read-only)

- **`/model` today fetches ONE provider**: `openModel` (`tui.nim:1432`) reads
  `currentProvider(L)`, calls `listModels(backing.get)` (`1455`) and builds rows
  with `MenuItem(label: id, description: "")`. There is **no per-provider
  catalog loop**.
- **`listModels` is not a Lua contract**: `runtime/*.lua` reaches only
  `neopi.provider.generate`/`stream`, so the signature is internal.
  `listModels*(p: Provider): seq[string]` (`provider.nim:197-202`) →
  `listModels*(transport, baseUrl, apiKey)` (`openai_compat.nim:360-364`) →
  `listModelsAsync*` (`325-326`) → `buildModelsRequest` (`179-183`) →
  `transport.fetch` (`331-334`) → `resp.next()` (`345-349`) → `parseModels`
  (`358`). It returns **ids only** — no display `name`, which S5 needs.
- **Status yes, validators no**: `WireResponse` declares `status*: int` and
  `headers*: seq[(string, string)]` (`wire.nim:18-22`), but the production
  construction copies only `resp.status`, never the response headers
  (`wire.nim:113-130`). The catalog path never reads `resp.headers`; there is no
  `ETag`/`Last-Modified` under `src/neopi`. Conditional revalidation (S3) needs
  the headers plumbed through.
- **The pump does not cover the catalog fetch**: `Pump` (`pump.nim:24-26`) is
  injected by `tuiPump` (`tui.nim:908-934`) via `installTuiPump` (`936-943`), and
  it reaches the stream body read through `nextChunk` (`openai_compat.nim:204-246`,
  wired at `296`) and the child poll (`process.nim:179-190`). `listModelsAsync`
  has no pump parameter and directly awaits `resp.next()`, so S4 needs the seam
  extended to it (and to `transport.fetch`, the connect/headers wait).
- **The table and the credential seam**: `ProviderSpec{id, baseUrl, envVar,
  requiresKey, label}` (`provider.nim:57-69`), `knownProviders` (8 entries,
  `83-108`), `findProvider` (`110-115`), `newProvider` (`152-161`), and
  `providerState*` (`127-140`) which is the "configured" predicate
  (`stored`/`env`/`keyless` vs `not configured`). `authstore.nim` holds
  `configDir*` (`28-35`, honors `$NEOPI_CONFIG_DIR`), `authFilePath*` (`37-39`)
  and a private `writeNode` (`68-85`: owner-only, `.tmp` sibling, rename over the
  target, no lock file) — the atomic write the models store reuses.
- **A model pick does not move the provider today**: `setModel*` (`tui.nim:1424-1426`)
  writes the id and the Lua `_tuiModel` only; `setActiveProvider*` (`1507-1519`)
  is the one that rebuilds the live `Provider` (stored key, then `getEnv`). S4's
  cross-provider pick reuses that path.
- **nimterm's `Menu` has no header, footer, counter or details line**, and its
  `title` renders ONLY inside a border (`newMenu`,
  `~/proyectos/nimterm/src/nimterm/widgets/menu.nim:31-36`; the title is nested
  under `if bordered` at `:105,121-123`) — so neopi's picker titles
  (`"pick a model:"`, `"Select provider to configure:"`) are **invisible today**,
  because every picker is built unbordered (`tui.nim:1203,1224,1475,1497-1499`).
  `MenuItem` carries only `label`/`description`, and a nonempty description
  paints on the same row, after two spaces (`menu.nim:14-16,140-151`).
  **Verdict: renderable today, no nimterm patch** — `Menu.items`/`selected` are
  public and neopi owns `NeopiScreen.paint`, so the header, the counter and the
  `Model Name:` line are neopi's own chrome around the widget.
- **The footer is `<provider-id>/<model> | in N | out M`** (`tui.nim:681-690`),
  and the fetch's status row is `"fetching the models…"` with
  `presentApp(state, force = true)` (`1451-1452`).

## Design

- **The catalog record carries the display name**: `ModelInfo{id, name}`, parsed
  from the endpoint's `id`/`name` (pi's `Model Name:` line is the endpoint's
  `name`, not a prettified id). `parseModels` keeps the name; `listModels`'s
  existing shape stays if anything still wants bare ids.
- **The store is one file, one entry per provider**: `models-store.json` holds
  `{<provider-id>: {models: [{id, name}], checkedAt, etag?, lastModified?}}` —
  pi's `ModelsStoreEntry`. It reuses the credential store's atomic owner-only
  write **unchanged** (the helper is exported, its behaviour is not); the missing
  lockfile stays the known limit it already is.
- **Freshness is a validator, not a clock** (S3): a stored `etag` goes back as
  `If-None-Match` and a stored `lastModified` as `If-Modified-Since`; a `304`
  keeps the cached list and refreshes only `checkedAt`. No TTL. `force` is not a
  user knob in this slice.
- **Restore first, fetch after**: the picker paints the cached list immediately
  (`restore`), then refreshes every **configured** provider (S1's "proveedores
  activos" = `providerState != not configured`), painting as each catalog
  arrives and persisting it.
- **The refresh does not freeze the loop** (S4): the seam of #16 is extended to
  the catalog fetch — the pump is raced into `transport.fetch` (the connect and
  headers wait) and into the body read, the `nextChunk` way, so Esc/Ctrl+C and
  the repaint keep working while a slow endpoint answers. This is the pump doing
  what it was built for, not #29's async state machine.
- **The rows are provider-aware**: `<id> [<provider-id>]`, the search text
  keeps the provider first (the `/model` rule from `picker-search`), and picking a
  row whose provider differs from the live one moves the live provider through
  `setActiveProvider` before the model id lands.
- **Ctrl+S stays out** (S4): the footer shows `Enter to select · Escape/Ctrl+C to
  cancel`.
- **The layout keeps neopi's order, not pi's**: neopi paints the menu above the
  composer (`tui.nim:304-351`), so the picker reads list-then-search where pi
  reads header-search-list. S5's lines (the header, the counter, `Model Name:`)
  are what port; the order is a known divergence, not a nimterm change.
- **Out of scope**: a default model, pi's phrase-token session search, and the
  `reasoning level` pi shows in its status bar.

## Tasks

| ID | What | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | `ModelInfo{id, name}` + `parseModels` keeps the name; `listModels` intact | S1, S5 | inline, RED→GREEN | `feat(provider): the model catalog carries the display name` — `dcd7678` |
| T2 | `src/neopi/modelsstore.nim`: `models-store.json` per provider + the restore/persist shape over the exported atomic write | S1, S2, S3 | inline, RED→GREEN — **item 2 adjacency** (the credential write helper is exported): its own commit + independent verification | `feat(config): the model-catalog cache in models-store.json` — `7b70d18` |
| T3 | The fetch: the conditional headers, the `304`, the response headers the production transport was DROPPING, and the #16 pump on BOTH waits (`listModels` → `fetchModels`) | S3, S4 | inline, RED→GREEN — differential check on the streaming path (the shared `wire.nim` producer + `nextChunk`), `Risk: none` | `feat(provider): the catalog refresh revalidates and stops freezing the frame` — `3a39c1a` |
| T4 | `src/neopi/catalog.nim`: `configuredProviders`, `restoreCatalog`, `namesAmong`, `refreshProvider`, plus `credentialFor` extracted out of the TUI | S1, S2, S3 | worker, RED→GREEN | `feat(provider): the catalog policy — configured providers, cached restore, revalidated refresh` — `ab9a321` |
| T5 | The picker: the cache painted first, the live per-provider revalidation, the rows `<id> [<provider>]`, the data-carrying pick, neopi's own chrome, the cross-provider move | S1, S4, S5 | worker, RED→GREEN — differential on the shared picker slot | `feat(tui): /model lists every configured provider, from the cache first` — `6fa734b` |
| T6 | README + the ROADMAP row + this record's Evidence, limits and close | S1-S6 | inline | `docs(model-catalog): #28 leaves Remaining — the slice, the evidence and the limits` — `beffe33` |

### Round 2 — what the user found living with it

| ID | What | Specs | Route | Commit |
|---|---|---|---|---|
| R1 | The crash: the picker must never hand a negative `selected` back to a non-empty Menu (the `min` that kept `-1`), plus the `Menu` hardening itself with the pin bump | S7 | inline, RED→GREEN | `fix(tui): clearing a search that matched nothing no longer crashes the TUI` — `ab7bcdd` |
| R2 | The keyless rule: `configuredProviders` requires a real configuration, not `requiresKey: false`; the server-URL question goes to the END of the ROADMAP | S8 | inline, RED→GREEN | `fix(catalog): a keyless provider is not configured for merely existing` — `b77a15b` |
| R3a | The `Picker` block in our nimterm fork (header, input, rows, counter, detail, notice, keys) AND the `Menu` hardening, with the fork's own tests | S9, S7 | the fork, RED→GREEN | `feat(widgets): the Picker block, in pi's order, and a total Menu` — nimterm `d206e94` |
| R3b | neopi hands the block the data and the widgets, and its own chrome path goes away | S9 | inline, RED→GREEN | `feat(tui): the model picker becomes the fork's block, in pi's order` — `3578256` |
| R4 | The pins: chronos by EXACT version, and leave one nimterm revision installed (the lock measured and deferred) | S10 | inline, measured | `build: pin chronos by exact version, and leave one nimterm revision installed` — `11b4f88` |
| R5 | README + ROADMAP + this round's evidence and close | S7-S10 | inline | `docs(model-catalog): round 2 — the crash, the keyless rule, the fork's Picker and the pins` — `c6f868f` |

### Round 3 — the look, side by side with pi

Read from pi with codegraph (the user's own instruction) on 2026-11-11; every
claim below is from the source, not from the screenshot:

- `MAX_VISIBLE = 10` (`packages/coding-agent/src/modes/interactive/components/model-selector.ts:38`),
  and the window follows the selection (`:320-322`) — the list scrolls, it does
  not fill the screen.
- The roles: the header hint is `theme.fg("warning", hintText)` (`:115`); the
  cursor `→` and the SELECTED row's id are `accent` (`:334,336`); the provider
  badge, the model's display name, `· default`, the counter, `Model Name:` and
  "No matching models" are all `muted` (`:332,338,339,347,359,363`); the refresh
  notice is `theme.fg(success or muted, …)` (`:368`).
- The counter is `(${selectedIndex + 1}/${filteredModels.length})` (`:347`): the
  position over what the QUERY leaves, not over the whole catalog.
- **pi's search RANKS**: `fuzzyFilter` (`packages/tui/src/fuzzy.ts:121`) says
  "Filter and sort items by fuzzy match quality (best matches first)", splits the
  query into tokens on `/\s/]+/` (space AND slash), requires every token to
  match, and sorts by score. neopi filters with ONE subsequence and keeps the
  source order — that is what the user noticed.
- The search text is `` `${provider} ${provider}/${id} ${provider} ${id}${name}` ``
  (`packages/coding-agent/src/modes/interactive/model-search.ts:43`).
- The keys line is `Enter to select · Ctrl+S to set as default · Escape/Ctrl+C to
  cancel` (`:146`).
- **The thinking is NOT the same token**: pi's reasoning paints with
  `theme.fg("thinkingText", …)` + italic (`components/assistant-message.ts:195`),
  while this chrome is `muted`. neopi conflates them (its thinking is
  `muted + italic`, `tui.nim:832-833`) — a pre-existing divergence, out of this
  round, and the answer to the user's question is **no**.

nimterm's `Theme` already carries every role this needs
(`accent`, `success`, `warning`, `muted`, `dim`, `text`), so the colors are
neopi's mapping and the fork needs no change.

| ID | What | Specs | Route | Commit |
|---|---|---|---|---|
| N1 | The list windows to ten rows (pi's `MAX_VISIBLE`) and scrolls instead of filling the screen | S12 | inline | `feat(tui): the model picker reads like pi's — window, roles, counter, ranking` — `f74f2c3` |
| N2 | The roles from the theme: the header `warning`, the counter/detail/keys `muted`, the notice `success` INSIDE the block and NO chat line left behind | S13, S14 | inline | ↑ `f74f2c3` — N1-N5 are ONE work unit: one surface, the block's look, a handful of lines each |
| N3 | The counter reads `(position/what the query leaves)` | S17 | inline | ↑ `f74f2c3` |
| N4 | The search becomes pi's: tokens split on space AND slash, all must match, SCORED and sorted best-first; the search text aligned to pi's | S16 | inline | ↑ `f74f2c3` |
| N5 | The SELECTED row paints in the theme's `accent` | S15 | inline | ↑ `f74f2c3` |
| N6 | Tests + this round's evidence and close | S12-S17 | inline | the commit that carries this section |

## Evidence

Every gate ran with `PATH="$HOME/.local/share/grabnim/current/bin:$PATH"` and
`TMPDIR="$HOME/tmp-nim"`, and each task observed its RED before the fix.

- **T1** — RED: `Error: undeclared field: 'id' for type system.string`, exit 1.
  GREEN: the focused file **1/1 OK** and the whole suite **248/248 OK**, exit 0.
- **T2** — RED: `Error: cannot open file: neopi/modelsstore`, exit 1. GREEN: the
  cache's suite **7/7 OK** and the whole suite **255/255 OK**, exit 0 — and the
  INDEPENDENT verification (risk item 2, the credential write path) returned
  **PASS**: `writeNode`'s body is byte-identical to its parent (only `*` and the
  docs changed), the credential suite stayed **10/10 OK**, a fresh config
  directory came back `700` with both files `600`, a malformed
  `models-store.json` is DISCARDED while a malformed `auth.json` still raises
  `AuthStoreError` and stays byte-identical (`md5sum` equal before and after).
  Its gap is recorded rather than hidden: nothing asserts the atomic rename, the
  `.tmp` sibling, or failure-preserves-target directly.
- **T3** — RED: `Error: attempting to call undeclared routine: 'fetchModels'`,
  exit 1. GREEN: the focused file **39/39 OK**, the whole suite **260/260 OK**,
  the busted specs **22 successes / 0 failures**, exit 0 in all three. The
  DIFFERENTIAL against `7b70d18` over the three streaming suites — the code the
  request did not name but which shares the wire producer — is identical in
  stdout and exit code once the elapsed time of the summary lines is
  normalized.
- **T4** — RED: `Error: cannot open file: neopi/catalog`, exit 1 (the worker).
  GREEN: the policy's suite **6/6 OK**, the whole suite **267/267 OK**, the
  `/login` suite **13/13 OK**, exit 0. The orchestrator's review then closed a
  gap the plan had not asked for: `credentialFor` is the KEY the live provider is
  built with, while `providerState` only names the STATE, and nothing pinned
  their agreement — a new `tp_provider` test pins the stored-first order
  (**21/21 OK**). One orchestrator style nit broke the build first (`let
  provider` against `setPump(p: var Provider)`), which is why that is the retry.
- **T5** — RED: `Error: undeclared field: 'catalogTransport' for type
  tui.TuiState`, exit 1 (the worker). GREEN: the TUI file **99/99 OK**, the whole
  suite **269/269 OK**, the busted specs **22 successes / 0 failures**, exit 0 in
  all three. The DIFFERENTIAL against `ab9a321` over the NINE suites that share
  the picker slot (`/resume`, `resumeSession`, the sessions list,
  `/login`+`/logout`, the command completion, the completion in the composer, the
  composer's keys, the fuzzy matcher, the `/` dispatch) is identical in stdout
  and exit code.

### Round 2 — the fixes the user found living with it

- **R1 (the crash)** — reproduced FIRST, with the user's own stack (`menu.nim:139
  paint` → `index -1`), before any fix. RED: `Unhandled defect: index -1 not in 0
  .. 1 [IndexDefect]` out of the clear. GREEN: the focused test 1/1, the file
  **100/100**, the suite **270/270**, exit 0.
- **R2 (keyless)** — the tree went RED on my own edits twice, and both are worth
  the line: `check x.mapIt(it.id)` does not compile (unittest2 wraps the checked
  expression in an iterator and the `it` breaks there), and neither does `check
  ids == @[]` (an untyped `@[]` loses its element type in that wrapper). GREEN:
  the policy 7/7, the TUI 100/100, the suite **271/271**, busted 22/22.
- **R3a (the fork)** — `Picker` + the `Menu` hardening in
  `~/proyectos/nimterm`: **87 [OK], 0 FAILED** in the fork's own suite, with the
  negative-index regression pinned. Commit `d206e94`, pushed by the user.
- **R3b (neopi uses it)** — TWO delegated workers stalled on this round (and one
  earlier, on T3); the second left ONLY the tests, and the work moved inline. Its
  tests were KEPT, because they encode the contract the design wanted: the
  block's fields, `picker.input == inputW`, `picker.menu == screen.menu`,
  `picker.isNil` once closed, and the painted ORDER. GREEN: the file **101/101**,
  the suite **272/272**, busted 22/22, and the shared picker slot unchanged
  (`/resume` 1, `/login` 13, the command completion 4, the composer 7, its keys
  3, the `/` dispatch 2).
- **R4 (the pins)** — measured, and the premise was WRONG: the two chronos copies
  are not the hazard AGENTS.md documents (they carry different versions,
  `nimblePath` keeps the higher one, and `4.0.4` has to STAY because
  `nimlangserver` 1.14.0 requires it — read out of `nimbledata2.json`'s
  `reverseDeps`). The hazard was the pair the nimterm bump created: version
  `0.1.0` twice. The old copy is gone, **309 nimcaches** cleared, and the
  acceptance probe — `newPicker`, a symbol only the pinned revision has —
  compiles. `chronos == 4.4.1`, an EXACT version rather than a commit URL, since
  nimble 0.24.1 answers "Unable to identify url" for that repository.
  `nimble lock` was generated and measured: it fixes the hazard for `nimble
  build` (an explicit `--path` per locked revision, and no package-list read) but
  on 0.24.1 it breaks a bare `nim c` and therefore `nimble test`. The user's read
  is that it is the old nimble, so it waits in the ROADMAP's Deferred.

### Round 3 — the look, side by side with pi

- **N1-N5 landed as ONE work unit** (`f74f2c3`): they are one surface — the
  block's look — and each is a handful of lines, so five commits would have been
  five diffs nobody could review apart. The user's own list is what defines the
  unit.
- RED, observed: the focused file went to **5 failures** when the code moved —
  the row's shape (the label gave the ` [provider]` badge to the description)
  and the counter (`(filtered/total)` became `(position/filtered)`) — and the
  frame search for `openai-fresh [openai]` stopped matching, because the Menu
  pads the label to the widest one before it paints the description.
- GREEN: the focused file **104/104**, the whole suite **275/275** (272 + the
  three tests this round added), busted **22 successes / 0 failures**, exit 0.
- The three new tests ARE the round's rules: the block's STYLES come from the
  theme (`warning`/`muted`/`accent`/`success`); the notice lives in the block
  and the chat status stays empty; the list windows to **ten** rows on a 30-row
  terminal with a 25-model catalog (the fake backend grew an optional height
  for exactly that, since a ten-row screen cannot show ten rows plus the
  block); and the matcher takes pi's tokens and scores best-first.
- The `codegraph` reading is in the Verified basis above, including the answer
  to the user's own question: pi's thinking is `thinkingText` + italic, **not**
  `muted`, so neopi's conflation of the two is a pre-existing divergence and
  out of this round.

### What the slice settled

- **A cache without validators is a clock.** The user asked for pi's shape, and
  pi's cache stores how to REVALIDATE (`{models, checkedAt, etag?,
  lastModified?}`) instead of a TTL. That is what made the conditional GET — and
  therefore the response headers the production transport was DROPPING — part of
  the slice, instead of an optimization to add later.
- **The pick carries data, never a display string.** The rows live beside the
  menu, and the source, the search texts and the rows are filtered in ONE loop,
  so the menu's index addresses the row it shows. It is `/model`'s own NUL lesson
  (a string read out of a released widget) turned into structure: a value
  recovered from a label is the same mistake one step later.
- **The chrome's PLACE belongs to a widget, not to the app.** The first attempt
  painted the picker's lines in neopi — `Menu` cannot carry a header, a counter
  or a footer, and its `title` only paints inside a border, so every picker's
  title had been invisible — and the layout left them BELOW the editor. The
  user's side-by-side screenshot settled it (R3b): pi's ORDER is a widget's job,
  and the fork's `Picker` owns it while neopi only hands over the data.
- **#16 was the missing piece, not a prerequisite that expired.** The pump it
  built now covers the catalog's two waits, so the deferral ("Dejalo para #16")
  came back into the slice it belonged to.

## Known limits

- **One request per provider, in series.** The pump keeps the frame alive and
  abortable, so nothing freezes, but every row is fresh only when the walk ends.
  Parallel fetches (or an event source that polls the dispatcher) are #29's
  shape, not this slice's.
- **Esc stops the WALK, not the request in flight**: `tuiPump` answers an abort
  only for `quit` and `abortRequested` (the run's abort), so the current fetch
  finishes before the walk notices. Ctrl+C does abort it.
- **No lockfile**, the same limit the credential store already carries: two neopi
  processes refreshing at once can lose one write.
- **`/model` no longer requires a live provider.** The old "no provider: run
  /login or set `<VAR>`" message is gone; the picker decides from the table and
  the cache, and when nothing is available it says "No model catalogs are
  available. Use /login to add providers." — the same actionable half, one step
  later.
- **The search text is now `<provider>/<id> <id> <name>`** (the endpoint's
  display name included, pi's rule), where it used to be `<provider> <id>`.
- **The counter and the name USED to be painted under the EDITOR**, while pi
  paints them under its LIST — RESOLVED by R3b, where the fork's `Picker` paints
  pi's order. The line stays as the record of what the first attempt got wrong.
- **Ctrl+S "set as default" is NOT here, and it is not a colour.** pi's row
  carries ` · default` (`model-selector.ts:332`) and its keys line names
  `Ctrl+S to set as default` (`:146`), but the feature needs a DEFAULT MODEL:
  where it is stored, how a turn reads it, and the badge that shows it. The user
  deferred it once ("ctrl s puede ser el siguiente slice") and this round only
  matched the look; it is the natural next slice.
- **The search's SCORE is ours, not pi's.** The structure is pi's `fuzzyFilter`
  (tokens on space and slash, all required, best first), but pi's `matchQuery`
  weighs the gaps, the start position and even swaps an alphanumeric token
  ("3d" for "d3", +5). A ranking difference shows as a different ORDER, never as
  a wrong set.
- **The rows do not carry the model's display name** the way pi's do
  (`id (Name) [provider]`, `model-selector.ts:338`): neopi's row is the id plus
  the provider badge. The name is still what `Model Name:` prints, and the
  search text carries it, so a query finds the model by name — the ROW does not
  repeat it.

## Log

- **L1** (the original request, verbatim): "apague rdd, por cierto, pi no te pone
  ese provider al hacer /login,debemos hacer que /models soporte y muestre todos
  los modelos de los proveedores activos (cómo se vé en
  ~/Imágenes/01-11-2026-21:30:55.png), en este espacio creo que también deberíamos
  agregar caching de la lista de modelos para que cargue instantaneo mientras
  hace el fecth a la url"
- **L2** (the cache's name, verbatim): "creo que deberíamos usar el mismo nombre
  que pi en vez de catalogs.json"
- **L3** (the deferral this slice now reverses, verbatim): "Dejalo para #16 (que
  ya es lo próximo)" — #16 landed (`odd/tasks/live-tools.md`), so the
  non-blocking refresh comes back into #28 by the user's call today.
- **L4** (the copy-pi instruction, verbatim): "me gustaría revisar primero con
  codegraph en ~/proyectos/pi exactamente como lo hace pi"
- **L5** (this session's request, verbatim): "arranquemos con el siguiente
  remaining en el roadmap, #28, primero contextualizate con engram, si vas a
  buscar en el codigo usa codegraph o nimlangserver"
- **L6** (the two decisions, verbatim): the fetch — "Hacerlo no bloqueante con el
  seam de #16"; the keys — "solo enter para seleccionar, ctrl s puede ser el
  siguiente slice".
- **L7** (2026-11-09, the landing): T1-T5 on `main` as the work units `dcd7678`,
  `7b70d18`, `3a39c1a`, `ab9a321` and `6fa734b` — T2 independently verified (risk
  item 2), T3 and T5 differential-checked against their base over the shared
  code the request did not name. Two failures are kept instead of smoothed over:
  the first delegated worker (T3) STALLED and left no side effect at all, so the
  task moved inline rather than being relaunched blindly; and an orchestrator
  style nit (`let provider`) broke the build against `setPump(p: var Provider)`,
  caught by the compiler and fixed before the gate passed. The `#28` row left
  ROADMAP's Remaining for Done, and the note that "the refresh still freezes the
  loop until #16 lands" retired with it.
