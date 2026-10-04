# ARCHITECTURE

neopi is two layers: the CORE (Nim, the mechanism) and the RUNTIME (Lua,
shipped with the binary, user-modifiable). The core exposes primitives; the
runtime composes them into the agent. This doc is the layer map and the
honest record of the design decisions.

## The two layers

| Layer | Where | Role |
|---|---|---|
| CORE | `src/neopi/*.nim` + `src/neopi.nim` | The mechanism: provider, hooks, Lua, fs/process, session, tools, exposures, the print mode |
| RUNTIME | `runtime/*.lua` | The policy: the loop, the tools, the request shape — user-modifiable |

## The core modules

| Module | Role |
|---|---|
| `provider.nim` | The anti-corruption layer over nimgent: `generate`/`stream`/`toolCall`, neopi-owned types and exceptions; nimgent types never leak |
| `hooks.nim` | The hook bus: `neopi.on` from Lua, `emit` with block/rewrite from return values, pcall containment (a handler error aborts only that handler) |
| `lua.nim` | The LuaJIT 5.1 FFI bindings: macro-only 5.1 names wrapped Nim-side (`lua_pop`, `lua_pushcfunction`, `lua_getglobal`/`setglobal`, `luaUpvalueIndex = luaGlobalsIndex - i`); selective lib opening — ffi/io/os/debug/jit closed; the loadlib closure (`package.loadlib = nil`, C loader removed) |
| `fs.nim` | The confined fs primitives (`neopi.fs`: read/write/mkdir/exists/list) + `resolveConfined`, the one confinement source of truth shared with the agent tools |
| `process.nim` | The spawn-per-call process primitive (`neopi.process.run`): `process_run` hook (block/rewrite), then `execCmdEx` in the workspace root |
| `extensibility.nim` | The assembly: hook bus + provider/session exposures + confined fs/process on one interpreter (`newExtensibility`); `loadUserConfig` loads `.neopi/init.lua` the nvim way (package.path + loadScript, a failure raises LuaError) |
| `session.nim` | The session tree: append-only JSONL, id + parent, the active branch, `navigateTo` (branch in place), the torn-tail rule |
| `tools.nim` | The Nim agent tools (read/write/edit/bash) over `resolveConfined`; failures raise model-facing messages |
| `expose.nim` | The Lua exposure of provider/session: `neopi.provider` (generate/stream/setScripted) and `neopi.session` (append/history/navigate); `stopReasonOf` maps `frCancelled` → "aborted" |
| `tui.nim` | The TUI: the pure render layer (wrapLine/lineColor/transcriptLines/usageTotals/footerLine/visibleRange/selectLines), the three components (transcript/composer/footer) + the select overlay, the async timer (`pollTimerKeys`, addTimer 50ms), the stream sink (`tuiOnEventCB` via lua_pushcclosure), and the loop (`tuiLoop`: init + key dispatch + the SIGINT hook) |

## The runtime modules

| Module | Role |
|---|---|
| `runtime/init.lua` | The entry: requires the pieces, the tool and command registries (the runtime owns both), `neopi.runCommand` (the `/` dispatcher), returns the agent table (LuaCATS-annotated) |
| `runtime/agent.lua` | The loop: history → request → `neopi.provider.stream`/`generate` → append assistant → the steering drain (`drainSteering`) → tool calls → the compaction trigger → next turn while `toolUse` or steering queued (LuaCATS-annotated) |
| `runtime/tools.lua` | bash/read/edit/write in Lua over `neopi.fs`/`neopi.process` (LuaCATS-annotated) |

## Two tool implementations, on purpose

`tools.nim` (Nim) and `tools.lua` (runtime) implement the same four tools
separately. The print mode's model calls the Lua tools — the runtime loop
builds the request; `tools.nim` is the embedding API for Nim callers. They
differ today: the Lua `read` returns raw content (no line numbers, no
truncation); the Nim `read` numbers lines (cat -n) and truncates at 2000
lines / 50KB. Converging them is runtime work, not core work.

## The design decisions (and WHY)

1. **The anti-corruption layer.** nimgent is a dependency with an exit plan:
   fork the local checkout or replace the wrapper — the swap is one module
   (`provider.nim`), and callers never see nimgent types.
2. **The loop in Lua (the nvim experiment).** The loop FLOWED in Lua; the
   migration is gradual (nvim moved built-ins to the scriptable layer when
   the C cost more than it gave). The session tree stays Nim core-stable —
   it is the user's data contract — while the tools and the loop are Lua.
3. **The trust model.** Scripts are trusted code with NO native-code escape:
   FFI closed, `package.loadlib` nil, the C loader removed. fs/process go
   through confined primitives (native, not script-side). bash's gate is the
   approval layer — the `process_run` hook today, a harness approval later —
   not the cwd: bash runs in the workspace root without fs confinement, by
   design (pi-canonical).
4. **pi's harness.md is the spec for the mature harness** — three stores,
   the operation state machine — later, when durability matters. The session
   tree is the slice-4a foundation.
5. **The static profile.** 3 hard deps (libm, libluajit, libc); libssl and
   libpcre arrive via dlopen at load time.
6. **The interface is separate from the engine.** The loop and the tools do
   not change for the TUI: sends go through the same `agent.run` chunk print
   mode uses, and the deltas render live through the stream sink (a Lua
   closure carrying the TUI state pointer as its first upvalue) that applies
   them to nimterm's transcript and flushes the frame in the same thread
   the turn's waitFor pumps — no timer, no races, no threading (nimterm's
   App is the loop owner). The pure render layer tests without a terminal.
7. **Extensions load the nvim way.** `.neopi/init.lua` is one config file
   the user owns; `require` (through `package.path` extended with
   `.neopi/`) is the loading mechanism — a directory scan is redundant with
   it (YAGNI). A broken config warns and the agent still works (the loader
   raises, the binary decides the severity — nvim's surface-and-continue).
8. **The registry pointer is the session swap.** `exposeSession` binds one
   registry pointer + one table of cfunctions; the cfunctions read the
   pointer dynamically per call, so resuming a session is a
   `setRegistryPointer` update — the table stays intact.
9. **Esc aborts, Ctrl+C exits.** nimterm's backend owns raw mode and the
   signal handlers: Esc and Ctrl+C arrive as key events the app reads —
   during a stream, Esc (or Ctrl+C) aborts and the cancel flows through the
   sink into the partial response (`frCancelled` → "aborted"); in the idle
   loop Ctrl+C exits the process.

## The interfaces

Print mode: `neopi "prompt"` → the runtime loop → stdout. Interactive: the
TUI (`neopi` with no prompt) — the transcript, the composer, the footer,
`/commands` and `/resume` — over the same agent/session mechanisms; the
core stays stable, an interface is one more composer. JSON/RPC interfaces
come later.

Test interfaces today: the Nim suite (`tests/tp_all.nim` dispatcher, 81
tests, unittest2) and the in-process busted specs (4 spec files through the
test-only `tests/busted_main.nim` runner) — the specs run in the host's
live Lua state with the core exposed (the nvim pattern). The TUI is also
tested end-to-end by the agent through a pty harness (the keys written to
the master, the render captured, the session JSONL as the verdict).
