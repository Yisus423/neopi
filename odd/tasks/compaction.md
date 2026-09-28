# Compaction (slice 4c)

## Goal

Long sessions stay usable: when the context exceeds the threshold, old
messages are summarized into a compaction entry that replaces them in
subsequent model requests. The original entries remain in the tree.

## Verified basis (obs #1152 — pi's compaction.md + message-types.md)

- Trigger: contextTokens > contextWindow - reserveTokens (pi: 16384 default,
  20k keepRecent).
- Flow: find the cut point (walk backwards accumulating tokens until
  keepRecent, NEVER at tool results) → summarize (structured format, the
  previous summary as iterative context) → append CompactionEntry (summary +
  firstKeptEntryId + tokensBefore) → rebuild: summary + messages from
  firstKeptEntryId onwards.
- Cut rules: cut at user/assistant messages; NEVER at tool results.
- Repeated compactions start at the previous compaction's kept boundary.
- Summary format: Goal, Progress, Next Steps (+ Critical Context).
- serializeConversation: [User]/[Assistant]/[Assistant tool calls]/[Tool
  result]; tool results truncated to 2000 chars.
- CompactionEntry structure: {type: "compaction", id, parentId, timestamp,
  summary, firstKeptEntryId, tokensBefore, usage?, details?}.

## The architecture for neopi (the loop-in-Lua pattern)

- The POLICY lives in the loop (Lua): the trigger check, the cut point, the
  summary call — the loop compacts.
- The DATA CONTRACT lives in Nim (the session tree): the compaction entry
  kind + its JSONL round-trip; the exposure's append gains the "compaction"
  kind.
- The PROJECTION lives in the loop (Lua): toMessages respects compaction
  entries — the summary becomes a system-role message and entries before
  firstKeptId are skipped.

## Non-goals (later)

- Split user-message spans (two merged summaries).
- Branch summarization (/tree navigation).
- The session_before_compact hook (the neopi.on pattern — a later slice).
- Prompt-cache-write disabling for summarization requests.

## Design

- Nim: `ekCompaction` in the SessionEntry variant {summary: string,
  firstKeptId: int, tokensBefore: int} + the JSONL serializer/loader + the
  exposure's append ("compaction" kind) + the setScripted steps gain usage
  ({usageInput} — the trigger needs a real token estimate in tests).
- Lua (agent.lua): toMessages computes the projection (compaction-aware);
  after each turn the loop checks the threshold (config.contextWindow /
  reserveTokens / keepRecentTokens — defaults: 128k / 16384 / 20000); when
  crossed: walk the branch backwards from the tip, never crossing tool
  results, until keepRecent tokens → serializeConversation →
  neopi.provider.generate (the summary prompt, pi's format) → append the
  compaction entry.
- The threshold check happens after the tool results are appended, before
  the next request (pi's prepareNextTurn point).

## Tasks

- [x] 1. Nim: the ekCompaction kind + JSONL round-trip + the exposure's append kind
- [x] 2. Nim: the setScripted steps gain usage
- [x] 3. Lua: the projection (toMessages compaction-aware)
- [x] 4. Lua: the trigger + the cut point + the summary + the entry
- [x] 5. Tests: the compaction round-trip (Nim), the exposure's compaction kind,
      and the end-to-end loop compaction with a small scripted window (no network)
- [x] 6. Work-unit commit(s) on main; record evidence here

## Evidence

- `a594f62` — feat: compaction - long sessions stay usable (9 files, 490
  insertions: session.nim + provider.nim + expose.nim + runtime/agent.lua +
  the tests + the busted_main exit fix)
- nimble test verbatim: "[Summary] 61 tests run (2.45s): 61 OK, 0 FAILED,
  0 SKIPPED" + busted "2 successes / 0 failures / 0 errors" — the full build
  system green (Nim + the busted specs through the test-only runner).
- The busted runner's exit contract FIXED during the slice: standalone=false
  + the forceExit=true (named chunk) — failures os.exit with their real code
  (verified: a failing spec exits 1; the passing specs exit 0). My earlier
  probes measured the pipeline's exit, not the binary's — the masking claim
  was wrong.
- Known limits: the cut walk is not bounded by a previous compaction's
  firstKeptId (the projection's latest-wins rule handles the repeated case);
  a failed summary skips the compaction (best-effort, retried next check);
  split spans and branch summarization are later; the session_before_compact
  hook is a later slice.
