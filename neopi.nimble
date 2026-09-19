version       = "0.1.0"
author        = "jesus"
description   = "Minimal coding agent core: provider primitives + Lua extensibility"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"
requires "https://github.com/martineastwood/nimgent"

task test, "Run the test suite":
  exec "nim c -r --hints:off --threads:on --mm:orc -o:build/tp_all tests/tp_all.nim"
