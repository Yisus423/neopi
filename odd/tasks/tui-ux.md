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
| Custom editor component (`modal-editor`, `rainbow-editor`) | any widget can be the editor | hardcoded `InputWidget` | **does NOT go into the Lua surface** (Lua cannot draw a widget) | OUT (escape: fork patch / core feature) |
| Anchored overlays with margins, offsets, animation (`ctx.ui.custom({overlay:true})`) | `Stack` (same rect) + `modal` + hit routing; no anchor/margin engine | the resume `Menu` floats above the input by hand in `paint` | **does NOT go into the Lua surface** | OUT (escape: a core custom widget) |
| Borders / panels / cards (ROADMAP #13 "the widget borders") | `Panel`, `Card`, `Menu(bordered)` | the TUI uses none; only a literal `─` rule | decide the chrome | core |
| Image component | not present | not present | — | OUT |
| Editor autocomplete (`addAutocompleteProvider`) | not present (`Menu` exists, no completion hook) | not present | — | OUT / fork |
| Multi-question with a tab bar (`questionnaire`) | `QuestionWidget` is one question | not present | — | OUT (or chained questions) |

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
| T1 | The study: this document (read-only, no source line) | S1, S3, S5, S6 | inline | `docs(tui): the UX map and the slice targets` |
| T2 | The theme: the TUI paints through `setTheme(compileBuiltinTheme(...))` chosen from `detectDepth()` + `prefersLightBackground()`, with the pure selection extracted so it is testable | S3, S7 | inline | `feat(tui): the theme reaches the transcript and the markdown` |
| T4 | The transcript keys and the mouse with the editor still focused: pageUp/pageDown/home/end/ctrl+o routed to the transcript, and the `copy` action (drag selection + clipboard) | S3, S7 | worker | `feat(tui): the transcript answers page keys and copy while the editor holds focus` |
| T3 | The chrome: a header area, a keyed status bar with clearing, widgets with placement, and an N-row footer in `NeopiScreen` — the slot vocabulary this slice exists to settle | S4, S7 | worker | `feat(tui): the layout grows a header, a status bar and placed widgets` |

**Batch 2 — the plumbing and the events that need it (S8, S9):**

| ID | Task | Spec | Route | Commit |
|---|---|---|---|---|
| T9 | The plumbing: `addSource`/`post`/`AgentUiEvent` replace `flushFrame`/`feedKeys`/`drainGapKeys`/`applySession`-per-turn; the turn posts agent events instead of pumping frames by hand | S8 | worker | `refactor(tui): the agent drives the loop through the event source` |
| T5 | The thinking: the reasoning deltas reach the transcript as `ueThinkingDelta` and the collapsed label becomes the pi-shaped one | S8 | worker | `feat(tui): the reasoning deltas render as the collapsed thinking item` |
| T6 | The dialogs: `neopi.ui.select` / `neopi.ui.confirm` as **events** — the question renders and its answer arrives through the event source, with no handler blocking on a wait | S8, S9 | worker | `feat(ui): the extension dialogs land on nimterm's question widget` |
| T8 | Approvals: the transcript's `approval` action bridged to the `tool_call` verdict as an event, not a synchronous prompt | S8, S9 | worker | `feat(tui): the tool gate can ask the user` |

**Pending the user's word (not cut either way):**

| ID | Task | Spec | Route | Commit |
|---|---|---|---|---|
| T7 | Transcript search: `setSearch`/`nextSearch`/`clearSearch` bound to a search mode. It is the same family as T4 (transcript keys with the editor focused) and could fold into it | S3 | worker | `feat(tui): the transcript search mode` |
| T10 | The UX regression gate: canvas + FakeBackend assertions over the chrome, extending `bench/tui_bench.nim`. ODD requires checks per task regardless; this task is the standing gate, not a substitute | S1 | inline | `test(tui): the interface has a regression gate` |

Not in this slice, recorded so nobody re-derives them: the custom editor
component, anchored/animated overlays, images, autocomplete, the tab-bar
questionnaire (all OUT of the Lua surface per S4), and the terminal title
(needs an OSC 2 fork patch or a core write — no consumer yet).

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
  plus the explicit OUT list.
- **L7 (verbatim, the scope cut):** "1. ¿Qué ancho le damos a este slice? —
  El primer tramo: tema, teclas/mouse, y el chrome / 2. T9 (la plomería del
  event source) y su solapamiento con #16 — T9 va acá, junto con lo que lo usa
  (T5/T6/T8) / 3. T6 (diálogos) y T8 (aprobaciones) chocan con la invocación
  síncrona — T6/T8 entran como eventos, sin diálogos que esperen". Decisions
  recorded as S7, S8, S9; the task table is re-cut into batch 1, batch 2, and
  the two targets left pending (T7, T10).
- **Open.** Two things still outside the cut: T7 (the transcript search — the
  cheapest place for it is inside T4's batch) and T10 (the standing UX
  regression gate). And the commit standing: the work-unit commits assume the
  repository's own convention (slices land on `main`); the parent session does
  not commit without the user's word.
