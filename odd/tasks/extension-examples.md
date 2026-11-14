# extension-examples — ROADMAP #19: porting pi's examples onto the Lua surface

The bar AGENTS.md sets for the frozen surface: "porting pi's
`examples/extensions/*` onto `neopi.on`/`fs`/`process`/`provider`/`session`/
`registerTool`/`registerCommand`/`ui` is the 'real consumers exist' bar … it
proves the API and finds its gaps, in Lua, without touching the core". It is
also the first item of the release path (ROADMAP #35), because the Lua surface
is the differentiator and a consumer from OUTSIDE the runtime is what tests it.

## Specs

- **S1** (the item, verbatim from the ROADMAP): "Porting pi's
  `examples/extensions/*` onto `neopi.on`/`fs`/`process`/`provider`/`session`/
  `registerTool`/`registerCommand`/`ui` is the 'real consumers exist' bar
  AGENTS.md sets for the frozen surface — it proves the API and finds its gaps,
  in Lua, without touching the core. The surface it would have to work against
  was settled first (item 20)".
- **S2** (the user's call to start it, verbatim): "dale, sigamos".
- **S3** (the release context, the user's own call): the audit comes FIRST in
  the path to `0.1.0-alpha` (ROADMAP #35), so this record is what stands between
  the surface being *used by the runtime* and the surface being *proved by an
  outsider*.

## Verified basis

**pi's examples** (read 2026-11-12, `~/proyectos/pi/packages/coding-agent/examples/extensions/`):
about **70 files plus subdirectories, ~10,400 lines of TypeScript**, grouped by
the README into lifecycle/safety, custom tools, commands & UI, git, prompt &
compaction, resources, messages, session metadata, custom providers and
external dependencies. Porting ALL of them is not one slice; the README is the
API map and the ports are chosen from it.

**pi's extension API, from the repo's own snippet and its README**:
- `pi.on(event, handler)` — lifecycle events (`tool_call`, `session_start`,
  `project_trust`, `model_select`, `user_bash`, `input`, `resources_discover`,
  …); a handler returns `{block: true, reason}` to stop a call.
- `pi.registerTool({name, label, description, parameters,
  execute(toolCallId, params, signal, onUpdate, ctx) → {content, details}})`,
  where **`details` is PERSISTED in the session** ("State persistence via
  details", and the README's own example reconstructs state from
  `ctx.sessionManager.getBranch()`).
- `pi.registerCommand(name, {description, handler(args, ctx)})`.
- `ctx.ui.*`: `confirm`, `select`, `notify`, `setStatus`, `setWidget`,
  `setEditorText`, `setFooter`, `setHeader`, `setHiddenThinkingLabel`,
  `setWorkingIndicator`, `setEditorComponent` (modal/rainbow editors, overlays).
- Session metadata: `ctx.sessionManager.getBranch()`, `setSessionName`,
  `setLabel`, `appendEntry`, `registerEntryRenderer`,
  `registerMessageRenderer`.
- `pi.sendUserMessage()`, `pi.events` (inter-extension), `ctx.shutdown()`,
  `reload_runtime`; providers: `registerVirtualModel` and whole custom
  providers; prompt: `systemPromptAppend`, `resources_discover`; custom
  compaction.

**neopi's surface, exactly as the runtime assembles it** (`runtime/init.lua`,
plus the Nim-side table from AGENTS.md):
- `neopi.registerTool(name, description, schema, execute)` — **positional**, and
  `execute(args: table) → string`.
- `neopi.registeredTools()`, `neopi.registerCommand(name, description,
  execute)`, `neopi.registeredCommands()`, `neopi.runCommand(input)`.
- `neopi.on`, `neopi.fs` (`read`/`write`/`mkdir`/`list`), `neopi.process`
  (`run`), `neopi.provider` (`generate`/`stream`), `neopi.session`, `neopi.ui`
  (`status`/`widget`/`input`), `neopi.emit`, `neopi.steeringQueue`.

### The gaps already visible (before writing a line)

1. **No tool `details`, so no state persistence.** pi's tools return
   `{content, details}` and `details` rides the session entry, which is how
   `todo.ts` and `tic-tac-toe.ts` survive a turn and a fork. neopi's `execute`
   returns a plain string: the result's TEXT is all that exists. This is the
   biggest gap and the one a real extension hits first.
2. **No `onUpdate`.** pi streams a tool's partial output into its row while the
   tool runs; neopi's `execute` is a plain call with no way to report progress.
3. **No `signal`.** pi hands the tool an `AbortSignal`; neopi's `execute` has no
   abort handle at all (the abort exists, but only around the wire and the child
   process).
4. **No tool `label`.** pi's tools carry a human label for the TUI's row; neopi
   has the name and the description only.
5. **The context is the globals** (`neopi.ui`, `neopi.session`) instead of a
   per-call `ctx` — a shape difference a port can adapt, but it decides whether
   two extensions can hold different state.
6. **CORRECTED while reading the specs — `ctx.ui` is much CLOSER than this list
   first claimed.** `neopi.ui` already carries `header` (pi's `setHeader`),
   `status`, `widget` WITH pi's two placements, `notify`, `working`, `title`,
   and — the pair that matters for the safety examples — **`select` and
   `confirm`** (`tests/spec/ui_spec.lua` proves them). This record's first
   version listed the surface from AGENTS.md's one-line summary and got it
   wrong; the SPEC is the authority, and that is the audit correcting its own
   author before a line of port was written. What is still missing here is
   `setEditorComponent` (modal/rainbow editors, overlays) and the themed COLOUR
   argument pi's `setStatus` takes.
7. **The dialogs are CALLBACKS, not awaits — and that is the first real wall.**
   pi's handlers are async, so `permission-gate.ts` reads `await
   ctx.ui.confirm(...)` INSIDE its `tool_call` handler and returns `{block:
   true}` when the answer is no. Lua cannot wait mid-handler, so neopi's
   `confirm`/`select` take an answer callback (the shape #21 settled on for
   every dialog). A port therefore cannot be a transliteration: the block has to
   happen FROM the callback, and whether that is even possible depends on what
   the `tool_call` hook allows at the moment it is asked — the next thing this
   audit has to read.
8. **Session metadata is absent in neopi**: no `setSessionName`, `setLabel`,
   `appendEntry`, and no renderer registration; `/resume` lists sessions by their
   file and their first text.
9. **Providers are closed**: the table is built in Nim and an extension cannot
   add an entry or a virtual model (a known deferral of #23, S5).

## Design

- **The ports are chosen to cover the SURFACE, not the catalogue**: every
  capability neopi publishes gets at least one example that uses it, and the
  examples that need something neopi does not have are ported AS FAR AS THEY GO
  with the wall named — that wall IS the audit's deliverable.
- **Each port is a Lua spec** under `tests/spec/` (the suite that already runs
  through `./build/busted_main`), because a spec is what keeps the claim honest
  after the fact, and an **example file** under `examples/extensions/` for a
  human to read and load. A port with no spec is a blog post.
- **No core edits in this slice.** When a port needs a gap filled, the port stops
  and the record names it: sealing the surface with its first consumer's
  convenience is how the surface stops being general. Filling a named gap is its
  own slice with its own record.
- **The gap list is the deliverable**, and it is what decides whether the release
  promise ("the differentiator is Lua") holds.

### The port list

| # | pi's example | neopi capability it exercises | expected wall |
|---|---|---|---|
| P1 | `hello.ts` | `registerTool` + `registeredTools` | the args/result SHAPE (positional vs object; the result's `details`) |
| P2 | `status-line.ts` | `ui.status` | `ctx.ui.setStatus`'s themed colors |
| P3 | `widget-placement.ts` | `ui.widget` above/below | — |
| P4 | `commands.ts` | `registerCommand` + `runCommand` | — |
| P5 | `permission-gate.ts` | `on("tool_call")` + block | `ctx.ui.confirm` (neopi has `ui.input`) |
| P6 | `protected-paths.ts` | `on("tool_call")` + block on a write | — |
| P7 | `event-bus.ts` | `emit` | `pi.events`: is there a LISTENER (not just an emitter)? |
| P8 | `session-name.ts` | — | `setSessionName` has no home in neopi |
| P9 | `input-transform.ts` | `on("input")` | does the `input` hook rewrite, and does it see mid-stream input? |
| P10 | `todo.ts` | `registerTool` + a command + state | `details`, i.e. gap 1 |

## Tasks

| ID | What | Specs | Route | Commit |
|---|---|---|---|---|
| E1 | This record: the API maps and the gap list, before any port | S1-S3 | inline | |
| E2 | The ports that MAP: P1-P4, each with its spec and its example (`tests/spec/extensions_spec.lua` + `examples/extensions/*.lua`) | S1 | inline, RED→GREEN | |
| E3 | The gate ports: P5-P6 — read what `neopi.on("tool_call")` allows FIRST, because the wall of gap 7 is decided there. **Read, and the wall is exact**: `hooks.nim` collects a `HookOutcome` (`allowed`/`reason`/`patched`/`payload`) SYNCHRONOUSLY from `emit`, so a `tool_call` handler must DECIDE BEFORE IT RETURNS, while neopi's dialogs answer in a CALLBACK. P5 as written is therefore impossible; the honest port is a POLICY the handler consults (set earlier, by a command) and the interactive variant is the wall | S1 | inline, RED→GREEN | |
| E4 | The ports that hit a WALL: P7-P10 — TWO of them turned out to map once the hook contract was read (the bus, the input rewrite) and two are walls, each pinned by a spec that asserts the absence | S1 | inline, RED→GREEN | `test(extension-examples): the first four ports of pi's examples, and the gap map` — `2a8990d` (E2) |
| E5 | The gap list as the audit's result + the ROADMAP's item + close | S1-S3 | inline | `docs(extension-examples): the wall the audit found, and what neovim does instead` — `d46c8e5` (E3) + the commit that carries this section |

### E3's wall, in one paragraph

pi's `permission-gate.ts` awaits `ctx.ui.confirm` INSIDE its `tool_call`
handler and returns `{block: true}` when the answer is no. In neopi the hook's
outcome is a VALUE returned synchronously to `emit` (`src/neopi/hooks.nim`:
`HookOutcome` with `allowed`, `reason`, `patched`, `payload`), and the dialogs
answer through a CALLBACK (the shape #21 settled on: `neopi.ui.confirm(title,
detail, function(answer) ... end)`). Both halves are deliberate and neither is
wrong; together they mean **an extension cannot ask a question and act on the
answer inside the same hook pass**. That is the first pi pattern the surface
cannot express, and it is worth more than the whole list above it: it is the
reason the async question is now a real one instead of a taste (ROADMAP,
Deferred: "An async API for Lua extensions").

## Evidence

The gate ran with `PATH="$HOME/.local/share/grabnim/current/bin:$PATH"` and
`TMPDIR="$HOME/tmp-nim"`.

- **E1/E2** — the audit's specs are NOT RED-first, and this record will not
  pretend they were: they assert what the surface ALREADY does, so the honest
  RED is the one E1 paid — the gap map above was **WRONG about `neopi.ui`**
  (it listed the surface from AGENTS.md's one-line summary, while
  `tests/spec/ui_spec.lua` carries `header`, `status`, `widget` with pi's
  placements, `notify`, `working`, `title`, and the `select`/`confirm` pair).
  The correction is written where the error was, in the gap list, because the
  audit correcting its own author before a line of port is the point.
- GREEN: `./build/busted_main tests/spec` → **26 successes / 0 failures / 0
  errors / 0 pending** (22 before this slice; the four ports are the four new
  successes).
- The four ports that MAP, each with its spec and its example file:
  `hello.lua` (`registerTool` + `registeredTools`), `status-line.lua`
  (`ui.status`), `widget-placement.lua` (`ui.widget`, pi's two placements,
  with an unknown placement refused), `commands.lua` (`registerCommand` +
  `runCommand`, and the args being the rest of the input).
- **E3/E4** — the hook contract read (`hooks.nim` + `expose.nim`) turned two of
  the four remaining ports from walls into MAPS, and pinned the walls as specs:
  `./build/busted_main tests/spec` → **35 successes / 0 failures** (29 after the
  four mapped ports, plus the six of `hook_bus_spec.lua`). What came out:
  - **the inter-extension bus already exists**, because `on` takes any event
    name and `emit` returns `{allowed, reason, patched, payload}` — richer than
    pi's `pi.events`, which only publishes;
  - **the input transform works** (the `!{cmd}` expansion of `inline-bash.ts`
    is a handler returning the rewritten table);
  - **the permission gate ports HALF**: the verdict and the reason do, the
    ASKING does not (E3's wall);
  - **two walls are pinned**: a tool's result has no `details` to carry state
    (pi persists it), and a session cannot be named (`setSessionName`,
    `setLabel`).
- The audit's OUTPUT, which is what #19 was for: the gaps are no longer an
  opinion. The tool `details` gap goes to the ROADMAP as its own item; the
  async API is the Deferred entry it reopened; the session metadata, the
  editor component and the provider registration are named but unranked.

## Log

- **L1** (the item, verbatim, from the ROADMAP): "Porting pi's
  `examples/extensions/*` onto `neopi.on`/`fs`/`process`/`provider`/`session`/
  `registerTool`/`registerCommand`/`ui` is the 'real consumers exist' bar
  AGENTS.md sets for the frozen surface — it proves the API and finds its gaps,
  in Lua, without touching the core."
- **L2** (the call to start it, verbatim): "dale, sigamos" — after the user's own
  read of the release path: "lo que lo diferencia que es la extensión por lua
  deja mucho que desear", which is exactly what this audit is for.
