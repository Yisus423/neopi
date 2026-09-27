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
  configured in .mcp.json (load it by restarting the pi session).
- **grep/find**: the fallback when the two above cannot answer.

## The build recipe (exact)

Nim 2.2.12 via grabnim current. The environment the commands need:

```bash
PATH="$HOME/.local/share/grabnim/current/bin:$PATH"   # Nim 2.2.12 (grabnim current)
TMPDIR="$HOME/tmp-nim"                                # disk-backed; the /tmp tmpfs fills
LD_LIBRARY_PATH="$HOME/.local/lib/nimlet"             # nimgent dlopens libpcre at load time
```

Compile with `-o:build/<name>` — NEVER next-to-source (a binary was
committed once and removed). The `nimble test` task sets TMPDIR and
LD_LIBRARY_PATH itself, so `nimble test` is self-contained; direct
`nim c` builds need the env above.

## Testing

- `nimble test` — self-contained; the Nim suite via unittest2 (57 tests; the
  live OpenRouter check reads OPENROUTER_API_KEY from the env or .env and
  self-skips without it).
- Compile-fresh discipline: compile while you write (a 7-defect class in
  lua.nim came from writing without compiling).
- The Lua layer: `tp_expose.nim` today; the busted specs run through the
  test-only runner `./build/busted_main <spec>` (2 specs, verified green);
  the `neopi --spec` CLI mode is deferred.

## The conventions

- 2-space indent, lines ≤100, camelCase procs, constructor-initialized
  results, no `continue`.
- English artifacts: code, comments, commit messages, docs.
- The tool schema is what the model sees — write tool descriptions for the
  model, not for humans.
- Doc comments (`##`) on every exported symbol.

## The layer rules

- nimgent types never leak out of `provider.nim`.
- The Lua extension surface (`neopi.on`/`fs`/`process`/`provider`/`session`)
  stays frozen until real consumers exist.
- fs/process confinement is the security boundary — native, not script-side:
  it lives in `resolveConfined` (lexical; known limit: symlinks followed).
  bash's gate is the approval layer, not the cwd.
