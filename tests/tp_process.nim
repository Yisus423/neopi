## Tests for the non-blocking process runner: the normal command contract, the
## pump seam during a long child, and the Lua-visible abort failure. Every
## workspace root is a fresh subdirectory of the temp dir, cleaned up in its
## test.
import std/[os, strutils, times]
import neopi/hooks
import neopi/lua
import neopi/process
import neopi/pump
import unittest2

# Same file-scope typedef as lua.nim: this module's generated C calls into the
# Lua state directly, and no C headers exist to declare the type.
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

proc freshWorkspace(name: string): string =
  ## A fresh subdirectory of the temp dir as a workspace root.
  result = getTempDir() / name
  createDir(result)

suite "process runner":
  test "a short command keeps its output and exit code":
    let root = freshWorkspace("neopi-tp-process-short")
    try:
      let outcome = runCommand("printf out; printf err >&2; exit 7", root)
      check outcome.output == "outerr\n"
      check outcome.code == 7
      check not outcome.aborted
    finally:
      removeDir(root)

  test "a pump aborts a long command and keeps the partial output":
    let root = freshWorkspace("neopi-tp-process-abort")
    try:
      var polls = 0
      let pump: Pump = proc (): bool =
        inc polls
        polls >= 3
      let started = epochTime()
      let outcome = runCommand("printf 'partial\n'; sleep 3", root, pump)
      let elapsed = epochTime() - started
      check outcome.aborted
      check polls >= 3
      check elapsed < 1.0
      check "partial" in outcome.output
    finally:
      removeDir(root)

  test "an abort kills descendants in the process group":
    let root = freshWorkspace("neopi-tp-process-tree")
    try:
      var polls = 0
      let pump: Pump = proc (): bool =
        inc polls
        polls >= 3
      let command = "(while [ ! -f trigger ]; do sleep 0.01; done; " &
        "printf survived > survived) & printf partial; wait"
      let outcome = runCommand(command, root, pump)
      check outcome.aborted
      writeFile(root / "trigger", "go")
      os.sleep(200)
      check not fileExists(root / "survived")
    finally:
      removeDir(root)

  test "a pump that never aborts lets a short command finish":
    let root = freshWorkspace("neopi-tp-process-no-abort")
    try:
      var polls = 0
      let pump: Pump = proc (): bool =
        inc polls
        false
      let outcome = runCommand("echo ready", root, pump)
      check not outcome.aborted
      check outcome.output == "ready\n"
      check outcome.code == 0
      check polls > 0
    finally:
      removeDir(root)

  test "Lua sees the normal result shape":
    let root = freshWorkspace("neopi-tp-process-lua-shape")
    try:
      let bus = newHookBus()
      exposeProcess(bus.state, root)
      let outcome = evalString(bus.state, """
        local result = neopi.process.run("echo hello")
        return tostring(result.code) .. ":" .. result.output
      """)
      check outcome == "0:hello\n"
    finally:
      removeDir(root)

  test "Lua sees an abort as an error":
    let root = freshWorkspace("neopi-tp-process-lua-abort")
    try:
      var polls = 0
      let pump: Pump = proc (): bool =
        inc polls
        polls >= 3
      let bus = newHookBus()
      exposeProcess(bus.state, root, nil, pump)
      let outcome = evalString(bus.state, """
        local ok, err = pcall(neopi.process.run, "printf 'partial\n'; sleep 3")
        if ok then return "unexpected success" end
        return tostring(err)
      """)
      check "aborted" in outcome
    finally:
      removeDir(root)
