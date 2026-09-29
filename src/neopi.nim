## The neopi CLI entry: the print mode and the interactive TUI.
##
## `neopi "prompt"` assembles the extensibility runtime against the current
## directory, loads the Lua runtime, runs the agent loop with the prompt, and
## prints the final text to stdout. With no prompt argument, the interactive
## TUI opens instead and drives the same engine. The provider key comes from
## the environment or the local .env file.
##
## Errors (no key, provider failure, Lua failure) print a clear message to
## stderr and exit non-zero. Compile always with -o:build/neopi (never
## next-to-source).

import std/[envvars, json, options, os, parseopt, strutils, syncio, times]
import neopi/[extensibility, lua, provider, session, tui]

# Same file-scope typedef as lua.nim and the bridge modules: no C headers
# exist to declare the opaque state type, and this file's generated C
# prototypes take it (loadRuntime's LuaState parameter).
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

const DefaultModel = "inclusionai/ling-3.0-flash-vl"
  ## The tp_real default (openrouter-flavored); override with --model or
  ## <PROVIDER>_MODEL.

const Usage = """Usage:
  neopi "prompt" [--provider openai|openrouter] [--model <id>]
  neopi [--provider openai|openrouter] [--model <id>]
"""

proc fatal(msg: string) {.noreturn.} =
  ## A clear failure message on stderr and a non-zero exit.
  stderr.writeLine("neopi: " & msg)
  quit(1)

func escapeLua(s: string): string =
  ## Escape a string for a single-quoted Lua literal: only the quote and the
  ## backslash need escaping there.
  result = ""
  for c in s:
    case c
    of '\'', '\\': result.add "\\" & c
    else: result.add c

proc loadDotEnv(path = ".env") =
  ## Populate the environment from a local KEY=VALUE file. Existing values
  ## win; the file never overwrites them. (The tp_real pattern.)
  if not fileExists(path):
    return
  for line in lines(path):
    let trimmed = line.strip
    if trimmed.len > 0 and not trimmed.startsWith('#'):
      let sep = trimmed.find('=')
      if sep > 0:
        let key = trimmed[0 ..< sep].strip
        let value = trimmed[sep + 1 .. ^1].strip(chars = Whitespace + {'"'})
        if key.len > 0 and getEnv(key).len == 0:
          putEnv(key, value)

proc runtimeDir(): string =
  ## The Lua runtime directory: $NEOPI_RUNTIME_DIR when set, else
  ## <binary dir>/../runtime (a build from the repo), else ./runtime. The
  ## binary drives, the runtime composes; shipping the runtime with the
  ## binary is a later packaging concern.
  let env = getEnv("NEOPI_RUNTIME_DIR")
  if env.len > 0:
    return env
  let fromBinary = getAppDir() / ".." / "runtime"
  if dirExists(fromBinary):
    return fromBinary
  result = "runtime"

proc loadRuntime(L: LuaState) =
  ## Extend package.path with the runtime directory and load the runtime
  ## entry. The entry returns the agent table; the callers reach the modules
  ## through package.loaded, so the return value is not needed here.
  let dir = runtimeDir()
  if not fileExists(dir / "init.lua"):
    fatal("runtime entry not found: " & dir / "init.lua" &
      " (set NEOPI_RUNTIME_DIR)")
  let chunk = "package.path = '" &
    escapeLua(dir / "?.lua;" & dir / "?/init.lua") & ";' .. package.path"
  try:
    runScript(L, chunk, "runtime-path")
  except LuaError as e:
    fatal("cannot extend the lua package paths: " & e.msg)
  var source = ""
  try:
    source = readFile(dir / "init.lua")
  except OSError, IOError:
    fatal("cannot read " & dir / "init.lua")
  try:
    runScript(L, source, "runtime/init.lua")
  except LuaError as e:
    fatal("the runtime failed to load: " & e.msg)

proc runPrint(prompt, providerName: string, modelId: string) =
  ## The print mode: one prompt → one run; the final text on stdout.
  loadDotEnv()
  let upper = providerName.toUpperAscii
  case providerName
  of "openai", "openrouter": discard
  else: fatal("unknown provider \"" & providerName & "\" (openai or openrouter)")
  let key = getEnv(upper & "_API_KEY")
  if key.len == 0:
    fatal("no " & upper & "_API_KEY in the environment or .env; export it " &
      "or pass --provider/--model")
  let p = if providerName == "openai": openAI(key) else: openRouter(key)
  let root = getCurrentDir()
  let sessionsDir = root / ".neopi" / "sessions"
  try:
    createDir(sessionsDir)
  except OSError, IOError:
    fatal("cannot create " & sessionsDir & ": " & getCurrentExceptionMsg())
  let sessionPath = sessionsDir /
    ("run-" & ($epochTime()).replace(".", "-") & ".jsonl")
  let s = try: newSession(sessionPath)
    except CatchableError as e:
      fatal("cannot open the session: " & e.msg)
  # The prompt enters the session first; the loop builds each request from
  # the session history.
  s.append(SessionEntry(kind: ekUser, text: prompt))
  let ext = newExtensibility(root, some(p), s)
  loadRuntime(ext.bus.state)
  # The loop: agent.run(neopi.session, {model = ...}) — the response is a
  # Lua table; evalJson converts it.
  let chunk = "local agent = require('agent'); " &
    "return agent.run(neopi.session, {model = '" & escapeLua(modelId) & "'})"
  let response = try: evalJson(ext.bus.state, chunk)
    except LuaError as e:
      fatal("the agent loop failed: " & e.msg)
  stdout.writeLine(response{"text"}.getStr)
  if response{"stopReason"}.getStr == "stepLimit":
    stderr.writeLine("neopi: the loop hit its step cap before the model finished")

proc runTui(providerName, modelId: string) =
  ## The TUI mode: no prompt argument; the interactive loop drives the
  ## engine (the same agent.run chunk with the stream sink — the deltas
  ## render live) and the session persists through the same JSONL tree.
  loadDotEnv()
  let upper = providerName.toUpperAscii
  case providerName
  of "openai", "openrouter": discard
  else: fatal("unknown provider \"" & providerName & "\" (openai or openrouter)")
  let key = getEnv(upper & "_API_KEY")
  if key.len == 0:
    fatal("no " & upper & "_API_KEY in the environment or .env; export it " &
      "or pass --provider/--model")
  let p = if providerName == "openai": openAI(key) else: openRouter(key)
  let root = getCurrentDir()
  let sessionsDir = root / ".neopi" / "sessions"
  try:
    createDir(sessionsDir)
  except OSError, IOError:
    fatal("cannot create " & sessionsDir & ": " & getCurrentExceptionMsg())
  let sessionPath = sessionsDir /
    ("run-" & ($epochTime()).replace(".", "-") & ".jsonl")
  let s = try: newSession(sessionPath)
    except CatchableError as e:
      fatal("cannot open the session: " & e.msg)
  # No prompt enters the session here: the composer's sends do.
  let ext = newExtensibility(root, some(p), s)
  loadRuntime(ext.bus.state)
  let error = tuiLoop(s, ext.bus.state, providerName, modelId)
  if error.len > 0:
    fatal("the agent loop failed: " & error)

proc main() =
  var prompt = ""
  var providerName = "openrouter"
  var modelId = ""
  var sawPrompt = false
  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "provider": providerName = val
      of "model": modelId = val
      of "h", "help":
        stdout.writeLine(Usage)
        quit(0)
      else:
        fatal("unknown option --" & key & "; " & Usage)
    of cmdArgument:
      if sawPrompt:
        fatal("expected one prompt argument; " & Usage)
      prompt = key
      sawPrompt = true
    of cmdEnd: discard
  if modelId.len == 0:
    modelId = getEnv(providerName.toUpperAscii & "_MODEL", DefaultModel)
  if not sawPrompt:
    # The TUI mode: no prompt argument; the interactive loop drives the
    # engine. A clean exit returns here; a loop failure fatals inside.
    runTui(providerName, modelId)
    quit(0)
  runPrint(prompt, providerName, modelId)

when isMainModule:
  main()
