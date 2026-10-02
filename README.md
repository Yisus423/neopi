# neopi

A minimal coding-agent core in Nim with Lua extensibility — the neovim model:
the binary drives, the runtime composes. The Nim core exposes provider,
session, filesystem, process, and hook primitives; the agent loop and its
tools live in `runtime/` Lua files that ship with the binary and are
user-modifiable.

**Status: alpha.** Private project, no releases yet. The Lua extension
surface is complete (hooks, fs/process, registerTool, registerCommand, UI
primitives); extensions load from `.neopi/init.lua` the nvim way — one
config file you own, the `require` mechanism loads what it references.

## Quick path

1. Build and test (Nim 2.2; the suite is self-contained):

   ```bash
   nimble test                          # 119 Nim tests + 10 busted specs; the live check needs a key
   nim c -o:build/neopi src/neopi.nim   # the binary (print mode + the TUI)
   ```

2. Run one prompt (print mode, against the current directory):

   ```bash
   export OPENROUTER_API_KEY=sk-...     # or put it in .env (gitignored)
   ./build/neopi "fix the failing test in tests/foo.nim"
   ```

   Options: `--provider openai|openrouter` (default openrouter),
   `--model <id>` (default `inclusionai/ling-3.0-flash-vl`). Keys neopi
   reads: `<PROVIDER>_API_KEY`, optionally `<PROVIDER>_MODEL` (there is no
   `.env.example` template).

3. Or open the interactive TUI (no prompt argument):

   ```bash
   ./build/neopi
   ```

   Keys: **Enter** sends (or runs `/commands`, or steers while the model
   works); **Esc** aborts the stream (the partial turn renders marked) or
   clears the composer; **Ctrl+C** exits; **PgUp/PgDn** scroll the
   transcript; **/resume** opens the sessions picker (Enter loads, Esc
   cancels). The transcript renders the deltas live — the model's thinking
   pauses don't freeze it (an asyncdispatch timer, no threading).

3. Verify: the final text prints to stdout and a session file lands in
   `.neopi/sessions/run-<timestamp>.jsonl`. A build from the repo finds the
   runtime at `build/../runtime` automatically; elsewhere set
   `NEOPI_RUNTIME_DIR`.

The run needs `LD_LIBRARY_PATH="$HOME/.local/lib/nimlet"` when libpcre is not
on the default loader path — nimgent dlopens it at load time (see
[AGENTS.md](AGENTS.md) for the full build recipe).

## What it is

| Layer | Language | Contents |
|---|---|---|
| Core | Nim | provider (anti-corruption layer over nimgent), session tree (append-only JSONL), confined fs/process, hook bus, LuaJIT embedding, agent tools, the TUI |
| Runtime | Lua (`runtime/`, user-modifiable) | `init.lua` (entry + the tool/command registries), `agent.lua` (the loop: streaming, compaction, the steering drain), `tools.lua` (bash/read/edit/write) |

The binary assembles the core, loads the runtime, and drives it. Runtime
files are user-modifiable on purpose: the loop's behavior — turn
orchestration, tools, request shape — is Lua, not compiled-in logic.

## The tool surface

Agent tools (what the model calls): bash, read, edit, write — each with a
JSON schema the model sees and execution confined to the workspace root.
Two implementations exist by design:

| Implementation | Where | Who calls it |
|---|---|---|
| Nim tools | `src/neopi/tools.nim` | embedding callers (the Nim API) |
| Lua tools | `runtime/tools.lua` | the model, via the runtime's agent loop (what print mode runs) |

The Lua extension surface (what scripts see), plus the user config entrypoint:

| Table | API | Notes |
|---|---|---|
| `neopi.on` | `on(event, fn)` | lifecycle hooks; return values block or rewrite |
| `neopi.fs` | `read` / `write` / `mkdir` / `exists` / `list` | workspace-confined; escapes raise |
| `neopi.process` | `run(cmd)` | runs in the workspace root; the `process_run` hook gates commands |
| `neopi.provider` | `generate(config)` / `stream(config, onEvent)` / `setScripted(steps)` | one model turn per call; `stream` sends `{text = delta}` to onEvent (return false cancels) |
| `neopi.session` | `append(kind, payload)` / `history()` / `navigate(id)` | the session tree, colon syntax |
| `neopi.registerTool` | `registerTool(name, description, schema, execute)` | extensions add tools the model calls |
| `neopi.registerCommand` | `registerCommand(name, description, execute)` | extensions add `/commands`; the output renders as the status line |
| `neopi.ui` | `status(text)` / `widget(name, text)` | extensions drive the TUI's status and widget lines (no-ops without the TUI) |

Extensions load from `.neopi/init.lua` (the nvim model: one config file you
own; `require('extensions.echo')` resolves through `package.path` extended
with `.neopi/`). A broken config warns on stderr and the agent still works.

## The TUI

With no prompt argument, the interactive TUI opens: the transcript (the
session's entries, color-coded, scrollable), the composer (the editable
input), the extension widgets + status line, and the footer (the provider,
model, token usage, the working indicator). The interface drives the
engine: sends go through the same `agent.run` chunk print mode uses, the
deltas render live through the stream sink, and an asyncdispatch timer
keeps the keys polling and the frame redrawing during the stream — no
threading.

## Known limits (honest)

- **libpcre at load time** — nimgent's structured_output import chain dlopens
  libpcre; the binary needs it on the loader path.
- **Lexical confinement** — path checks do not resolve symlinks; a symlink
  inside the workspace pointing outside it is followed.
- **The abort during a thinking pause** waits for the next delta (the
  cancel flag lands then); the deltas are usually flowing enough.
- **No arg completions, no mouse, no themes** — the select list and the
  transcript are plain; colors are hardcoded.
- **Linux-only** — LuaJIT linking and the test environment assume Linux.
- **nimgent upstream** — solo-dev dependency with an exit plan (see
  [ROADMAP.md](ROADMAP.md)); the swap is one module.

## License

MIT.
