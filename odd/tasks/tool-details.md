# tool-details — ROADMAP #19b: a tool that keeps state

The audit's biggest gap, and the only one that is a CORE change. pi's tools
return `{content, details}` and the session PERSISTS `details` beside the call,
which is how its own tools (`todo.ts`, `tic-tac-toe.ts`) survive a turn and a
fork: the tool writes what it needs to remember, and `session_start` reads it
back off the branch. neopi's tool returns the output TEXT and the session entry
keeps that alone, so an extension tool cannot remember anything between turns.

## Specs

- **S1** (the item, verbatim from the ROADMAP): "The audit's biggest gap, and
  the only one that is a CORE change: pi's `execute` returns `{content,
  details}` and the session PERSISTS `details` beside the call — which is how
  its own tools (`todo.ts`, `tic-tac-toe.ts`) keep state across a turn and a
  fork. neopi's tool returns the TEXT and the session entry keeps the output
  alone, so an extension tool cannot hold state. `extra` and the tool-rows work
  (#33) already learned the shape of this key: one optional field, stored
  verbatim, parsed once on the way in."
- **S2** (the user's call, verbatim): "mete 19b, podemos dejar la release 0.0.1
  para despues".
- **S3** (pi's own pattern, from its examples' README, verbatim): "Store state
  in tool result details for proper forking support … Reconstruct on session
  events: `pi.on("session_start", async (_event, ctx) => { for (const entry of
  ctx.sessionManager.getBranch()) { … const details = entry.message.details …"
  — one write, one read, and the fork follows because the details ride the
  ENTRY, not the tool's memory.

## Verified basis

- **The entry today** (`src/neopi/session.nim`): `ekToolResult` carries
  `toolCallId`, `toolName`, `output`, `isError` and — since #33 —
  `toolArgs*: JsonNode` (`:65-68`). `toolArgs` is the pattern to copy EXACTLY:
  written as the model's object, defaulted to `newJObject()` when absent
  (`:161-162`), read as `optObject(node, "toolArgs")` (`:195`), and a stored
  entry with a nil one is patched to `{}` on the way out (`:274-275`) so a file
  written before the key reads as an empty object instead of crashing.
- **The dispatch** (`runtime/agent.lua:232 executeCall`): the tool's execute is
  called through `pcall(tool.execute, effective)` (`:270`) and the result is
  the output; right after, `neopi.emit("tool_result", …)` (`:275`) lets a hook
  PATCH the payload — the "mappedTools" pattern. Both the entry and the hook
  payload are built there, so both are where a second value has to land.
- **The read side ALREADY EXISTS** (`src/neopi/expose.nim:686`):
  `neopi.session:history()` returns the active branch's entries as Lua tables —
  pi's `getBranch()` equivalent. #19's gap list called this "session metadata
  absent"; the truth is narrower: the HISTORY is there, the NAMING
  (`setSessionName`, `setLabel`) is not. This slice needs no new reader.
- **The Lua registry** (`runtime/init.lua`): `neopi.registerTool(name,
  description, schema, execute)` with `execute(args) -> string`. Lua returns
  several values, so a second one is backwards compatible by construction.
- **THE RUNNER EMBEDS THE NIM** (`tests/busted_main.nim` compiles the core in),
  so a direct `./build/busted_main` right after a Nim change runs the OLD code —
  `nimble test` rebuilds it, a direct run does not. This cost the slice one
  FALSE failure: `session:history()` looked like it was dropping `details`,
  while the truth was that the runner predated the field. Recorded because the
  next person will hit it, and because a false RED is worse than no RED.

## Design

- **The entry gains `details`**: an optional JSON OBJECT stored verbatim, with
  `toolArgs`' whole discipline — `{}` when absent on the way in, nil patched to
  `{}` on the way out, and the key never invented from the output text.
- **The tool returns `(output, details)`**: Lua's multiple returns, so every
  tool written before this keeps working untouched (a single-valued return is
  still a single-valued return). An OPTIONS-TABLE result (`{content = …,
  details = …}`, pi's exact shape) would break every existing tool and the
  registry's documented contract, for a translation the port can do in one
  line.
- **The runtime passes the second value through TWICE**: into the appended
  entry AND into the `tool_result` payload, because a hook that rewrites an
  output would otherwise silently drop the state that came with it.
- **The read is `session:history()`**, and the slice ships the RECONSTRUCTION
  IDIOM as an example (a tool that remembers a list, and `session_start`
  reading it back), because the pattern is the deliverable and not the reader.
- **Out of scope**: RENDERING the details (a tool row showing a summary built
  from them) — that is the TUI's, and it belongs with the tool-rows work; and a
  per-tool details SCHEMA, which pi does not have either.

## Tasks

| ID | What | Specs | Route | Commit |
|---|---|---|---|---|
| D1 | `session.nim`: `details` on the tool-result entry, written, read, and nil-patched like `toolArgs`, with its round-trip and old-file tests | S1, S3 | inline, RED→GREEN | `feat(session): a tool result carries the tool's own details` — `2a33574` |
| D2 | `runtime/agent.lua`: `executeCall` captures the tool's second return and puts it in the entry AND the `tool_result` payload | S1 | inline, RED→GREEN | ↑ `2a33574` |
| D3 | `expose.nim`: `session:append("toolResult", …)` accepts the details table, normalizing a non-object (the empty-table-as-array rule) to `{}` | S1 | inline (covered end-to-end by D4) | ↑ `2a33574` |
| D4 | The Lua spec: the round trip through the session, an absent state reading as an empty object, and the EXAMPLE loaded and driven through its own reconstruction | S1, S3 | inline, RED→GREEN | ↑ `2a33574` + the commit that carries this section |
| D5 | The example (`examples/extensions/state.lua`), this record and the roadmap | S1-S3 | inline | the commit that carries this section |

## Evidence

The gate ran with `PATH="$HOME/.local/share/grabnim/current/bin:$PATH"` and
`TMPDIR="$HOME/tmp-nim"`.

- **D1** — RED was the compile error the new test earns (`details` did not
  exist); GREEN: `tests/tp_session.nim` **13/13**.
- **D1-D4** — the full gate: `./build/busted_main tests/spec` **37 successes /
  0 failures** and the Nim suite **285/285** (284 + the entry's round-trip
  test), both exit 0. **The runner had to be REBUILT first**, and that is the
  slice's own lesson: it embeds the Nim, so a direct run after a Nim change
  executes the OLD core — which is exactly how this slice got its false RED
  (`session:history()` looked like it was dropping `details`; it was the stale
  binary).
- **D5** — the example is EXECUTED, not just written: `busted` loads
  `examples/extensions/state.lua`, drives the tool twice, appends what the loop
  would append, and reads the result back through the port's own
  `/remembered` command → **38 successes / 0 failures**.
- What the spec proves, in one line: the tool writes, the ENTRY carries the
  state, the state survives a re-read, and the read needs no new surface —
  `neopi.session:history()` is the branch.

## Log

- **L1** (the call, verbatim): "mete 19b, podemos dejar la release 0.0.1 para
  despues".
- **L2** (where it came from, verbatim from the audit): see S1 — the gap was
  found by porting pi's examples, not by reading its docs.
