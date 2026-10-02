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

## Remaining (priority order)

| # | Item | Notes |
|---|---|---|
| 10 | lazy.npi (the lazy plugin manager, the user's plan) | An extension: `neopi.fs.list` + `require` on-trigger — everything against the surface |
| 11 | The interface study: what else to copy from pi's TUI | The renderers (markdown), the mouse, the themes, the widget borders |
| 12 | Packaging (single-binary distribution) | The runtime ships with the binary |
| 13 | Fork/clone to new files | Branch-in-place covers the MVP; forking copies the tree |
| 14 | grep/find/ls agent tools | If the model needs them |

## Deferred

- **The `neopi --spec` CLI mode** — busted 2.3.0's standalone runner + the CLI
  parser fights (verified: the exit code does not reflect failures in this
  configuration). The specs themselves run today through the test-only runner
  (`tests/busted_main.nim`, 4 spec files, verified green via `nimble test`); the
  CLI-integrated mode waits.
- **A provider layer replacement of our own** — nimgent is a solo-dev risk:
  3 of its author's 5 repos were deleted from GitHub (the author pivoted
  niminal to C++). The local checkout is the fork seed; the anti-corruption
  layer keeps the swap to one module.
- **An async API for Lua extensions** — Lua is synchronous; an async surface
  would need coroutines. The core is async inside already (nimgent's
  streamText); the timer covers the TUI's responsiveness.
- **`neopi.ui.select` (the dialogs API)** — commands ask the TUI for a
  selection (pi's ExtensionUIDialogs); deferred until an extension needs it.
- **The global `~/.neopi/init.lua`** — the project config loads today; the
  global one (the user's personal extensions across projects) waits.
- **A manifest** (package.json-style declared paths) — redundant with the
  entrypoint's `require` for now.
