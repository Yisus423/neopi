version       = "0.1.0"
author        = "jesus"
description   = "Minimal coding agent core: provider primitives + Lua extensibility"
license       = "MIT"
srcDir        = "src"
binDir        = "build"

import std/os
bin           = @["neopi"]

requires "nim >= 2.0.0"
requires "chronos >= 4.0.0"
# Pinned by commit, never a local path: a fresh clone resolves these itself.
# nimterm is OUR fork (upstream `martineastwood/nimterm` is the one that got
# deleted once); the SSE parser's package name is `server_sent_events` even
# though its module is `sse`.
requires "https://github.com/Yisus423/nimterm#800bf7f"
requires "https://github.com/iceberg-work/sse#87934ce"

task bench, "Run the TUI measurement harness (headless, no terminal)":
  # Same env need as the tests: the disk-backed TMPDIR (/tmp is a small
  # tmpfs). The harness renders through a fake backend, so it needs no
  # terminal.
  if not existsEnv("TMPDIR"):
    putEnv("TMPDIR", getHomeDir() / "tmp-nim")
  exec "nim c -r --hints:off --threads:on --mm:orc -o:build/tui_bench bench/tui_bench.nim"

task test, "Run the test suite":
  # The suite's only env need is a disk-backed TMPDIR (/tmp is a small tmpfs);
  # set here so `nimble test` is self-contained. Existing values win.
  if not existsEnv("TMPDIR"):
    putEnv("TMPDIR", getHomeDir() / "tmp-nim")
  exec "nim c -r --hints:off --threads:on --mm:orc -o:build/tp_all tests/tp_all.nim"
  # The busted specs for the Lua layer, through the test-only runner (never
  # shipped; a failing spec exits non-zero and fails this task).
  exec "nim c --hints:off --threads:on --mm:orc -o:build/busted_main tests/busted_main.nim"
  exec "./build/busted_main tests/spec"
