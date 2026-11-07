# thinking — the reasoning: persisted, coloured, and collapsible

ROADMAP **#32**. The model's reasoning is rendered live and then lost: the
session does not carry it, so nothing survives the turn, it has no colour of its
own, and there is no key to fold it away. The slice revisits the YAGNI call the
session slice made when the reasoning did not exist, with pi as the reference.
The bash tool's row (the command beside its output) is **#33**, not here.

## Specs

- **S1** (the report, verbatim): "oye pero el thinking desparece cuando el modelo
  termina de responder, aparte ni siquiera se guarda en la sesión, tampoco tiene
  un color distintivo como en pi, también estaría fino separar el keybind de
  ocultar el thinking cómo en pi, esto puede ser facilmente otro slice en el que
  se revise/recuerde que se omitió en el slice de las sessions por YAGNI (cuando
  no había thinking)."
- **S2** (the scope, the user's choice, verbatim): "Dos slices: #32 el thinking,
  #33 los tool rows" — this record is #32, and the shared cause is why they were
  proposed together: both need the session to keep something it drops today (the
  reasoning for the assistant entry, the call's arguments for the tool entry).
- **S3** (the toggle's flag, the user's choice, verbatim): "Persistido en el dir
  global, como pi" — the preference lives in the global config directory the
  credential store already uses (`$NEOPI_CONFIG_DIR`), not in the session.
- **S4** (the reference, verbatim): "tampoco tiene un color distintivo como en
  pi, también estaría fino separar el keybind de ocultar el thinking cómo en pi"
  — the colour and the key come from pi, read below with `path:symbol`.

## Verified basis (2026-11-06) — pi's design, and what neopi already has

### pi does it like this

1. **The reasoning is a content block of the assistant message**, not a separate
   kind of entry: `ThinkingContent { type: "thinking", thinking: string,
   thinkingSignature?: string }` (`packages/ai/src/types.ts:428-431`) inside
   `AssistantMessage.content` (`:585-588`). The session entry serializes the whole
   message (`core/session-manager.ts:64-67`), persisted on `message_end`
   (`core/agent-session.ts:1163-1181`), so **a resumed session renders it again**
   (`modes/interactive/interactive-mode.ts:4304-4308`).
2. **The rendering is a muted colour plus italic**, with contiguous reasoning
   blocks coalesced into one (`components/assistant-message.ts:105-181`):
   `new Markdown(thinkingBlocks.join("\n\n"), …, { color: text =>
   theme.fg("thinkingText", text), italic: true })`. Hidden reasoning becomes an
   italic label in the same colour (`:105-181`, default label `"Thinking..."`,
   `interactive-mode.ts:defaultHiddenThinkingLabel`).
3. **The colour tokens**: dark `thinkingText: "okhsl(226 7% 65%)"`
   (`theme/dark.json:26`), light `thinkingText: "okhsl(234 8% 55%)"`
   (`theme/light.json:26`); `theme-tokens.ts:THEME_TOKENS.thinkingText` is
   "Thinking block text color".
4. **Visible by default, folded with Ctrl+T**: `app.thinking.toggle` defaults to
   `"ctrl+t"` (`core/keybindings.ts:51-54`), `hideThinkingBlock = false`
   (`settings-defaults.ts:27`), the key flips it, **persists it** in the global
   settings file (`core/settings-manager.ts:986-990`) and pushes it to every
   assistant component for re-render (`interactive-mode.ts:4676-4689`).

### neopi today (`path:line`)

1. **The reasoning reaches the TUI and nothing else**: the sink posts
   `ueThinkingDelta` (`src/neopi/tui.nim:1166-1168`) and the transcript's
   preview item shows it; #16's fix keeps that item after the turn (the
   mitigation in `postRunFinished`), but a session swap or a resume rebuilds
   from the session — where the reasoning is not.
2. **The session has no field for it**: `ekAssistant` carries `model`,
   `provider`, `usageInput`, `usageOutput`, `stopReason` (`src/neopi/session.nim:58-61`)
   and nothing else. Its sibling omission — the tool call's arguments — is #33.
3. **The colour is a style the widget already owns**: nimterm's
   `TranscriptWidget` has `thinkingStyle*`/`thinkingRailStyle*`
   (`src/nimterm/widgets/transcript.nim:23,28`) applied through
   `itemStyle`/`itemRailStyle` (`:185,194`), and neopi builds the widget with the
   default styles (`newTranscriptWidget`).
4. **The collapsing already exists, key and all**: `tikThinking` renders
   `"Thinking …"` while pending and not expanded, `"Thinking"` plus the text when
   expanded, and `"Thinking · N lines (Ctrl-O)"` when collapsed
   (`src/nimterm/widgets/transcript.nim:132-142`) — and neopi already routes
   `keyCtrlO` to the transcript (`src/neopi/tui.nim:565`). **Ctrl+T is free**
   (Ctrl+C exits, Esc aborts, Ctrl+O is the transcript's), so pi's key can be
   adopted verbatim, and the toggle is a matter of flipping `expanded` on every
   thinking item at once.

## Design

1. **Persist the reasoning as a field of the assistant entry** (pi keeps it in the
   message's content blocks; neopi's entry is flat, so the house shape wins):
   `ekAssistant` gains `thinking*: string`, written by the loop that appends the
   entry and read back by the adapter. The chain has four links, all narrow:
   `OaiAccum` accumulates the thinking deltas (`openai_compat.nim`, next to
   `text`), `Response` exposes it (`primitives.nim`), the exposure's table
   carries it (`expose.nim`), and `runtime/agent.lua` appends it with the
   assistant entry. The JSONL gains ONE optional key: an older file keeps
   loading, and a file without it reads as empty.
2. **The colour is pi's token**: a `thinkingText` theme entry with pi's two
   values (dark `okhsl(226 7% 65%)`, light `okhsl(234 8% 55%)`), applied as
   `thinkingStyle`/`thinkingRailStyle` on the transcript at theme install. No
   nimterm change: the slots exist.
3. **Ctrl+T folds every thinking item** (`expanded = false`) and unfolds them
   again, with the transcript's `invalidateLines()` after the mutation. The
   widget does the rendering (the label with its line count), so the "hidden"
   state is the widget's own collapsed shape rather than a text substitution —
   which also means the streaming deltas keep accumulating in the item's text
   while it is folded.
4. **The preference is persisted in the global directory**: a small
   `settings.json` beside `auth.json` in `$NEOPI_CONFIG_DIR`, written atomically,
   read at start, and a file that is not valid JSON reported instead of
   rewritten — the same discipline the credential store already follows
   (`src/neopi/authstore.nim`). #26 owns the config's future shape; this slice
   only needs one key of it.
5. **A resumed session shows the reasoning again**, collapsed per the flag, through
   the adapter (`adapterItem` maps `thinking` to a `tikThinking` item).

**Frozen contracts**: the session's JSONL only GAINS an optional key (an old file
keeps loading and an entry without it reads as empty); the reasonig is never
truncated or trimmed entering the file; the toggle touches `expanded` only, so no
text is ever lost in memory.

## Tasks

- **T1** (S1, S2) — The reasoning reaches the session: the accumulator, the
  `Response` field, the exposure's table, the Lua append, and the `ekAssistant`
  field with its JSONL round-trip. Route: parent inline (the format change is the
  slice's structural risk).
- **T2** (S1) — The colour: the `thinkingText` theme token with pi's two values
  and the transcript's thinking styles at theme install. Route: worker
  (`## Allowed edit surfaces`: `src/neopi/tui.nim`, `tests/tp_tui.nim`).
- **T3** (S1, S3) — Ctrl+T folds and unfolds every thinking item, and the flag is
  persisted in the global settings file (atomic, tolerant of a broken file).
  Route: worker (`src/neopi/tui.nim`, `src/neopi/settings.nim` (new),
  `tests/tp_tui.nim`, `tests/tp_all.nim`).
- **T4** (S1, S2) — The resume path: the adapter maps the persisted reasoning to
  its item, and a resumed session shows it folded per the flag. Route: parent
  inline.
- **T5** (S1) — The proof: the session JSONL's shape, a resume round-trip, the
  colour in both themes, the key's persistence across a restart, and the pty pass
  over the real binary. Route: `gentle-ai-verify` (the format change is Task
  Size item 1).

## Evidence

_(filled as the tasks land: commit → task → the check that passed)_

## Known limits

_(filled at closure)_

## Log

- **L1** (2026-11-06, the report, verbatim): "oye pero el thinking desparece
  cuando el modelo termina de responder, aparte ni siquiera se guarda en la
  sesión, tampoco tiene un color distintivo como en pi, también estaría fino
  separar el keybind de ocultar el thinking cómo en pi, esto puede ser facilmente
  otro slice en el que se revise/recuerde que se omitió en el slice de las
  sessions por YAGNI (cuando no había thinking)."
- **L2** (the same message's tail, verbatim): "Ya hice push pero lo de el test
  hay que anotarlo y revisarlo luego" — the `/resume` test's isolation is
  ROADMAP #31 and is not this slice.
- **L3** (the decisions, verbatim): "Dos slices: #32 el thinking, #33 los tool
  rows" and "Persistido en el dir global, como pi".
- **L5** (2026-11-06, the report that arrived mid-flight, verbatim): "hay un
  error en el thinking, este se renderiza una sola ves por pregunta (lo que hace
  que cuando el modelo llame a una herramienta o de la respuesta abajo luego el
  bloque thinking de arriba crezca en vez de que se haga uno nuevo abajo)".
  **The cause**: the widget keys an item by `runId:step:kind`, and the sink posted
  every delta of a run with `step = 0` — while a run holds several MODEL turns
  when the model calls a tool, so the second turn's reasoning and text grew the
  first turn's item. The step is the TUI's own drive loop (`sendTurn` iterates one
  `agent.runTurn` per model turn), so the fix is TUI-side: `turnStep` reset per run
  and incremented per iteration. **The lesson**: probing each link in isolation is
  what localized it, and the two links that silently swallowed the new field — the
  Lua scripted-steps parser and the assistant payload parser — were invisible from
  either end of the chain.
- **L4** (the mitigation that opened the slice, already committed): the turn's
  thinking items are no longer dropped with the rest of the preview
  (`402f522`), because the session had nothing to replace them with. That commit
  is the slice's starting point, not its answer: the reasoning still dies with a
  session swap.
