# TUI UX: bring the interface close to pi, on nimterm

The slice that closes the UX gap between neopi's TUI and pi's, and with it
settles the interface vocabulary BEFORE any extension is written against it.
Stage 1 (this document) is a read-only study: no source line changes in it.

## Specs

- **S1 — the study is read-only and it is the deliverable of stage 1.**
  The user's words: "hay mucho que hablar y investigar antes de si quiera
  tocar el proyecto" and "hablemos primero y dime que encontraste". The map
  below (pi feature → nimterm today → neopi today → gap → who closes it) is
  the artifact; it produces the target list, and nothing is written to source
  until the targets are cut.
- **S2 — this slice precedes the extension slice.** The user's words: "yo
  propondría primero hacer el slice de la acercar la ux de la tui a pi, sería
  mejor limpiar la casa bien (el core) antes de que entre la visita
  (extensiones), siento que hacerlo con extensiones nos ataría las manos".
- **S3 — own TUI vs vendor nimterm must be answered with evidence, not
  opinion.** The user's words: "vuelven mis dudas anteriores con la TUI y si
  necesitaremos hacer la nuestra propia o vendorearla".
- **S4 — the slice must not leave a refactor hanging for after the
  extensions exist.** The user's words: "hacer un refactor luego de esto
  sería un suicidio". Consequence: whatever this slice exposes must be
  decided deliberately, including what is deliberately left OUT of the
  extension surface.
- **S5 — no payload-vs-`ctx` decision is required from the user here.** The
  user's words: "no conozco ni tengo tanto criterio para decidir entre payload
  o ctx, jamás he hecho una extensión de pi o nvim". The study answers it
  with measurable facts instead of asking for a preference.
- **S6 — `nimterm` is a dependency whose pinned revision is the subject.**
  The user's note: "puedes usar codegraph en nintern o leer su
  documentación". Verified: `~/proyectos/nimterm` HEAD is exactly the pinned
  `f7e518e` (`neopi.nimble`), so the docs read describe the revision neopi
  links.
- **S7 — the slice's scope is the first stretch: theme, keys/mouse, chrome.**
  The user's answer: "El primer tramo: tema, teclas/mouse, y el chrome" →
  batch 1 (T2, T4, T3).
- **S8 — the plumbing (T9) belongs to this slice, together with what uses
  it.** The user's answer: "T9 va acá, junto con lo que lo usa
  (T5/T6/T8)" → the plumbing is not deferred to ROADMAP #16.
- **S9 — the dialogs and the approvals land as events, never as a blocking
  wait.** The user's answer: "T6/T8 entran como eventos, sin diálogos que
  esperen": the synchronous-handler wall is documented as a known limit,
  not crossed by this slice.
- **S11 — T3's shape, cut by the user (verbatim answers).** D1: "Reemplazar
  por `ui.status(key, text)`" — the unkeyed form is replaced and the migration
  is paid now, while the only consumers are the specs. D2: "Todos, incluidos
  notify y title" — `neopi.hasUI`, `ui.working(text)`, `ui.notify(text, level)`
  and `ui.title(text)` all land in T3. D3: "El footer queda del core; su slot
  llega con L2" — pi's canonical footer consumer right-aligns with the width,
  and an L1 slot has no width. T3 therefore ships as two work units: **T3a**
  (the geometry and the four core slots) and **T3b** (the four adjacent ones),
  and it carries the `statusLine` find below.
  first one.** The user's words: "dale corrige antes de arrancar", answering
  "¿Querés que corrija el mapa con L1/L2/L3 antes de arrancar T3…". **L1** is
  the slot vocabulary (what T3 settles: the core owns geometry and pixels, Lua
  fills text). **L2** — the core hands Lua a width and receives lines back — is
  reachable, deliberately deferred, and carries a named trigger. **L3**, the
  host's object model, is out permanently. The L1 surface must be **additive**:
  no slot name closed into an enum, no geometry ownership baked in, so L2 can
  land later without breaking the extensions written against L1.

## The study: the map

Sources read (all read-only): pi `docs/{tui,extensions,keybindings}.md` and
`packages/coding-agent/src/core/extensions/types.ts` (the authoritative
surface: 41 `on()` events, ~26 API actions, ~30 `ExtensionUIContext` methods);
nimterm `docs/src/content/docs/{reference/core-api,widgets,agent-frontends,
input-and-events,testing}.md` plus `src/nimterm/{app,widget,theme}.nim` and
`src/nimterm/widgets/transcript.nim`; neopi `src/neopi/tui.nim` (all of it)
and `src/neopi/openai_compat.nim`.

| pi UX feature | nimterm today | neopi today | gap | who closes it |
|---|---|---|---|---|
| Markdown in the transcript | `newMarkdown` + the transcript renders it | yes, through `TranscriptWidget` | none | — (done) |
| Collapsed thinking + toggle (`ctrl+t`) + `setHiddenThinkingLabel` | `ueThinkingDelta`, collapsed summary, `keyCtrlO` (transcript.nim:459) | **the data never arrives**: `openai_compat` drops `delta.reasoning` by design (openai_compat.nim:3,54 — pinned by a test) and the sink only reads `{"text"}` | the reasoning must reach the transcript | core (provider + sink) |
| Expandable tool output (`ctrl+o`) | compact/expanded + `toolDetails` + `formatToolLine` | partial: the transcript renders it, `toolDetails` is never set, `ctrl+o` needs transcript focus | wiring + details | core |
| Tool approvals (`permission-gate`, `ctx.ui.confirm`) | `ueApprovalRequired` + `approvalChoices` + the `approval` action (transcript.nim:447,456) | the gate is a non-interactive Lua hook (block/allow); the `approval` action is **dropped** (`onAction` only handles `submit`, tui.nim:639) | a whole interactive path | core + slot |
| Dialogs: `select`/`confirm`/`input`/`editor` | `QuestionWidget` (modal, options + free text + cancel) and `Menu` | `Menu` is used only for `/resume`, built-in, not exposed to Lua | expose it | slot Lua (+ the sync wall if it must block) |
| Keyed, clearable status bar (`setStatus(key, text)`) | `appendStatus` (a transcript row) | `ui.status(text)` — no key, no clearing, no status bar | slot vocabulary + an area | slot + core (layout) |
| Persistent widgets with placement above/below the editor (`setWidget`) | compose the tree | `ui.widget(name, text)` lands as a transcript status row | placement + clearing | slot + core (layout) |
| Customizable working indicator / message / visibility | the transcript already paints "working" on pending items (transcript.nim:163) | the footer hardcodes `" | working"` | slot + de-duplication | slot |
| Themes: semantic tokens, dark/light, `/theme` | `ThemeSpec`, `detectDepth`, `compileBuiltinTheme(dark|light)`, `setTheme` — and markdown + transcript already consume `currentTheme` | **neopi never calls `setTheme`** (verified: zero matches) | one call + a command | core (1 call) + command |
| Mouse: wheel scroll | SGR wheel routed to the widget under the pointer, `ScrollView` | inherited from the app's routing — needs verification | verify | verify |
| Mouse: drag selection + copy (`ctrl+c`) | `selectedText`, `copySelection`, the `copy` action (transcript.nim:417) | the `copy` action is **dropped** | handle the action + `mouseCapture` | core |
| Transcript keys with the editor still focused (pageUp/pageDown/home/end/ctrl+home/ctrl+end) | the transcript is `focusable` and handles them (transcript.nim:111,428-434), but routing walks focus → **parents**, and the transcript is a **sibling** of the input | unreachable without Tab stealing focus from the editor (pi gives these keys precedence with the editor focused) | route those keys to the transcript before the input | core |
| Transcript search (`tui.altScreen.search`) | `setSearch` / `nextSearch` / `clearSearch` | no binding at all | a search mode + slot | core + slot |
| `notify(message, type)` | **not present** (no notify, no OSC; verified) | not present | a transient slot (status bar or a transient row) | slot (no new nimterm capability) |
| `setTitle` (terminal title) | **not present** (no OSC 2 found) | not present | OSC 2 | fork patch or core |
| Custom footer / header factories | compose the tree | footer hardcoded to one `TextWidget` row; **no header** | layout: a header area + an N-row footer | core + slot (text only) |
| Custom editor component (`modal-editor`, `rainbow-editor`) | any widget can be the editor | hardcoded `InputWidget` | the contract blocks it, not the language — and the contract is `render(width): string[]` | **L2** (deferred; its focus/input half is the cost) |
| Anchored overlays with margins, offsets, animation (`ctx.ui.custom({overlay:true})`) | `Stack` (same rect) + `modal` + hit routing; no anchor/margin engine | the resume `Menu` floats above the input by hand in `paint` | two gaps with different owners: anchoring/margins/percentages are geometry, the animated content is the component contract | core (anchors) + **L2** (content) |
| Borders / panels / cards (ROADMAP #13 "the widget borders") | `Panel`, `Card`, `Menu(bordered)` | the TUI uses none; only a literal `─` rule | decide the chrome | core |
| Image component | not present | not present | a terminal image is a capability problem (sixel/kitty protocols), not an extension-model one | OUT (no consumer) |
| Editor autocomplete (`addAutocompleteProvider`) | not present (`Menu` exists, no completion hook) | not present | the core owns the editor's completion hook; it is an input affordance, not a rendered component | OUT / core feature (no consumer) |
| Multi-question with a tab bar (`questionnaire`) | `QuestionWidget` is one question | not present | chained questions already cover the workflow; a tab bar is chrome over the same widget | OUT (chain them) / **L2** |

### The levels: L1, L2, L3

The map's component-shaped rows used to read "OUT of the Lua surface (escape: a
fork patch or a core feature)". **That was wrong**, and it matters because it
decides what T3's vocabulary must not close off.

- **L1 — slots.** The core owns geometry and pixels; Lua fills text. What neopi
  has (`ui.status`, `ui.widget`) and what T3 settles.
- **L2 — a Lua-rendered component.** The core hands Lua a width and receives
  lines back — `render(width): string[]`. That is literally pi's `Component`
  contract (`~/proyectos/pi/packages/tui/src/tui.ts:117`: those six lines, plus
  optional `handleInput`/`handleMouse` and `invalidate`; `Focusable` is just
  `{focused: boolean}`), and everything else there — `Text`, `Container`, `Box`,
  `SelectList`, `ScrollView` — is a library on top of it. It is reachable in
  neopi because the core **already calls Lua from Nim** (the stream sink
  `tuiOnEventCB`, the hook bus): the primitive is the same trick. **Deferred,
  with its trigger:** the first real consumer that needs UI the slots cannot
  express, whose canonical example is pi's own `custom-footer.ts` — one line
  carrying the git branch and the token totals. Costs when it lands: input
  callbacks (a focused Lua widget needs `handle`), `lua_pcall` containment
  inside `paint` (a Lua error must not kill the frame, and the `lua_error`
  longjmp discipline applies), geometry staying in Nim, and a per-line cache
  keyed by `(width, revision)` — the discipline pi documents. **L2 does not
  need async:** a `render` callback is synchronous by nature, so it is
  unrelated to the wall S9 carries.
- **L3 — the host's object model.** Out permanently, and for a better reason
  than "Lua cannot draw": pi and Neovim agree that the component vocabulary
  belongs in a library, never in the engine. Neovim is the proof — `nui.nvim`
  ships `Popup`/`Input`/`Menu`/`Split`/`Layout` as a **Lua library** over the
  engine's data primitives (`nvim_buf_set_lines` + extmarks + floating-window
  geometry) and the C engine knows nothing about components, layout or menus.

The primitive is the same in all three projects: **text plus highlighting as
data** — pi hides it inside ANSI strings, Neovim in `lines` + `extmarks`,
nimterm in `Canvas` cells through `writeAnsiText`.

### The plumbing row (the highest-leverage finding)

The turn runs **synchronously inside the widget dispatch**: `sendTurn` drives
`evalJson` per turn and `flushFrame` / `feedKeys` / `drainGapKeys` re-implement
by hand what nimterm's loop already does — `flushFrame` duplicates
`app.render` + `backend.present`, and `feedKeys` duplicates `app.dispatch`.
nimterm already offers the alternative: `EventSource` + `addSource`, `post`,
`schedule`, `step`, and the agent-neutral `AgentUiEvent` vocabulary the
transcript consumes.

Consequence: this slice and ROADMAP #16 (the tool execution alive during a
run) are the same wall seen twice. Anything built on the manual pumping
(`| working` in the footer, approvals, thinking) inherits the freeze; adopting
the event-source model retires the pumping and makes the pi-shaped UX
expressible without more of it.

## Tasks

Route: inline = parent session; worker = delegated; verify = independent.
Commits are the work-unit commits of the slice (Conventional Commit) — the
repository's own convention (ROADMAP: "slices land on `main` as work-unit
commits"); a task closes only with one.

**Batch 1 — the first stretch (S7):**

| ID | Task | Spec | Route | Commit |
|---|---|---|---|---|
| T1 | The study: this document (read-only, no source line) | S1, S3, S5, S6 | inline | `docs(tui): the UX map and the slice targets` — `401a682` |
| T2 | The theme: the TUI paints through `setTheme(compileBuiltinTheme(...))` chosen from `detectDepth()` + `prefersLightBackground()`, with the pure selection extracted so it is testable | S3, S7 | inline | `feat(tui): the palette follows the terminal instead of a hardcoded dark` — `87c27cd` |
| T4 | The transcript keys and the mouse with the editor still focused: `pageUp`/`pageDown`/`ctrl+o` routed to the transcript, and the `copy` action (drag selection + clipboard). `home`/`end`/`ctrl+b`/`ctrl+f` are deliberately NOT routed — nimterm's `InputWidget` binds all four for cursor movement | S3, S7 | inline (both workers stalled) | `feat(tui): the transcript answers the page keys and the copy action` — `f4a46a4` |
| T3 | The chrome, in two work units. **T3a**: the `NeopiScreen` geometry (a header area, the transcript, widgets above the editor, a keyed status bar with clearing, the rule and the input, widgets below, an N-row footer) plus `ui.header(lines)`, `ui.status(key, text)` and `ui.widget(key, lines, {placement})`; it also fixes `TuiState.statusLine`, which the resume paths write and nobody reads. **T3b**: the four adjacent slots — `neopi.hasUI`, `ui.working(text)`, `ui.notify(text, level)` (a row the core clears on submit) and `ui.title(text)` (OSC 2, a capability nimterm lacks, written through `termWrite` the way `copyToClipboard` is) | S4, S7, S10, S11 | inline | `feat(tui): the chrome grows a header, a status bar and placed widgets` — `581daca` + `feat(ui): the adjacent slots - notify, working, title and the hasUI guard` — `d064a1d` |

**Batch 2 — the plumbing and the events that need it (S8, S9):**

| ID | Task | Spec | Route | Commit |
|---|---|---|---|---|
| T9 | The plumbing, in two work units. **T9a**: the app owns dispatch and render — `wireApp` extracts the loop's callbacks so they are testable, the stream sink **posts** agent events instead of drawing by hand, `pumpApp`/`presentApp` replace `feedKeys`/`flushFrame`/`drainGapKeys`, the turn sets `working` (a field nothing ever wrote, so the `| working` indicator never reached a frame), the abort request becomes observable, and a submit while the turn runs queues steering instead of recursing into a nested turn. **T9b**: the incremental transcript sync — DONE, with the fork's `appendItem` (`800bf7f`) and the pin bumped with it. The full rebuild replaced every item once per turn, so the items' view state went with it: an expanded tool collapsed and a pending approval disappeared from the UI. `syncTranscript` appends only what is past a watermark, and the full path (`seedTranscript`) stays for a fresh screen and for a branch that moved back. The streamed text is provisional, so the run is closed in the widget (`postRunFinished`) before the sync appends the real entry. **`addSource`/`EventSource` is NOT in T9**: it presumes a loop free to poll, which is ROADMAP #16's wall — the sink is called from *inside* the blocked turn | S8 | inline | `1bb3ff5` (T9a) + `0e976bd` (T9b), the fork `800bf7f`, the pin `ea0d956` and the procedure `39078a1` |
| T5 | The thinking: the reasoning deltas reach the transcript as `ueThinkingDelta` and the collapsed label becomes the pi-shaped one | S8 | worker | `feat(tui): the reasoning deltas render as the collapsed thinking item` |
| T6 | The dialogs: `neopi.ui.select` / `neopi.ui.confirm` as **events** — the question renders and its answer arrives through the event source, with no handler blocking on a wait | S8, S9 | worker | `feat(ui): the extension dialogs land on nimterm's question widget` |
| T8 | Approvals: the transcript's `approval` action bridged to the `tool_call` verdict as an event, not a synchronous prompt | S8, S9 | worker | `feat(tui): the tool gate can ask the user` |

**Pending the user's word (not cut either way):**

| ID | Task | Spec | Route | Commit |
|---|---|---|---|---|
| T7 | Transcript search: `setSearch`/`nextSearch`/`clearSearch` bound to a search mode. It is the same family as T4 (transcript keys with the editor focused) and could fold into it | S3 | worker | `feat(tui): the transcript search mode` |
| T10 | The UX regression gate: canvas + FakeBackend assertions over the chrome, extending `bench/tui_bench.nim`. ODD requires checks per task regardless; this task is the standing gate, not a substitute | S1 | inline | `test(tui): the interface has a regression gate` |

Not in this slice, recorded so nobody re-derives them: the custom editor
component and the animated overlay content are **L2** (deferred, trigger
above), and the overlay *geometry* half — anchors, margins, percentages — is a
genuine **core** gap, because nimterm's `Stack` shares one rect and has no
anchor engine. Images stay out as a terminal-capability problem, editor
autocomplete stays out because the core would own that input affordance, the
tab-bar questionnaire can be chained questions, and the terminal title needs an
OSC 2 fork patch (no consumer yet).

**Known limit this slice carries (S9).** Handlers stay **synchronous**
(`lua_pcall`, hooks.nim:79). A dialog or an approval therefore cannot block a
handler while it waits for the user; the events arrive through the event
source and the extension reacts to them. Crossing that wall is ROADMAP #16's
owner, and T9's plumbing is the part of it that this slice consumes.

## Log

- **L1 (verbatim, the original request):** "sigamos con el próximo slice, hay
  mucho que hablar y investigar antes de si quiera tocar el proyecto"
- **L2 (verbatim):** "podías haber usado codegraph en ~/proyectos/pi/"
  Evidence: `~/proyectos/pi` is a full pi checkout with a `.codegraph` index;
  the authoritative extension surface is
  `packages/coding-agent/src/core/extensions/types.ts` (2273 lines). The first
  pass had read only the packaged docs; L2 corrected the method.
- **L3 (verbatim):** "esperate, ni siquiera me dijiste nada, lanzaste la
  pregunta de una" and "hablemos primero y dime que encontraste". Correction:
  present findings before asking for decisions.
- **L4 (verbatim):** "entonces creo que significa que esto no es lo siguiente
  que deberíamos hacer. Con eso que dijiste vuelven mis dudas anteriores con la
  TUI y si necesitaremos hacer la nuestra propia o vendorearla, porque hacer un
  refactor luego de esto sería un suicidio, yo propondría primero hacer el
  slice de la acercar la ux de la tui a pi, sería mejor limpiar la casa bien
  (el core) antes de que entre la visita (extensiones), siento que hacerlo con
  extensiones nos ataría las manos. Aunque en realidad no conozco ni tengo
  tanto criterio para decidir entre payload o ctx, jamás he hecho una extensión
  de pi o nvim para saber las bondades y maldades de cada uno"
  This is the ordering decision (S2) and the reason this document exists.
- **L5 (verbatim):** "puedes usar codegraph en nintern o leer su
  documentación". (The name is nimterm; the instruction is the one followed.)
- **L6 (verbatim):** "dale arranca" — authorizes stage 1 (the study) only.
- **Evidence — the measured cost of the surface decisions (S5).**
  `neopi.on(` appears 11 times in the whole repository and **zero** times in
  shipped Lua (`runtime/*.lua`, `.neopi/`); the 11 are tests
  (`tests/spec/notes_spec.lua` 2, `tests/tp_lua.nim` 7, `tests/tp_fs.nim` 2).
  And in Lua a handler declared `function(payload)` called as
  `handler(payload, ctx)` still works — extra arguments are discarded, exactly
  as returning a value from a function that ignored it does. So adding a
  second argument (or an unsubscribe handle) later is NOT a breaking change.
  The irreversible contract is the **synchronous handler invocation**
  (`lua_pcall` in `hooks.nim:79`), because in pi handlers are awaited and
  `await ctx.ui.select(...)` is legal. That is the same wall as ROADMAP #16.
- **Evidence — the own-TUI question (S3).** nimterm at the pinned `f7e518e`
  already provides the component model (`Widget` with
  `measure`/`layout`/`handle`/`paint`/`children`/`modal`/
  `allowsBackgroundEvent`), containers (`Column`, `Panel`, `Card`, `Stack`),
  focus routing with modal scoping and mouse capture, SGR mouse with drag and
  wheel, focus reports and bracketed paste, a theme engine with depth
  detection that markdown and the transcript already consume, and the
  agent-neutral `AgentUiEvent` vocabulary with approvals, thinking deltas,
  tool details, search, selection and copy. The two things pi's UX assumes
  that nimterm lacks are the anchored-overlay engine and editor autocomplete
  — both a custom widget or a fork patch, not a rewrite. The vendoring
  decision therefore stands, now on capability grounds rather than only on the
  performance measurement of fdc0c3d.
- **Evidence — the Lua boundary (S4).** pi's `setFooter`/`setHeader`/
  `custom`/`registerMessageRenderer`/`setEditorComponent` exist because a
  TypeScript extension **returns a `Component`**. A Lua extension cannot
  construct a Nim widget, so the only UI an extension can reach is *data into
  predefined slots*. The surface today has two slots (`ui.status(text)` with no
  key, `ui.widget(name, text)` with no placement and no clearing), both landing
  as transcript status rows. S4's "clean the house" is exactly this vocabulary
  plus the levels above — L1 now, L2 deferred with its trigger, L3 out — which
  is the correction recorded under L8.
- **L7 (verbatim, the scope cut):** "1. ¿Qué ancho le damos a este slice? —
  El primer tramo: tema, teclas/mouse, y el chrome / 2. T9 (la plomería del
  event source) y su solapamiento con #16 — T9 va acá, junto con lo que lo usa
  (T5/T6/T8) / 3. T6 (diálogos) y T8 (aprobaciones) chocan con la invocación
  síncrona — T6/T8 entran como eventos, sin diálogos que esperen". Decisions
  recorded as S7, S8, S9; the task table is re-cut into batch 1, batch 2, and
  the two targets left pending (T7, T10).
- **Evidence — T4's routed set was corrected while delegating (evidence, not a
  requirement change).** The row first read
  "pageUp/pageDown/home/end/ctrl+o". nimterm's own key table
  (`~/.local/share/.../nimterm/docs/src/content/docs/guides/input-and-events.md`,
  "Input widget editing") shows the `InputWidget` binds Home, End, Ctrl-B and
  Ctrl-F for cursor movement, and pi's keybindings do not steal them either
  (pi binds `tui.altScreen.pageUp`/`pageDown` and `ctrl+home`/`ctrl+end`).
  Routing them to the transcript would break text editing to fix scrolling, so
  the routed set is exactly `pageUp`, `pageDown`, `ctrl+o`.
- **Evidence — the delegation incident (the harness, not the task).** The first
  `gentle-ai-worker` for T4 died with the known stall ("stalled for 4 min after:
  bash"): 6 turns, 10 tool calls and ZERO files touched, so the stall was the
  model call and not the command. A bounded rescue was relaunched through
  `subagent_continue`; if it stalls again the task lands inline and the harness
  is reported as unavailable rather than retried into ceremony.
- **Evidence — T4 closed, implemented inline after two dead workers.** The
  routed set is `pageUp`, `pageDown`, `ctrl+o`, decided by the predicate and
  NEVER by the widget's response: nimterm's `TranscriptWidget` scrolls on the
  page keys and still answers `eventIgnored` (its four scroll branches carry no
  `return`, `transcript.nim:424-435`), so a caller trusting `handled` would have
  handed the key to the editor as well. The README's PgUp/PgDn claim was FALSE
  before this task and is true now, and the suite pins both sides of that: the
  widget tree alone does not deliver the key (nimterm's dispatch walks from the
  focused widget up to its parents, and the transcript is a SIBLING of the
  focused input), and the routed key does move the viewport. The resume menu
  keeps precedence for its own paging — `Menu` handles Page Up and Page Down
  (`menu.nim:92,94`), and without that ordering its page keys would have
  scrolled the transcript behind the open menu. The transcript's `copy` action
  used to be dropped silently; it now reaches the clipboard through a sink on
  `TuiState`, which is also what makes the copy observable from a test.
  RED: `tests/tp_tui.nim(319,11) Error: undeclared identifier:
  'transcriptRoutedKey'`, exit 1. GREEN: 118 tests (114 before; the four added
  ones cover the predicate's truth table, the tree's inability to deliver the
  key, the scroll itself, and the copy), 0 FAILED.
- **L8 (verbatim):** "dale corrige antes de arrancar" — answering "¿Querés que
  corrija el mapa con L1/L2/L3 antes de arrancar T3, o preferís que T3 se
  diseñe ya con la vista puesta en L2 y dejamos el mapa para el commit de
  evidencia?". The user chose: correct the map first, then start T3.
- **Correction — the component-shaped family is NOT "OUT of the Lua surface",
  and it decides T3's design.** Evidence: pi's `Component` contract is six
  lines (`packages/tui/src/tui.ts:117`) and codegraph counts 171 callers and
  ~26 implementations for it, pi's own `FooterComponent` among them — so
  `setFooter(factory)` swaps which component owns the slot instead of adding to
  a privileged widget. Neovim shows where the vocabulary lives: `nui.nvim`
  ships `Popup`/`Input`/`Menu`/`Split`/`Layout` as a Lua library over the
  engine's data primitives (`nvim_buf_set_lines` + extmarks + floating-window
  geometry), and its README's own wording is "UI Component Library for
  Neovim". The earlier reading — "a Lua extension cannot construct a Nim
  widget, so the only reachable UI is data into slots" — conflated *constructing
  Nim widgets* with *satisfying the contract*: pi's contract needs no objects,
  only lines. Recorded as S10 and as the levels above; the rows that said OUT
  were rewritten individually rather than as a family, because their owners
  differ (images and autocomplete stay out, the editor and the overlay content
  become L2, the overlay geometry becomes core).
- **L9 (verbatim, the T3 cuts):** "1. ¿Qué hacemos con `ui.status(text)`? —
  Reemplazar por `ui.status(key, text)` / 2. ¿Cuáles slots adyacentes entran en
  T3? — Todos, incluidos notify y title / 3. El footer: ¿slot de texto en L1 o
  caso de L2? — El footer queda del core; su slot llega con L2". Recorded as
  S11; T3 is re-cut into T3a and T3b.
- **Evidence — the three facts that shaped T3 (measured before any code).**
  (1) `ui.status`/`ui.widget` have ZERO production consumers: the only callers
  are four assertions in `tests/spec/ui_spec.lua` plus doc mentions, so
  replacing the signature costs one spec file. (2) `TuiState.statusLine` is
  **write-only** — `openResume` and `resumeSession` assign it and no code reads
  it, so "no sessions to resume" and "cannot resume X" never reach the user
  today; the status bar is where they belong and T3a pins them with a test.
  (3) pi's canonical footer consumer (`custom-footer.ts`) computes its padding
  as `width - visibleWidth(left) - visibleWidth(right)`, which is exactly why
  the footer's slot is L2 and not L1.
- **Evidence — the first stretch closed: T2 + T4 + T3a + T3b as four work-unit
  commits on `main`.** `87c27cd` (T2), `f4a46a4` (T4), `581daca` (T3a) and
  `d064a1d` (T3b), on top of `401a682` (T1, this document). Every task was
  test-first with an observed RED, and the closing gate is 127 tests OK plus 17
  busted successes, with the measurement harness flat (7.203/7.198 ms render at
  5000 entries, RSS 23.4 MB). **Four gates failed along the way and every one
  was the parent's own error, each of a different class** — which is the
  strongest argument this slice produced for keeping the gates: (1)
  `undeclared field: 'chrome' for type tui.TuiState` — the field went onto
  `NeopiScreen` and not its sibling `TuiState`, an incomplete contract change;
  (2) `121 OK / 1 FAILED, footerAt was -1` — the test asserted a rendered
  footer without calling `refreshFooter`, claiming more than the contract
  promises; (3) `tui_bench: the delta did not render` — the harness relied on a
  hand-wired `state.screen`, and removing the duplicated geometry took that
  implicit job with it, so the fix moved the wiring into the single producer
  (`buildScreen`) instead of papering over it; (4) `neopi.hasUI` read nil — a
  Lua stack index, the boolean being set while `-2` was the `ui` table and not
  `neopi`. None of the four was visible by reading the code.
- **L10 (verbatim):** "sigue por aca" — after the first stretch closed, the
  user chose to continue in this session rather than open a fresh one ("ya
  tienes lo aprendido en cache, una sesión nueva sería lo mismo").
- **Correction — T9's line was wrong about `addSource`, and it splits.**
  Reading nimterm's loop settles it: `EventSource`/`addSource` are polled by the
  loop, so they presume a loop that is free. neopi's sink is called from
  *inside* the turn's blocking `evalJson`, so the loop is not running and there
  is nothing to poll: the event vocabulary is adoptable now, the source model
  is ROADMAP #16's. T9a is therefore the dispatch/render ownership and T9b (the
  incremental sync, to retire the per-turn transcript rebuild) is deferred
  behind a dependency decision — dropping that rebuild cleanly needs
  `appendItem` in nimterm, whose `linesValid` is private and whose
  `setTranscript` clears every cache, and bumping the pinned revision is not
  the parent's call to make alone.
- **Evidence — a third dead field, found while scoping T9.**
  `TuiState.streaming` was read by `refreshFooter` and written non-empty by
  **nobody**: production only initialised it to `""` and reset it to `""`, and
  the only thing that ever set it was a test. So the footer's `| working`
  indicator never reached a frame — the same class as `statusLine` (a test
  asserting a field that production never writes, and a README promising the
  behaviour). T9a fixes it by making the field mean what it is read for.
- **Evidence — T9a closed (`1bb3ff5`), and the tooling changed mid-task.** The
  skills' own gap surfaced first: `.codegraph` was reported as Lua-only and the
  language server was not loaded, so the session had been grepping Nim — and
  grepping is what *nearly* hid the bench's dependence on `flushFrame` (it was
  found by breaking it). With the Nim-parsing codegraph fork and nimlangserver
  active, both questions became one call: codegraph listed `flushFrame` with
  "3 callers in `bench/tui_bench.nim`, `src/neopi/tui.nim`" and `feedKeys` with
  2, and `nimCheckFile` returned diagnostics **in seconds instead of a build** —
  it caught a `streaming: ""` left in the constructor that a 60-second build
  would have reported, and a dead `sessionRegistryKey` nobody knew about. Two
  reds were observed in this task, both the parent's: the 131-test run failed on
  `st.inputW.text == ""` and `#neopi.steeringQueue == 1` because the test's
  fake-app helper never focused the input, and nimterm routes keys from the
  focused widget — production does it in `tuiLoop`, so the helper was not
  assembling what it claimed to. The narrow `grep` that missed the constructor
  is also a lesson worth keeping: after a rename, grep the bare identifier, not
  the access pattern.
- **Evidence — T9b closed (`0e976bd`), and the pin arc with it.** The value it
  delivered is not the one that opened the task: the per-turn rebuild replaced
  every transcript item, so it discarded what the items carry — an expanded tool
  collapsed and a pending approval disappeared from the UI, and a test now pins
  that premise before pinning the fix. The full rewrap of a 5000-entry
  transcript, the thing the fork patch removes, costs about 7 ms *per turn*:
  real, and unfeelable. The patch (`nimterm` `800bf7f`: `appendItem`) was pushed
  and verified with `ls-remote` instead of assumed, and bumping the pin exposed
  a reproducibility hole ROADMAP #11 believed closed — nimble keeps the previous
  revision alongside the new one under the SAME version, so `nimblePath` had
  two candidates for the module and the winner was decided by hash ordering
  (`757d0d4f` before `d4c4f347`). `nimble uninstall` cannot fix that (these
  copies arrived as dependencies: `no packages to delete`); the cache now holds
  one copy, chosen by reading `vcsRevision`, and `AGENTS.md` documents the step
  plus the Nim caches that keep naming the removed path. The ambiguity was not
  theoretical: the language server had resolved nimterm to the stale copy and
  lost its context with hundreds of `cannot open file: nimterm` errors when it
  disappeared, while the compiler happened to pick the pinned one.
- **Evidence — T9b's two failed gates, both the parent's, and neither a design
  error.** (1) Inserting the watermark clobbered the `working` field's
  declaration and left its doc orphaned on the new field; (2) four Nim caches
  still named the removed copy and the build died with `cannot open:
  <removed>/nimterm.nim`. Both are the class of thing a build catches and a
  reading does not, which is now the third slice where that sentence holds.
- **Evidence — the pin's acceptance passed from outside the project, and the
  failed attempt was the test's own doing.** `nimble build` on a clone at
  `/tmp/neopi-fresh` (the path the #11 evidence recorded) resolves `800bf7f`
  and produces `build/neopi` (2.96 MB). The first attempt had cloned into
  `build/fresh-clone`, *inside* the project, and died with a `type mismatch` on
  `newExtensibility`; the sources of the two checkouts are byte-identical
  (`diff` is empty) because a nested clone inherits the outer `config.nims`,
  whose `switch("path", thisDir() / "src")` adds the outer `src` to the search
  path — so two copies of the same modules meet under different paths. The
  parent's hypothesis (a shared nimcache, since Nim keys it by target name) was
  **wrong**, and the counter-experiment says so: redirecting the clone's
  nimcache left the failure unchanged. The user's memory pointed at the right
  thing. `AGENTS.md` now says to verify a fresh clone from outside the project,
  which is the only place that check means anything.
- **Open.** Batch 2 continues with T5 (the thinking), T6 (the dialogs) and T8
  (the approvals): T9a and T9b are closed. Two things stay outside the cut: T7
  (the transcript search) and T10 (the standing UX regression gate, whose
  argument is the real regression the harness caught during T3a). Operational
  reminder for the next dependency bump: the `vcsRevision` guard and the Nim
  cache cleanup are in `AGENTS.md`, and neither was theory — the bump this
  slice required produced both failures. A third: verify the fresh clone from
  outside the project, because a nested one inherits the outer `config.nims`.
