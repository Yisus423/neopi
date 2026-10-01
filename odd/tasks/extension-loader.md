# User config: the .neopi/init.lua entrypoint (the nvim model)

## Goal

Extensions actually load from disk — via the nvim model: ONE user config
file (.neopi/init.lua) that neopi sources at startup; the config requires
the extensions (require is THE Lua mechanism — idiomatically
lazy-loadable). The config path the user asked for.

## Decision (2026-09-30 — the user's call)

The loading model: **B (the entrypoint)**, not the directory scan (pi's
model). The reasoning (the user + the analysis):
- lazy.npi (the future lazy plugin manager, the user's plan) would be an
  EXTENSION: it lists with neopi.fs.list (exists, fs.nim:136) and loads
  on-trigger with require — everything against the surface, NO Nim-side
  scan.
- The scan (C's neopi.loadExtensions) is REDUNDANT with require — YAGNI.
- The config as code (versionable, the order in the user's control); the
  dir layout (extensions/, plugins/) is CONVENTION, not mechanism.
- The global ~/.neopi/init.lua: a later slice (the user's earlier call:
  solo proyecto).

## Verified basis (2026-09-30)

- neopi's extensibility.nim: only Extensibility + newExtensibility — NO
  loader (the surface is complete but nothing loads extension files).
- The containment: the Lua runtime cannot scan directories (io/os closed by
  the hardening); the entrypoint loading is Nim-side (the source read +
  loadScript's pcall containment).
- The runtime's loadRuntime pattern (neopi.nim): the package.path chunk +
  the source read + runScript — the entrypoint follows the same shape for
  .neopi/.
- The failure model: nvim sources the config, surfaces the error, and
  continues. loadUserConfig raises LuaError; the binary catches → the
  stderr warning + continue (the loader raises, the binary decides — the
  same split as loadRuntime's fatal, with a milder severity).

## Design

- **loadUserConfig(root, L)** (extensibility.nim — testable, cohesive: the
  extensibility loads the user's config): <root>/.neopi/init.lua exists?
  → extend package.path with .neopi/ (the config's requires resolve:
  require('extensions.echo')) + read the source + loadScript. Missing: a
  no-op (the bare agent). Failure: LuaError.
- **neopi.nim** (runPrint/runTui): after loadRuntime, try loadUserConfig →
  catch LuaError → the stderr warning + continue.
- **The tests** (tp_expose, the extensibility suites): the config loads and
  registers a command; the config's require('extensions.echo') resolves
  through the extended package path; no config is a no-op; a broken config
  raises LuaError.
- **Non-goals**: the global ~/.neopi/init.lua (later); the manifest; the
  directory scan (redundant with require — the decision above); the trust
  gate (the Lua VM's hardening IS the containment); hot reload; lazy.npi
  (the user's future extension — its needs are all in the surface).

## Tasks

- [x] 1. loadUserConfig in extensibility.nim
- [x] 2. The wiring in neopi.nim (runPrint/runTui, the warning + continue)
- [x] 3. The tests: tp_expose (the config suites)
- [x] 4. Work-unit commit on main; record evidence here

## Evidence

- The parent implemented the slice inline (the writer lesson: the writers
  of this runtime stall systematically; the parent writes the slices inline
  from the task file's contracts).
- nimble test verbatim: "[Summary] 107 tests run (2.40s): 107 OK, 0 FAILED,
  0 SKIPPED" + busted "10 successes" — the config suites (the config loads
  and registers a command, the require('extensions.echo') resolves through
  the extended package path, no config is a no-op, a broken config raises
  LuaError) pass.
- nimlangserver nimCheckFile: 0 diagnostics on extensibility.nim and
  neopi.nim (the first check reported stale unused-import/escapeLua
  diagnostics — the server's cache after the double edit; the connect
  refresh cleared them, and the compiler was clean throughout); the
  production binary builds clean (3.4M).
- The test pattern: the config tests load the runtime entry FIRST (the
  production order: the runtime's registry on the neopi table, then the
  user's config) — the loadRuntimeEntry helper (the tp_register pattern).
- Known limits: solo proyecto (the global ~/.neopi/init.lua is a later
  slice); the escapeLua/raiseLuaError file-scope copies keep growing (the
  consolidation into lua.nim is a future cleanup); the config's failure is
  a stderr warning (no UI surface for it yet); hot reload / lazy.npi are
  future (lazy.npi's needs are all in the surface: fs.list + require +
  registerCommand).
