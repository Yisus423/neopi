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
import neopi/[authstore, extensibility, lua, provider, session, tui]

# Same file-scope typedef as lua.nim and the bridge modules: no C headers
# exist to declare the opaque state type, and this file's generated C
# prototypes take it (loadRuntime's LuaState parameter).
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

const DefaultModel = "inclusionai/ling-3.0-flash-vl"
  ## The tp_real default (openrouter-flavored); override with --model or
  ## <PROVIDER>_MODEL.

proc usage(): string =
  ## The help text, built from the provider TABLE so the list can never drift
  ## from what `--provider` accepts: every entry's id, the endpoint it targets
  ## and the variable its key comes from (or that it needs none). The synopsis
  ## spells the `=` form because that is the one this CLI parses — a
  ## space-separated value arrives as a positional argument.
  var providers = ""
  for spec in knownProviders():
    let key = if spec.requiresKey: spec.envVar else: "keyless"
    providers.add "  " & spec.id.alignLeft(11) & spec.baseUrl.alignLeft(36) &
      key & "\n"
  result = "Usage:\n" &
    "  neopi \"prompt\" [--provider=<id>] [--model=<id>] [--base-url=<url>]\n" &
    "  neopi [--provider=<id>] [--model=<id>] [--base-url=<url>]\n" &
    "\n" &
    "Options:\n" &
    "  --provider=<id>   which provider to use (default openrouter)\n" &
    "  --model=<id>      the model to request: <PROVIDER>_MODEL when set, else\n" &
    "                    " & DefaultModel & "\n" &
    "  --base-url=<url>  overrides the endpoint — a gateway whose URL differs,\n" &
    "                    or one the table does not carry\n" &
    "\n" &
    "Providers:\n" & providers &
    "\n" &
    "The key comes from " & authFilePath() & " (a stored credential\n" &
    "wins), then the provider's variable, then the project's .env; a keyless\n" &
    "server needs none. The TUI's /login writes the store.\n"

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

proc specOf(name: string): ProviderSpec =
  ## The table entry a `--provider` value names, or a clear failure listing what
  ## this build carries. The name is validated ONCE, here, so every path below
  ## reads the same entry.
  let spec = findProvider(name)
  if spec.isSome:
    return spec.get
  var known: seq[string]
  for entry in knownProviders():
    known.add entry.id
  fatal("unknown provider \"" & name & "\" (known: " & known.join(", ") & ")")

proc resolveKey(spec: ProviderSpec): string =
  ## The key a start uses, in pi's order: a STORED credential wins, then the
  ## entry's environment variable (which `.env` has already populated). A stored
  ## credential owns its provider, so an environment variable never overrides a
  ## key the user installed with `/login`.
  let stored = loadApiKey(spec.id)
  if stored.isSome:
    return stored.get
  getEnv(spec.envVar)

proc providerFor(spec: ProviderSpec, baseUrl: string): Option[Provider] =
  ## The provider a start builds from its entry. An entry that REQUIRES a key and
  ## has none yields no provider — the state `/login` completes from inside the
  ## TUI — while a keyless entry always builds one, with whatever key it happens
  ## to carry.
  let key = resolveKey(spec)
  if key.len == 0 and spec.requiresKey:
    return none(Provider)
  some(newProvider(spec, key, baseUrl))

proc runPrint(prompt: string, spec: ProviderSpec, modelId, baseUrl: string) =
  ## The print mode: one prompt → one run; the final text on stdout.
  loadDotEnv()
  let key = resolveKey(spec)
  if key.len == 0 and spec.requiresKey:
    fatal("no " & spec.envVar & " in the environment or .env, and no stored " &
      "credential in " & authFilePath() & "; export it, or run the TUI and " &
      "install it with /login")
  let p = newProvider(spec, key, baseUrl)
  let root = getCurrentDir()
  let sessionsDir = root / ".neopi" / "sessions"
  try:
    createDir(sessionsDir)
  except OSError, IOError:
    fatal("cannot create " & sessionsDir & ": " & getCurrentExceptionMsg())
  let sessionPath = newSessionPath(root)
  let s = try: newSession(sessionPath)
    except CatchableError as e:
      fatal("cannot open the session: " & e.msg)
  # The prompt enters the session first; the loop builds each request from
  # the session history.
  s.append(SessionEntry(kind: ekUser, text: prompt))
  let ext = newExtensibility(root, some(p), s)
  exposeUi(ext.bus.state)
  loadRuntime(ext.bus.state)
  try:
    loadUserConfig(root, ext.bus.state)
  except LuaError as e:
    stderr.writeLine("neopi: the user config failed to load: " & e.msg)
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

proc runTui(spec: ProviderSpec, modelId, baseUrl: string) =
  ## The TUI mode: no prompt argument; the interactive loop drives the
  ## engine (the same agent.run chunk with the stream sink — the deltas
  ## render live) and the session persists through the same JSONL tree.
  loadDotEnv()
  # A missing key is not fatal in the TUI: `/login` is the key's runtime home,
  # so a keyless start is reachable. The session opens with no provider and a
  # turn attempted before `/login` reports it as feedback. The print mode keeps
  # its own fatal — it has no `/login`.
  let backing = providerFor(spec, baseUrl)
  let root = getCurrentDir()
  let sessionsDir = root / ".neopi" / "sessions"
  try:
    createDir(sessionsDir)
  except OSError, IOError:
    fatal("cannot create " & sessionsDir & ": " & getCurrentExceptionMsg())
  let sessionPath = newSessionPath(root)
  let s = try: newSession(sessionPath)
    except CatchableError as e:
      fatal("cannot open the session: " & e.msg)
  # No prompt enters the session here: the composer's sends do.
  let ext = newExtensibility(root, backing, s)
  exposeUi(ext.bus.state)
  loadRuntime(ext.bus.state)
  try:
    loadUserConfig(root, ext.bus.state)
  except LuaError as e:
    stderr.writeLine("neopi: the user config failed to load: " & e.msg)
  let error = tuiLoop(s, ext.bus.state, spec.id, modelId, root)
  if error.len > 0:
    fatal("the agent loop failed: " & error)

proc main() =
  var prompt = ""
  var providerName = "openrouter"
  var modelId = ""
  var baseUrl = ""
  var sawPrompt = false
  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "provider": providerName = val
      of "model": modelId = val
      of "base-url": baseUrl = val
      of "h", "help":
        stdout.writeLine(usage())
        quit(0)
      else:
        fatal("unknown option --" & key & "; " & usage())
    of cmdArgument:
      if sawPrompt:
        fatal("expected one prompt argument; " & usage())
      prompt = key
      sawPrompt = true
    of cmdEnd: discard
  let spec = specOf(providerName)
  if modelId.len == 0:
    modelId = getEnv(spec.id.toUpperAscii & "_MODEL", DefaultModel)
  if not sawPrompt:
    # The TUI mode: no prompt argument; the interactive loop drives the
    # engine. A clean exit returns here; a loop failure fatals inside.
    runTui(spec, modelId, baseUrl)
    quit(0)
  runPrint(prompt, spec, modelId, baseUrl)

when isMainModule:
  main()
