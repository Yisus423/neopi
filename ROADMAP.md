# ROADMAP

Where neopi is and where it goes. Alpha status: slices land on `main` as
work-unit commits; `odd/tasks/*.md` are the evidence records holding the
verified basis of each slice.

## Done

| Slice | What | Why that shape |
|---|---|---|
| 1. Provider primitives | `generate`/`stream`/`toolCall` + types over nimgent (`4abd12e`) | The anti-corruption layer: nimgent stays inside `provider.nim`, the swap is one module |
| 2. LuaJIT + hooks | In-process LuaJIT (own FFI bindings) + `neopi.on` with block/rewrite (`4ab9640`) | The pi/nvim model: the core exposes primitives, Lua composes, pcall containment |
| 2.5. Confined fs/process + the loadlib closure | `neopi.fs`/`neopi.process` + FFI closed, C loader removed (`ecbd716`) | Scripts are trusted code with no native-code escape; side effects go through confined primitives |
| 3. Agent tools | bash/read/edit/write as model tool calls (`93fc832`) | grep/find/ls skipped: absorbable by bash, pi has them off by default |
| 4a. Session tree | Entries + append-only JSONL + active branch + `navigateTo` (`7674da8`) | id + parent: a session is a tree, the active path supplies the model history |
| 4b. The loop in Lua + print mode | `runtime/` + `neopi "prompt"` + the torn-line fix (`03947ea`) | The experiment: it flowed — the nvim lesson (the binary drives, the runtime composes) |
| 4c. Compaction | The threshold + cuts never at tool results + `CompactionEntry` with `firstKeptId` (`a594f62`) | The policy in the loop (Lua), the data contract in Nim; the projection is compaction-aware, latest compaction wins |
| 5. registerTool | `neopi.registerTool` + `neopi.emit` + the notes extension (`825a7e7`) | The Lua surface completes: extensions add tools and emit events, in Lua, without touching the core |
| 5a-1. The streaming exposure | `neopi.provider.stream` + the loop's streaming (`12ebb39`) | The interface's render sink: the deltas stream live; the onEvent is a Lua function |
| 5a-2. The TUI | illwill + the pure render layer + the three components + the keys (`8d12040`) | The interface separate from the engine: sends go through the same `agent.run` chunk; the pure layer tests without a terminal |
| 5b-1. The queues | The abort (the partial response + `frCancelled`) + the steering queue + the loop's drain (`19aa9bd`) | Esc/Ctrl+C abort the stream and the TUI recovers; steering enters after the assistant turn (pi's model); no threading |
| 5b-2. `neopi.ui.*` | `neopi.ui.status`/`widget` + the TUI's render (`7f1bc9a`) | Extensions drive the TUI's status and widget lines; exposed always, no-ops without the TUI |
| Fix. Esc aborts, Ctrl+C exits gracefully | The sink's Esc case + the SIGINT hook (`505eb88`) | Ctrl+C is the terminal's INTR (ISIG on, no raw mode) — the OS kills before any key loop; the hook restores the terminal |
| 6a. Agent commands | `neopi.registerCommand` + the composer's `/` dispatch (`54f839a`) | Extensions add `/commands`; the runtime owns the registry and the dispatch; a command failure is feedback, not fatal |
| 6b. User config | `.neopi/init.lua` loads extensions the nvim way (`5acc809`) | One config file you own; `require` is the loading mechanism (a scan is redundant — YAGNI); the failure warns and continues |
| 7. The TUI async | The asyncdispatch timer + the sink's simplification (`950142f`) | The timers fire during the stream's waitFor (same thread, no races); the thinking pauses don't freeze the TUI |
| 8. TUI polish | Per-line colors + the abort marker + the working indicator (`6a9c53d`) | pi-like rendering; `lineColor` is pure and testable |
| Fix. The timer stays alive | The Callback returns `false` (`7c8bdc6`) | asyncdispatch's Callback semantics are inverted: `false` = stay alive; `true` unregistered after the first fire |
| 9. Session resume | `/resume` + the select overlay + the registry swap (`ed4a006`) | pi's SelectList pattern; the swap rebinds the registry pointer the cfunctions read dynamically |
| 10. The TUI on nimterm | The backend swap: nimterm's widget tree, unicodedb widths, and markdown replace illwill; the async tangle (the timer, the keyPoller) out (`6d4a998`) | The user regretted illwill (the unicode widths, the markdown gap); nimterm's App is the loop owner — the deltas flush direct from the sink, no timer; the local checkout is the fork seed |
| Fix. The nimterm tail | The dead illwill requires + the dead exitHook out; AGENTS.md/ARCHITECTURE.md refreshed (`71d88dd`) | The port left the tail behind: no module imports illwill anymore, and the docs still described the old recipe and the removed timer |
| 11. The wire contract on chronos | `WireRequest`/`WireResponse`/`Transport` + the in-memory fake; chronos in the nimble (`766f95c`) | The injection point had to exist in the design, not be added later (the pi `client` pattern): the L1 tests run keyless over the fake, the production transport rides chronos |
| 11.1. The SSE layer + the real fixtures | iceberg-work/sse adopted + the captured OpenRouter fixtures + the chunk → `StreamEvent` mapping (`6af207e`) | A dependency earns its place or gets absorbed: 588 spec-complete lines instead of writing the state machine; the fixtures replay the real wire (the reasoning field, the fragmented calls) instead of a guess |
| 11.2. The openai-compatible provider | `buildChatRequest`/`chatHeaders`/`streamChat` on chronos — the cancellation contract + the per-read timeout (`17a5444`); the scripted transport encoding one step per fetch as the real wire (`433adc1`) | The same cancellation contract nimgent gave (expose builds the partial response) plus the timeout it never had; the L2 tests exercise the whole stack with zero nimgent |
| 11.3. The swap off nimgent | The types out of `provider.nim` into `primitives.nim`, `Message` with the tool round-trip, the loop and the hook gates ported, the live transport defect fixed (`fe51fed`) | The anti-corruption layer absorbed its own replacement: `expose.nim` byte-identical and the 109 pre-existing tests unmodified still pin the contract. The live path had never run and crashed on a nil body reader |
| Fix. The nimgent tail | The nimble requires and the libpcre path out; the live check opt-in (`NEOPI_LIVE_TEST`); AGENTS/README/ARCHITECTURE refreshed (`950bcf1`) | The build and the claims had to follow the code: `nimble test` is keyless and offline, and the docs still promised libpcre and described the layer as a wrapper over a dependency that no longer exists |
| Fix. The dependency pin | chronos + our nimterm fork + sse resolve through nimble by git URL and commit; `nim.cfg` has no path at all; `binDir` is `build/`; config.nims' dead `../nimgent` loop out (`11688bc`) | A fresh clone could not build (absolute local paths) and the versions were whatever the checkouts happened to be. The same "depend deliberately" call the provider layer made, the other way round: a commit pin is exact, `nimble develop` still overrides it, and the installed copy is provably the pinned commit |
| 20. The TUI UX (pi's interface, on nimterm) | The palette follows the terminal (`87c27cd`); the transcript answers the page keys and the copy while the editor keeps focus (`f4a46a4`); the chrome gains a header, a keyed status bar and placed widgets (`581daca`) with the adjacent slots — `hasUI`, `working`, `notify`, `title` (`d064a1d`); the app owns the dispatch and the frame (`1bb3ff5`); the transcript syncs incrementally so the view state an item carries survives (`0e976bd`); the model's reasoning reaches the transcript (`ab901f4`); the dialogs ask and answer through a callback (`d518d0c`) | The slice that closed the UX gap and settled the extension surface BEFORE anything was written against it. The study (the plan, the specs S1–S11, the map and the evidence live in `odd/tasks/tui-ux.md`) found that pi's component contract is six lines — `render(width): string[]` — and that the component vocabulary belongs in a library and not in the engine, which is why the surface lands in levels and why the component-shaped family is deferred rather than declared impossible. It moved the nimterm pin to `800bf7f` for `appendItem`, and `AGENTS.md` carries the bump procedure that move taught |
| 22. The command autocompletion | `/` opens the completion above the composer with the registered names and their descriptions, narrowed as you type (`c91d389`); the keys are pi's — Tab completes, Enter completes and runs it, Esc closes the menu keeping the draft (`c197113`); the builtin answers for the completed text too (`f4ac13b`) | The roadmap's own claim held: `neopi.registeredCommands` was the source and nimterm's `Menu` was the widget. The trigger was the open question, and the editor already emits a `change` action per edit — so the completion needs no timer and no work inside `paint` (the TUI UX slice's lesson: the app owns the frame). The two menus share the slot above the composer, so the state now says which one it holds (`menuKind`). pi's fuzzy match is not ported: the filter is one pure proc, and a prefix match is what "as you type" needs. The bugs the user hit on landing — the picker's Esc keeping the state, which silenced the completion for the session; Tab handing the composer's keys to the transcript; and the open menu blanking the composer's rule — are fixed in `59754ec` and `27518e6`. The record is `odd/tasks/command-autocomplete.md` |
| 21. The session commands | `/login` asks for the provider's key in a masked line and installs it in the live provider (`7f61b75`); `/logout` drops it; a turn with no provider is feedback instead of a loop failure, and `runTui` no longer dies without `<PROVIDER>_API_KEY`; `/model` lists the endpoint's real catalog (`d31554d`, the new `listModels`) in a scrolling picker and rebinds the per-turn model (`1c93912`). The API study that opened the slice is `d363c3a`, and `neopi.ui.input` (`d36b02f`) is the only piece that reached Lua | The study ruled before the code was written: nimterm's `QuestionWidget` already carried `allowFreeText` and a `secret` flag and neopi simply never passed either, so the `input` hook the UX map named turned out to be a thin wrapper over the callback shape the dialogs landed with — and the synchronous wall (#16) never entered the picture, because nothing here needs to block. The real gap was the provider's runtime state: the model was already read per turn, so `/model` only rebinds a string, while the provider sat closed inside the exposure's holder — which is why the registry key and the Nim-side accessors (`373c2e2`) exist, and why the mutation stays in the CORE, the user's call, with `ui.input` the only addition to the Lua surface. Two lessons the slice paid for and the record keeps: a string taken from a widget dies with that widget (the menu's label read after its picker was released wrote `model: 0\0ta` where `model: beta` belonged, while the copies taken earlier read correctly), and the Menu — not the QuestionWidget — is the picker for a long catalog, because only the Menu scrolls its selection into view. The record is `odd/tasks/session-commands.md` |
| 23. The provider table + the key's home | The provider name becomes data (`ProviderSpec` + `knownProviders`/`findProvider`/`newProvider`), so `--provider=<id>` takes any entry: `openai`/`openrouter` as before, `deepseek`/`groq`/`together`/`cerebras` (the four endpoints a real client reaches with this same wire) and the keyless local `ollama`/`llamacpp`, with `--base-url=<url>` for an endpoint the table does not carry; an empty key sends no `Authorization` header at all; and `/login` keeps installing the key while now SAVING it — `~/.neopi/auth.json` in pi's shape, owner-only, read-modify-write, atomic, a file that is not valid JSON reported instead of rewritten (`94a503b`) — with a start resolving the stored credential first, then the entry's variable, then `.env` (`4a6a055`) | The hardcoded trio was the real gap: the wire already generalized (`openAI(key, baseUrl)` reached any compatible gateway), so a third provider meant editing three call sites that each guessed the pair. pi set the shape — the provider owns its auth, a keyless entry is first class, a stored credential owns its provider, and a broken credential file is never clobbered — and pi's own catalog set the table: xai and mistral stay OUT, because pi reaches them through `openai-responses` and `mistral-conversations`, so their base URLs are no evidence for our wire. The record is `odd/tasks/provider-auth.md` |

## Remaining (priority order)

The numbers are stable identifiers, not a dense sequence or a rank: the ORDER
of the table is the priority (#10, #11, #20, #21, #22 and #23 left this list —
see Done).

| # | Item | Notes |
|---|---|---|
| 19 | Pi's extension examples + the interface UX | Porting pi's `examples/extensions/*` onto `neopi.on`/`fs`/`process`/`provider`/`session`/`registerTool`/`registerCommand`/`ui` is the "real consumers exist" bar AGENTS.md sets for the frozen surface — it proves the API and finds its gaps, in Lua, without touching the core. The surface it would have to work against was settled first (item 20) |
| 12 | lazy.npi (the lazy plugin manager, the user's plan) | An extension: `neopi.fs.list` + `require` on-trigger — everything against the surface |
| 13 | The interface study: what else to copy from pi's TUI | The mouse, the themes, the status bar and the transcript's scroll keys landed with the TUI UX slice (`87c27cd`, `f4a46a4`, `581daca`), and the markdown came with nimterm. What is left: the widget borders, and whatever pi's dialogs do that the callback shape does not |
| 14 | Packaging (single-binary distribution) | The runtime ships with the binary |
| 15 | Fork/clone to new files | Branch-in-place covers the MVP; forking copies the tree |
| 16 | The tool execution alive during a run | bash runs frozen inside the turn's chunk (the threads/async gap pi and nimlet solve); the abort during a thinking pause waits for the next delta. **The approval flow rides here too** (it was the TUI UX slice's T8, deferred by the user's call): an approval is a tool call that must survive a user wait, and the re-drive it needs already exists — `drainSteering` in `runtime/agent.lua` reads `neopi.steeringQueue` after each turn, and that queue is a plain Lua table an extension can push into, so an approval answered mid-turn starts the next turn with the decision and needs no new primitive. The missing piece is the producer: a registration for the tools that need approval, and a core that skips them, posts nimterm's approval item (choices included) and emits the decision as an event |
| 17 | grep/find/ls agent tools | If the model needs them |
| 24 | The transcript search | `setSearch`/`nextSearch`/`clearSearch` already exist in nimterm; what is missing is the binding and the search mode in the composer (the TUI UX slice's T7) |
| 25 | The UX regression gate | Canvas + FakeBackend assertions over the chrome as a standing gate (the TUI UX slice's T10). Its argument is empirical: `bench/tui_bench.nim`'s own self-check caught a regression that 127 tests did not |
| 26 | The global `~/.neopi/` (config and sessions) | The user's finding while deciding #23: neopi reads only the project's `.neopi/`, so a `~/.neopi/init.lua` reaches nothing in other projects — and every session file stays in the directory it was opened in, where `~/.neopi/sessions/` is where they belong. #23 builds the first global thing (`~/.neopi/auth.json`, through the `$NEOPI_CONFIG_DIR` seam) so the directory and the override exist; what is missing is the load order for the config (project over global? both?) and reading/writing sessions globally |
| 27 | The CLI's space-separated option values | `--provider x` fails with "expected one prompt argument": this CLI's `parseopt` only binds a value attached with `=` or `:`, and what follows a space arrives as a positional argument. PRE-EXISTING (verified against the previous build while closing #23), not a regression of it — the attached form is what the README and `--help` document. The fix is small but it changes the parser every option shares, so it wants its own tests (a `parseArgs` extracted from `main`, testable without a terminal) instead of riding along with a slice that is about providers |
| 18 | The provider's recorded follow-ups | The known limits the swap's verification left: wrap a mid-stream failure as `ProviderError` (trigger: the first Nim consumer or a retry policy); port the argument JSON-Schema validation (trigger: malformed model args, or the extension tool surface growing); bound the wire's `tool_calls` index (`openai_compat.nim:79` — cheap, no trigger). The thinking delta landed with the TUI UX slice (`ab901f4`), so what is left is the two limits that still have no trigger |

## Reconsidered

- **The TUI replacement, cancelled 2026-10-11** (it was #11 here; the plan is
  kept in `odd/tasks/tui-own.md`). The stated reason was performance: "the
  per-delta full render is the performance defect". MEASURED
  (`bench/tui_bench.nim`, the numbers in that task file): the full render is
  FLAT at ~7.2 ms from 50 to 5000 entries — nimterm's per-item line caches
  and its row-differential present were already right — and the one real
  defect was OURS: the stream sink called the transcript model's `apply` and
  then `invalidateLines()`, re-wrapping the whole transcript per streamed
  token (6588 ms at 5000 entries). One line fixed that (13.4 ms) and a second
  one of our own (the footer walked the session history per frame) made the
  frame flat (46.7 → 7.2 ms). With the performance case gone the replacement
  stood on ownership alone, and the risk it targeted — the dependency
  vanishing — is already mitigated: the code is on our GitHub, checked out
  locally, MIT, and a fork patch is the tool for a needed change, not a
  rewrite. The HARNESS STAYS as the regression gate (it caught a 120x that
  113 tests did not). **Revisit if** we need a change inside nimterm that a
  fork patch cannot carry cleanly, or if the fork drifts from what we need.

## Deferred

- **The `neopi --spec` CLI mode** — busted 2.3.0's standalone runner + the CLI
  parser fights (verified: the exit code does not reflect failures in this
  configuration). The specs themselves run today through the test-only runner
  (`tests/busted_main.nim`, 5 spec files, verified green via `nimble test`); the
  CLI-integrated mode waits.
- **An async API for Lua extensions** — Lua is synchronous; an async surface
  would need coroutines. The core is async inside already (chronos behind
  the provider's waitFor); the key drain covers the TUI's responsiveness. The
  dialogs answered it for the one case that needed it: an answer that arrives
  later travels as a callback (`d518d0c`), never as a blocking wait.
- **The global `~/.neopi/init.lua`** — the project config loads today; the
  global one (the user's personal extensions across projects) waits.
- **A manifest** (package.json-style declared paths) — redundant with the
  entrypoint's `require` for now.
