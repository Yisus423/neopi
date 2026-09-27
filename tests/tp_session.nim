## Tests for the session tree: the entry variant, JSONL persistence, the
## active branch, and branching in place. Every file is a fresh temp path,
## cleaned up in its test.
import std/[json, options, os, strutils]
import neopi/session
import unittest2

proc freshPath(name: string): string =
  ## A fresh temp file path per test; a stale leftover from an earlier run is
  ## removed first.
  result = getTempDir() / ("neopi-tp-session-" & name & ".jsonl")
  removeFile(result)

proc sampleAssistant(text, model: string): SessionEntry =
  ## An assistant entry with fixed usage metadata for round-trip checks.
  SessionEntry(kind: ekAssistant, text: text, model: model, provider: "openai",
    usageInput: 12, usageOutput: 34, stopReason: "end_turn")

suite "session tree":
  test "append and load round-trip":
    let path = freshPath("roundtrip")
    try:
      let s = newSession(path)
      check not fileExists(path)
      s.append(SessionEntry(kind: ekUser, text: "hello"))
      check fileExists(path)
      s.append(sampleAssistant("hi there", "m1"))
      s.append(SessionEntry(kind: ekToolResult, toolCallId: "call-1",
        toolName: "read", output: "file content", isError: false))
      check s.entries.len == 3
      check s.currentId == 3
      let reopened = newSession(path)
      check reopened.entries.len == 3
      check reopened.currentId == 3
      check reopened.entries[0].kind == ekUser
      check reopened.entries[0].id == 1
      check reopened.entries[0].parentId.isNone
      check reopened.entries[0].text == "hello"
      check reopened.entries[1].kind == ekAssistant
      check reopened.entries[1].id == 2
      check reopened.entries[1].parentId == some(1)
      check reopened.entries[1].text == "hi there"
      check reopened.entries[1].model == "m1"
      check reopened.entries[1].provider == "openai"
      check reopened.entries[1].usageInput == 12
      check reopened.entries[1].usageOutput == 34
      check reopened.entries[1].stopReason == "end_turn"
      check reopened.entries[2].kind == ekToolResult
      check reopened.entries[2].id == 3
      check reopened.entries[2].parentId == some(2)
      check reopened.entries[2].toolCallId == "call-1"
      check reopened.entries[2].toolName == "read"
      check reopened.entries[2].output == "file content"
      check not reopened.entries[2].isError
    finally:
      removeFile(path)

  test "jsonl line format":
    let path = freshPath("format")
    try:
      let s = newSession(path)
      s.append(SessionEntry(kind: ekUser, text: "hello"))
      let lines = readFile(path).strip(chars = {'\n', '\r'}).splitLines()
      check lines.len == 1
      let first = parseJson(lines[0])
      check first["type"].getStr == "user"
      check first["id"].getInt == 1
      check first["parentId"].kind == JNull
      check 'T' in first["timestamp"].getStr
      check first["text"].getStr == "hello"
    finally:
      removeFile(path)

  test "history is the active path":
    let path = freshPath("linear")
    try:
      let s = newSession(path)
      s.append(SessionEntry(kind: ekUser, text: "first"))
      s.append(sampleAssistant("second", "m1"))
      s.append(SessionEntry(kind: ekUser, text: "third"))
      let branch = s.history()
      check branch.len == 3
      check branch[0].id == 1
      check branch[0].text == "first"
      check branch[1].id == 2
      check branch[2].id == 3
      check branch[2].text == "third"
    finally:
      removeFile(path)

  test "navigateTo branches in place":
    let path = freshPath("branch")
    try:
      let s = newSession(path)
      s.append(SessionEntry(kind: ekUser, text: "root"))
      s.append(sampleAssistant("first answer", "m1"))
      s.append(SessionEntry(kind: ekUser, text: "follow-up"))
      s.navigateTo(1)
      check s.currentId == 1
      s.append(SessionEntry(kind: ekUser, text: "retry"))
      check s.entries[3].id == 4
      check s.entries[3].parentId == some(1)
      let branch = s.history()
      check branch.len == 2
      check branch[0].id == 1
      check branch[1].id == 4
      check branch[1].text == "retry"
    finally:
      removeFile(path)

  test "multi-branch persistence":
    let path = freshPath("multibranch")
    try:
      let s = newSession(path)
      s.append(SessionEntry(kind: ekUser, text: "root"))
      s.append(SessionEntry(kind: ekUser, text: "branch one"))
      s.navigateTo(1)
      s.append(SessionEntry(kind: ekUser, text: "branch two"))
      check s.currentId == 3
      let reopened = newSession(path)
      check reopened.entries.len == 3
      check reopened.entries[1].parentId == some(1)
      check reopened.entries[2].parentId == some(1)
      let branch = reopened.history()
      check branch.len == 2
      check branch[0].id == 1
      check branch[1].id == 3
      check branch[1].text == "branch two"
    finally:
      removeFile(path)

  test "navigateTo to an unknown id raises":
    let path = freshPath("unknown")
    try:
      let s = newSession(path)
      s.append(SessionEntry(kind: ekUser, text: "only"))
      expect SessionError:
        s.navigateTo(9)
      check s.currentId == 1
    finally:
      removeFile(path)

  test "malformed line raises with the line number":
    let path = freshPath("malformed")
    try:
      writeFile(path,
        """{"type":"user","id":1,"parentId":null,"timestamp":"t1","text":"hi"}
not json
{"type":"assistant","id":2,"parentId":1,"timestamp":"t2","model":"m1","provider":"p1","usageInput":1,"usageOutput":2,"stopReason":"end_turn"}
""")
      var message = ""
      try:
        discard newSession(path)
      except SessionError as e:
        message = e.msg
      check "line 2" in message
      check "invalid JSON" in message
      writeFile(path,
        """{"type":"user","id":1,"parentId":null,"timestamp":"t1","text":"hi"}
{"type":"assistant","id":2,"parentId":1,"timestamp":"t2"}
{"type":"toolResult","id":3,"parentId":2,"timestamp":"t3","toolCallId":"call-1","toolName":"read","output":"x","isError":false}
""")
      message = ""
      try:
        discard newSession(path)
      except SessionError as e:
        message = e.msg
      check "line 2" in message
      check "text" in message
    finally:
      removeFile(path)

  test "torn tail is discarded and truncated on the next append":
    let path = freshPath("torn")
    try:
      writeFile(path,
        """{"type":"user","id":1,"parentId":null,"timestamp":"t1","text":"hi"}
{"type":"user","id":2,"parentId":1,"timestamp":"t2","text":"torn
""")
      let s = newSession(path)
      check s.entries.len == 1
      check s.currentId == 1
      check s.tornTail
      # The torn bytes are still on disk until the first append admits
      # new writes.
      check "torn" in readFile(path)
      s.append(SessionEntry(kind: ekUser, text: "next"))
      check not s.tornTail
      let reopened = newSession(path)
      check reopened.entries.len == 2
      check reopened.entries[1].id == 2
      check reopened.entries[1].parentId == some(1)
      check reopened.entries[1].text == "next"
      check not reopened.tornTail
      check "torn" notin readFile(path)
    finally:
      removeFile(path)

  test "a torn-only file starts fresh and truncates on the first append":
    let path = freshPath("torn-only")
    try:
      writeFile(path, "{\"type\":\"user\",\"id\":1")
      let s = newSession(path)
      check s.entries.len == 0
      check s.currentId == 0
      check s.tornTail
      s.append(SessionEntry(kind: ekUser, text: "first"))
      check not s.tornTail
      let reopened = newSession(path)
      check reopened.entries.len == 1
      check reopened.entries[0].id == 1
      check reopened.entries[0].parentId.isNone
      check reopened.entries[0].text == "first"
    finally:
      removeFile(path)
