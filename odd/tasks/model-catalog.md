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
| T1 | `ModelInfo{id, name}` + `parseModels` keeps the name; `listModels` intact | S1, S5 | inline, RED→GREEN | |
| T2 | `src/neopi/modelsstore.nim`: `models-store.json` per provider + the restore/persist shape over the exported atomic write | S1, S2, S3 | inline, RED→GREEN — **item 2 adjacency** (the credential write helper is exported): its own commit + independent verification | |
| T3 | The wire's validators: the production transport keeps response headers; the conditional GET + `304` keeps the cache | S3 | inline, RED→GREEN — differential check on the streaming path (shared `nextChunk`) | |
| T4 | The catalog loop with the pump: every configured provider, non-blocking through the #16 seam, restore-before-fetch, persist per provider | S1, S3, S4 | inline, RED→GREEN | |
| T5 | The picker: rows `<id> [<provider>]` across providers, the header, the counter, the display name, the refresh notice, the footer keys (neopi's own chrome — no nimterm patch); a cross-provider pick moves the live provider | S1, S4, S5 | inline, RED→GREEN | |
| T6 | README + the ROADMAP row + this record's Evidence and close | S1-S6 | inline | |

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
