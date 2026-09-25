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

- [x] 1. `src/neopi/fs.nim`: confined primitives + exposeFs
- [x] 2. `src/neopi/process.nim`: spawn-per-call + process_run hook + exposeProcess
- [x] 3. `src/neopi/hooks.nim`: public state; `src/neopi/extensibility.nim`: assembly
- [x] 4. `src/neopi/lua.nim`: harden (loadlib nil, C loader removed)
- [x] 5. Tests: confinement rejects escapes, fs round-trip, list/exists,
      process run echo, process_run hook blocks, loadlib closed + loaders count
- [x] 6. Work-unit commit(s) on main; record evidence here

## Evidence

- `ecbd716` — feat: confined fs/process primitives and the loadlib closure
  (8 files, 538 insertions: fs.nim + process.nim + extensibility.nim + the
  hardening + the luaUpvalueIndex fix + tp_fs.nim)
- Independent verification (gentle-ai-verify): dispatcher verbatim
  "[Summary] 25 tests run (2.24s): 25 OK, 0 FAILED, 0 SKIPPED"; confinedPath
  rejects escapes, the root upvalue resolves to -10003, all ops confine
  before filesystem access, the hook fires before execution with block/
  rewrite, execCmdEx runs in the workspace, the hardening removes the C
  loader and nils loadlib, and newExtensibility assembles everything on one
  interpreter.
- Two real defects fixed during the slice (both gdb/nm-verified):
  luaUpvalueIndex computed registry - i (-10001, an invalid pseudo-index in
  5.1) instead of the real macro LUA_GLOBALSINDEX - i (-10003) — reading it
  segfaulted; and lua_error longjmps out of Nim C-callback frames with frames
  on, skipping frame pops and corrupting the runtime frame stack — the bridge
  modules now compile with stacktrace: off.
- Known limits: confinement is lexical (symlinks inside the workspace pointing
  outside are followed); with no emit wired, process.run executes freely
  (trusted-code model); the persistent jobstart-style primitive is a later
  slice.
