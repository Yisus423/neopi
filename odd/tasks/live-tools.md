# live-tools — the tool execution alive during a run

ROADMAP **#16**, mechanism only (the user's call: "Mecanismo primero"). One
injected **pump** hook, called from every blocking wait, keeps the TUI alive
while a tool runs AND during a thinking pause. The approval flow (the TUI UX
slice's T8) is NOT in this slice, and the async state machine (option C of the
study) is noted at the end of the ROADMAP.

## Specs

- **S1** (the request, verbatim): "empecemos con #16"
- **S2** (why it is next, verbatim, from the previous slice's Log): "creo que
  deberíamos mover #16 al proximo en vez #19, creo que es lo que separa a neopi
  de un juguete a una herramienta, podríamos al final revisar en engram cuantas
  features o cosas han sido bloqueadas o degradadas por #16" — the list that
  tail asks for is in the Verified basis below.
- **S3** (the roadmap item's own words, verbatim, `ROADMAP.md:52`): "bash runs
  frozen inside the turn's chunk (the threads/async gap pi and nimlet solve);
  the abort during a thinking pause waits for the next delta."
- **S4** (the mechanism, the user's choice, verbatim): "Vamos con A, con ese
  slice chiquito solucionamos el problema de hoy." — the option A the study
  offered: a pump hook injected into the blocking waits
  (`pump(): bool`, `true` = abort requested), called where today nothing runs.
- **S5** (the scope, verbatim): "Mecanismo primero." — the approval flow does
  not ride this slice; it stays in the ROADMAP as its own work.
- **S6** (the deferred shape, verbatim): "C podemos anotarla al final del
  roadmap, cuando haya tiempo capaz me ponga a parchear nimterm para
  mejorarlo" — the async state machine becomes a ROADMAP item, and nimterm's
  limits are the reason it would want a patch.
- **S7** (the nimterm write-up, verbatim): "las issues,problemas y diagnosticos
  que has encontrado sobre nimterm me gustaria que los documentaras y
  comitearas en la carpeta de su proyecto" — a doc IN the nimterm checkout,
  committed there.
- **S8** (the evidence discipline, verbatim): "¿estas seguro de lo que dices?,
  ¿comprobaste eso con engram?" and "lee ambos, yo te sugeriria leer nimterm
  desde ~/proyectos/nimterm, ambos con codegraph para cerlo todo y sin cortar
  el output" — every claim in this record carries `path:line` evidence, read
  from the checkouts, not from a summary.

## Verified basis (2026-11-05)

### The freeze, in neopi (`path:line`)

1. **The turn is one synchronous `lua_pcall`**, entered from nimterm's action
   callback: `handleTuiAction` → `sendTurn` (`src/neopi/tui.nim:1545-1555`) →
   `evalJson` (`:1521`) → `lua_pcall` (`src/neopi/lua.nim:309-317`).
2. **During the stream the App is pumped by hand** from the stream sink, once
   per text/thinking delta: `tuiOnEventCB` (`src/neopi/tui.nim:1117-1134`) calls
   `pumpApp` (`:762-772`, `while state[].app.step(0): discard`). No delta ⇒ no
   pump: that is the thinking pause (S3).
3. **The tool does not go through `provider.invokeTool`**: the Lua exposure runs
   ONE model turn (`maxSteps = 1`, `src/neopi/expose.nim:311,437`) and
   `runTurn` checks the cap BEFORE executing tools
   (`src/neopi/provider.nim:286-295`), so the side effect comes from the Lua
   loop: `executeCall` (`runtime/agent.lua:232-281`) →
   `pcall(tool.execute, effective)` (`:270`) → `runtime/tools.lua:135`
   `neopi.process.run` → **`execCmdEx`** (`src/neopi/process.nim:45-68`), which
   waits for the child on the same thread. Nothing pumps there: the whole App
   is frozen until bash exits.
4. **Esc vs Ctrl+C** (verified against the code AND `odd/interactive-5b`
   memory): Esc sets `abortRequested` only while `working`
   (`src/neopi/tui.nim:2029-2030`) and the sink answers `false` after the next
   dispatched delta (`:1132-1134`); Ctrl+C **leaves** (`:2032-2033`,
   `app.running = false`) — the escape hatch the F3 fix left deliberately.
   Ctrl+C is not part of the `frCancelled` contract, and during bash it cannot
   even be dispatched.
5. **chronos is the async runtime, and nothing joins it to the TUI**: 0 files
   in `src/`+`runtime/` mention `asyncdispatch`; chronos lives behind `waitFor`
   in the provider layer (`src/neopi/openai_compat.nim:265-271`) and in the
   transport (`src/neopi/wire.nim:113-137,147`). `provider.nim` has no chronos
   import. No `std/thread`, `{.thread.}` or coroutine anywhere in `src/` or
   `runtime/`.
6. **The re-drive a deferred design would need already exists**:
   `drainSteering` (`runtime/agent.lua:298-309`) reads `neopi.steeringQueue`
   after the assistant response, before that turn's tools (`:353-357`), and the
   TUI queues while working (`src/neopi/tui.nim:736-745,2151-2156`).
7. **Test seams**: `tests/tp_tui.nim` drives turns through a fake backend/App
   (`:64-101`), with Ctrl+C/Esc (`:1411,:1439`), the working frame (`:1766`)
   and the steering queue (`:1828`). Bash is only exercised with `pwd`/`false`
   (`tests/tp_tools.nim:179-192`). **No test runs a long tool or asserts App
   responsiveness while a tool runs** — that is the gap this slice has to fill.

### The nimterm contract (checkout `/home/jesus/proyectos/nimterm`)

The decisive constraints, all read from source:

1. **No reentrancy guard.** The complete `App` type has no `inStep`/`stepping`
   field (`src/nimterm/app.nim:25-41`) and `dispatch` calls the callback
   directly (`:163-168`). A nested `step` pops and dispatches another event
   recursively while the outer dispatch is active; nothing documents or tests
   it as safe. **neopi already relies on it** (the sink pumps per delta), and
   option A extends that reliance — this is the slice's item-4 risk.
2. **`step(timeoutMs=0)` processes at most one event**: queue pop → source poll
   → blocking backend read → source poll → dispatch → flush
   (`src/nimterm/app.nim:213-237`). `idleTimeout` is `pollIntervalMs` (**16 ms**)
   when some source polls, `-1` (indefinite) otherwise (`:93-96`), reduced to
   the earliest timer (`:86-91`); `run` calls `step(idleTimeout)` (`:239-252`).
3. **`EventSource` is the documented extension point for a long producer**
   (`docs/src/content/docs/guides/application-loop.md:91-111`), but its
   `poll(): seq[UiEvent]` is called **synchronously** by `collectEvents`
   (`src/nimterm/app.nim:63-75`): a blocking poll blocks the UI, and a source
   that raises is closed and removed.
4. **The backend selects only stdin and its own wake pipe**
   (`src/nimterm/platform_posix.nim:129-140`): there is no API to poll an
   arbitrary child FD.
5. **No thread-safe repaint.** The queue's mutex is the only synchronization
   (`src/nimterm/queue.nim:1-20`); `invalidate`/`flush`/`render` are
   unsynchronized, and no cross-thread `App.post` contract is documented.
6. **A copied `App` is a mixed value/reference copy**: `backend`, `queue`,
   `root`/`focus` and the source objects are shared; `running`, `dirty`, the
   frame, `timers`, `sources` and `lastPresent` belong to the copy
   (`src/nimterm/app.nim:25-41`). neopi copies the app (`state.app = app`)
   before `wireApp` (`src/neopi/tui.nim:2181-2185`), so **anything added to the
   original after the copy never reaches the pump's app** — a limit this slice
   must not trip over (option A adds no source and no timer).

### pi's mechanism (checkout `/home/jesus/proyectos/pi`)

pi does not solve this asynchronously-adjacent to the UI: **its tool never
blocks the loop**.

1. The bash tool is an `async` function that AWAITS the child:
   `exec: async (command, cwd, {onData, signal, timeout, env})`
   (`packages/coding-agent/src/core/tools/bash.ts:99`), with `onData` streaming
   the output through `appendText` → `options.onChunk(text)`
   (`packages/coding-agent/src/core/bash-executor.ts:76-104`).
2. The child is awaited as a Promise, never polled on a blocked thread:
   `waitForChildProcess` (`packages/coding-agent/src/utils/child-process.ts:49`)
   resolves on `exit`/`close` and even defers `EXIT_STDIO_GRACE_MS` so a tail
   still arriving is not truncated.
3. **Abort kills the whole process tree**: "Handle abort signal by killing the
   entire process tree" (`packages/coding-agent/src/core/tools/bash.ts:141-143`),
   `SIGTERM` then `SIGKILL` if the child did not exit
   (`packages/coding-agent/src/core/exec.ts:79-83,88-92`), and the result
   returns the partial output with `cancelled: true`
   (`bash-executor.ts:122-128,137-145`). A signal-killed shell reports
   `128 + signal` as its exit code (`bash.ts:155-158`).
4. **The UI paints because the loop is free**: one Node event loop, no threads,
   and the repaint is coalesced and throttled — `requestRender` schedules
   through `process.nextTick`, `scheduleRender` holds the frame to
   `MIN_RENDER_INTERVAL_MS` with a `setTimeout`
   (`packages/tui/src/tui.ts:1033-1086`).

**The translation**: neopi cannot copy pi's `await`. Its loop is a synchronous
`lua_pcall` inside the App's callback, so the equivalent is **cooperative
pumping**: the blocking waits hand control back to the App between polls.

### Blocked, degraded or deferred by #16 (S2's list)

| Where | What it says |
|---|---|
| `ROADMAP.md:52` | "bash runs frozen inside the turn's chunk"; the abort during a thinking pause waits for the next delta; the approval flow rides #16 |
| `ROADMAP.md:53` | `/model`'s catalog refresh "still freezes the loop until #16 lands" |
| `odd/tasks/tui-ux.md:146-150` | the manual pumping "inherits the freeze"; the event-source model deferred to #16 |
| `odd/tasks/tui-ux.md:175,193-197,232-234` | the approval deferred; synchronous handlers cannot wait for the user; awaiting handlers are "the same wall" |
| `odd/tasks/tui-ux.md:356-361` | `EventSource`/`addSource` excluded because the sink runs inside the blocked `evalJson` |
| `odd/tasks/tui-ux.md:453-459` | T8 (the approval flow) explicitly "deferred to #16" |
| `odd/tasks/tui-nimterm.md:79-82,224-227` | tool execution "stays frozen during a run" (line 227 still calls it #14 — stale numbering) |
| `odd/tasks/provider-select.md:6-7,32,106-107` | the non-blocking model refresh deferred, waits for #16 |
| `odd/tasks/session-commands.md:53-58` | #16 needed only for an awaited/blocking `ctx.ui.input` |
| `odd/tasks/interactive-5b.md:67-69,132-136`, `odd/tasks/picker-search.md:80-82`, `odd/tasks/tui-async.md:68-69,106-109` | the same wall, not tagged #16 |

## Design — option A: the pump seam

**The contract (frozen here so the three units can be written against it):**

- A `Pump` is a plain injected closure: `proc (): bool` — `true` means *abort
  requested*. It is **nil-safe**: nil (print mode, headless, tests that do not
  care) means "never abort, never pump", and every call site must work with it.
- The pump is called **between polls**, never inside a callback that can
  re-enter: the child wait calls it after each non-blocking read; the wire's
  read loop calls it after each poll that produced no complete chunk.
- The pump owns **no policy**: it does not decide what an abort means for the
  turn. It reports the request; the call sites turn it into a killed child and
  an aborted result.

**The three call sites:**

1. **The child (`src/neopi/process.nim`)** — replace `execCmdEx` with a
   non-blocking spawn: `startProcess` + non-blocking pipes + `waitpid(WNOHANG)`
   (the shape `bench/` already uses for a pty-free child is not enough; this is
   `posix_spawn`/`fork` + `setBlocking(handle, false)`), reading what is
   available on every turn and emitting it as output. On `pump() == true`: kill
   the tree (`SIGTERM`, a short grace, then `SIGKILL`, pi's shape), keep the
   partial output, and report the result as aborted.
2. **The stream's wait (`src/neopi/wire.nim` / `src/neopi/openai_compat.nim`)**
   — the read loop calls the pump after a poll that yielded no complete chunk.
   This is the thinking-pause fix (S3): the App keeps rendering while the model
   says nothing. **Constraint: no TUI type may leak into the provider layer** —
   the hook travels as a closure on the request/transport, exactly like the
   existing sink and transport injections.
3. **The TUI (`src/neopi/tui.nim`)** — installs the pump: it is `pumpApp`
   (which already returns `abortRequested`) plus the presentation the sink
   already does, so the tool's streamed output lands in the transcript as it
   arrives and Esc keeps meaning "abort the turn".

**Abort semantics (the user-visible contract, to be tested):**

- **Esc during a tool**: the child is killed, the tool result is an error
  ("aborted"), the turn ends (no further model call), the partial transcript
  stays, and the composer is usable again — the same shape the stream's abort
  already has.
- **Ctrl+C during a tool**: neopi leaves (unchanged, S3 of the roadmap row is
  not about this) AND the exit path kills the running child — otherwise a
  `sleep 600` outlives the UI.
- **Idle**: no pump runs, no behaviour changes.

**What stays out (explicitly):**

- The **approval flow** (S5): it needs a producer (which tools require approval)
  and a waiting semantic the callback shape does not have yet.
- **Option C**, the async state machine (S6): noted at the end of the ROADMAP.
- **The App copy** (nimterm limit 6): option A adds no source and no timer, so
  the copy is not touched. If a future unit wants `EventSource`, it must add it
  before the copy.
- The blocking `execCmdEx` call in `src/neopi/tools.nim:218,235`: it has no
  production caller today (only `tests/tp_tools.nim`); the slice leaves it
  alone unless T2 shows it is on the path.

## Tasks

- **T1** (S3, S4) — The pump seam: the `Pump` type + the nil-safe call contract,
  with unit tests over a fake pump. Route: parent inline (this is the frozen
  contract the other two units write against).
- **T2** (S3, S4) — The non-blocking child in `src/neopi/process.nim`:
  streamed output, `pump()` between reads, kill-the-tree on abort, the partial
  result as aborted, and `neopi.process.run`'s shape unchanged for callers.
  Route: worker (`## Allowed edit surfaces`: `src/neopi/process.nim`,
  `tests/tp_process.nim`).
- **T3** (S3, S4) — The stream's wait pumps: the read loop calls the pump after
  a poll with no complete chunk, hook injected as a closure, no TUI types in
  the provider layer. Route: worker (`src/neopi/wire.nim`,
  `src/neopi/openai_compat.nim`, `tests/tp_openai_compat.nim`,
  `tests/tp_wire.nim` if it exists).
- **T4** (S3, S4) — The TUI wiring: install the pump, render the tool's
  streamed output in the transcript, the Esc-kills-the-tool semantics, and the
  Ctrl+C exit path killing the child. Route: parent inline (integration +
  the reentrancy risk).
- **T5** (S3, S4) — The pty/E2E proof over the real binary: a long command, the
  frame alive during it, Esc during it, Ctrl+C during it, and the session JSONL
  as the verdict. Route: `gentle-ai-verify` (independent, Risk item 4).
- **T6** (S7) — The nimterm write-up in `/home/jesus/proyectos/nimterm` +
  commit there: the six limits of the Verified basis, each with `path:line`.
  Route: parent inline (the user asked for it in that repo).
- **T7** (S2, S6) — The ROADMAP: option C noted at the end as its own item, the
  #16 row closed with this record, and the Evidence section below filled with
  the commits. Route: parent inline.

## Evidence

_(filled as the tasks land: commit → task → the check that passed)_

## Known limits

_(filled at closure)_

## Log

- **L1** (2026-11-05, the request, verbatim): "empezemos con #16"
- **L2** (the user's challenge to the study, verbatim): "Mecanismo primero.
  ¿estas seguro de lo que dices?, ¿comprobaste eso con engram?, que yo recuerde
  esc era para cortar el stream y ctrl c era para salir, hace tiempo que
  cambiamos asyncdispatch por chronos, creo que fue cuando nos deshicimos de
  nimgent, preferiria revisar las memorias antes" — the claims were re-checked
  against `src/neopi/tui.nim:2029-2033` and Engram (`odd/interactive-5b`), and
  the async framing was corrected: chronos IS the runtime; what is missing is a
  shared dispatcher with nimterm. Both corrections are in the Verified basis.
- **L3** (the accesses, verbatim): "lee ambos, yo te sugeriria leer nimterm
  desde ~/proyectos/nimterm, ambos con codegraph para cerlo todo y sin cortar
  el output"
- **L4** (the decisions, verbatim): "Vamos con A, con ese slice chiquito
  solucionamos el problema de hoy. C podemos anotarla al final del roadmap,
  cuando haya tiempo capaz me ponga a parchear nimterm para mejorarlo, las
  issues,problemas y diagnosticos que has encontrado sobre nimterm me gustaria
  que los documentaras y comitearas en la carpeta de su proyecto"
