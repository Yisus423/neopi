# Search in the pickers: /model and /resume filter as you type

The slice the user asked for after living with #21 for an afternoon: scrolling
hundreds of model ids is tedious, and pi's pickers filter as you type. The
query lives in the COMPOSER, which the picker already floats above and whose
`change` action already drives the completion, and both pickers share one fuzzy
matcher. The same slice carries the blocking fetch the Ctrl+C verification
measured: while `/model`'s catalog GET runs, the loop processes no event at all.

## Specs

- **S1** (the request, verbatim): "También se siente algo tedioso scrollear entre
  cientos de modelos, podríamos implementar busqueda en /models y /resume como
  lo hace pi"
- **S2** (the query's home, the user's choice, verbatim): "El composer
  (recomendado)" — the picker filters from what the composer holds, as the
  completion already does; no second input widget inside the picker.
- **S3** (the matcher, the user's choice, verbatim): "Un matcher fuzzy para los
  dos" — one matcher, shared by `/model` and `/resume`; not pi's richer
  session-search model (phrase tokens, a name filter, three sort orders).

## Verified basis (2026-10-23) — how pi does it

Read from `~/proyectos/pi/packages/coding-agent/src/modes/interactive/`:

- `model-search.ts` (21 lines) — the match text is not the bare id:
  `"${provider} ${provider}/${id} ${provider} ${id} ${name}"`, **provider
  first**, with the comment spelling out why: an exact provider-prefixed query
  should rank before proxy-provider ids like `openrouter/openai/gpt-5`.
- `components/model-selector.ts` — a search `Input` is a CHILD of the selector
  and receives every key (`this.searchInput.handleInput(keyData)` →
  `filterModels(this.searchInput.getValue())`): no mode, no prefix, live
  filtering. The filter is `fuzzyFilter(models, query, searchText)`. With a
  query the selection returns to the first match; clearing it keeps the
  position clamped; Enter selects the first filtered row; `isDefaultSearch`
  treats a "default" query as no filter at all.
- `components/session-selector-search.ts` (194 lines) — the richer model this
  slice deliberately does NOT port: `parseSearchQuery` into phrase tokens plus
  `NameFilter = "all" | "named"` (a failed parse matches nothing),
  `matchSession` requiring every token with a position score (`idx * 0.1`), and
  `filterAndSortSessions` in three orders (`threaded` | `recent` | `relevance`).

neopi today: nimterm's `Menu` navigates and scrolls (`scrollOffset`,
`keepSelectionVisible`) but **does not filter**; the only filter in the tree is
the completion's, a pure proc of case-insensitive **prefix** over
`{name, description}`, recomputed on the composer's `change` action (#22). Both
pickers build their items in `openResume` and `openModel`, and `closeMenu`
releases the slot and its `MenuKind`.

**Measured** (F2's verification, `odd/tasks/session-commands.md`): with `/model`
the Ctrl+C exit arrives ~0.95 s late because `openModel`'s `listModels` is a
blocking GET — while it runs, the loop dispatches nothing. The pty harness saw
the same state exceed 4 s on a slower network.

## Design

- **The composer is the query.** While a picker is open (`mkResume`, `mkModel`),
  its text is the filter. The picker's items are rebuilt from the query on the
  composer's `change` action — the completion's mechanism, so there is no timer,
  no polling and no work inside `paint`. Opening a picker starts from an empty
  query (the command path clears the composer) and the picker's own keys (Esc
  closes, arrows navigate, Enter picks) stay as they are.
- **One fuzzy matcher, a pure proc**, in the completion's family: it takes the
  query and the candidate's search text and returns whether it matches, so both
  pickers share it and it is testable without a terminal. Subsequence matching
  (`gpt5` finds `gpt-5`), case-insensitive, with the query's characters required
  in order.
- **The search text follows pi's ordering rule** where it matters: the model
  picker matches against `provider/provider-id id name` so a provider-prefixed
  query ranks before a proxy id, and `/resume` matches the session's label and
  path.
- **The selection returns to the first row while a query is active** (pi's
  rule), and stays where it was when the query is cleared.
- **The blocking fetch is fixed in the same slice**: the catalog GET pumps the
  app while it waits, the shape the turn drive already uses (`waitFor` with the
  app stepped and presented), so keys and Ctrl+C keep working — with a
  "fetching the models…" status so the wait is visible.
- **Out of scope** (S3): pi's phrase tokens, its name filter and its three sort
  orders.

## Tasks

| ID | What | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | The fuzzy matcher (a pure proc) + its tests | S3 | inline | — |
| T2 | `/model` filters from the composer as you type | S1, S2 | inline | — |
| T3 | `/resume` filters the same way | S1, S2 | inline | — |
| T4 | The catalog GET stops freezing the loop | S1 | inline | — |
| T5 | Docs (README's keys/commands) and the close | S1-S3 | inline | — |

## Log

- **L1** (verbatim, the request): "También se siente algo tedioso scrollear entre
  cientos de modelos, podríamos implementar busqueda en /models y /resume como
  lo hace pi"
- **L2** (the two design decisions, verbatim): S2 and S3 above.
- **L3** (verbatim, the method correction that preceded the slice): "podrías
  haber usado codegraph en ~/proyectos/nimterm o revuisar sus docs" — for
  nimterm the checkout's index and docs are the first reach, not a grep of the
  installed package.
