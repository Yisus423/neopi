# AGENTS.md

Project instructions for AI agents working in this repository. Alpha status,
private project: the public API is frozen until real consumers exist.

## CodeGraph and the Nim language server

The `.codegraph/` index exists and indexes ONLY the Lua layer (it has no
parser for Nim — verified: "Files by Language: lua 4" of ~20 repo files).
Use it BEFORE grep for the runtime Lua code:

- **CodeGraph (Lua)**: `codegraph explore "<question>"` or the MCP tool —
  the symbols and call paths of runtime/*.lua and tests/spec/*.lua.
- **nimlangserver MCP (Nim)**: the nimFindSymbols/nimFindReferences tools for
  symbol search and references, nimCheckProject/nimCheckFile for diagnostics —
  configured in .pi/mcp.json (native pi project config; local-only, not
  versioned; loaded at session start, /mcp inspects in-session).
- **grep/find**: the fallback when the two above cannot answer.

## The build recipe (exact)

Nim 2.2.12 via grabnim current. The environment the commands need:

```bash
PATH="$HOME/.local/share/grabnim/current/bin:$PATH"   # Nim 2.2.12 (grabnim current)
TMPDIR="$HOME/tmp-nim"                                # disk-backed; the /tmp tmpfs fills
```

Dependencies are PINNED in `neopi.nimble`: chronos plus two packages by git
URL and commit — `Yisus423/nimterm` (our fork; the TUI) and
`iceberg-work/sse` (the provider layer's SSE parser — the PACKAGE is named
`server_sent_events` while its module is `sse`). Never a sibling checkout,
never an absolute path. `nimble build` (or `nimble test`) resolves and
installs them once; after that a direct
`nim c --hints:off --threads:on --mm:orc -o:build/neopi src/neopi.nim` works
too, because Nim's `nimblePath` finds installed packages. Build with
`nimble build` — `binDir` is `build/`, so nothing lands next to the source (a
binary was committed once and removed). To co-develop a dependency, override
the pin with the local checkout: `nimble develop ~/proyectos/nimterm`. The
`nimble test` task sets TMPDIR itself, so `nimble test` is self-contained;
direct `nim c` builds need the env above. A COLD full build takes minutes
(the nimcache is invalidated whenever the dependency paths change); warm
rebuilds are seconds.

## Testing

- `nimble test` — self-contained and offline: the Nim suite via unittest2
  (112 tests) plus the busted specs. The live OpenRouter check is opt-in:
  it skips unless NEOPI_LIVE_TEST is set and a key is found in the env or
  in .env. Run it with `NEOPI_LIVE_TEST=1 nimble test` — it needs the
  network and a real turn, so it never gates the default suite.
- Compile-fresh discipline: compile while you write (a 7-defect class in
  lua.nim came from writing without compiling).
- The TUI measurement harness: `nimble bench` builds and runs
  `bench/tui_bench.nim` (or `build/tui_bench [entries] [frames]`). It renders
  headless through a fake nimterm backend — no terminal needed — sweeps the
  transcript size, and prints one greppable line per size. The numbers it
  produced live in odd/tasks/tui-own.md. Bound it with an explicit
  `entries`/`frames` when you are exploring a slow path: the delta cost
  scales with the transcript.
- The Lua layer: the busted specs run through the test-only runner
  `./build/busted_main <spec>` (5 spec files, 13 successes, verified
  green); the `neopi --spec` CLI mode is deferred.
- The TUI's pty harness: `openpty` + TIOCSCTTY + TIOCSWINSZ (without the
  winsize, terminalHeight() is 0 and the buffer clamps to 1 row — the only
  footer renders; without TIOCSCTTY, no SIGINT). The harness writes keys to
  the master and the session JSONL is the verdict (`stop=aborted` vs
  `stop`).

## The conventions

- 2-space indent, lines ≤100, camelCase procs, constructor-initialized
  results, no `continue`.
- English artifacts: code, comments, commit messages, docs.
- Commit messages: a Conventional Commit title plus a body with the why —
  the title carries the what, the body the reasoning and the notable
  decisions; no body-only or title-only commits.
- The tool schema is what the model sees — write tool descriptions for the
  model, not for humans.
- Doc comments (`##`) on every exported symbol.

## The layer rules

- The provider layer is ours, in four pieces: `primitives.nim` holds the
  caller-facing types and exceptions, and `provider.nim` re-exports them
  (so `import neopi/provider` keeps the whole surface); `openai_compat.nim`
  holds the OpenAI wire mapping and `streamChat`; `wire.nim` holds the
  transport contract (`WireRequest`/`WireResponse`/`Transport`) with the
  chronos implementation and the in-memory fake. `provider.nim` holds the
  policy: the Provider/Model objects, the tool round-trip loop (`runTurn`)
  and the hook gates (`invokeTool`). chronos and sse types never leak past
  `wire.nim`/`openai_compat.nim`.
- The Lua extension surface
  (`neopi.on`/`fs`/`process`/`provider`/`session`/`registerTool`/`registerCommand`/`ui`)
  stays frozen until real consumers exist. Extensions load from
  `.neopi/init.lua` (the nvim way: one config file; `require` through
  `package.path` extended with `.neopi/`).
- The `{.push stacktrace: off.}` bridge procs: `lua_error` longjmps out of
  Nim C-callback frames; with frames on, the abandoned frames corrupt the
  runtime frame stack (the next nimFrame call segfaults). fs/process/hooks
  use it module-wide; tui.nim scopes it to the bridge procs only (the TUI's
  own procs keep their traces).
- fs/process confinement is the security boundary — native, not script-side:
  it lives in `resolveConfined` (lexical; known limit: symlinks followed).
  bash's gate is the approval layer, not the cwd.
