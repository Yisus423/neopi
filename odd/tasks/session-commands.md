# The session commands: /login, /logout, /model inside the TUI

ROADMAP #21. Today the provider and the model come from the CLI flags and the
environment: there is no way to change them from inside the TUI and no way to
manage a key. The slice's entry was the **study of the `input` hook** — the one
gap the UX map lists — and the study found that the dialog gap is thinner than
the map reads and that the real gap is the provider's runtime state.

## Specs

- **S1** (the roadmap item, verbatim): "The session commands inside the TUI:
  `/login`, `/logout`, `/model` | The user's next slice, "algo más terrenal":
  today the provider and the model come from the CLI flags and the
  environment, with no way to change them from inside the TUI and no way to
  manage a key. `/commands` already dispatch through the composer,
  `neopi.registeredCommands` is the registry, and the completion (#22) now
  lists them; the missing piece for an interactive prompt is the `input` hook,
  the one gap the UX map lists"
- **S2** (the request, verbatim): "arranquemos con #21: el estudio del hook
  input"
- **S3** (the surface, the user's choice, verbatim): "¿Realmente es necesario
  exponer esto?, todavía no pienso en ninguno que lo necesite y siento que es
  mas cosa del core, lo que si va a lua es ui.input" — the provider's mutation
  stays **inside the core**; the one thing that reaches Lua is `ui.input`.
- **S4** (the key's home, the user's choice, verbatim): "para 23, pero
  seguramente sea un auth.json/.lua en la config global (aunque recuerda que
  actualmente ya hay una carpeta .neopi/)" — persistence is **ROADMAP #23's
  decision**; this slice keeps the key in the session.
- **S5** (the catalog, the user's choice, verbatim): "`GET /v1/models` del
  provider → select real" — `/model` offers the provider's real catalog.
- **S6** (the tools, verbatim): "¿porque carajos no usas engram?" and "¿y
  porque carajos no usas codegraph para ver el código o nimlangserver?" — the
  session's method correction: memory first, and the code tools before grep.

## Verified basis (2026-10-22) — the study

Read with codegraph (the index **does** carry `src/neopi/tui.nim`; the "stale
index" note in the previous session's summary is out of date) and with
nimlangserver (`nimFindSymbols` resolved `luaUiSelect` and `QuestionWidget`;
`nimCheckProject` baseline: **0 errors**, one pre-existing
`UnusedImport: 'times'` at `src/neopi.nim:13`).

**The dialog gap is thinner than the map reads.** nimterm's `QuestionWidget`
(`nimterm/widgets/question.nim:24`) already carries `allowFreeText`,
`freeTextLabel`, and a constructor `secret = bool` that flips the free-text
`InputWidget` into `masked`. neopi uses it with `allowFreeText = false` in
`luaUiSelect` (`src/neopi/tui.nim:1300`) and `luaUiConfirm` (`:1329`); no
`ui.input` exists. A pure text prompt is `newQuestion(title, options = @[],
allowFreeText = true, secret = s)`: with no options `selected = 0` lands on the
free text, Enter answers, Esc cancels (`question.nim:37-49,61-77`). So
`ui.input` is a **thin wrapper, not a new nimterm capability**.

**The synchronous wall does not block this slice.** The callback shape landed in
`d518d0c`: `ui.select`/`ui.confirm` return at once and the answer arrives at
the callback, because a Lua handler cannot wait (`hooks.nim:79`, `lua_pcall`).
`ui.input` rides the same shape. ROADMAP #16 (the threads/async gap) is needed
only for pi's `await ctx.ui.input(...)` — a handler that *blocks* waiting —
which no command here needs.

**The model is already per-turn; the provider is not.** `sendTurn` passes
`neopi._tuiModel` on every `evalJson` (`tui.nim:1144-1146`) and
`agent.runTurn` reads it per turn (`runtime/agent.lua:325-341`), so rebinding
that string is all `/model` needs. The provider, by contrast, is closed over in
`ProviderContext` (`src/neopi/expose.nim:470-476`), built once in `runTui`
(`src/neopi.nim:139-152`) from `getEnv(<PROVIDER>_API_KEY)` plus `.env`
(`loadDotEnv`, read-only — nothing writes a key today). The only runtime
mutation is `setScripted` (`expose.nim:339-373`), which replaces
`context.provider`; `Provider` carries `name`/`apiKey`/`baseUrl` and a private
`transport` (`provider.nim:36-45`).

**There is no model catalog.** The id comes from `--model` or
`<PROVIDER>_MODEL` with a hardcoded `DefaultModel` (`src/neopi.nim:21,199`).

**Where the commands live.** The core's builtins are dispatched in `runCommand`
(`tui.nim:1042-1068`: `/resume`, `/new`, `/compact`, `/quit`) and everything
else goes to the runtime's registry (`runtime/init.lua:61-97`); the completion
lists `coreCommands()` (`tui.nim:745`) plus `neopi.registeredCommands()`.

**Cosmetic limits of `QuestionWidget` as a pure prompt** (accepted for this
slice, no fork patch): the `InputWidget` has no `placeholder`
(`nimterm/widgets/input.nim:40` carries only `masked`), the hint row hardcodes
"↑↓ select  Enter submit  Esc cancel" (`question.nim:170`) and the free-text
row paints the "○ Other" marker (`question.nim:159-166`). `setText` exists
(`input.nim:98`), so a prefill is available.

## Design

- **`neopi.ui.input(title, [opts,] onAnswer)`** (S3): the only Lua addition.
  `onAnswer(text)` receives the typed text, or `nil` on cancel — the same
  contract `ui.select` has. `opts` may carry `secret = true` (masked, for a
  key) and `value = "<prefill>"`. Without a TUI the callback fires at once with
  `nil`, exactly as `answerWithoutUi` does today. The call is refused when a
  question is already open (the existing rule).
- **The provider's mutation stays in the core** (S3): `/login` and `/logout`
  rebuild the live `Provider` in Nim; no `neopi.provider.configure` reaches
  Lua. The holder the builtins mutate is the same `ProviderContext` the
  exposure already owns.
- **`/model` uses the real catalog** (S5): a `GET <baseUrl>/models` over the
  existing wire, parsed into ids, offered through a **third `MenuKind`
  (`mkModel`) over nimterm's `Menu`** — and not through a `QuestionWidget`, as
  this bullet first said. The implementation proved the bullet wrong: the
  catalog can be long, the `Menu` keeps the selection in view (`scrollOffset`
  plus `keepSelectionVisible(rows)` in its paint) and the `QuestionWidget`
  moves its selection with no scrolling at all, so a long catalog would have
  moved the cursor out of sight. The answer rebinds `neopi._tuiModel` **and**
  `state.model`. Page/limit handling is bounded to what the endpoint returns
  (OpenRouter and OpenAI both answer one page).
- **Persistence is deferred** (S4): the key lives in the session's provider
  only; `~/.neopi/` (a global config) and its `auth.json`/`.lua` shape are
  ROADMAP #23's, together with the auth shape per provider.
- **Starting keyless** (the explicit consequence of S1): `runTui`'s fatal on a
  missing `<PROVIDER>_API_KEY` becomes "start without a provider and say so",
  because `/login` existing is what makes that reachable. A turn attempted
  before `/login` reports it as feedback instead of a provider crash.

## Tasks

| ID | What | Specs | Route | Commit |
|---|---|---|---|---|
| T1 | This record: the study, the map and the specs | S1-S6 | inline | `docs(tui): the session commands and the input study` — `d363c3a`, plus `docs(tui): the record names its own commit` — `48c1af2` |
| T2 | `neopi.ui.input` (the plain and the `secret` variant) + its tests | S3 | inline | `feat(ui): ui.input asks for a line and answers through a callback` — `d36b02f`, plus the README's `neopi.ui` row in `docs(ui): ui.input joins the extension surface table` — `f1defd3` |
| T3 | The core's provider holder: the runtime rebuild path `/login`/`/logout` use | S3, S4 | delegated (inline here) | `feat(tui): the provider can be rebuilt at runtime` — `373c2e2` |
| T4a | The catalog over the wire: `GET <baseUrl>/models` and `listModels(p)` | S5 | delegated | `feat(provider): the model catalog comes from the endpoint` — `d31554d` |
| T4b | `/model`: the picker over a third `MenuKind`, and the per-turn rebind | S5 | inline | `feat(tui): /model picks from the provider's real catalog` — `1c93912` |
| T5 | `/login` and `/logout`, and the keyless start | S3, S4 | delegated, then inline | `feat(tui): /login and /logout manage the key, and the TUI starts without one` — `7f61b75` |
| T6 | The Evidence section below, the README's command list and the ROADMAP's row | S1-S6 | inline | `docs(tui): the session commands join the record` — the commit that carries this section |

## Evidence

Each task's gate, verbatim, then the batch gate and the two rules the parent
applied to every delegated unit.

- **T1** — the record itself; no gate.
- **T2** — focused `tests/tp_tui.nim` **56/56 OK**; RED observed first as
  `attempt to call field 'input' (a nil value)`.
- **T3** — focused `tests/tp_expose.nim` **21/21 OK**; RED was a compile error,
  `undeclared identifier: 'currentProvider'`.
- **T4a** — focused `tests/tp_openai_compat.nim` **28/28 OK**, re-run by the
  parent on a file that does not import the module the concurrent writer had in
  flight; RED was `attempting to call undeclared routine: 'listModels'`.
- **T5** — focused `tests/tp_tui.nim` **62/62 OK**, `EXIT=0`.
- **T4b** — focused `tests/tp_tui.nim` **65/65 OK**, `EXIT=0`.
- **T6** — no code: this section, the README's command list and the ROADMAP's
  row.
- **The batch gate** — the parent, on the whole tree, `set -o pipefail`:
  `nimble test` → `[Summary] 176 tests run (3.37s): 176 OK, 0 FAILED, 0
  SKIPPED` and `22 successes / 0 failures / 0 errors / 0 pending`, `EXIT=0`.
  176 = the 156 the tree carried before the slice plus the 20 added here
  (2 + 4 + 5 + 6 + 3). After F1's fix the same gate reads `[Summary] 178 tests
  run (3.56s): 178 OK, 0 FAILED, 0 SKIPPED` with `22 successes` and `EXIT=0`:
  178 = 176 plus F1's two focus tests.
- **The two rules** the parent applied to each delegated unit: read the
  delivered diff before committing it, and re-run a focused test file that does
  not depend on the file a concurrent writer has in flight.

### What this slice learned the hard way

- **The borrowed label — a real bug, fixed in `1c93912`.** `setModel` read the
  picker's label *after* `closeMenu` had released the picker, so the status line
  stored `model: 0\x00ta` — a NUL byte; `cat -v` showed `0^@ta` — where
  `model: beta` belonged, the same length, while `state.model` and
  `neopi._tuiModel`, both taken with the menu still alive, read correctly. That
  is what made the corruption look impossible until the order of the reads was
  written down. The name is now materialized before the picker is released, and
  `setModel`'s doc comment carries the lesson: a string taken from a widget is
  good only for as long as that widget lives.
- **`closeResume` became `closeMenu`,** its guard widened from `!= mkResume` to
  `notin {mkResume, mkModel}`. The narrow guard is exactly the shape of the
  earlier F1 bug — a stale `menuKind` silences the completion for the rest of
  the session — so copying it for the model picker would have planted the same
  bug a second time.
- **The completion list grew** by `/model`, `/login` and `/logout`, and the
  core's list now ends with `quit`. That moves the indices three pre-existing
  completion tests pin (`commandItems`, the no-registry case, and the composer's
  menu): those projections were updated together with the count assertions, no
  assertion was dropped, and the code's order and the tests' were aligned to the
  same list.
- **The `| tail` trap.** The earlier gates of this slice were run as
  `nimble test 2>&1 | tail -N` and reported "exit 0" — which was `tail`'s exit
  code, not the gate's. The content evidence was real (it was read from the
  log), but the exit-code claim was not. Every gate after that ran under
  `set -o pipefail`, which is what makes the batch gate's `EXIT=0` a fact.
- **Two incidents, for the record.** The writer handed T5 stalled after leaving
  its RED tests in place; the parent finished the three pieces those tests
  pinned (the `coreCommands` entries, the `runCommand` branches and the
  `sendTurn` guard). The writer that was to close this record timed out twice
  before producing anything, so the record and the two user-facing docs were
  finished inline instead of retried a third time. Neither incident invalidated
  the plan: the contracts were already in the tests and the code, and the
  record's own `## Log` carries what the user said about it.

### F1 — the bug the slice left behind: a closed dialog left the TUI deaf

Found by the user right after the slice landed: "primera issue, luego de hacer
login, la tui creo que deja de registrar al teclado o por lo menos el input ya
no se renderiza".

**What it was.** `QuestionWidget` is a MODAL widget — `modal = not resolved` —
and the `Menu` (the resume and model pickers) is not, which is why `/resume`
never showed this and `/login` did, in its first real use. nimterm's `dispatch`
scopes a modal widget's routing and, on every event, drops an `app.focus` that
falls outside that scope:

    let scope = if modal.isNil or modal.allowsBackgroundEvent(event): app.root else: modal
    if not app.focus.isNil and not scope.contains(app.focus): app.focus = nil

`wireApp` claims every KEY while a question is open, so the composer's focus
survives the typing — but a NON-key event (a terminal focus report, a resize,
the wheel: anything `wireApp` answers `eventIgnored` to) reaches that dispatch
while the modal is in scope, and the composer's focus is dropped. When the
question then closed, nothing restored it. With no focus, the next key routes
to `@[scope]` — the root alone — whose `handle` ignores everything: the TUI is
deaf and the composer paints no cursor. Both of the user's symptoms are that
one line.

**Why the tests missed it.** They asserted the answer — the callback, the
provider, the status line — and never that the composer still took the keys
afterwards; and they queued only key events, so the dispatch that drops the
focus never ran. Reproduced by queueing one `uiResize` while the question is
open: both new tests then failed with an empty composer (65/67, `EXIT=1`).

**The fix.** The answer hands the composer its focus back, and only when no
other question took its place (a chained dialog keeps the keys to itself). It
sits in the one branch every dialog resolves through, so `ui.select`,
`ui.confirm` and `ui.input` are covered by the same line: they carried the same
defect and had simply never been used in a real TUI.

**Gate.** Focused `tests/tp_tui.nim` **67/67 OK**, `EXIT=0`, with the two new
tests — the `/login` question and `ui.select` — pinning the composer's keys
after the dialog closes.

### F2 — Ctrl+C did nothing while a dialog was open

Reported right after F1: "ahora veo que salir con ctrl+c no está funcionando,
creo que eso ocurrió cuando implementamos /exit".

**Found with the tools the user named**, in the order he named them: Engram
first — the SIGINT history, where Ctrl+C was the terminal's INTR and killed the
process in the illwill era, which is why the abort had moved to Esc — and
CodeGraph for the branch order. Neither was decisive on its own, so a pty
harness (the recipe this repository already documents) ran Ctrl+C in five real
states: idle, the completion open, the resume picker, the model picker, and a
dialog. Idle and every menu left with code 0; **the dialog did not** — and the
dialog was the one state no builtin command could reach before `/login`.

**What it was.** `QuestionWidget.handle` answers Esc, the arrows, Enter and the
editing keys and ignores everything else — but `wireApp`'s dialog branch
returned `eventHandled` for EVERY key, so a Ctrl+C the widget ignored went
nowhere: no abort, no exit, nothing. That branch sits above both the turn's
abort and the exit check, so it swallowed the one key that leaves.

**The fix.** The dialog does not own Ctrl+C: the branch is skipped for it, so
it falls through to the abort while a turn runs and to the exit otherwise. Esc
stays the dialog's — cancelling the question is the innermost interaction — and
the turn's abort keeps its precedence.

**Gate.** Focused `tests/tp_tui.nim` **69/69 OK**, `EXIT=0`, with two tests:
one pins that Ctrl+C stops the app with a `/login` question open (RED observed
first: `st.app.running was true`), the other pins that Ctrl+C during a turn
still only asks for the abort. The rebuilt binary then ran the same five-state
pty harness, and every state leaves with code 0.

**Measured while verifying it.** With `/model` the exit arrives about a second
after Ctrl+C, because `openModel`'s catalog fetch is a BLOCKING GET over the
provider's transport: while it runs, the loop processes no event at all — not
Ctrl+C, not a key. That is the blocking-fetch limit the Design already carried,
now measured. The shape of its fix is the one the turn drive already uses (the
app is pumped while the wait runs), and it goes with the next slice.

## Log

- **L1** (verbatim, the original request): "arranquemos con #21: el estudio del
  hook input"
- **L2** (verbatim): "¿porque carajos no usas engram?" — method correction: the
  session starts at `mem_context` → the record → reconcile, before touching
  files.
- **L3** (verbatim): "¿y porque carajos no usas codegraph para ver el código o
  nimlangserver?" — the same correction for the code tools; codegraph and
  nimlangserver are the first reach, grep the fallback.
- **L4** (the three product decisions, verbatim): S3, S4 and S5 above.
- **L5** (verbatim, the S6 remainder): "para 23, pero seguramente sea un
  auth.json/.lua en la config global" — the user's own reading of where the key
  will land, recorded so #23 has it.
- **L6** (verbatim): "sigamos, hubo un corte de luz que apagó la compu :(" — the
  session was interrupted by a power outage after T4b's implementation and
  before its gate. The work resumed from the committed state plus the memory
  mirror, and no uncommitted work was lost.
- **L7** (verbatim): "primera issue, luego de hacer login, la tui creo que deja
  de registrar al teclado o por lo menos el input ya no se renderiza" — the
  first bug reported after the slice landed; it is F1 above, a `/login` symptom
  of a defect every dialog shared.
- **L8** (verbatim): "ok, todo fino, ahora veo que salir con ctrl+c no está
  funcionando, creo que eso ocurrió cuando implementamos /exit, habría que
  revisarlo con engram y codegraph. También se siente algo tedioso scrollear
  entre cientos de modelos, podríamos implementar busqueda en /models y
  /resume como lo hace pi" — the Ctrl+C report is F2 above; the scrolling and
  the search request open the next slice.
