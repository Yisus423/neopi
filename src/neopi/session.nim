## The session tree: entries, JSONL persistence, and the active branch.
##
## A session is a tree of entries persisted as one JSON object per line,
## appended only: existing lines are never rewritten. Each entry refers to its
## parent; the path from the root to `currentId` is the active branch and
## supplies the ordered history for a model request. Continuing from an
## earlier entry (`navigateTo` plus the next `append`) creates another branch
## in the same file.
##
## Design choices:
## - `parentId` is `Option[int]`: `none` marks the root entry, `some(n)` names
##   the parent. The JSONL spelling is `null` for the root.
## - One `append` proc takes a `SessionEntry` the caller constructs with its
##   kind and payload; append assigns the id, the parent, and the timestamp
##   (values the caller set for those fields are ignored) and writes one line.
## - `text` is a base field shared by user and assistant entries: Nim variant
##   branches cannot reuse a field name across branches.
##
## Known limits: the file is not locked, so concurrent writers are out of
## scope; load validation is per line (JSON validity, 1-based strictly
## increasing ids, parents that appear earlier in the file), so a file that
## passes it always yields a well-defined active branch.

import std/[algorithm, json, options, os, sets, strutils, tables, times]

type
  SessionError* = object of CatchableError
    ## Raised for session load, parse, validation, and append failures.

  EntryKind* = enum
    ## The MVP entry kinds persisted in a session file. The strings are the
    ## JSONL `"type"` spelling, so `$` and the file round-trip directly.
    ekUser = "user"
    ekAssistant = "assistant"
    ekToolResult = "toolResult"

  SessionEntry* = object
    ## One entry in the session tree. Base fields: `id` (1-based, increasing
    ## per file), `parentId` (none for the root), the ISO 8601 `timestamp`,
    ## and `text` (the author text for user and assistant entries). The
    ## variant branches carry the kind-specific payload.
    id*: int
    parentId*: Option[int]
    timestamp*: string
    text*: string
    case kind*: EntryKind
    of ekUser:
      discard
    of ekAssistant:
      model*, provider*: string
      usageInput*, usageOutput*: int
      stopReason*: string
    of ekToolResult:
      toolCallId*, toolName*, output*: string
      isError*: bool

  Session* = ref object
    ## A session tree: the loaded entries in file order, the JSONL file they
    ## persist to, and the active branch's tip. `currentId` is 0 only while
    ## the session is empty; the first append becomes the root.
    entries*: seq[SessionEntry]
    path*: string
    currentId*: int

proc missingField(line: int, key: string) {.noinline, noreturn.} =
  ## One private helper for load failures: a required field is missing or has
  ## the wrong JSON kind.
  raise newException(SessionError,
    "line " & $line & ": missing or invalid field \"" & key & "\"")

proc reqString(node: JsonNode, key: string, line: int): string =
  ## A required string field, or a SessionError with the line number.
  if node.hasKey(key) and node[key].kind == JString:
    return node[key].getStr
  missingField(line, key)

proc reqInt(node: JsonNode, key: string, line: int): int =
  ## A required integer field, or a SessionError with the line number.
  if node.hasKey(key) and node[key].kind == JInt:
    return node[key].getInt
  missingField(line, key)

proc reqBool(node: JsonNode, key: string, line: int): bool =
  ## A required boolean field, or a SessionError with the line number.
  if node.hasKey(key) and node[key].kind == JBool:
    return node[key].getBool
  missingField(line, key)

proc reqParent(node: JsonNode, key: string, line: int): Option[int] =
  ## The required `parentId` field: a JSON integer or `null` for the root.
  if node.hasKey(key) and node[key].kind in {JInt, JNull}:
    if node[key].kind == JNull:
      return none(int)
    return some(node[key].getInt)
  missingField(line, key)

proc entryToJson(entry: SessionEntry): JsonNode =
  ## One entry as its JSONL object: type, id, parentId, timestamp, then the
  ## kind-specific payload fields.
  result = newJObject()
  result["type"] = newJString($entry.kind)
  result["id"] = newJInt(entry.id)
  result["parentId"] =
    if entry.parentId.isSome: newJInt(entry.parentId.get)
    else: newJNull()
  result["timestamp"] = newJString(entry.timestamp)
  case entry.kind
  of ekUser:
    result["text"] = newJString(entry.text)
  of ekAssistant:
    result["text"] = newJString(entry.text)
    result["model"] = newJString(entry.model)
    result["provider"] = newJString(entry.provider)
    result["usageInput"] = newJInt(entry.usageInput)
    result["usageOutput"] = newJInt(entry.usageOutput)
    result["stopReason"] = newJString(entry.stopReason)
  of ekToolResult:
    result["toolCallId"] = newJString(entry.toolCallId)
    result["toolName"] = newJString(entry.toolName)
    result["output"] = newJString(entry.output)
    result["isError"] = newJBool(entry.isError)

proc entryFromJson(node: JsonNode, line: int): SessionEntry =
  ## Rebuild one entry from a parsed JSONL line. The `"type"` discriminator
  ## and every field the kind requires are mandatory; a missing or invalid
  ## field raises SessionError with the line number.
  let typeStr = reqString(node, "type", line)
  let id = reqInt(node, "id", line)
  let parentId = reqParent(node, "parentId", line)
  let timestamp = reqString(node, "timestamp", line)
  case typeStr
  of "user":
    result = SessionEntry(kind: ekUser, id: id, parentId: parentId,
      timestamp: timestamp, text: reqString(node, "text", line))
  of "assistant":
    result = SessionEntry(kind: ekAssistant, id: id, parentId: parentId,
      timestamp: timestamp, text: reqString(node, "text", line),
      model: reqString(node, "model", line),
      provider: reqString(node, "provider", line),
      usageInput: reqInt(node, "usageInput", line),
      usageOutput: reqInt(node, "usageOutput", line),
      stopReason: reqString(node, "stopReason", line))
  of "toolResult":
    result = SessionEntry(kind: ekToolResult, id: id, parentId: parentId,
      timestamp: timestamp, toolCallId: reqString(node, "toolCallId", line),
      toolName: reqString(node, "toolName", line),
      output: reqString(node, "output", line),
      isError: reqBool(node, "isError", line))
  else:
    raise newException(SessionError,
      "line " & $line & ": unknown entry type \"" & typeStr & "\"")

proc newSession*(path: string): Session =
  ## Load the JSONL file at `path`, or start a fresh empty session when the
  ## file does not exist (it is created on the first append). Entries rebuild
  ## in file order and `currentId` defaults to the last entry's id — the
  ## active branch is the last appended path. A malformed line raises
  ## SessionError with its line number.
  if not fileExists(path):
    return Session(path: path, currentId: 0, entries: @[])
  var content = ""
  try:
    content = readFile(path)
  except OSError, IOError:
    raise newException(SessionError,
      "cannot read session file: " & getCurrentExceptionMsg())
  if content.len == 0:
    return Session(path: path, currentId: 0, entries: @[])
  let lines = content.strip(chars = {'\n', '\r'}).splitLines()
  var entries: seq[SessionEntry]
  var seen: HashSet[int]
  for i, line in lines:
    let lineNumber = i + 1
    let node = try: parseJson(line)
      except JsonParsingError as e:
        raise newException(SessionError,
          "line " & $lineNumber & ": invalid JSON: " & e.msg)
    let entry = entryFromJson(node, lineNumber)
    if entry.id < 1:
      raise newException(SessionError,
        "line " & $lineNumber & ": entry ids are 1-based")
    if entries.len > 0 and entry.id <= entries[^1].id:
      raise newException(SessionError,
        "line " & $lineNumber & ": entry ids must increase per file")
    if entry.parentId.isSome and entry.parentId.get notin seen:
      raise newException(SessionError,
        "line " & $lineNumber & ": parent id " & $entry.parentId.get &
        " does not appear earlier in the file")
    seen.incl entry.id
    entries.add entry
  let currentId = if entries.len > 0: entries[^1].id else: 0
  result = Session(path: path, entries: entries, currentId: currentId)

proc append*(s: Session, entry: SessionEntry) =
  ## Append `entry` to the session: the id (last id + 1), the parent (the
  ## active branch's tip — none for the root), and the ISO 8601 timestamp are
  ## assigned here and overwrite what the caller set for those fields. One
  ## JSONL line is appended (existing lines are never rewritten) and
  ## `currentId` moves to the new entry. A write failure raises SessionError.
  let id = (if s.entries.len > 0: s.entries[^1].id else: 0) + 1
  var stored = entry
  stored.id = id
  stored.parentId =
    if s.currentId > 0: some(s.currentId)
    else: none(int)
  stored.timestamp = now().format("yyyy-MM-dd'T'HH:mm:sszzz")
  var line = ""
  toUgly(line, entryToJson(stored))
  line.add '\n'
  try:
    var file = open(s.path, fmAppend)
    try:
      file.write(line)
    finally:
      file.close()
  except IOError:
    raise newException(SessionError,
      "cannot append to session file: " & getCurrentExceptionMsg())
  s.entries.add stored
  s.currentId = id

proc navigateTo*(s: Session, id: int) =
  ## Move the active branch to the existing entry with `id`: the next
  ## append's parent becomes that entry, branching in place, and `currentId`
  ## changes immediately. Any existing entry is navigable — navigating to
  ## another branch's tip switches the active branch, the general form of the
  ## earlier-entry case. Raises SessionError when no entry with `id` exists.
  for entry in s.entries:
    if entry.id == id:
      s.currentId = id
      return
  raise newException(SessionError,
    "no entry with id " & $id & " in " & s.path)

proc history*(s: Session): seq[SessionEntry] =
  ## The active branch's entries, root first: the path from the root entry to
  ## `currentId` — the ordered history for a model request.
  var index: Table[int, int]
  for i, entry in s.entries:
    index[entry.id] = i
  var branch: seq[SessionEntry]
  var current = s.currentId
  while current > 0:
    let entry = s.entries[index[current]]
    branch.add entry
    current = entry.parentId.get(0)
  result = reversed(branch)
