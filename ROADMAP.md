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

## Remaining (priority order)

| # | Item | Notes |
|---|---|---|
| 5a-2 | The TUI | illwill (0.4.1 installed) + the component model (requestRender, pi's pattern) + transcript/composer/footer — the interface separate from the engine; the streaming sink (5a-1) is its channel |
| 5b | The interactive queues + `neopi.ui.*` | steering/follow-up/abort + the Lua UI primitives for extensions (setStatus/setWidget/footer) |
| 6 | The manager as an extension + the directory convention + `neopi.load` | Decided: manager = extension, not core; YAGNI until extensions exist |
| 7 | Fork/clone to new files | Branch-in-place covers the MVP; forking copies the tree |
| 8 | grep/find/ls agent tools | If the model needs them |

## Deferred

- **The `neopi --spec` CLI mode** — busted 2.3.0's standalone runner + the CLI
  parser fights (verified: the exit code does not reflect failures in this
  configuration). The specs themselves run today through the test-only runner
  (`tests/busted_main.nim`, 4 specs, verified green via `nimble test`); the
  CLI-integrated mode waits.
- **A provider layer replacement of our own** — nimgent is a solo-dev risk:
  3 of its author's 5 repos were deleted from GitHub (the author pivoted
  niminal to C++). The local checkout is the fork seed; the anti-corruption
  layer keeps the swap to one module.
