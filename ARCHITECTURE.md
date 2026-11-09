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
| `primitives.nim` | The caller-facing provider types and exceptions (`ProviderError`/`CancelledError`, `Message`/`ChatRole`, `Response` — including the turn's `thinking` — `Tool`, `StreamEvent`/`StreamCallback`, `ScriptStep`); `provider.nim` re-exports it, so `import neopi/provider` keeps the whole surface |
| `wire.nim` | The transport contract: `WireRequest`/`WireResponse`/`Transport` plus the chronos implementation (`getBodyReader` + `readOnce`, TLS via bearssl) and the in-memory fake the L1 tests drive |
| `openai_compat.nim` | The OpenAI-compatible protocol: the SSE chunk mapping onto `StreamEvent`/`Response`, `buildChatRequest`/`chatHeaders`, `streamChat` (cancellation + read timeout), the scripted transport |
| `provider.nim` | The policy: the `Provider`/`Model` objects (`openAI`/`openRouter`/`scriptedProvider`, the injectable transport), the tool round-trip loop (`runTurn`), the hook gates (`invokeTool`); chronos and sse types never leak past wire/openai_compat |
| `hooks.nim` | The hook bus: `neopi.on` from Lua, `emit` with block/rewrite from return values, pcall containment (a handler error aborts only that handler) |
| `lua.nim` | The LuaJIT 5.1 FFI bindings: macro-only 5.1 names wrapped Nim-side (`lua_pop`, `lua_pushcfunction`, `lua_getglobal`/`setglobal`, `luaUpvalueIndex = luaGlobalsIndex - i`); selective lib opening — ffi/io/os/debug/jit closed; the loadlib closure (`package.loadlib = nil`, C loader removed) |
| `fs.nim` | The confined fs primitives (`neopi.fs`: read/write/mkdir/exists/list) + `resolveConfined`, the one confinement source of truth shared with the agent tools |
| `process.nim` | The spawn-per-call process primitive (`neopi.process.run`): `process_run` hook (block/rewrite), then a NON-BLOCKING child in its own process group — the output pipe polled, the injected pump consulted between polls, an abort killing the group (`SIGTERM`, grace, `SIGKILL`) and keeping the partial output. POSIX only: the non-POSIX branch still calls the blocking `execCmdEx` |
| `pump.nim` | The pump seam: one injected closure (`proc (): bool`, nil-safe, `{.closure, gcsafe, raises: [].}`) that a blocking wait calls between polls so the owner of the frame keeps running. Two call sites today — the child above and the stream's body read (`openai_compat.nextChunk`) — and the TUI installs it (`tui.installTuiPump`) on both exposures |
| `extensibility.nim` | The assembly: hook bus + provider/session exposures + confined fs/process on one interpreter (`newExtensibility`); `loadUserConfig` loads `.neopi/init.lua` the nvim way (package.path + loadScript, a failure raises LuaError) |
| `session.nim` | The session tree: append-only JSONL, id + parent, the active branch, `navigateTo` (branch in place), the torn-tail rule. It is the USER'S DATA CONTRACT and the source of truth the transcript is rebuilt from: an assistant entry carries the model's reasoning (`thinking`) and a tool result carries the call's arguments (`toolArgs`, the model's object with its order, its nulls and its empty objects intact). Both are OPTIONAL keys — a file written before them keeps loading, and an entry without them reads empty, never nil |
| `tools.nim` | The Nim agent tools (read/write/edit/bash) over `resolveConfined`; failures raise model-facing messages |
| `expose.nim` | The Lua exposure of provider/session: `neopi.provider` (generate/stream/setScripted) and `neopi.session` (append/history/navigate); `stopReasonOf` maps `frCancelled` → "aborted" |
| `tui.nim` | The TUI over nimterm: the root widget (`NeopiScreen`) and the chrome it lays out (`tuiLayout`: a header, the transcript, the placed widgets, one row per status key, the composer, the footer), the extension slots (`neopi.ui`: status/widget/header/notify/working/title plus the dialogs), the app's callbacks (`wireApp`: the keys, the resume menu, the open question, the agent events, the actions), the stream sink (`tuiOnEventCB`: a Lua callback that posts nimterm agent events and lets the app dispatch and present), the transcript sync (incremental, with a full rebuild on a branch change), the ADAPTER that maps one session entry to the items it becomes (`adapterItems`: the reasoning first, then the message; a tool call's title is `$ <command>` for bash and `name path` otherwise), the reasoning's own style (the theme's muted plus italic) with Ctrl+T folding every thinking item and the preference in the global settings file, and the turn drive (`sendTurn`: one turn per `evalJson`, the app draining keys and events between them, each MODEL turn keyed by `turnRunId:turnStep` so a tool round-trip's reasoning starts its own item) |

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

1. **The anti-corruption layer paid off.** nimgent is gone and not one caller
   changed: the swap landed in a single commit and the Lua surface
   (`expose.nim`) did not move a byte. What the layer did force: because the
   protocol module needs the caller-facing types while the policy module needs
   the protocol, the type block had to leave the module that re-exports it
   (`primitives.nim`). A conversion boundary keeps the callers safe; it does
   not keep the module count down.
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
5. **The dynamic profile.** Four shared objects at runtime: `libm`, `libc`,
   `libgcc_s` and **LuaJIT** (`libluajit-5.1.so.2`) — verified with `ldd`.
   Nothing is `dlopen`ed: libpcre left with nimgent, and the OpenSSL wrapper is
   NOT linked (the `--define:ssl` that pulled the stdlib's binding in is gone;
   chronos's own bearSSL is the TLS that runs, statically). The binary is
   ~4.9 MB, of which ~3.9 MB is `text`, and it is the SMALLEST of the four
   native-core-plus-Lua agents measured on this machine (uji 17 MB, smelt
   48 MB, maki 125 MB — all of them static or heavier runtimes).

   **The portability consequence is written where it happens**: `lua.nim` links
   LuaJIT with `{.passL: "-l:libluajit-5.1.so.2".}`, GNU ld's literal-soname
   form. That line is why the build is Linux-only today; a Windows or macOS port
   starts by branching it per platform and shipping that platform's LuaJIT.
**The pinned dependencies** (AGENTS.md carries the recipe): `chronos` 4.4.1,
our `nimterm` fork at `0399fa1` and `iceberg-work/sse` at `87934ce`, each by git
URL and commit, never a path. A pin bump has a trap worth knowing here: after
changing the pin, `nimble build` REUSED the installed copy and compiled against
the old revision with exit 0 — the old copy has to be deleted (exactly one
candidate under `~/.nimble/pkgs2/`, checked by `vcsRevision`, not by version) and
the caches that name its path cleared, which is how consuming nimterm's
key-hint patch was done.

6. **The interface is separate from the engine.** The loop and the tools do
   not change for the TUI: sends go through the same `agent.run` chunk print
   mode uses, and the stream sink — a C callback carrying the TUI state pointer
   as its first upvalue — **posts** each delta as a nimterm agent event and lets
   the app dispatch and present it. The app owns the frame (the canvas, the
   dirty flag and the frame budget) so the keys, the resume menu, an open dialog
   and the stream events all take one path, and the transcript grows
   incrementally so the view state an item carries (an expanded tool, a pending
   approval) survives the next turn. No timer, no races, no threading: nimterm's
   `App` is the loop owner and the turn's `waitFor` is what pumps it. The layout
   (`tuiLayout`) and the transcript sync are pure, so they test without a
   terminal — a canvas and a fake backend are the harness.
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

Test interfaces today: the Nim suite (`tests/tp_all.nim` dispatcher, **247
tests**, unittest2) and the in-process busted specs (5 spec files, 22 successes,
through the test-only `tests/busted_main.nim` runner) — the specs run in the
host's live Lua state with the core exposed (the nvim pattern).

The TUI's STANDING gate is the canvas and the fake backend: `buildScreen` plus a
`TerminalBackend` that records the frames, so the chrome, the transcript and the
wiring are asserted without a terminal. That is deliberate, and the two defects
it could NOT see say why: the app the pump drove had no callbacks (#16) and the
tool arguments lost their shape on the way through Lua (#33), and an independent
agent found BOTH by running the real binary under a pty (`openpty` + `TIOCSCTTY`
+ `TIOCSWINSZ`, the keys written to the master, the frames and the session JSONL
as the verdict). The pty stays a MANUAL verification technique, never a committed
second harness in another language: it is what a verifier reaches for when the
fake path cannot see the question.

## Windows, honestly

The core is portable in principle — Nim with a C ABI, Lua, nimterm has a Windows
backend and chronos supports one — and exactly three things stand in the way
today:

1. **The LuaJIT link line** (above): a per-platform branch plus that platform's
   DLL.
2. **`process.nim`**: the polling child is POSIX (`startProcess` + a non-blocking
   pipe + `killpg`); on Windows the tools fall back to the blocking `execCmdEx`,
   so "the interface stays alive while a command runs" does NOT hold there.
3. **The pty technique** (above), which only affects verification — plus the
   busted runner's own POSIX assumptions in the test layer.

Nothing in the runtime, the session, the provider layer or the TUI's design is
the obstacle; the work is a platform branch in one module and a link line.
