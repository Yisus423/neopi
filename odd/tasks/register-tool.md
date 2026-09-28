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

- [ ] 1. Lua: neopi.registerTool + neopi.registeredTools (the registry in the runtime)
- [ ] 2. Nim: the generate merges the registered tools (luaL_ref/unref)
- [ ] 3. Lua: executeCall falls back to the registered tools
- [ ] 4. tests/spec/notes.lua: the first real extension (tool + hook + e2e)
- [ ] 5. Nim tests: the register → generate → execute flow
- [ ] 6. Work-unit commit(s) on main; record evidence here

## Evidence

(recorded as tasks close)
