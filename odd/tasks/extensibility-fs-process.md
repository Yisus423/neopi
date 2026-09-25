# Extensibility slice 2: confined fs/process primitives + the loadlib closure

## Goal

Confined filesystem and process primitives exposed to the same Lua
interpreter as the hook bus, plus the native-code escape-hatch closure:
scripts compute in Lua only; side effects go through the core's confined
primitives.

## Study basis (obs #1127)

- pi/nvim both trust extension code; nvim's side-effect surface IS its API
  (vim.api). neopi's adaptation: the core is the only side-effect surface and
  it is confined (fs inside the workspace, process gated by the process_run
  hook).
- nvim's jobstart: persistent process, job-id = channel-id. Slice 2 keeps the
  spawn-per-call primitive simple; the persistent model is a later slice.
- Known limit from slice 1: package.loadlib (dlopen) reachable from scripts.

## Non-goals (later slices)

- Persistent process primitive (jobstart-style, job-id = channel-id).
- TUI in-process primitives: status/widget/footer (slice 3).
- Manager + manifest convention (slice 4).
- LuaJIT FFI exposure (stays closed).

## Design

- `src/neopi/fs.nim`: confined fs primitives — read/write/exists/list. The
  confinement resolves the requested path against the workspace root with
  `normalizedPath`, rejecting escapes (outside the root) with a Lua error.
  The workspace root travels as a closure upvalue. Exposed as the `neopi.fs`
  table via `exposeFs(L, workspaceRoot)`.
- `src/neopi/process.nim`: the spawn-per-call process primitive — `run(cmd)`
  fires the `process_run` hook (block/rewrite via the hook bus's emit,
  dependency-injected as a closure to avoid an import cycle), then executes
  via `execCmdEx` with `workingDir = workspaceRoot`, returning
  `{output, code}`. Exposed as the `neopi.process` table via
  `exposeProcess(L, workspaceRoot, emit)`.
- `src/neopi/hooks.nim`: the bus's Lua state becomes public (`state*`) so the
  assembly can expose fs/process on the same interpreter.
- The assembly lives in a new `src/neopi/extensibility.nim`:
  `newExtensibility(workspaceRoot)` = hook bus + fs/process on one state.
  With an empty workspaceRoot, only the hooks exist.
- Hardening in `lua.nim`: `harden(L)` (declared before newLuaState, using
  loadbuffer+pcall directly) removes the C (dlopen) package loader
  (`table.remove(package.loaders, 3)`) and nils `package.loadlib`;
  `newLuaState` calls it — no native-code escape hatch for scripts.
- Trust model (documented, honest): scripts are trusted code with no
  native-code escape (FFI closed, loadlib nil, C loader removed); fs/process
  go through confined primitives; the process_run hook can gate commands.

## Tasks

- [ ] 1. `src/neopi/fs.nim`: confined primitives + exposeFs
- [ ] 2. `src/neopi/process.nim`: spawn-per-call + process_run hook + exposeProcess
- [ ] 3. `src/neopi/hooks.nim`: public state; `src/neopi/extensibility.nim`: assembly
- [ ] 4. `src/neopi/lua.nim`: harden (loadlib nil, C loader removed)
- [ ] 5. Tests: confinement rejects escapes, fs round-trip, list/exists,
      process run echo, process_run hook blocks, loadlib closed + loaders count
- [ ] 6. Work-unit commit(s) on main; record evidence here

## Evidence

(recorded as tasks close)
