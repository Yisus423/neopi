# Agent loop in Lua + torn-line fix + busted specs (slice 4b)

## Goal

The Lua experiment: the agent loop lives in the runtime layer (Lua, shipped
with the binary, user-modifiable) composing the exposed core primitives;
the print mode is the first real neopi run. The nvim model: the binary
drives, the runtime composes.

## Verified basis (obs #1154, #1155)

- The user's reflection: "estamos volcando mucho en nim" — the nvim lesson:
  built-ins written in the scriptable layer, shipped with the binary
  (runtime/lua/), user-modifiable. The experiment: the loop in Lua.
- pi's harness.md: "A torn final line is discarded whole... and truncated
  before new writes are admitted" — session.nim raises SessionError on a torn
  line today: a real defect class to fix first.
- nvim's testing: busted specs (*_spec.lua) + LuaCATS annotations (the LSP
  autocompletes the API for users). busted 2.3.0 installed (luarocks --local,
  ~/.luarocks/bin/busted).

## Non-goals

- Compaction (slice 4c).
- Steering/follow-up/abort queues (the interactive layer; print mode is
  one prompt → one run).
- The durable operation state machine (pi's harness.md — the mature spec,
  later when durability matters).
- JSON/RPC interfaces (later).

## Design

### Task 1: the torn-line fix (src/neopi/session.nim, Nim)

- The load discards a TORN FINAL line whole (a line that fails JSON parsing
  is discarded silently when it is the LAST line, with a note in the
  session's state — e.g. a `tornTail: bool` field — and truncated before new
  writes are admitted: the first append after a torn tail rewrites the file
  without the torn bytes, per pi's J1-style rule). Interior malformation
  stays corruption (SessionError).

### Task 2: the exposure (Nim, on the extensibility's Lua state)

- `neopi.provider` table: `generate(config)` — config: {model, messages =
  [{role, text}], system?, tools? = [{name, description, schema, execute?}]}
  → the response table {text, stopReason, usage = {input, output},
  toolCalls = [{id, name, args}]}. The Lua-defined tools map to nimgent
  Tools: the Lua `execute` is a function ref stored via luaL_ref; the nimgent
  execute closure calls it through pcall (the hooks pattern reversed — Lua
  tool, Nim glue).
- `neopi.session` table: `append(kind, payload)` / `history()` /
  `navigate(id)` — the Nim Session wrapped; the session pointer travels as a
  registry lightuserdata (process-lifetime owned by the Nim side).

### Task 3: the runtime (Lua, runtime/ in the repo — shipped with the binary later)

- `runtime/init.lua` — the entry: loads the runtime pieces, exposes the
  agent table.
- `runtime/tools.lua` — bash/read/edit/write in Lua over `neopi.fs` /
  `neopi.process`, LuaCATS-annotated (`---@param`, `---@return`).
- `runtime/agent.lua` — the loop: `agent.run(session, config)` — the turn
  orchestration: build the request from the session history + tools →
  `neopi.provider.generate` → append the assistant entry → execute tool
  calls (via the Lua tools) → append toolResult entries → next turn while
  stopReason == "toolUse" and steps remain → return the final response.
  LuaCATS-annotated.

### Task 4: the print mode (Nim, src/neopi.nim — the binary entry)

- `bin = @["neopi"]` in neopi.nimble; src/neopi.nim: the CLI — `neopi
  "prompt"`: parse the args, assemble the extensibility runtime, load
  runtime/init.lua, call the agent loop with the prompt, print the final
  text. The provider key comes from env or the local .env (the tp_real
  pattern). Compile always with -o:build/neopi.

### Task 5: the busted spec mode + one spec

- The CLI gains a spec mode: `neopi --spec <file>` — loads busted from the
  luarocks paths (package.path/cpath extended to ~/.luarocks), runs the spec
  INSIDE the live Lua state with the core exposed (the nvim pattern: the
  specs run in the host).
- `tests/spec/agent_spec.lua` — the first busted spec: the loop runs a
  scripted-model session end-to-end in-process (no network): append user →
  the loop → the tool call executes via the Lua tool → the toolResult entry
  lands → the final response. LuaCATS-annotated.
- The Nim suite stays green (48/48 + the torn-line tests).

## Tasks

- [ ] 1. Torn-line fix in session.nim (discard + truncate-on-next-append)
- [ ] 2. The exposure: neopi.provider + neopi.session (Lua-callable)
- [ ] 3. runtime/: init.lua + tools.lua + agent.lua (LuaCATS-annotated)
- [ ] 4. The print mode: src/neopi.nim + bin target
- [ ] 5. The busted spec mode + tests/spec/agent_spec.lua
- [ ] 6. Work-unit commit(s) on main; record evidence here

## Evidence

(recorded as tasks close)
