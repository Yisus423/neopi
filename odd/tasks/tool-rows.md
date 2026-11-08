# tool-rows — the command beside its output

ROADMAP **#33**. The transcript shows a tool's OUTPUT and never the CALL: the user
reads what a command printed without knowing which command the model ran. The
session keeps the tool's name, its output and its error flag, and drops the
arguments — the same YAGNI the reasoning had (#32), on the `ekToolResult` side.

## Specs

- **S1** (the request, verbatim): "También estaría fino que la tool bash muestre
  el comando en la TUI y no solo el resultado (el usuario no sabe que comandos
  está ejecutando el modelo, solo ve el output)."
- **S2** (the split, the user's choice, verbatim): "Dos slices: #32 el thinking,
  #33 los tool rows" — this record is #33, and it follows #32.
- **S3** (the reference, verbatim): "como en pi" — the shape of pi's row is read
  below with `path:symbol`.

## Verified basis (2026-11-07)

### pi's row

1. **The call leads the row.** `createShellRenderers`
   (`packages/coding-agent/src/core/tools/renderers/bash.ts:20-25`) formats the
   call as `theme.fg("toolTitle", theme.bold(`${prompt} ${commandDisplay}`))`
   with `prompt = "$"` for bash and a ` (timeout Ns)` suffix, so the row BEGINS
   with the command. The generic fallback shows the tool's name plus its JSON
   arguments (`tool-execution.ts:formatToolExecution`, `render-utils.ts`).
2. **The result follows in the same row**: the output in `toolOutput`, collapsed
   to the last 5 lines with the tail kept (`renderers/bash.ts:55-67`,
   `BASH_PREVIEW_LINES = 5`), an error result whose text ends with
   "Command exited with code N" (`core/tools/bash.ts:400-405`), and the duration
   as `Elapsed 4.2s` while running and `Took 4.2s` finally
   (`render-utils.ts:toolTimerText`).
3. **Status is encoded**: pending/success/error, plus the row's expandable state
   (`tool-execution.ts:282-286`, Ctrl+O globally).

### neopi today (`path:line`)

1. **The session keeps everything except the call**: `ekToolResult` carries
   `toolCallId`, `toolName`, `output`, `isError` (`src/neopi/session.nim:62-64`)
   and no arguments — so a resume cannot show a command either, because it was
   never written down.
2. **The loop HAS the arguments at the moment it appends**: it executes
   `call.name`/`call.args` and appends the result with the id and the name
   (`runtime/agent.lua`, the tool loop) — the args are dropped at the append, not
   unavailable.
3. **The widget already renders a title, a details hook and a collapsed output**:
   `tikTool` prints the status glyph, `item.title`, up to three lines from
   `widget.toolDetails(item.title, item.toolInput, item.text)` when the tool has
   one, and then the output collapsed to two lines with `(Ctrl-O)` for the rest
   (`src/nimterm/widgets/transcript.nim:143-175`). The item carries `toolInput*:
   JsonNode` and `durationMs*` already (`transcript.nim:15-32`).
4. **neopi sets neither**: `toolDetails` appears nowhere in `src/`, and the
   adapter's tool branch sets only `title = entry.toolName`, `text = entry.output`
   and `isError` (`src/neopi/tui.nim`, `adapterItem`) — so the row is
   `✓ bash` followed by the output, and the command is nowhere on screen.

## Design

1. **Persist the call's arguments on the tool result**: `ekToolResult` gains
   `toolArgs*: JsonNode` (the call's JSON object, exactly what the model sent),
   OPTIONAL in the file like the reasoning is: `entryToJson` writes it,
   `entryFromJson` reads it with the optional helper, and an older file reads as
   an empty node. The chain is two links: the loop passes `call.args` into the
   append (`runtime/agent.lua`) and the exposure's payload parser keeps it
   (`expose.nim`), next to the fields it already reads.
2. **The row leads with the call**, pi's way, decided by the ADAPTER so a resume
   and a live turn render identically:
   - a call whose arguments carry a `command` string (bash) becomes
     `$ <command>` — pi's prompt and shape;
   - any other call keeps the tool's name and gains a one-line argument summary
     (the `path` when there is one), which is pi's generic fallback in miniature.
   The item also carries `toolInput` (the parsed arguments), which is what the
   widget's details hook reads, so a later slice can grow the expanded form
   without touching the session again.
3. **The output stays where it is**: the widget already collapses it to two lines
   with `(Ctrl-O)` for the rest, which is pi's behaviour in this widget's
   vocabulary. The command must not push it out of the row.

**Frozen contracts**: the session's JSONL only GAINS an optional key (an old file
keeps loading, and an entry without it reads as an empty object); the arguments are
stored as THE MODEL'S OWN OBJECT — its key order, its `null`s and its empty objects
intact — which is why they travel as TEXT and are parsed once on the way in: the
Lua table the tools execute with cannot carry any of the three (a `null` becomes
`nil` and the key vanishes, and `{}` reads as `[]`). That last sentence is the
verification's blocker, written into the contract: the first implementation handed
the Lua table back and lost exactly those three things; the adapter is the only
place that decides how a call LOOKS.

**Out of scope (recorded, not forgotten)**: the duration (`Elapsed/Took`, pi's
`durationMs`) — the item field exists and nothing measures it yet; and the
`toolDetails` expansion (pi's full JSON args for a generic tool) — the hook is
wired by virtue of `toolInput` landing, but its content is a later slice's.

## Tasks

- **T1** (S1, S2) — Persist the call's arguments: the loop, the payload parser,
  the entry field and its JSONL round-trip. Route: parent inline (the format
  change is the slice's structural risk).
- **T2** (S1, S3) — The row: the adapter's title (`$ <command>` / name + a path
  summary) and `toolInput`, with the rendered row pinned in a test. Route: parent
  inline (it is one proc and its tests).
- **T3** (S1) — The proof: the JSONL's shape, an old file, a resumed session
  showing the command, the rendered row for bash and for a `read`, and the pty
  pass over the real binary. Route: `gentle-ai-verify` (a session-format change
  is Task Size item 1).

## Evidence

- **T1** — the arguments reach the session. RED: `undeclared field: 'toolArgs'`
  in `tests/tp_session.nim`; GREEN: `tp_session` 12/12 — the round-trip and a
  hand-written OLD line reading an empty object, never nil — and `tp_tui` 95/95,
  where the end-to-end assertion reads the driven `write` call's arguments
  (`history()[2].toolArgs["path"]`).
- **T2** — the row leads with the call. GREEN: `tp_tui` 96/96 — the adapter's
  decision for bash (`$ printf hi`), for a `read` (`read src/neopi.nim`) and for
  a call whose entry has no arguments (the bare name, and an EMPTY object rather
  than nil), plus the RENDERED row: the session seeds the transcript and the
  canvas shows `$ printf hi` above the output.
  **The test caught a crash before it shipped**: a hand-built entry carries a nil
  `toolArgs`, and `hasKey` on nil is a SEGFAULT, not a false (`std/json`'s trap,
  met again in this codebase). The writer now normalizes what it STORES — an
  empty object for a tool result — and both readers tolerate nil, so no path can
  hand a nil node to a widget that dereferences it.

## Known limits

- **The duration is not measured**: pi's row shows `Took 4.2s` and the item has
  the field (`durationMs`), but nothing here records how long a call took — the
  session does not carry it.
- **The expanded form is still the widget's**: the item now carries the parsed
  arguments (`toolInput`), which is exactly what the details hook reads, but
  neopi sets no `toolDetails`, so a generic call shows its name and its path
  rather than pi's full JSON arguments. Same field, later slice.
- **The title is the adapter's decision**: the widget's OWN tool-event path
  (`ueToolCalled`, unused by neopi today) still titles a row with the bare tool
  name, so if a future slice posts those events the titles would differ until it
  goes through the adapter.
- **A call with no usable arguments shows the bare name**, deliberately: a row
  that leads with a broken or empty command is worse than a row that shows no
  command at all.
- **The session grows by the arguments**, and for a `write` call they carry the
  whole file content — the biggest line the file can gain per call. pi stores the
  same thing (the tool call lives in its assistant message), and the alternative
  — showing the command without storing it — cannot survive a resume.
- **The output's collapse is the widget's** (two lines with `(Ctrl-O)` for the
  rest), so a long output and the command compete for the same few rows: the
  command always wins because it leads the title.

## Log

- **L1** (2026-11-07, the request, verbatim): "También estaría fino que la tool
  bash muestre el comando en la TUI y no solo el resultado (el usuario no sabe que
  comandos está ejecutando el modelo, solo ve el output)."
- **L2** (the split, verbatim): "Dos slices: #32 el thinking, #33 los tool rows".
- **L3** (the state that opened the slice): #32 closed with the reasoning
  persisted; this slice is the same shape of gap on the tool side, and its first
  task is the same kind of format change — an optional key, verified the same way.
