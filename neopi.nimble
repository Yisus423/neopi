version       = "0.1.0"
author        = "jesus"
description   = "Minimal coding agent core: provider primitives + Lua extensibility"
license       = "MIT"
srcDir        = "src"

import std/os
bin           = @["neopi"]

requires "nim >= 2.0.0"
requires "https://github.com/martineastwood/nimgent"

task test, "Run the test suite":
  # The env the tests need (libpcre for dlopen, a disk-backed TMPDIR); set
  # here so `nimble test` is self-contained. Existing values win.
  if not existsEnv("TMPDIR"):
    putEnv("TMPDIR", getHomeDir() / "tmp-nim")
  let libDir = getHomeDir() / ".local" / "lib" / "nimlet"
  if dirExists(libDir) and not existsEnv("LD_LIBRARY_PATH"):
    putEnv("LD_LIBRARY_PATH", libDir)
  exec "nim c -r --hints:off --threads:on --mm:orc -o:build/tp_all tests/tp_all.nim"
