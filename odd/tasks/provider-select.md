# provider-select — the provider picker behind /login and /logout

Slice A of the selection work: one picker over the provider table, each row a
human label plus its configuration state, opened by `/login` (configure) and
`/logout` (drop the credential). Slice B — `/model` across every configured
provider with the catalog cache — follows, and its design rides #16 for the
non-blocking refresh.

## Specs

- **S1** (the request, verbatim): "Deberíamos meter una seleccion de proveedores
  como lo hace pi (~/Imágenes/01-11-2026-20:05:01.png) o parecido a nuestro
  /models."
- **S2** (the screenshotted shape, verbatim from pi's TUI): "Select provider to
  configure:" — a list whose rows are the provider and its state (`· not
  configured`, `✓ stored`), a marker on the selected row, and a position
  counter. pi's other mode is "Select provider to logout:".
- **S3** (the rows, the user's choice, verbatim): "Label humana + estado
  (OpenRouter, Together AI…)" — a `label` joins `ProviderSpec`, and every row
  carries its state.
- **S4** (what the commands are, the user's choice, verbatim): "/login y /logout
  abren el picker, y elegir cambia el activo" — with the user's own correction
  about pi in the same message: "pi no te pone ese provider al hacer /login".
  neopi keeps the switch (S4 is the explicit choice); pi's behaviour is the
  other path, and it arrives with slice B, where picking another provider's
  model in `/model` moves the live provider.
- **S5** (the slices, the user's choice, verbatim): "Dos: primero el picker,
  después /model" — this record is the picker.
- **S6** (the catalog cache, decided after reading pi): "me gustaría revisar
  primero con codegraph en ~/proyectos/pi exactamente como lo hace pi" — the
  reading is in the Verified basis below, and the cache belongs to slice B; the
  non-blocking refresh is deferred: "Dejalo para #16 (que ya es lo próximo)".

## Verified basis — pi's picker, and pi's catalog cache

**The picker** (`packages/coding-agent/src/modes/interactive/components/
oauth-selector.ts`): one component, two modes — the title is `Select provider to
configure:` for login and `Select provider to logout:` for logout (`:105`).
`formatAuthSelectorProviderStatus` (`:37`) is the state column, and it separates
FOUR cases: no status → ` • not configured` (muted); a stored status whose type
differs from what the provider expects → ` • <TYPE> configured` (warning);
source OAuth/stored/absent → ` ✓ configured` (success); an environment source →
`env: <VAR>` (the uppercase-name regex is at `:50`). So pi's state is not "has a
key": it is "has a credential, and is it the kind this provider expects", in
three colors.

**The catalog cache** (`packages/ai/src/models-store.ts`,
`packages/coding-agent/src/core/models-store.ts`, and the dynamic-provider
refresh in `packages/ai/src/models.ts:1132`):

1. `FileModelsStore` writes `~/.pi/agent/models-store.json` **through the same
   locked storage backend as the credentials** (`FileAuthStorageBackend`): the
   same lockfile, the same read-modify-write, the same modes. The model and the
   auth stores share one engine.
2. `ModelsStoreEntry` is `{models, checkedAt?, etag?, lastModified?}`: the
   catalog, when the last remote check COMPLETED, and the HTTP validators (the
   ETag stored verbatim and echoed as `If-None-Match`). The cache stores how to
   REVALIDATE, not only the result.
3. The refresh is **restore first, fetch after**: `if (context.stored) publish({
   update: restore })` → `if (!context.allowNetwork) return` → fetch → `publish({
   persist: { models, checkedAt: now }, update })`. That is what makes the list
   appear instantly while the network is still working.
4. **No TTL**: the cache is revalidated whenever the network is allowed
   (conditionally, when the endpoint offers validators). The knobs are `force`
   (bypass a provider's own freshness check) and `allowNetwork: false` (disk
   only). Freshness is a validator, not a clock.
5. Concurrency: concurrent refreshes coalesce per runtime and abort when nobody
   waits (`ModelCatalogRefreshCoordinator`). Reads are sync; fetching is an
   explicit async verb — and the selector's "Model catalogs refreshed." is its
   completion.

**neopi today**: the table (`ProviderSpec`: id, baseUrl, envVar, requiresKey),
the store (`loadApiKey`/`saveApiKey`/`deleteApiKey` with its atomic owner-only
write), and the picker machinery `/model` and `/resume` already use — one `Menu`
above the composer, the composer as the search field (`updatePickerSearch`), the
shared `MenuKind`, the status line for feedback.

## Design

- **The rows are a pure function of the table plus the store**, so they are
  testable without a terminal: per entry the label, and the state in neopi's own
  vocabulary — `stored` (the global store holds a key for it), `env: <VAR>`
  (the variable is set, which `.env` also populates), `keyless`
  (`requiresKey == false`), else `not configured`. The order is the table's.
- **A new `MenuKind` (`mkProvider`)** reuses the picker plumbing: the slot above
  the composer, the composer as the search field, Enter picks, Esc closes and
  the query leaves with the picker. The state carries the MODE (configure |
  logout), because one picker answers both commands — pi's two titles, one
  component.
- **Picking sets the active provider** (S4): the state's name, the footer and the
  per-turn model string move, the way `/model` already moves the model id. Then
  the mode decides the rest: `configure` opens the masked key question FOR THAT
  ENTRY, saves it, and reports where it went; `logout` deletes that entry's
  stored credential and clears the live provider when it was the active one.
- **The label is data**: `label` joins `ProviderSpec` (`OpenRouter`,
  `Together AI`, `llama.cpp`). The help that already builds itself from the table
  keeps printing the ID — that is what you type — while the picker prints the
  label: what you read.
- **Slice B's handoff** (written here so it is not rediscovered): the cache
  lives in **`~/.neopi/models-store.json`** — pi's file name, the user's call
  ("creo que deberíamos usar el mismo nombre que pi en vez de catalogs.json"),
  one entry per provider (`{models, checkedAt}` at least, plus the validators if
  we take the conditional path), written through the store's atomic write and
  **restored before the fetch**; `/model` lists every configured provider's models as
  `id [provider]`, with the header "Only showing models from configured
  providers" and the counter; the non-blocking refresh waits for #16, which is
  where the loop's async mechanism lands.

## Tasks

| ID | What | Spec | Route | Commit |
|---|---|---|---|---|
| T1 | `label` on `ProviderSpec` + the pure row/state builder with its tests | S3, S4 | inline, RED→GREEN | `d9e9b59` |
| T2 | The picker: `mkProvider`, the two titles, the selection action, the composer search | S2, S4 | inline, RED→GREEN | `747e746` |
| T3 | The wiring: `/login` and `/logout` open it; configure asks and saves for the picked entry; logout deletes that entry; the active provider moves | S4 | inline, RED→GREEN — and it rewrites the six existing tests that assume `/login` opens the question directly (`/login opens a masked question…`, `answering /login installs…`, `/login installs the provider the TABLE declares`, `Esc on the /login question…`, `/logout clears the provider…`, `the composer takes the keys again after the /login question closes`): each gains the picker step, and none of their assertions may be dropped to make that easier | |
| T4 | Docs: README (the picker, its two modes, the states) + ROADMAP's row when the slice closes | S1-S5 | inline | |
| T5 | The close: `## Evidence` with the gates, the known limits, slice B's handoff | S1-S6 | inline | |

## Log

- **L1** (2026-11-01, the request, verbatim): "Deberíamos meter una seleccion de
  proveedores como lo hace pi (~/Imágenes/01-11-2026-20:05:01.png) o parecido a
  nuestro /models. Deberíamos actualizar el -h para que se vean los --provider:.
  Hagamos primero la del -h que es trivial y pasamos a la de la selección. Por
  cierto creo que deberíamos mover #16 al proximo en vez #19, creo que es lo que
  separa a neopi de un juguete a una herramienta, podríamos al final revisar en
  engram cuantas features o cosas han sido bloqueadas o degradadas por #16"
- **L2** (the second half of the request, verbatim): "apague rdd, por cierto, pi
  no te pone ese provider al hacer /login,debemos hacer que /models soporte y
  muestre todos los modelos de los proveedores activos (cómo se vé en
  ~/Imágenes/01-11-2026-21:30:55.png), en este espacio creo que también deberíamos
  agregar caching de la lista de modelos para que cargue instantaneo mientras
  hace el fecth a la url"
- **L3** (the decisions, verbatim): the rows — "Label humana + estado
  (OpenRouter, Together AI…)"; the commands — "/login y /logout abren el picker,
  y elegir cambia el activo"; the slices — "Dos: primero el picker, después
  /model"; the fetch — "Dejalo para #16 (que ya es lo próximo)"; the cache —
  "me gustaría revisar primero con codegraph en ~/proyectos/pi exactamente como
  lo hace pi".
- **L4** (the tail of L1, already done before this record): the `-h` fix —
  the help is built from the table and shows the `=` form that actually parses
  (`80338d8`) — and the ROADMAP's #16 ahead of #19 (`96f1cda`). RDD was switched
  off in the same message (L2), so the review dispositions stop applying.
