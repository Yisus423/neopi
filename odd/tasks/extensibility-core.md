# Extensibility core: LuaJIT in-process + lifecycle hooks (slice 1)

## Goal

LuaJIT embedded in-process (own FFI bindings to the 5.1 C API) with a `neopi`
global exposing lifecycle hooks that can block and rewrite — the pi/nvim
model: the core exposes primitives, Lua composes.

## Study basis (obs #1127 — executed 2026-09-21)

- pi: jiti in-process, no worker isolation; ~20 hooks with mutation power
  (block / patch input / replace payload); ctx.ui in-process; errors collected
  per extension (fail-safe in tool_call).
- nvim: LuaJIT in-process, 3 layers without duplication, pcall containment
  (callback error aborts the script, not the host); jobstart persistent.
- Neither has a real plugin sandbox. neopi's honest delta: LuaJIT FFI disabled
  by default, fs/process confined as core primitives.

## Non-goals (later slices)

- fs/process confined primitives (slice 2).
- TUI in-process primitives: status/widget/footer (slice 3).
- Manager + manifest convention (slice 4).
- LuaJIT FFI exposure to Lua (disabled by default; deliberate escape hatch later).

## Design

- `src/neopi/lua.nim`: own FFI bindings to the LuaJIT 5.1 C API (newstate,
  openlibs, loadbuffer, pcall, getglobal, pushstring, pushinteger,
  pushboolean, pop, tolstring, type), a LuaState wrapper, and script loading
  with pcall containment.
- `src/neopi/hooks.nim`: hook registry (`on(event, fn)` callable from Lua),
  core-side emit that invokes Lua callbacks through pcall, and block/rewrite
  semantics taken from return values (pi's pattern: return values mutate).
- Wiring: the provider generate/stream/toolCall paths fire `tool_call`
  (block/rewrite arguments), `tool_result` (rewrite output), and stream events
  through the hook pipeline.
- `pcall` wraps every Lua callback: a Lua error aborts that callback's
  contribution, never the host.

## Tasks

- [ ] 1. LuaJIT dependency available (5.1 headers and lib on this machine)
- [ ] 2. `src/neopi/lua.nim`: FFI bindings + LuaState wrapper + script loading
- [ ] 3. `src/neopi/hooks.nim`: hook registry + emit with pcall containment
- [ ] 4. Wire provider paths through the hooks (tool_call block/rewrite,
      tool_result rewrite, stream events)
- [ ] 5. Tests: a Lua script registers hooks → core emits → Lua blocks and
      rewrites → behavior changes (scripted provider)
- [ ] 6. Work-unit commit(s) on the feature branch; record evidence here

## Evidence

(recorded as tasks close)
