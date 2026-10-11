version       = "0.1.0"
author        = "jesus"
description   = "Minimal coding agent core: provider primitives + Lua extensibility"
license       = "MIT"
srcDir        = "src"

import std/os
bin           = @["neopi"]

requires "nim >= 2.0.0"
requires "chronos >= 4.0.0"

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
