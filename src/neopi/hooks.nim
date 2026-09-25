## Hook registry and core-side emit for neopi's extensibility.
##
## Extension scripts register handlers with `neopi.on(event, fn)`; the core
## fires events through `emit`, invoking every handler registered for the
## event in registration order via pcall containment. Handler return values
## block or rewrite — the pi/nvim model: the core exposes primitives, Lua
## composes, and a handler error aborts only that handler's contribution,
## never the host.

import std/json
import neopi/lua

# Same file-scope typedef as lua.nim: each module generates its own C file,
# and hooks.nim's C code references the opaque state type too.
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

proc lua_error*(L: LuaState): cint {.importc, cdecl.}
  ## Raise a Lua error from a Nim C function; never returns (it longjmps to
  ## the enclosing pcall). Declared here because lua.nim's frozen binding
  ## surface omits it.

proc raiseLuaError(L: LuaState, message: string) {.noreturn.} =
  ## Push `message` and raise it as a Lua error; lua_error longjmps to the
  ## enclosing pcall, so control never returns here.
  lua_pushstring(L, message)
  discard lua_error(L)

type
  HookBus* = ref object
    ## Owns the embedded Lua interpreter and the registered handler count.
    L: LuaState
    handlers: int

  HookOutcome* = object
    ## Result of one emit pass: whether the event is allowed, why it was
    ## blocked, and the rewritten payload when a handler patched it.
    allowed*: bool
    reason*: string
    patched*: bool
    payload*: JsonNode

const busRegistryKey = "neopi.bus"

proc luaOn(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.on(event, fn)`: validate the registration, store the
  ## handler in the registry, and count it. An invalid registration raises a
  ## Lua error, so the script's own pcall containment turns it into a load
  ## failure.
  let bus = cast[HookBus](getRegistryPointer(L, busRegistryKey))
  if bus.isNil or lua_gettop(L) != 2 or lua_type(L, 1) != luaTString or
      lua_type(L, 2) != luaTFunction:
    raiseLuaError(L, "neopi.on expects (event: string, handler: function)")
  discard luaL_ref(L, luaRegistryIndex)
  inc bus.handlers
  result = 0

proc newHookBus*(): HookBus =
  ## Create a hook bus with its own embedded Lua interpreter, store the bus
  ## pointer in the Lua registry so the Nim-implemented `neopi_on` can reach
  ## its owner, and expose `neopi.on(event, handler)` to extension scripts.
  result = HookBus(L: newLuaState(), handlers: 0)
  setRegistryPointer(result.L, busRegistryKey, cast[pointer](result))
  registerFunction(result.L, "neopi_on", luaOn)
  # Also expose the documented Lua API: a `neopi` table whose `on` field is
  # the same registration handler, so scripts call neopi.on(event, fn).
  lua_createtable(result.L, 0, 1)
  lua_pushcfunction(result.L, luaOn)
  lua_setfield(result.L, -2, "on")
  lua_setglobal(result.L, "neopi")

proc emit*(bus: HookBus, event: string, payload: JsonNode): HookOutcome =
  ## Fire every handler registered for `event` in registration order. The
  ## first return value drives the verdict: `false` blocks (a string second
  ## value, when present, is the reason), a table rewrites (it becomes
  ## `payload`), and `true`, `nil`, or nothing allows the event unchanged.
  ## Any blocked outcome stops the pass immediately. A Lua error inside a
  ## handler aborts only that handler's contribution.
  result = HookOutcome(allowed: true)
  if bus.handlers == 0:
    return
  let L = bus.L
  # Registration refs are dense 1..handlers: `neopi_on` refs handlers
  # without ever unref'ing, so luaL_ref handed out exactly that many refs.
  for i in 1 .. bus.handlers:
    lua_rawgeti(L, luaRegistryIndex, cint(i))
    pushJson(L, payload)
    if lua_pcall(L, 1, 2, 0) != 0:
      lua_pop(L, 1)  # containment: skip this handler's contribution
    else:
      if lua_gettop(L) >= 2:
        let kind = lua_type(L, -2)
        if kind == luaTBoolean and lua_toboolean(L, -2) == 0:
          result.allowed = false
          if lua_type(L, -1) == luaTString:
            result.reason = $lua_tolstring(L, -1, nil)
          lua_pop(L, 2)
          return
        if kind == luaTTable:
          result.patched = true
          result.payload = jsonOfStack(L, -2)
        lua_pop(L, 2)
      elif lua_gettop(L) > 0:
        # Defensive: stray results allow the event unchanged.
        lua_pop(L, lua_gettop(L))

proc loadExtension*(bus: HookBus, code: string) =
  ## Run an extension script in the bus's interpreter; its `neopi_on` calls
  ## register handlers. A LuaError here means the extension failed to load.
  runScript(bus.L, code, "extension")
