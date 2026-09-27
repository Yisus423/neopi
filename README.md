# neopi

A minimal coding-agent core in Nim with Lua extensibility — the neovim model:
the binary drives, the runtime composes. The Nim core exposes provider,
session, filesystem, process, and hook primitives; the agent loop and its
tools live in `runtime/` Lua files that ship with the binary and are
user-modifiable.

**Status: alpha.** Private project, no releases yet. The Lua extension
surface is frozen until real consumers exist; expect churn before then.

## Quick path

1. Build and test (Nim 2.2; the suite is self-contained):

   ```bash
   nimble test                          # 57 tests; the live check self-skips without a key
   nim c -o:build/neopi src/neopi.nim   # the print-mode binary
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
| Core | Nim | provider (anti-corruption layer over nimgent), session tree (append-only JSONL), confined fs/process, hook bus, LuaJIT embedding, agent tools |
| Runtime | Lua (`runtime/`, user-modifiable) | `init.lua` (entry), `agent.lua` (the loop), `tools.lua` (bash/read/edit/write) |

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

The Lua extension surface (what scripts see):

| Table | API | Notes |
|---|---|---|
| `neopi.on` | `on(event, fn)` | lifecycle hooks; return values block or rewrite |
| `neopi.fs` | `read` / `write` / `mkdir` / `exists` / `list` | workspace-confined; escapes raise |
| `neopi.process` | `run(cmd)` | runs in the workspace root; the `process_run` hook gates commands |
| `neopi.provider` | `generate(config)` / `setScripted(steps)` | one model turn per call |
| `neopi.session` | `append(kind, payload)` / `history()` / `navigate(id)` | the session tree, colon syntax |

## Known limits (honest)

- **libpcre at load time** — nimgent's structured_output import chain dlopens
  libpcre; the binary needs it on the loader path.
- **Lexical confinement** — path checks do not resolve symlinks; a symlink
  inside the workspace pointing outside it is followed.
- **Print mode only** — one prompt → one run; no TUI, no steering, no abort.
- **Linux-only** — LuaJIT linking and the test environment assume Linux.
- **nimgent upstream** — solo-dev dependency with an exit plan (see
  [ROADMAP.md](ROADMAP.md)); the swap is one module.

## License

MIT.
