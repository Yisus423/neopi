## Tests for the extensibility surface: confined fs primitives, the
## spawn-per-call process primitive, the process_run hook, and the loadlib
## hardening. Every workspace root is a fresh subdirectory of the temp dir,
## cleaned up in its test.
import std/[os, strutils]
import neopi/extensibility
import neopi/hooks
import neopi/lua
import unittest2

# Same file-scope typedef as lua.nim: this module's generated C calls into
# the Lua state directly, and no C headers exist to declare the type.
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

proc freshWorkspace(name: string): string =
  ## A fresh subdirectory of the temp dir as a workspace root.
  result = getTempDir() / name
  createDir(result)

suite "extensibility fs":
  test "fs read/write round-trip":
    let root = freshWorkspace("neopi-tp-fs-roundtrip")
    try:
      let ext = newExtensibility(root)
      runScript(ext.bus.state, "neopi.fs.write('hello.txt', 'hi')")
      check fileExists(root / "hello.txt")
      check evalString(ext.bus.state,
        "return neopi.fs.read('hello.txt')") == "hi"
    finally:
      removeDir(root)

  test "fs confinement rejects escapes":
    let root = freshWorkspace("neopi-tp-fs-escape")
    try:
      let ext = newExtensibility(root)
      let relative = evalString(ext.bus.state, """
        local ok, err = pcall(neopi.fs.read, "../../etc/passwd")
        if ok then return "allowed" end
        return "blocked: " .. err
      """)
      check relative.startsWith("blocked: ")
      check "workspace root" in relative
      let absolute = evalString(ext.bus.state, """
        local ok, err = pcall(neopi.fs.read, "/etc/passwd")
        if ok then return "allowed" end
        return "blocked: " .. err
      """)
      check absolute.startsWith("blocked: ")
      check "workspace root" in absolute
    finally:
      removeDir(root)

  test "fs list returns names":
    let root = freshWorkspace("neopi-tp-fs-list")
    try:
      let ext = newExtensibility(root)
      runScript(ext.bus.state, """
        neopi.fs.write("a.txt", "1")
        neopi.fs.write("b.txt", "2")
      """)
      let listed = evalString(ext.bus.state,
        "return table.concat(neopi.fs.list('.'), ',')")
      check "a.txt" in listed
      check "b.txt" in listed
      let count = evalString(ext.bus.state,
        "return tostring(#neopi.fs.list('.'))")
      check count == "2"
    finally:
      removeDir(root)

  test "fs exists":
    let root = freshWorkspace("neopi-tp-fs-exists")
    try:
      let ext = newExtensibility(root)
      runScript(ext.bus.state, "neopi.fs.write('present.txt', 'x')")
      check evalString(ext.bus.state,
        "return tostring(neopi.fs.exists('present.txt'))") == "true"
      check evalString(ext.bus.state,
        "return tostring(neopi.fs.exists('missing.txt'))") == "false"
    finally:
      removeDir(root)

suite "extensibility process":
  test "process run echo":
    let root = freshWorkspace("neopi-tp-process-echo")
    try:
      let ext = newExtensibility(root)
      let ran = evalString(ext.bus.state, """
        local r = neopi.process.run("echo hello")
        return tostring(r.code) .. ":" .. r.output
      """)
      check ran.startsWith("0:")
      check "hello" in ran
    finally:
      removeDir(root)

  test "process_run hook blocks":
    let root = freshWorkspace("neopi-tp-process-block")
    try:
      let ext = newExtensibility(root)
      loadExtension(ext.bus, """
        neopi.on("process_run", function(p)
          if string.find(p.cmd, "danger", 1, true) then
            return false, "danger commands are blocked"
          end
          return true
        end)
      """)
      let outcome = evalString(ext.bus.state, """
        local ok, err = pcall(neopi.process.run, "danger-cmd")
        if ok then return "ran" end
        return "blocked: " .. err
      """)
      check outcome == "blocked: danger commands are blocked"
      let safe = evalString(ext.bus.state,
        "return neopi.process.run('echo safe').output")
      check "safe" in safe
    finally:
      removeDir(root)

  test "process_run hook rewrites":
    let root = freshWorkspace("neopi-tp-process-rewrite")
    try:
      let ext = newExtensibility(root)
      loadExtension(ext.bus, """
        neopi.on("process_run", function(p)
          return {cmd = "echo rewritten"}
        end)
      """)
      let rewrote = evalString(ext.bus.state,
        "return neopi.process.run('anything').output")
      check "rewritten" in rewrote
      check "anything" notin rewrote
    finally:
      removeDir(root)

suite "extensibility hardening":
  test "loadlib is closed":
    let ext = newExtensibility("")
    check evalString(ext.bus.state, "return type(package.loadlib)") == "nil"
    check evalString(ext.bus.state,
      "return tostring(#package.loaders)") == "3"
    check evalString(ext.bus.state, "return type(neopi.fs)") == "nil"
    check evalString(ext.bus.state, "return type(neopi.process)") == "nil"
