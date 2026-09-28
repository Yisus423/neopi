# neopi.registerTool: extensions register tools (slice 5)

## Goal

The Lua extensibility surface completes: an extension registers a tool the
model calls, in Lua, without touching the core. With this, the surface is
hooks + fs/process + registerTool — the differentiator complete.

## Verified basis (obs #1127, #1154-#1158)

- pi's ExtensionAPI: registerTool (the model calls extension tools; they join
  the tool list the model sees).
- The mapping exists since slice 4b: the Lua tools → nimgent via luaL_ref/pcall
  (per-call). registerTool adds the persistent registry.
- The UX decision (frozen until real consumers exist): this slice brings the
  first real consumer (the notes extension) — the API gets polished with use.

## Non-goals

- Tool namespacing/collisions (pi's suffixes — later when multiple extensions
  exist).
- The approval gating for extension tools (pi: they ask; the hook can gate —
  later).
- Unregistering (later).
- The UI surface (the interactive layer, later).

## Design

- Lua (runtime/init.lua): `neopi.registerTool(name, description, schema,
  execute)` — the REGISTRY in Lua puro (a table in the runtime), the
  api-shaped entry point; `neopi.registeredTools()` returns them.
- Nim (expose.nim): the generate MERGES the config's tools + the registered
  ones (the model sees both): after reading the config's tools, read the
  registered list (lua_getfield on the neopi table, call registeredTools,
  map each entry to a Tool — the fn ref via luaL_ref + makeLuaToolExecute, the
  existing pattern). The refs are luaL_unref'd when the generate completes
  (the registry does not grow per call).
- Lua (runtime/agent.lua): executeCall falls back to the registered tools —
  the loop executes a registered tool's Lua function directly (Lua puro).
- The first real consumer: tests/spec/notes.lua — the notes extension:
  registers save_note (a tool that appends to NOTES.md via neopi.fs) + a
  tool_call hook (protection: blocks another tool) + the end-to-end loop run
  with a scripted model — the API's UX test with real use.

## Tasks

- [x] 1. Lua: neopi.registerTool + neopi.registeredTools (the registry in the runtime)
- [x] 2. Nim: the generate merges the registered tools (luaL_ref/unref)
- [x] 3. Lua: executeCall falls back to the registered tools
- [x] 4. tests/spec/notes_spec.lua: the first real extension (tool + hook + e2e)
- [x] 5. Nim tests: the register → generate → execute flow
- [x] 6. Work-unit commit(s) on main; record evidence here

## Evidence

- `825a7e7` — feat: neopi.registerTool - extensions register tools the model
  calls (the registry in the runtime, the exposure merge, the executeCall
  fallback, notes_spec.lua, tp_register.nim)
- `f3ea7bd` — fix: emit fires only handlers registered for the event (the
  registry was a single counter with dense refs; emit fired EVERY handler for
  every event — a real bug the writer found; the registry keeps (event, refs)
  pairs now and emit filters)
- nimble test verbatim: "[Summary] 66 tests run (2.89s): 66 OK, 0 FAILED,
  0 SKIPPED" + busted "4 successes / 0 failures / 0 errors" (agent_spec 2 +
  notes_spec 2)
- The UX verdict from the first real consumer (the notes extension, the
  writer's notes): the 4-arg register reads natural in Lua; the schema literal
  is the same shape as config.tools (no second format); the append policy in
  Lua puro over the confined fs; the hook block carried the reason to the
  model. The friction found: handlers must key in the payload (fixed: the
  event-keying now works) — a tool_result handler without the fix would have
  needed it.
- Known limits: unregistering, namespacing/collisions, the approval gating
  are non-goals (later); the config.tools validation error paths leak refs
  created until that point; the merge's direct observable is indirect
  (response.toolCalls is not filtered by the scripted provider).
