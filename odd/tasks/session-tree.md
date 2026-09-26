# Session tree: entries + JSONL + active branch (slice 4a)

## Goal

The harness foundation: a session is a TREE of entries persisted as JSONL.
Each entry has an ID and refers to its parent; the path from the root to the
current entry is the active branch and supplies the model request history.
Continuing from an earlier entry creates another branch in the same file.

## Verified basis (obs #1151, #1152)

- how-pi-works.md: "Messages and events in a session form a tree. Each path
  through that tree is a branch. The branch ending at the current entry is
  the active branch and supplies the history for the next model request."
- message-types.md: the AgentMessage union; "pending" assistant messages are
  never persisted in session JSONL; tool results carry toolCallId.
- compaction.md: session entries use ISO 8601 timestamps; the cut-point rules
  (never at tool results) are slice 4c.

## Non-goals (later slices)

- Compaction entries + branch summaries (slice 4c).
- The agent loop + print mode (slice 4b).
- Fork/clone to new files (a later slice; branch-in-place covers the MVP).
- Steering/follow-up/abort queues (the interactive layer).

## Design

- `src/neopi/session.nim`:
  - Entry variant object (the MVP set): user (text), assistant (text, model,
    provider, usage input/output, stopReason), toolResult (toolCallId,
    toolName, output, isError). Base fields: id (int, increasing per file),
    parentId (int or none — null for the root), timestamp (ISO 8601).
  - Session = ref object: entries (the loaded tree in file order), the JSONL
    path, currentId (the active branch's tip).
  - `newSession(path)`: load an existing JSONL file or start a new one;
    currentId defaults to the deepest leaf (the last entry).
  - `append(session, entry)`: validates, assigns id/parentId (the parent is
    currentId — navigating changes the next append's parent), writes the JSONL
    line, updates currentId.
  - `navigateTo(session, id)`: moves the active branch to an earlier entry —
    the next append branches from there.
  - `history(session)`: the active branch's entries (root → current path) —
    the ordered history for a model request.
- The JSONL format: one JSON object per line, appended only (existing lines
  are never rewritten — the tree is append-only history).
- The model request conversion (entries → generate/stream messages) is slice
  4b, not here.

## Tasks

- [ ] 1. `src/neopi/session.nim`: entry types + Session + newSession/append + JSONL round-trip
- [ ] 2. navigateTo + history (the active path)
- [ ] 3. Tests: append/load round-trip, navigate + branch, history = the active
      path, multi-branch in one file, persistence across reopen
- [ ] 4. Work-unit commit(s) on main; record evidence here

## Evidence

(recorded as tasks close)
