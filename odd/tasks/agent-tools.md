# Agent tool layer: bash, read, edit, write as model tool calls (slice 3)

## Goal

The agent's tool surface: the four tools the MODEL calls, implemented in Nim
over the confined fs/process primitives and passed to generate/stream via the
existing toolCall primitive. This is the layer pi keeps in
`packages/coding-agent/src/core/tools/` — core-owned, model-facing.

## Verified basis (obs #1146, #1147)

- pi's agent tools (core/tools/): bash, read, edit (+edit-diff), write, grep,
  find, ls, powershell. The default active set is the minimum; grep/find/ls
  are absorbable by bash (decision: neopi skips them — add later per commit).
- write is its OWN tool (no wrapper of edit): "Creates the file if it doesn't
  exist, overwrites if it does. Automatically creates parent directories."
  Patterns to imitate: resolveToCwd (confinement), withFileMutationQueue
  (serialized per-file mutations — not needed while tool calls run
  sequentially; revisit when tools go parallel), constrainedSampling.
- edit errors (edit-diff.ts): duplicate match (ambiguous), "No changes made"
  (identical content), not found.
- read: offset (1-indexed) / limit; output truncated to max lines or KB,
  whichever hits first.

## Non-goals

- grep/find/ls (absorbable by bash; add later if the model needs them).
- The mutation queue (tools run sequentially today).
- Fuzzy matching in edit (exact match only for MVP).
- The Lua surface changes (the agent tools are Nim-side; the Lua extension
  surface stays frozen until real consumers exist).

## Design

- `src/neopi/tools.nim`: four Tool constructors over the existing neopi Tool
  type — `readTool(workspaceRoot)`, `writeTool(workspaceRoot)`,
  `editTool(workspaceRoot)`, `bashTool(workspaceRoot)`. Each builds a Tool
  with a JSON schema (what the model sees) and a confined execute callback.
  Failures raise with model-facing messages (the tool mapping reports them as
  tool failures).
- Shared confinement: extract the pure confinement out of fs.nim's
  `confinedPath` into an exported `resolveConfined*(root, requested)` that
  raises an neopi-owned `FsError` on escape; the Lua ops translate FsError →
  lua_error; the agent tools use it directly. One source of truth.
- read: {path, offset?, limit?} — line-numbered output (mirror pi's read
  format after checking its render), truncated to 2000 lines / 50KB by
  default, offset/limit for large files.
- write: {path, content} — creates/overwrites, mkdir parents automatically,
  returns "Successfully wrote to <path>".
- edit: {path, oldText, newText} — exact match, must be unique (0 → not
  found, >1 → duplicate, identical → no change), replaces and writes back.
- bash: {command} — execCmdEx in the workspace; output plus the exit code
  when non-zero.
- Wiring: none — the tools pass to generate/stream via the tools param (the
  toolCall primitive); the hook bus wiring is orthogonal and already works.

## Tasks

- [x] 1. Shared confinement: `resolveConfined` + FsError in fs.nim, the Lua ops translated
- [x] 2. `src/neopi/tools.nim`: readTool + writeTool
- [x] 3. editTool (exact match, the three error paths) + bashTool
- [x] 4. Tests: happy paths + escape + not found + duplicate + no change +
      truncation + an end-to-end mini agent workflow (read → edit)
- [x] 5. Work-unit commit(s) on main; record evidence here

## Evidence

- `93fc832` — feat: agent tools - bash, read, edit, write as model tool calls
  (5 files, 571 insertions: tools.nim + the fs.nim confinement refactor +
  tp_tools.nim)
- Independent verification (gentle-ai-verify): dispatcher verbatim
  "[Summary] 41 tests run (2.33s): 41 OK, 0 FAILED, 0 SKIPPED" — the
  confinement shared source confirmed, the read pipeline (number →
  offset/limit → truncate with pi's notes), the edit error order (empty →
  not found → duplicate → no change → replace), writeTool's parent-dir
  creation, and the end-to-end read → edit workflow asserting the file
  changed.
- Verified finding: pi's MODEL-FACING read is NOT line-numbered (the
  numbering is TUI-only, renderers/read.ts); neopi's read numbers per the
  slice design — a one-line change if the user prefers pi's plain format.
- Verified nuance: bashTool does NOT fs-confine its command (cwd only) — by
  design and pi-canonical: bash's gate is the approval layer (the
  process_run hook / a future harness approval), not the cwd.
- Known limits: confinement is lexical (no symlink resolution); edit is
  exact-match only (no fuzzy, no CRLF normalization); no mutation queue
  (tools run sequentially); bash appends the exit-code note only when
  non-zero.
