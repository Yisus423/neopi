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
  existing wire, parsed into ids, offered through the `QuestionWidget`'s option
  list; the answer rebinds `neopi._tuiModel`. Page/limit handling is bounded to
  what the endpoint returns (OpenRouter and OpenAI both answer one page).
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
| T1 | This record: the study, the map and the specs | S1-S6 | inline | `docs(tui): the session commands and the input study` — `d363c3a` |
| T2 | `neopi.ui.input` (the plain and the `secret` variant) + its tests | S3 | inline | `feat(ui): ui.input asks for a line and answers through a callback` |
| T3 | The core's provider holder: the runtime rebuild path `/login`/`/logout` use | S3, S4 | inline | `feat(tui): the provider can be rebuilt at runtime` |
| T4 | `/model`: `GET /v1/models` over the wire + the select | S5 | inline | `feat(tui): /model offers the provider's real catalog` |
| T5 | `/login` and `/logout`, and the keyless start | S3, S4 | inline | `feat(tui): /login and /logout manage the key` |
| T6 | Docs (README's API table and command list, ROADMAP) and the close | S1-S6 | inline | `docs(tui): the session commands join the record` |

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
