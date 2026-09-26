## Model-callable agent tools for neopi: read, write, edit, and bash.
##
## The four constructors build neopi `Tool` values the model calls through
## generate/stream: a JSON schema (what the model sees) and a confined
## execute callback over `resolveConfined`. The workspace root is a
## constructor parameter, so every path resolves against it; failures raise
## Nim exceptions whose messages the tool mapping reports to the model as
## tool failures. Known limit: confinement is lexical (`normalizedPath` does
## not resolve symlinks), so a symlink inside the workspace pointing outside
## it is followed.

import std/[json, os, osproc, strutils]
import neopi/[fs, provider]

const
  MaxReadLines = 2000       # pi's DEFAULT_MAX_LINES
  MaxReadBytes = 50 * 1024  # pi's DEFAULT_MAX_BYTES (50KB)

func toInt(n: JsonNode): int =
  ## A JSON number as an int: JInt and JFloat both convert; other kinds give 0.
  case n.kind
  of JInt: n.getInt
  of JFloat: int(n.getFloat)
  else: 0

func formatSize(bytes: int): string =
  ## Human-readable size mirroring pi's formatSize: 51200 becomes "50.0KB".
  if bytes < 1024:
    $bytes & "B"
  elif bytes < 1024 * 1024:
    formatFloat(bytes / 1024, ffDecimal, 1) & "KB"
  else:
    formatFloat(bytes / (1024 * 1024), ffDecimal, 1) & "MB"

proc readTool*(workspaceRoot: string): Tool =
  ## Model-callable `read`: the file content with cat -n style line numbers
  ## (a line-number prefix followed by a tab), truncated to 2000 lines or
  ## 50KB (whichever hits first); `offset` (1-indexed) and `limit` select a
  ## slice for large files. pi's model-facing read output is not numbered
  ## (its numbering is display-only in the TUI renderer), so the numbering
  ## here follows cat -n and mirrors pi's truncation notes.
  Tool(
    name: "read",
    description: "Read file contents. Output is truncated to " & $MaxReadLines &
      " lines or " & $(MaxReadBytes div 1024) &
      "KB (whichever is hit first). Use offset/limit for large files. " &
      "When you need the full file, continue with offset until complete.",
    inputSchema: %*{"type": "object",
      "properties": {
        "path": {"type": "string",
          "description": "Path to the file to read (relative or absolute)"},
        "offset": {"type": "number",
          "description": "Line number to start reading from (1-indexed)"},
        "limit": {"type": "number",
          "description": "Maximum number of lines to read"}},
      "required": ["path"]},
    execute: proc (args: JsonNode): string =
      let requested = args["path"].getStr
      let resolved = resolveConfined(workspaceRoot, requested)
      if not fileExists(resolved):
        raise newException(IOError, "file not found: " & requested)
      var content = ""
      try:
        content = readFile(resolved)
      except OSError, IOError:
        raise newException(IOError, "failed to read " & requested & ": " &
          getCurrentExceptionMsg())
      # cat -n semantics: a trailing newline does not start a new line.
      var lines: seq[string]
      if content.len > 0:
        lines = content.split('\n')
        if content.endsWith("\n"):
          discard lines.pop()
      let offsetGiven = args.hasKey("offset") and args["offset"].kind != JNull
      let limitGiven = args.hasKey("limit") and args["limit"].kind != JNull
      let offsetValue = if offsetGiven: toInt(args["offset"]) else: 0
      let start =
        if offsetGiven: max(1, offsetValue) - 1
        else: 0
      if offsetGiven and start >= lines.len:
        raise newException(ValueError, "Offset " & $offsetValue &
          " is beyond end of file (" & $lines.len & " lines total)")
      if lines.len == 0:
        return ""
      # Number every line with its absolute file line number, then apply
      # offset/limit on the numbered lines.
      var numbered: seq[string]
      for i, line in lines:
        numbered.add $(i + 1) & "\t" & line
      var selected: seq[string]
      if limitGiven:
        let endLine = min(start + toInt(args["limit"]), lines.len)
        selected = numbered[start..<endLine]
      else:
        selected = numbered[start..^1]
      # Truncate at 2000 lines or 50KB (whichever hits first), keeping
      # complete lines only.
      var kept: seq[string]
      var keptBytes = 0
      var truncated = false
      var truncatedByBytes = false
      for line in selected:
        if kept.len >= MaxReadLines:
          truncated = true
          break
        let lineBytes = line.len + (if kept.len > 0: 1 else: 0)
        if keptBytes + lineBytes > MaxReadBytes:
          truncated = true
          truncatedByBytes = true
          break
        kept.add line
        keptBytes += lineBytes
      if not truncated:
        return selected.join("\n")
      if kept.len == 0:
        # The first line alone exceeds the byte limit.
        let display = start + 1
        return "[Line " & $display & " is " & formatSize(selected[0].len) &
          ", exceeds " & formatSize(MaxReadBytes) &
          " limit. Use bash: sed -n '" & $display & "p' " & requested &
          " | head -c " & $MaxReadBytes & "]"
      let startDisplay = start + 1
      let endDisplay = startDisplay + kept.len - 1
      let nextOffset = endDisplay + 1
      var output = kept.join("\n")
      if truncatedByBytes:
        output.add "\n\n[Showing lines " & $startDisplay & "-" & $endDisplay &
          " of " & $lines.len & " (" & formatSize(MaxReadBytes) &
          " limit). Use offset=" & $nextOffset & " to continue.]"
      else:
        output.add "\n\n[Showing lines " & $startDisplay & "-" & $endDisplay &
          " of " & $lines.len & ". Use offset=" & $nextOffset &
          " to continue.]"
      output)

proc writeTool*(workspaceRoot: string): Tool =
  ## Model-callable `write`: creates the file if it does not exist, overwrites
  ## if it does, and creates parent directories automatically.
  Tool(
    name: "write",
    description: "Write content to a file. Creates the file if it doesn't " &
      "exist, overwrites if it does. Automatically creates parent directories.",
    inputSchema: %*{"type": "object",
      "properties": {
        "path": {"type": "string",
          "description": "Path to the file to write (relative or absolute)"},
        "content": {"type": "string",
          "description": "Content to write to the file"}},
      "required": ["path", "content"]},
    execute: proc (args: JsonNode): string =
      let requested = args["path"].getStr
      let resolved = resolveConfined(workspaceRoot, requested)
      let content = args["content"].getStr
      var failure = ""
      try:
        createDir(parentDir(resolved))
        writeFile(resolved, content)
      except OSError, IOError:
        failure = "failed to write " & requested & ": " &
          getCurrentExceptionMsg()
      if failure.len > 0:
        raise newException(IOError, failure)
      "Successfully wrote to " & requested)

proc editTool*(workspaceRoot: string): Tool =
  ## Model-callable `edit`: exact-match replacement that must be unique — 0
  ## matches is not found, more than 1 is ambiguous, and identical text makes
  ## no change. Exact match only: no fuzzy matching and no CRLF normalization.
  Tool(
    name: "edit",
    description: "Edit a single file using exact text replacement. oldText " &
      "must match a unique, non-overlapping region of the file.",
    inputSchema: %*{"type": "object",
      "properties": {
        "path": {"type": "string",
          "description": "Path to the file to edit (relative or absolute)"},
        "oldText": {"type": "string",
          "description": "Exact text to replace"},
        "newText": {"type": "string",
          "description": "Replacement text"}},
      "required": ["path", "oldText", "newText"]},
    execute: proc (args: JsonNode): string =
      let requested = args["path"].getStr
      let resolved = resolveConfined(workspaceRoot, requested)
      if not fileExists(resolved):
        raise newException(IOError, "file not found: " & requested)
      let oldText = args["oldText"].getStr
      let newText = args["newText"].getStr
      if oldText.len == 0:
        raise newException(ValueError, "oldText must not be empty in " &
          requested)
      var content = ""
      try:
        content = readFile(resolved)
      except OSError, IOError:
        raise newException(IOError, "failed to read " & requested & ": " &
          getCurrentExceptionMsg())
      let matches = content.count(oldText)
      if matches == 0:
        raise newException(ValueError, "oldText not found in " & requested)
      if matches > 1:
        raise newException(ValueError, "oldText matches " & $matches &
          " times in " & requested &
          " — provide more context to make it unique")
      if oldText == newText:
        raise newException(ValueError, "no changes made to " & requested)
      let updated = content.replace(oldText, newText)
      var failure = ""
      try:
        writeFile(resolved, updated)
      except OSError, IOError:
        failure = "failed to write " & requested & ": " &
          getCurrentExceptionMsg()
      if failure.len > 0:
        raise newException(IOError, failure)
      "Edited " & requested & ": 1 replacement")

proc bashTool*(workspaceRoot: string): Tool =
  ## Model-callable `bash`: runs the command in the workspace root and returns
  ## its output, with the exit code appended when non-zero.
  Tool(
    name: "bash",
    description: "Execute a bash command in the workspace root. Returns " &
      "stdout and stderr; a non-zero exit code is appended to the output.",
    inputSchema: %*{"type": "object",
      "properties": {
        "command": {"type": "string",
          "description": "The bash command to execute"}},
      "required": ["command"]},
    execute: proc (args: JsonNode): string =
      let command = args["command"].getStr
      var output = ""
      var failure = ""
      try:
        let outcome = execCmdEx(command, workingDir = workspaceRoot)
        output = outcome.output
        if outcome.exitCode != 0:
          if output.len > 0 and not output.endsWith("\n"):
            output.add "\n"
          output.add "[exit code: " & $outcome.exitCode & "]"
      except OSError, ValueError:
        failure = "failed to run " & command & ": " &
          getCurrentExceptionMsg()
      if failure.len > 0:
        raise newException(IOError, failure)
      output)
