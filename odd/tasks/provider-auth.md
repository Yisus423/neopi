# provider-auth — ROADMAP #23: the provider table, keyless auth, and the global auth.json

The slice that turns "two hardcoded provider names" into a table, makes a
keyless local endpoint a first-class provider, and gives `/login` a home that
outlives the session: `~/.neopi/auth.json`, pi's shape. Two independent units
(the table with keyless auth, and the store) plus the wiring that joins them.

## Specs

- **S1** (the request, verbatim — the ROADMAP #23 row): "The provider layer is
  ours now (the chronos stack), so a provider is a wire mapping plus a base URL
  and `openai_compat.nim` generalizes. The open question is the auth shape per
  provider — and what `login`/`logout` mean for each. #21 settled what it could:
  `/login` owns the key at runtime and the key lives in the SESSION only, so
  where it persists is open — the user's own reading is an `auth.json`/`.lua` in
  a global config — and that, plus the per-provider shape, is this item's
  decision"
- **S2** (the instruction, verbatim): "para empezar #23"
- **S3** (the scope, the user's choice, verbatim): "Solo OpenAI-compatible:
  tabla + base URL + keyless" — the table replaces the hardcoded names, a base
  URL can be overridden, and a keyless endpoint is a provider like any other.
  NOT another wire (Anthropic messages) and NOT OAuth: those wait.
- **S4** (where the key lives, the user's choice, verbatim): "Global
  ~/.neopi/auth.json (forma de pi)" — one file for every project, pi's
  credential shape, owner-only modes.
- **S5** (the table's owner + the flag the user raised in the same breath,
  verbatim): "diría que built-in más extensión, las extensiones de pi pueden
  agregar proveedores. De una vez te lo digo por aquí pero creo que queda para
  después: neopi actualmente solo lee el .neopi/ de el current directory, una
  configuración global en ~/.neopi/init.lua no afecta a las demás, esto también
  ocurre con el almacenamiento de sesiones (todas deberían estar en
  ~/.neopi/sessions/ pero se quedan en el directorio donde se abrieron)" — so:
  the table ships builtin, extensions adding providers is DEFERRED, and the
  global-`.neopi/` hole (config AND sessions) is registered as its own item, not
  merged into this slice.

## Verified basis (2026-10-26) — the code as it is, and how pi does it

neopi, from CodeGraph (the call paths, not a grep):

- `Provider` (`src/neopi/provider.nim:36`) is `name* + apiKey* + baseUrl* +
  transport` (private): identity, endpoint and credential in one object.
  Constructors: `openAI(apiKey, baseUrl = "", transport = nil)`,
  `openRouter(apiKey, transport = nil)`, `scriptedProvider(steps)`.
  `openAI`'s `baseUrl` is already the general escape hatch: "any compatible
  gateway (OpenRouter, DeepInfra, a local server) works" — the WIRE is not what
  is missing.
- The wire is `openai_compat.nim`: `POST <baseUrl>/chat/completions` and
  `GET <baseUrl>/models`, with `chatHeaders` (`:150`) hardcoding
  `Authorization: Bearer <key>` and `modelsHeaders` (`:156`) the bearer only.
- The provider NAME is hardcoded in three places: `runTui` validates
  `openai|openrouter` (`src/neopi.nim:145`), `runTui` builds the backing
  (`:153`), and `answerLogin` rebuilds it (`src/neopi/tui.nim:700`:
  `if name == "openai": openAI(answer) else: openRouter(answer)`).
  `providerEnvVar` (`src/neopi/tui.nim:473`) derives `<NAME>_API_KEY`, and
  `exposeProvider`/`currentProvider`/`setProvider` (`src/neopi/expose.nim:477`,
  `:509`, `:519`) are the live holder every `neopi.provider` closure reads
  (blast radius: 8 + 4 callers in `tui.nim`).
- The key today: `.env` via `loadDotEnv` (READ-only, never writes) + the
  environment. `/login` installs it into the live holder for the session;
  `/logout` empties it. **Nothing persists anywhere.**

pi, from the `packages/ai/README.md` the user pointed at plus the coding-agent
through the CodeGraph CLI (a different repo — the tool only resolves the current
workspace):

- **Auth is a capability of the provider, not a string**: `auth: { apiKey?,
  oauth? }`; `envApiKeyAuth(name, [ENV...])` is "stored credential wins, else
  the first env var that is set"; and a KEYLESS provider is first class —
  ollama/llama.cpp declare `resolve: async () => ({ auth: {} })`.
- **Login is a dialogue protocol**, not a hardcoded prompt:
  `login(interaction)` with `prompt({type: 'text'|'secret'|'select'|
  'manual_code'})` and `notify({type: 'info'|'auth_url'|'device_code'|
  'progress'})`, plus `refresh(credential, signal)` and `toAuth(credential)`.
  neopi's `QuestionWidget` (with `secret`) already covers the `prompt` half; the
  `notify` half is what OAuth would need — deferred with S3.
- **Persistence is a `CredentialStore`** (`read`/`list`/`modify` — the ONLY
  write path, a serialized read-modify-write — /`delete`). The coding-agent
  implements it in `~/.pi/agent/auth.json`: **global**, `Record<providerId,
  Credential>`, directory `0700`, file `0600`, a lockfile around the
  read-modify-write, and a revision-checked shared read state
  (`packages/coding-agent/src/core/auth-storage.ts:61`). A credential is
  `{type: "api_key", key, env?}` or `{type: "oauth", ...}`; the optional `env`
  carries provider-scoped configuration (Cloudflare's account/gateway ids).
- **The precedence rule is hard**: a stored credential OWNS its provider — the
  environment is consulted only when nothing is stored — and a failed refresh
  never silently falls back to an env key.
- pi's `/login` in the TUI is a provider selector + an auth-type selector
  (`handleLoginCommand` → `showLoginProviderSelector` /
  `showLoginAuthTypeSelector` → `loginProvider`,
  `packages/coding-agent/src/modes/interactive/interactive-mode.ts:5847`).

## Design

- **The table is data, and it lives where the policy already lives**
  (`provider.nim`): `ProviderSpec(id, name, baseUrl, envVar, requiresKey)` plus
  `knownProviders()` and `findProvider(id)`. `openAI`/`openRouter` keep their
  signatures — they are exported, `transport`-injectable and used by six test
  files — and a new `newProvider(spec, apiKey, baseUrl = "", transport = nil)`
  is what the table-driven paths call.
- **Keyless is expressed in the headers, not in a special case**: an empty key
  means no `Authorization` header at all (`chatHeaders`/`modelsHeaders`), so a
  local server never receives `Bearer ` with nothing after it. The two existing
  providers always pass a key, so their wire stays byte-identical.
  `requiresKey: false` relaxes the *requirement* (a start with no key yields a
  provider instead of `none`), never the credential: every entry keeps its env
  var, so a llama.cpp started with `--api-key` still receives its key.
- **`--provider <id>` accepts any entry; `--base-url <url>` overrides the
  entry's endpoint.** The override is what makes the built-in list a
  convenience instead of a claim: a gateway whose URL differs (or a provider
  not in the table) is reachable without editing code.
- **`~/.neopi/auth.json` is the key's home, in pi's shape**:
  `{"<providerId>": {"type": "api_key", "key": "..."}}`. Directory `0700`, file
  `0600`, written as read-modify-write so the other providers' entries survive,
  through a temp file plus a rename so the file is never half-written. The
  config directory is `$NEOPI_CONFIG_DIR` when set, else `~/.neopi` — the seam
  the tests use instead of the real home, and the same seam the deferred global
  config will want.
- **Precedence, in pi's order**: the stored credential wins; then the
  environment (which `loadDotEnv` has already populated from `.env`); then, for
  a provider that requires a key, no provider at all (the `/login` feedback path
  #21 built). A keyless entry never consults either.
- **A malformed auth file is never clobbered.** `loadApiKey` treats it as "no
  credential"; `saveApiKey`/`deleteApiKey` refuse and report, because silently
  rewriting it would destroy the keys of every other provider. The `/login`
  feedback names the path, never a key.
- **No cross-process lock this slice** (single-process CLI, atomic rename means
  the file never corrupts): two TUIs logging in at the same instant can lose one
  write. Registered as a known limit with a trigger — the first concurrent
  consumer, or OAuth's refresh.
- **Routes**: T1 and T2 are independent units over disjoint files (the table and
  keyless headers vs. the new store module); T3 is the wiring that depends on
  both.

### Frozen contracts

T2's module surface (the writer implements exactly this):

```nim
## src/neopi/authstore.nim — the global credential store: ~/.neopi/auth.json,
## pi's shape ({"<providerId>": {"type": "api_key", "key": "..."}}).
type AuthStoreError* = object of CatchableError

proc configDir*(): string              # $NEOPI_CONFIG_DIR when set, else ~/.neopi
proc authFilePath*(): string           # configDir() / "auth.json"
proc loadApiKey*(providerId: string): Option[string]
proc saveApiKey*(providerId, apiKey: string)
proc deleteApiKey*(providerId: string)
```

Semantics: read-modify-write so every other provider's entry survives; the
config dir is created `0700` and the file `0600` (pi's modes); the write goes
through a temp file plus a rename (never a half-written file); a malformed file
means `loadApiKey` returns `none` while `saveApiKey`/`deleteApiKey` raise
`AuthStoreError` and leave the file byte-unchanged (never clobber other keys); a
missing file or entry is `none` / a no-op. No cross-process lock this slice.

### The built-in table is evidence-backed, not recalled

Every base URL comes from pi's own provider factory where that factory speaks
OUR wire (`OpenAICompletionsApi`) — read in
`~/proyectos/pi/packages/ai/src/providers/<id>.ts`:

| id | baseUrl | env var | key | pi's factory today |
|---|---|---|---|---|
| `openai` | `https://api.openai.com/v1` | `OPENAI_API_KEY` | required | `openai-responses` (we speak completions; `/v1/chat/completions` is real) |
| `openrouter` | `https://openrouter.ai/api/v1` | `OPENROUTER_API_KEY` | required | mixed — already exercised by neopi |
| `deepseek` | `https://api.deepseek.com` | `DEEPSEEK_API_KEY` | required | `openai-completions` |
| `groq` | `https://api.groq.com/openai/v1` | `GROQ_API_KEY` | required | `openai-completions` |
| `together` | `https://api.together.ai/v1` | `TOGETHER_API_KEY` | required | `openai-completions` |
| `cerebras` | `https://api.cerebras.ai/v1` | `CEREBRAS_API_KEY` | required | `openai-completions` |
| `ollama` | `http://localhost:11434/v1` | `OLLAMA_API_KEY` | keyless | local server |
| `llamacpp` | `http://127.0.0.1:8080/v1` | `LLAMACPP_API_KEY` | keyless | local server |

xai and mistral are deliberately ABSENT: pi reaches them through
`openai-responses` and `mistral-conversations`, so their base URLs are no
evidence for our wire. `--base-url` reaches them today and an entry is one line
once someone exercises it. Live reachability is unexercised for every entry
except `openai`/`openrouter`; the tests pin the table's shape and the header
rule, never a network call.

## Tasks

| ID | What | Spec | Route | Commit |
|---|---|---|---|---|
| T1 | The provider table, `--provider <id>` for any entry, `--base-url`, and keyless (no `Authorization` header when the key is empty) | S3, S5 | inline, RED→GREEN | `4a6a055` |
| T2 | `src/neopi/authstore.nim` + `tests/tp_authstore.nim`: the global store — path and modes, read/save/delete per provider, read-modify-write, temp+rename, refuse to clobber a malformed file | S4 | delegated writer, **UNAVAILABLE** (see Evidence) → inline | `94a503b` |
| T3 | The wiring: startup resolves through the store (stored wins over env/.env), `/login` saves and installs, `/logout` deletes, `/login` on a keyless entry reports that no key is needed; the print mode resolves the same way | S3, S4 | inline, RED→GREEN | `4a6a055` |
| T4 | Docs: README (the table, `--base-url`, keyless, where the key lives, the precedence, the modes), ROADMAP (#23 to Done with the hashes; the global `~/.neopi/` item; the CLI parse defect the smoke check found) | S1, S3, S4, S5 | inline | this commit |
| T5 | The close: `## Evidence` with the gates verbatim, the known limits, and the RDD assessment over the slice's range | S1–S5 | inline | this commit |
| T6 | Independent verification of the credential handling (file modes, no key in any output or session, the precedence matrix, the malformed-file refusal) | S4 | `gentle-ai-verify` — **UNAVAILABLE** (see Evidence) | — |

## Evidence

The gate (the parent, `set -o pipefail`, 2026-10-26):

- `nim c --hints:off --threads:on --mm:orc -o:build/neopi src/neopi.nim` → **exit 0**.
- `nimble test` → `[Summary] 204 tests run (3.41s): 204 OK, 0 FAILED, 0 SKIPPED` +
  `22 successes / 0 failures / 0 errors / 0 pending` → **exit 0**. (204 = the 185
  the tree carried + 19 new: 2 in `tp_openai_compat`, 5 in `tp_provider`, 10 in
  `tp_authstore`, 2 in `tp_tui`.)
- The **RED** was observed before each fix, all three suites exiting 1:
  `tp_openai_compat` compiled but `chatHeaders("")` still carried the bearer
  header; `tp_provider` → `Error: undeclared identifier: 'knownProviders'`;
  `tp_tui` → `Check failed: installed.get.name == "deepseek"` (the hardcoded pair
  rebuilt an OpenRouter provider); `tp_authstore` (T2) → `Error: cannot open
  file: neopi/authstore`; and T3, before the wiring →
  `Check failed: loadApiKey("deepseek") == some("sk-ds-1")` plus
  `Check failed: loadApiKey("openrouter").isNone`.
- The store's own tests caught two real defects while it was being written: a
  SIGSEGV from `std/json`'s `node{key}` yielding **nil** (not `JNull`) for a
  missing key, and `createDir(dir, mode)` not existing in this Nim (the mode is
  applied after creation, before the secret is written).
- The CLI smoke check (a temp cwd, `NEOPI_CONFIG_DIR` set): `--help` exit 0 with
  the new Usage; `--provider=nope "hi"` exit 1 naming the known ids;
  `--provider=deepseek "hi"` exit 1 naming `DEEPSEEK_API_KEY`;
  `--provider=ollama --model=m "hi"` builds a **keyless** provider and reaches
  the wire (the connection fails — no local server — which is the proof it was
  built).
- The **differential against the base commit** (`7cfb7b6` cloned to /tmp and
  built there): identical exit codes and messages for the prompt-only,
  `--provider=openrouter`, `--model=x` and `--help` cases; the two intended
  differences are the unknown-provider hint and the print-mode hint. And
  **`--provider openrouter "hi"` fails the same way in BOTH builds** — the
  space-separated form is pre-existing (README known limit + ROADMAP #27), not a
  regression of this slice.

**Verification (T6) — UNAVAILABLE.** The risk line for this slice is item 2
(credentials), which requires an independent verifier. Both delegated writers
timed out **before their first tool call** (`prompt accepted; no first run event
received for model: nvidia/deepseek-ai/deepseek-v4.1-flash`, 0 turns, 0 tool
calls — the same failure the previous session recorded), so the subagent path is
down in this session and every task ran inline. The credential rules are covered
by the parent's own focused tests (the modes, the read-modify-write, the atomic
write, the refusal, the precedence) and by the smoke check, but **no independent
verification happened**: that is the user's decision (fix the subagent model and
relaunch a verifier, or accept the parent's gate).

**The native review (RDD) — BLOCKED by configuration, nothing consumed.** The
switch is on (`global: on`), so the entry rule applied: `assess` over
`7cfb7b6..HEAD` returned `reviewDue: true` (`reviewDueReason: high_risk`,
`nativeRisk: high`, `risk: medium`, 13 paths / 927 lines) and a plan whose
`independentVerifier` is false because no Task Size high-risk item was
escalated. `inspect` then reported an empty workspace candidate and offered a
start bound to the committed range, so `start` ran with all four lenses and
created **lineage `review-8f5ec190e0afd965`** (tier `high`, correction budget
200). The bound STATUS offered the four materialize slots; the group's forecast
(transport `pi_host_relay`, 4 model runs, the four lenses in provider order) was
relayed and acknowledged, and the launch **failed**: `reviewer-config-invalid`
— "no model is configured for review-risk; assign it a model in the agent model
routing config". A single-slot probe on `review-resilience` said the same for
that role, so the whole `review-*` family is unconfigured. Nothing ran and
nothing burned: `prepared_reviewers: 0`, `submitted_reviewers: 0`,
`mutation_outcome: none`. The lineage stays `reviewing` at revision
`sha256:4bfa86f635443cd27701e686de9827f473369cf90dcec9eda06484c3f84a28e3`
with the four slots reoffered, so assigning the roles their models lets the
capture resume on THIS lineage — there is no restart, and no replay of what was
never run.

**Where #23 stands**: the code, its tests and the docs are landed (four commits,
the gate green); what is missing is the OUTSIDE view (the native review) and the
independent verification. Both are blocked by the environment, not by the
change, and both are the user's call.

## Known limits

- **The space-separated option form** (`--provider x`) does not parse; verified
  pre-existing. Registered as ROADMAP #27 and in the README.
- **No cross-process lock on the store**: the write is atomic (temp file plus
  rename), so the file never corrupts, but two TUIs logging in at the same
  instant can lose one write. Trigger: the first concurrent consumer, or OAuth's
  refresh.
- **Live reachability is unexercised for every entry except `openai` and
  `openrouter`**: the tests pin the table's shape and the header rule, never a
  network call. `--base-url` is the escape hatch, and the four new entries are
  the ones pi reaches with this same wire.
- **The store holds only `api_key` credentials** — no OAuth shape and no
  provider-scoped `env`, because the scope stopped at OpenAI-compatible
  providers with a key.
- **Extensions registering providers stays deferred** (S5): the table is
  builtin, and no Lua surface changed in this slice.

## Log

- **L1** (2026-10-26, the request, verbatim): "haz un mem_context con engram para
  empezar #23, lee cómo lo hace pi
  (/home/jesus/proyectos/pi/packages/ai/README.md) y si necesitas revisar el
  código usa codegraph"
- **L2** (the correction, verbatim): "cuando hablo de #23 me refiero al roaadmap.
  ¿Porque usas sed en vez de codegraph?" — fair, and the third time: exploration
  goes through CodeGraph (the MCP tool for this workspace, the CLI for other
  repos) or nimlangserver, never `sed`/`grep` first. It also fixed my reading:
  #23 is the ROADMAP row ("New providers"), not a GitHub issue.
- **L3** (the decisions, verbatim): scope — "Solo OpenAI-compatible: tabla + base
  URL + keyless"; persistence — "Global ~/.neopi/auth.json (forma de pi)"; the
  table — "diría que built-in más extensión, las extensiones de pi pueden
  agregar proveedores. De una vez te lo digo por aquí pero creo que queda para
  después: neopi actualmente solo lee el .neopi/ de el current directory, una
  configuración global en ~/.neopi/init.lua no afecta a las demás, esto también
  ocurre con el almacenamiento de sesiones (todas deberían estar en
  ~/.neopi/sessions/ pero se quedan en el directorio donde se abrieron)".
