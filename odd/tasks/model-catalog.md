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
| T6 | README + the ROADMAP row + this record's Evidence, limits and close | S1-S6 | inline | the commit that carries this section |

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
- **The chrome is neopi's because nimterm's `Menu` cannot carry it** — and its
  `title` only paints inside a border, which is why every picker's title had been
  invisible. The picker's lines go BELOW the editor, where the floating menu
  cannot blank them.
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
- **The counter and the name are painted under the EDITOR**, while pi paints its
  counter, name and keys under its LIST: the lines are pi's, the order is neopi's
  (its search input sits below the list).
- **Ctrl+S "set as default" is out** by the user's call: a default model is a new
  feature and it goes to a later slice.

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
