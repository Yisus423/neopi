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
- **The blocking fetch's WAIT stops being silent** — and this bullet used to
  claim more than that ("the catalog GET pumps the app while it waits"), which
  the implementation proved wrong: the fetch still blocks the loop, and what
  ships is that the user is told why nothing answers. The status needs a
  FORCED frame (`presentApp(state, force = true)`): nimterm's flush respects
  the frame budget and the outer flush only runs once the action returns, which
  is after the wait the status explains. The real fix — a fetch that does not
  block — is an async event source that polls the chronos dispatcher (the shape
  nimlet's turn source uses), and its trigger is the first provider slow enough
  to make the freeze hurt.
- **Out of scope** (S3): pi's phrase tokens, its name filter and its three sort
  orders.

## Tasks

| ID | What | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | The fuzzy matcher (a pure proc) + its tests | S3 | inline | `feat(tui): the pickers get a fuzzy matcher` — `597f7c9` |
| T2 | `/model` filters from the composer as you type | S1, S2 | inline | `feat(tui): /model narrows the catalog as you type` — `6428a21` |
| T3 | `/resume` filters the same way | S1, S2 | inline | `feat(tui): /resume narrows the sessions as you type` — `c5b7fac` |
| T4 | The catalog fetch's wait stops being silent | S1 | inline | `feat(tui): the catalog fetch's wait stops being silent` — `4a426f8` |
| T5 | The README's keys, this evidence, and the close | S1-S3 | inline | `docs(tui): the picker search joins the record` — the commit that carries this section |

## Evidence

One gate per task, then the batch gate and what this slice learned.

- **T1** — focused `tests/tp_tui.nim` **70/70 OK**, `EXIT=0`; RED observed
  first as a compile error, `undeclared identifier: 'fuzzyMatch'`.
- **T2** — focused **71/71 OK**, `EXIT=0`; RED observed first as the list
  staying at three rows while the query was typed (`items.len was 3`).
- **T3** — focused **72/72 OK**, `EXIT=0`; RED observed first as `items.len was
  2` with one session matching.
- **T4** — focused **73/73 OK**, `EXIT=0`; RED observed first as no frame at
  all (`backend.frames.len was 0`), which is what "the wait is silent" looks
  like from inside the harness.
- **The batch gate** (on the whole tree, `set -o pipefail`): `nimble test` →
  `[Summary] 184 tests run (3.71s): 184 OK, 0 FAILED, 0 SKIPPED` and
  `22 successes / 0 failures / 0 errors / 0 pending`, `EXIT=0`. 184 = the 180
  the tree carried when the slice opened plus the four tests it added: the
  matcher (one test, seven assertions), `/model`'s filter, `/resume`'s filter
  and the fetch's status frame.

### What this slice learned

- **Filtering a picker surfaced two traps of the F1 family, both fixed in
  T2.** The completion's recompute ran for any kind that was not `mkResume`:
  with the model picker open it computed a prefix from the picker's query, found
  nothing and closed the slot — so typing killed the picker. And `menuOpen` was
  decided by the item count, so a picker whose query matched nothing could not
  be closed with Esc and kept its kind set, which is the state that silences
  the completion for the rest of a session. Now the completion yields to BOTH
  picker kinds, and the KIND decides whether a menu is open, not how many rows
  it holds.
- **A status before a blocking call needs a forced frame (T4).** `presentApp`'s
  flush respects nimterm's frame budget, and the outer flush only runs after the
  action returns — which is after the wait the status exists to explain. Without
  `force` the status is written, deferred and then covered by the picker's frame,
  and the user sees exactly the freeze it was meant to excuse.
- **The test can correct the author.** T3's first RED asserted the row label was
  the session's text; the real label is `<file> — <text>`, and the failing
  assertion is what taught it.

## Log

- **L1** (verbatim, the request): "También se siente algo tedioso scrollear entre
  cientos de modelos, podríamos implementar busqueda en /models y /resume como
  lo hace pi"
- **L2** (the two design decisions, verbatim): S2 and S3 above.
- **L3** (verbatim, the method correction that preceded the slice): "podrías
  haber usado codegraph en ~/proyectos/nimterm o revuisar sus docs" — for
  nimterm the checkout's index and docs are the first reach, not a grep of the
  installed package.
