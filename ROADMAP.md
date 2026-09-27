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

## Remaining (priority order)

| # | Item | Notes |
|---|---|---|
| 4c | Compaction | Threshold + cuts never at tool results + a CompactionEntry with `firstKeptEntryId` (pi's model) |
| 5 | The interactive harness | Steering/follow-up/abort queues + a TUI with in-process Lua UI primitives |
| 6 | `neopi.registerTool` | Extensions register tools the model calls |
| 7 | The manager as an extension + the directory convention + `neopi.load` | Decided: manager = extension, not core |
| 8 | Fork/clone to new files | Branch-in-place covers the MVP; forking copies the tree |
| 9 | grep/find/ls agent tools | If the model needs them |

## Deferred

- **The `neopi --spec` CLI mode** — busted 2.3.0 + the CLI parser fights. The
  specs themselves run today through the test-only runner
  (`tests/busted_main.nim`, 2 specs, verified green); the CLI-integrated
  mode waits.
- **A provider layer replacement of our own** — nimgent is a solo-dev risk:
  3 of its author's 5 repos were deleted from GitHub. The local checkout is
  the fork seed; the anti-corruption layer keeps the swap to one module.
