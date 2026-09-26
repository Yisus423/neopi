## Tests for the model-callable agent tools: read, write, edit, and bash,
## plus the shared confinement they resolve against. Every workspace root is
## a fresh subdirectory of the temp dir, cleaned up in its test. No API key
## or network: the end-to-end workflow uses the scripted provider.
import std/[json, os, strutils]
import neopi/fs
import neopi/provider
import neopi/tools
import unittest2

proc freshWorkspace(name: string): string =
  ## A fresh subdirectory of the temp dir as a workspace root.
  result = getTempDir() / name
  createDir(result)

suite "shared confinement":
  test "resolveConfined rejects escapes and keeps paths inside the root":
    let root = freshWorkspace("neopi-tp-tools-confine")
    try:
      expect FsError:
        discard resolveConfined(root, "../../etc/passwd")
      expect FsError:
        discard resolveConfined(root, "/etc/passwd")
      check resolveConfined(root, "notes.txt") == root / "notes.txt"
      check resolveConfined(root, root / "notes.txt") == root / "notes.txt"
      check resolveConfined(root, ".") == root
    finally:
      removeDir(root)

suite "agent tools read":
  test "read returns numbered lines":
    let root = freshWorkspace("neopi-tp-tools-read")
    try:
      writeFile(root / "notes.txt", "one\ntwo\nthree\n")
      let output = readTool(root).execute(%*{"path": "notes.txt"})
      check output.startsWith("1\tone")
      check "2\ttwo" in output
      check "3\tthree" in output
      # cat -n semantics: the trailing newline does not start line 4.
      check "4\t" notin output
    finally:
      removeDir(root)

  test "read offset and limit":
    let root = freshWorkspace("neopi-tp-tools-offset")
    try:
      writeFile(root / "notes.txt", "one\ntwo\nthree\n")
      let output = readTool(root).execute(
        %*{"path": "notes.txt", "offset": 2, "limit": 1})
      check output == "2\ttwo"
    finally:
      removeDir(root)

  test "read truncates at 2000 lines":
    let root = freshWorkspace("neopi-tp-tools-truncate-lines")
    try:
      var content = ""
      for i in 1..2500:
        content.add $i & "\n"
      writeFile(root / "big.txt", content)
      let output = readTool(root).execute(%*{"path": "big.txt"})
      check "1\t1" in output
      check "2000\t2000" in output
      check "2001\t2001" notin output
      check "[Showing lines 1-2000 of 2500. Use offset=2001 to continue.]" in output
    finally:
      removeDir(root)

  test "read truncates at 50KB":
    let root = freshWorkspace("neopi-tp-tools-truncate-bytes")
    try:
      # ~200 bytes per line across 500 lines: well under the line limit, so
      # the byte limit hits first.
      let line = repeat("x", 200)
      var content = ""
      for i in 1..500:
        content.add line & "\n"
      writeFile(root / "big.txt", content)
      let output = readTool(root).execute(%*{"path": "big.txt"})
      check "[Showing lines 1-" in output
      check "of 500" in output
      check "50.0KB limit" in output
      check "Use offset=" in output
    finally:
      removeDir(root)

  test "read missing file":
    let root = freshWorkspace("neopi-tp-tools-missing")
    try:
      expect IOError:
        discard readTool(root).execute(%*{"path": "missing.txt"})
    finally:
      removeDir(root)

suite "agent tools write":
  test "write creates parent directories":
    let root = freshWorkspace("neopi-tp-tools-write-parents")
    try:
      let result = writeTool(root).execute(
        %*{"path": "deep/dir/new.txt", "content": "hi"})
      check fileExists(root / "deep/dir/new.txt")
      check "Successfully wrote to" in result
    finally:
      removeDir(root)

  test "write overwrites an existing file":
    let root = freshWorkspace("neopi-tp-tools-write-overwrite")
    try:
      discard writeTool(root).execute(%*{"path": "f.txt", "content": "first"})
      discard writeTool(root).execute(%*{"path": "f.txt", "content": "second"})
      check readFile(root / "f.txt") == "second"
    finally:
      removeDir(root)

suite "agent tools edit":
  test "edit replaces a unique match":
    let root = freshWorkspace("neopi-tp-tools-edit")
    try:
      writeFile(root / "notes.txt", "alpha\nbeta\ngamma\n")
      let result = editTool(root).execute(
        %*{"path": "notes.txt", "oldText": "beta", "newText": "BETA"})
      check readFile(root / "notes.txt") == "alpha\nBETA\ngamma\n"
      check "1 replacement" in result
    finally:
      removeDir(root)

  test "edit oldText not found":
    let root = freshWorkspace("neopi-tp-tools-edit-notfound")
    try:
      writeFile(root / "notes.txt", "alpha\nbeta\n")
      var message = ""
      try:
        discard editTool(root).execute(
          %*{"path": "notes.txt", "oldText": "missing", "newText": "x"})
      except ValueError as e:
        message = e.msg
      check "oldText not found in notes.txt" in message
    finally:
      removeDir(root)

  test "edit duplicate match reports the count":
    let root = freshWorkspace("neopi-tp-tools-edit-duplicate")
    try:
      writeFile(root / "notes.txt", "dup\nmid\ndup\n")
      var message = ""
      try:
        discard editTool(root).execute(
          %*{"path": "notes.txt", "oldText": "dup", "newText": "x"})
      except ValueError as e:
        message = e.msg
      check "matches 2 times" in message
    finally:
      removeDir(root)

  test "edit identical text makes no change":
    let root = freshWorkspace("neopi-tp-tools-edit-nochange")
    try:
      writeFile(root / "notes.txt", "same\n")
      expect ValueError:
        discard editTool(root).execute(
          %*{"path": "notes.txt", "oldText": "same", "newText": "same"})
      check readFile(root / "notes.txt") == "same\n"
    finally:
      removeDir(root)

  test "edit escapes the workspace root":
    let root = freshWorkspace("neopi-tp-tools-edit-escape")
    try:
      var message = ""
      try:
        discard editTool(root).execute(
          %*{"path": "../../etc/passwd", "oldText": "root", "newText": "x"})
      except FsError as e:
        message = e.msg
      check "path escapes the workspace root" in message
    finally:
      removeDir(root)

suite "agent tools bash":
  test "bash runs in the workspace root":
    let root = freshWorkspace("neopi-tp-tools-bash-pwd")
    try:
      let output = bashTool(root).execute(%*{"command": "pwd"})
      check output.strip == root
      check "[exit code:" notin output
    finally:
      removeDir(root)

  test "bash reports a non-zero exit code":
    let root = freshWorkspace("neopi-tp-tools-bash-false")
    try:
      let output = bashTool(root).execute(%*{"command": "false"})
      check "[exit code: 1]" in output
    finally:
      removeDir(root)

suite "agent tools workflow":
  test "end-to-end mini agent workflow: read then edit":
    let root = freshWorkspace("neopi-tp-tools-e2e")
    try:
      writeFile(root / "notes.txt", "alpha\nbeta\ngamma\n")
      let m = scriptedProvider(@[
        ScriptStep(toolCalls: @[("call-1", "read",
          %*{"path": "notes.txt"})]),
        ScriptStep(toolCalls: @[("call-2", "edit",
          %*{"path": "notes.txt", "oldText": "beta", "newText": "BETA"})]),
        ScriptStep(text: "done")]).model("test")
      let r = m.generate("update the file",
        tools = @[readTool(root), editTool(root)], maxSteps = 3)
      check r.text == "done"
      check readFile(root / "notes.txt") == "alpha\nBETA\ngamma\n"
    finally:
      removeDir(root)
