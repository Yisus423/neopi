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

## Remaining (priority order)

| # | Item | Notes |
|---|---|---|
| 11 | **Pin the sibling dependencies (nimterm, sse)** | `nim.cfg` points at ABSOLUTE local paths (`~/proyectos/nimterm/src`, `~/proyectos/sse/src`), so a fresh clone does not build. Make them reproducible dependencies: a pinned `requires` (the fork we control, or upstream at a fixed commit) plus a lock, or a vendored copy. Same class of decision the provider layer made, the other way round — depend deliberately instead of owning |
| 12 | lazy.npi (the lazy plugin manager, the user's plan) | An extension: `neopi.fs.list` + `require` on-trigger — everything against the surface |
| 13 | The interface study: what else to copy from pi's TUI | The mouse, the themes, the widget borders; the markdown landed with nimterm; the transcript scroll keys pending |
| 14 | Packaging (single-binary distribution) | The runtime ships with the binary |
| 15 | Fork/clone to new files | Branch-in-place covers the MVP; forking copies the tree |
| 16 | The tool execution alive during a run | bash runs frozen inside the turn's chunk (the threads/async gap pi and nimlet solve); the abort during a thinking pause waits for the next delta |
| 17 | grep/find/ls agent tools | If the model needs them |
| 18 | The provider's recorded follow-ups | The known limits the swap's verification left: wrap a mid-stream failure as `ProviderError` (trigger: the first Nim consumer or a retry policy); port the argument JSON-Schema validation (trigger: malformed model args, or the extension tool surface growing); bound the wire's `tool_calls` index (`openai_compat.nim:79` — cheap, no trigger). They ride the TUI slice (#11) because it reopens the provider's event contract for the thinking delta, so it touches the same files |

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
  the provider's waitFor); the key drain covers the TUI's responsiveness.
- **`neopi.ui.select` (the dialogs API)** — commands ask the TUI for a
  selection (pi's ExtensionUIDialogs); deferred until an extension needs it.
- **The global `~/.neopi/init.lua`** — the project config loads today; the
  global one (the user's personal extensions across projects) waits.
- **A manifest** (package.json-style declared paths) — redundant with the
  entrypoint's `require` for now.
