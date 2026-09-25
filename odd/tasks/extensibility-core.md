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

- [x] 1. LuaJIT dependency available (5.1 headers and lib on this machine)
- [x] 2. `src/neopi/lua.nim`: FFI bindings + LuaState wrapper + script loading
- [x] 3. `src/neopi/hooks.nim`: hook registry + emit with pcall containment
- [x] 4. Wire provider paths through the hooks (tool_call block/rewrite,
      tool_result rewrite, stream events)
- [x] 5. Tests: a Lua script registers hooks → core emits → Lua blocks and
      rewrites → behavior changes (scripted provider)
- [x] 6. Work-unit commit(s) on the feature branch; record evidence here

## Evidence

- `4abd12e` — feat: provider primitives with anti-corruption layer over nimgent
- `e3cdf27` — docs: record provider-interface evidence
- `41214e2` — test: read live-check credentials from .env, fix the default free model
- `b1b0362` — fix: untrack compiled test binary, route test builds to build/
- `4ab9640` — feat: LuaJIT in-process hooks with block/rewrite over the provider layer
  (7 files, 632 insertions: lua.nim + hooks.nim + provider wiring + tp_lua.nim)
- Independent verification (gentle-ai-verify): dispatcher run verbatim
  "[Summary] 17 tests run (2.80s): 17 OK, 0 FAILED, 0 SKIPPED" — including the
  live OpenRouter streaming check ("neopi provider works",
  inclusionai/ling-3.0-flash-vl, 2.41s); hooks.nim stack discipline (pcall +
  pops, containment, verdict contract) and the provider wiring nil-path
  byte-identity verified by reading.
- Writer (gentle-ai-worker) notes: 7 mechanical defect classes fixed in
  lua.nim (written inline without compiling — the parent's lesson: compile as
  you write); Lua 5.1's lua_pop/pushcfunction/getglobal/setglobal are
  macro-only (no exported symbols — nm-verified), wrapped Nim-side over
  lua_settop/lua_pushcclosure/getfield/setfield with luaGlobalsIndex -10002;
  relative idx + lua_pushnil segfaults (ctypes-probed) — normalized to
  absolute. Design deviations documented in code: the verdict reads the FIRST
  return value (reason second); neopi.on exposed as both the global and a
  table; hasKey guards fall back to the original payload.
- Known limits: package.loadlib reachable from scripts (slice-2 confinement
  candidate); Lua states never closed (process exit reclaims); the
  invalid-registration path is implemented but untested.
