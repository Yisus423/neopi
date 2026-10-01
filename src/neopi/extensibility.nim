## Assembly of neopi's extensibility surface: the hook bus, the provider and
## session exposures, the confined fs primitives, the spawn-per-call
## process primitive, and the hook emit on one embedded Lua interpreter.
##
## `newExtensibility` owns the interpreter: extension scripts register
## handlers with `neopi.on`, publish events with `neopi.emit`, compute in
## Lua only, and reach side effects exclusively through the confined
## `neopi.fs` and `neopi.process` tables; the runtime layer reaches the
## provider and the session through `neopi.provider` and `neopi.session`.

import std/[json, options, os]
import neopi/lua
import neopi/hooks
import neopi/fs
import neopi/process
import neopi/expose
import neopi/provider
import neopi/session

# Same file-scope typedef as lua.nim/hooks.nim/provider.nim: the emit closure
# materializes the HookBus object, whose field holds the opaque state type.
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

type
  Extensibility* = ref object
    ## Owns the extensibility surface: the hook bus, the workspace root the
    ## confined primitives resolve against, and the optional session exposed
    ## to Lua as `neopi.session`. The session reference lives here, so the
    ## registry pointer the Lua callbacks read stays valid for the
    ## extensibility's lifetime.
    bus*: HookBus
    workspaceRoot*: string
    session: Session

proc newExtensibility*(workspaceRoot: string, provider = none(Provider),
                       session: Session = nil, hardened = true): Extensibility =
  ## Assemble the hook bus, the provider and session exposures, the confined
  ## fs primitives, and the process primitive on the same embedded
  ## interpreter. With an empty `workspaceRoot`, the confined fs and process
  ## primitives stay unexposed. `provider` is the optional backing provider
  ## for `neopi.provider.generate`; `session` is the optional session wrapped
  ## as `neopi.session`. `hardened = false` opens the full standard library
  ## set (the test/spec baseline).
  result = Extensibility(bus: newHookBus(hardened),
    workspaceRoot: workspaceRoot, session: session)
  if not session.isNil:
    exposeSession(result.bus.state, session)
  exposeProvider(result.bus.state, provider)
  exposeEmit(result.bus.state)
  if workspaceRoot.len == 0:
    return
  let bus = result.bus
  let busEmit = proc (event: string, payload: JsonNode): HookOutcome =
    bus.emit(event, payload)
  exposeFs(bus.state, workspaceRoot)
  exposeProcess(bus.state, workspaceRoot, busEmit)

func escapeLua(s: string): string =
  ## Escape a string for a single-quoted Lua literal: only the quote and the
  ## backslash need escaping there. The file-scope copy the other modules
  ## carry (neopi.nim, the test helpers); the consolidation into lua.nim is
  ## a future cleanup.
  result = ""
  for c in s:
    case c
    of '\'', '\\': result.add "\\" & c
    else: result.add c

proc loadUserConfig*(root: string, L: LuaState) =
  ## Load the user's config: the .neopi/init.lua entrypoint (the nvim model
  ## — ONE config file the user owns; the config requires the extensions,
  ## and require resolves through the extended package path). Missing: a
  ## no-op (the bare agent). A failure raises LuaError — the binary decides
  ## the severity (the stderr warning + continue, nvim's model).
  ##
  ## The package.path gains .neopi/ before the config sources, so the
  ## config's requires resolve: require('extensions.echo') loads
  ## .neopi/extensions/echo.lua.
  let configPath = root / ".neopi" / "init.lua"
  if not fileExists(configPath):
    return
  let chunk = "package.path = '" &
    escapeLua(root / ".neopi" / "?.lua") & ";' .. package.path"
  runScript(L, chunk, "userconfig-path")
  var source = ""
  try:
    source = readFile(configPath)
  except OSError, IOError:
    raise newException(LuaError, "cannot read " & configPath & ": " &
      getCurrentExceptionMsg())
  runScript(L, source, "userconfig/init.lua")
