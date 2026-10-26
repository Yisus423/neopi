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
   nimble test                          # 204 Nim tests + 22 busted specs; the live check needs a key
   nim c -o:build/neopi src/neopi.nim   # the binary (print mode + the TUI)
   ```

2. Run one prompt (print mode, against the current directory):

   ```bash
   export OPENROUTER_API_KEY=sk-...     # or put it in .env (gitignored)
   ./build/neopi "fix the failing test in tests/foo.nim"
   ```

   Options: `--provider=<id>` (a table entry — see below; default
   openrouter), `--model=<id>` (default `inclusionai/ling-3.0-flash-vl`), and
   `--base-url=<url>` to point an entry at another endpoint (a gateway, or a
   provider the table does not carry). **The value attaches with `=`** (or
   `:`): this CLI's parser reads `--provider x` as a positional argument, so
   the space-separated form fails with "expected one prompt argument" (a known
   limit below). Keys neopi reads: `<PROVIDER>_API_KEY`, optionally
   `<PROVIDER>_MODEL` (there is no `.env.example` template). The print mode
   needs that key; the TUI does not — it starts without one and `/login` asks
   for it.

3. Or open the interactive TUI (no prompt argument):

   ```bash
   ./build/neopi
   ```

   Keys: **Enter** sends (or runs `/commands`, or steers while the model
   works); typing `/` opens the command completion above the composer (the
   names and the descriptions, narrowed as you type: **Tab** fills the
   highlighted one in, **Enter** fills it in and runs it, **Esc** closes the
   menu and keeps the draft); the **/resume** and **/model** pickers filter the
   same way — while one is open the composer is its search field, so typing
   narrows the list as you go (a fuzzy match: `gpt5` finds `openai/gpt-5`),
   Enter picks, Esc closes and the query leaves with the picker; **Esc** aborts
   the stream (the partial turn
   renders marked) or clears the composer; **Ctrl+C** exits; **PgUp/PgDn**
   scroll the transcript; **Ctrl+O** expands or collapses the thinking and the
   tool output; **/resume** opens the sessions picker (Enter loads, Esc
   cancels), **/new** starts a fresh session, **/compact** summarizes the
   conversation now (it waits for the model), **/model** lists the provider's
   real catalog and switches the model, **/login** asks for the provider's API
   key in a masked line that never enters the session and saves it to
   `~/.neopi/auth.json`, **/logout** drops the live provider and that saved
   key, and **/quit** (or Ctrl+C) exits.
   Dragging the mouse over the transcript selects text, and the selection
   copies to the clipboard. The transcript renders the deltas live, and the model's thinking
   arrives as a collapsed item you can expand with Ctrl+O.

   The palette follows the terminal: the color depth (truecolor, 256, 16,
   and off for `NO_COLOR` or a dumb terminal) and the background reported by
   `COLORFGBG`. Set `NEOPI_THEME=dark` or `NEOPI_THEME=light` to force one
   (anything else, including unset, keeps the automatic choice).

3. Verify: the final text prints to stdout and a session file lands in
   `.neopi/sessions/run-<timestamp>.jsonl`. A build from the repo finds the
   runtime at `build/../runtime` automatically; elsewhere set
   `NEOPI_RUNTIME_DIR`.

The build needs a disk-backed `TMPDIR` (`/tmp` is a small tmpfs here) and the
Nim toolchain; the run itself needs nothing beyond the binary and the runtime
(see [AGENTS.md](AGENTS.md) for the full build recipe).

## Providers and the key

The built-in table holds the OpenAI-compatible endpoints this build knows:

| id | endpoint | key |
|---|---|---|
| `openai`, `openrouter` | the two neopi exercises | `<ID>_API_KEY`, required |
| `deepseek`, `groq`, `together`, `cerebras` | four endpoints a real client reaches with this same wire | `<ID>_API_KEY`, required |
| `ollama`, `llamacpp` | `http://localhost:11434/v1`, `http://127.0.0.1:8080/v1` | keyless |

A provider the table does not carry is one flag away (`--base-url=`).
**Keyless means a key is not REQUIRED, not that it is ignored**: an entry keeps
its variable, so a local server started with a key still receives it. `/model`
lists whatever the endpoint reports; `/login` opens the provider's key.

**Where the key lives.** `/login` installs the key in the live provider AND
saves it to `~/.neopi/auth.json` (`NEOPI_CONFIG_DIR` overrides the directory),
owner-only — a `0700` directory and a `0600` file — with one entry per provider
in pi's shape:

```json
{"openrouter": {"type": "api_key", "key": "sk-..."}}
```

`/logout` removes that entry along with the live provider. A start resolves a
key in this order: **the stored credential first** (a saved key owns its
provider), then `<ID>_API_KEY` in the environment, then the project's `.env`. A
file that is not valid JSON is never rewritten — `/login` reports it instead —
so the other providers' keys survive a broken one.

## What it is

| Layer | Language | Contents |
|---|---|---|
| Core | Nim | provider (our own chronos stack: `primitives` + `openai_compat` + the wire transport, with the policy in `provider.nim`), session tree (append-only JSONL), confined fs/process, hook bus, LuaJIT embedding, agent tools, the TUI |
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
| `neopi.registerCommand` | `registerCommand(name, description, execute)` | extensions add `/commands`; the output renders as the status line, and the composer completes the registered names as you type (the description is what the completion menu shows) |
| `neopi.ui` | `header(lines)` / `status(key, text)` / `widget(key, lines, opts)` / `notify(text, level?)` / `working(text)` / `title(text)` / `select(title, options, onAnswer)` / `confirm(title, message, onAnswer)` / `input(title, opts?, onAnswer)` | the extension chrome: a header block, one keyed row per status key, blocks placed above or below the composer (`opts.placement`), a transient line painted with its level's theme token, the footer's working token, the terminal window's title, and the dialogs — a choice, a confirmation and one line of text (`opts.secret` masks it for a key, `opts.value` prefills it) — which take a callback instead of returning an answer, because a Lua handler cannot wait for the user. A nil argument clears the slot; all of them are no-ops without the TUI, and `neopi.hasUI` says which mode you are in |

Extensions load from `.neopi/init.lua` (the nvim model: one config file you
own; `require('extensions.echo')` resolves through `package.path` extended
with `.neopi/`). A broken config warns on stderr and the agent still works.

## The TUI

With no prompt argument, the interactive TUI opens: the transcript (the
session's entries, color-coded, scrollable), the composer (the editable
input, which completes `/commands` as they are typed), the extension widgets
+ status line, and the footer (the provider,
model, token usage, the working indicator). The interface drives the
engine: sends go through the same `agent.run` chunk print mode uses, the
deltas render live through the stream sink, and the app's own loop keeps the
keys answering and the frame redrawing during the stream (no threading: the
sink hands the app its events and lets it dispatch).

## Known limits (honest)

- **A mid-stream failure is not a `ProviderError`** — a dropped connection or
  a non-JSON SSE payload surfaces as a transport or parse error: the provider
  wraps the fetch and the HTTP status, not the body stream. The Lua boundary
  still turns it into a Lua error instead of aborting the process.
- **No argument schema validation before a tool runs** — the hook gate (the
  approval layer) and each tool's own argument checks stand, but the
  pre-execution JSON-Schema check the previous provider layer ran is not
  ported.
- **The stream mapping trusts the wire's tool-call index** — the accumulator
  grows to the index the gateway sends, so a hostile gateway could ask for a
  huge allocation.
- **`--provider x` (space-separated) does not parse** — this CLI's `parseopt`
  only binds a value attached with `=` or `:`; with a space the value arrives
  as a positional argument and the run fails with "expected one prompt
  argument". Pre-existing (verified against the previous build), not a
  regression of the provider table: the attached form is the documented one.
- **The credential file has no cross-process lock** — the write is atomic (a
  temp file plus a rename), so the file never corrupts, but two TUIs logging in
  at the same instant can lose one write. The first concurrent consumer, or
  OAuth's refresh, is the trigger to add one.
- **Lexical confinement** — path checks do not resolve symlinks; a symlink
  inside the workspace pointing outside it is followed.
- **The abort during a thinking pause** waits for the next delta (the
  cancel flag lands then); the deltas are usually flowing enough.
- **No arg completions, no mouse, no themes** — the select list and the
  transcript are plain; colors are hardcoded.
- **Linux-only** — LuaJIT linking and the test environment assume Linux.

## License

MIT.
