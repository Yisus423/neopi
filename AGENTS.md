# AGENTS.md

Project instructions for AI agents working in this repository. Alpha status,
private project: the public API is frozen until real consumers exist.

## CodeGraph

This repo has no `.codegraph/` index yet — use `grep`/`find` or read files
directly (offer to index it). When an index exists, reach for it BEFORE
grep/find or reading files when you need to understand or locate code.

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
