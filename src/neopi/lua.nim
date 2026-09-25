## LuaJIT 5.1 embedding for neopi's extensibility, via own FFI bindings.
##
## The bindings target the Lua 5.1 C API that LuaJIT implements. C headers are
## not required: every function takes an opaque `lua_State`, and the constants
## below are part of the frozen 5.1 ABI. Standard libs open selectively —
## ffi, io, os, and debug stay closed, so scripts have no FFI, filesystem,
## process, or debug access by default. Every call into Lua runs through
## pcall containment: a Lua error aborts that call's contribution, never the
## host.

{.passL: "-l:libluajit-5.1.so.2".}

# C headers are absent, so the opaque state type needs a file-scope typedef:
# without it, each generated C prototype would declare its own incompatible
# incomplete `struct lua_State`.
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

import std/[json, math]

type
  lua_State {.importc, incompleteStruct.} = object
    ## Opaque interpreter state.

  LuaState* = ptr lua_State
    ## An embedded LuaJIT interpreter with ffi, io, os, and debug closed.

  LuaError* = object of CatchableError
    ## Raised when a Lua script fails to load or run.

  lua_CFunction* = proc (L: ptr lua_State): cint {.cdecl.}
    ## Nim-implemented Lua function (the C callback signature).

  lua_Integer* = int64
  lua_Number* = float64

const
  luaTNil* = 0.cint
  luaTBoolean* = 1.cint
  luaTNumber* = 3.cint
  luaTString* = 4.cint
  luaTTable* = 5.cint
  luaTFunction* = 6.cint
  luaMultret* = -1.cint
  luaRegistryIndex* = -10000.cint
  luaGlobalsIndex* = -10002.cint  ## Pseudo-index of the globals table (5.1).
  luaRefNil* = -1.cint  ## luaL_ref result for the nil value; not a real ref.

proc luaL_newstate*(): ptr lua_State {.importc.}
proc luaL_loadbuffer*(L: ptr lua_State, buff: cstring, sz: csize_t,
                      name: cstring): cint {.importc.}
proc lua_pcall*(L: ptr lua_State, nargs: cint, nresults: cint,
                errfunc: cint): cint {.importc.}
proc lua_pushlstring*(L: ptr lua_State, s: cstring, len: csize_t) {.importc.}
proc lua_pushstring*(L: ptr lua_State, s: cstring) {.importc.}
proc lua_pushinteger*(L: ptr lua_State, n: lua_Integer) {.importc.}
proc lua_pushnumber*(L: ptr lua_State, n: lua_Number) {.importc.}
proc lua_pushboolean*(L: ptr lua_State, b: cint) {.importc.}
proc lua_pushcclosure*(L: ptr lua_State, fn: lua_CFunction, n: cint) {.importc.}
proc lua_pushcfunction*(L: ptr lua_State, fn: lua_CFunction) {.inline.} =
  ## lua_pushcfunction is a macro in Lua 5.1's lua.h: pushcclosure with
  ## no upvalues.
  lua_pushcclosure(L, fn, 0)
proc lua_pushlightuserdata*(L: ptr lua_State, p: pointer) {.importc.}
proc lua_pushnil*(L: ptr lua_State) {.importc.}
proc lua_type*(L: ptr lua_State, idx: cint): cint {.importc.}
proc lua_tolstring*(L: ptr lua_State, idx: cint, len: ptr csize_t): cstring {.importc.}
proc lua_tointeger*(L: ptr lua_State, idx: cint): lua_Integer {.importc.}
proc lua_tonumber*(L: ptr lua_State, idx: cint): lua_Number {.importc.}
proc lua_toboolean*(L: ptr lua_State, idx: cint): cint {.importc.}
proc lua_touserdata*(L: ptr lua_State, idx: cint): pointer {.importc.}
proc lua_settop*(L: ptr lua_State, idx: cint) {.importc.}
proc lua_gettop*(L: ptr lua_State): cint {.importc.}
proc lua_pop*(L: ptr lua_State, n: cint) {.inline.} =
  ## lua_pop is a macro in Lua 5.1's lua.h: settop relative to the top.
  lua_settop(L, -n - 1)
proc lua_setfield*(L: ptr lua_State, idx: cint, k: cstring) {.importc.}
proc lua_getfield*(L: ptr lua_State, idx: cint, k: cstring) {.importc.}
proc lua_getglobal*(L: ptr lua_State, name: cstring) {.inline.} =
  ## lua_getglobal is a macro in Lua 5.1's lua.h: getfield on the globals.
  lua_getfield(L, luaGlobalsIndex, name)
proc lua_setglobal*(L: ptr lua_State, name: cstring) {.inline.} =
  ## lua_setglobal is a macro in Lua 5.1's lua.h: setfield on the globals.
  lua_setfield(L, luaGlobalsIndex, name)
template luaUpvalueIndex*(i: cint): cint =
  ## lua_upvalueindex is a macro in Lua 5.1's lua.h: a pseudo-index below
  ## the globals addressing the running C function's i-th upvalue
  ## (LUA_UPVALUEINDEX(i) = LUA_GLOBALSINDEX - i = -10002 - i).
  luaGlobalsIndex - i
proc lua_settable*(L: ptr lua_State, idx: cint) {.importc.}
proc lua_createtable*(L: ptr lua_State, narr: cint, nrec: cint) {.importc.}
proc lua_rawgeti*(L: ptr lua_State, idx: cint, n: cint) {.importc.}
proc lua_rawseti*(L: ptr lua_State, idx: cint, n: cint) {.importc.}
proc lua_next*(L: ptr lua_State, idx: cint): cint {.importc.}
proc lua_call*(L: ptr lua_State, nargs: cint, nresults: cint) {.importc.}
proc luaL_ref*(L: ptr lua_State, t: cint): cint {.importc.}
proc luaL_unref*(L: ptr lua_State, t: cint, refIndex: cint) {.importc.}

proc luaopen_base*(L: ptr lua_State): cint {.importc, cdecl.}
proc luaopen_package*(L: ptr lua_State): cint {.importc, cdecl.}
proc luaopen_table*(L: ptr lua_State): cint {.importc, cdecl.}
proc luaopen_string*(L: ptr lua_State): cint {.importc, cdecl.}
proc luaopen_math*(L: ptr lua_State): cint {.importc, cdecl.}
proc luaopen_bit*(L: ptr lua_State): cint {.importc, cdecl.}
proc luaopen_io*(L: ptr lua_State): cint {.importc, cdecl.}
proc luaopen_os*(L: ptr lua_State): cint {.importc, cdecl.}
proc luaopen_debug*(L: ptr lua_State): cint {.importc, cdecl.}
proc luaopen_jit*(L: ptr lua_State): cint {.importc, cdecl.}
proc luaopen_ffi*(L: ptr lua_State): cint {.importc, cdecl.}

proc openLib(L: ptr lua_State, name: string, opener: lua_CFunction) =
  ## Open one standard library under `name`, the way luaL_openlibs does.
  ## An empty name loads the library into the globals directly (base).
  lua_pushcfunction(L, opener)
  lua_pushstring(L, name)
  lua_call(L, 1, 0)

proc luaStackMessage(L: ptr lua_State): string =
  ## The error string on top of the stack, for a failed load or pcall.
  if lua_type(L, -1) == luaTString:
    $lua_tolstring(L, -1, nil)
  else:
    "lua error (non-string object on stack)"

proc harden(L: LuaState) =
  ## Close the native-code escape hatches: remove the C (dlopen) package
  ## loader and nil the direct loadlib API, so scripts compute in Lua only —
  ## no native-code escape hatch. Declared before newLuaState (which calls
  ## it) and uses loadbuffer+pcall directly, which precede it: the chunk runs
  ## under pcall containment, so a Lua error becomes a LuaError, never an
  ## unwinding longjmp with no setjmp point.
  const chunk = """
table.remove(package.loaders, 3)
package.loadlib = nil
"""
  if luaL_loadbuffer(L, chunk, csize_t(chunk.len), "harden") != 0:
    let message = luaStackMessage(L)
    lua_pop(L, 1)
    raise LuaError.newException(message)
  if lua_pcall(L, 0, 0, 0) != 0:
    let message = luaStackMessage(L)
    lua_pop(L, 1)
    raise LuaError.newException(message)

proc newLuaState*(): LuaState =
  ## Create an interpreter with the safe standard libs open: base, package,
  ## table, string, math, bit. ffi, io, os, debug, and jit stay closed, so
  ## scripts have no FFI, filesystem, process, or debug access by default.
  ## harden also removes the C package loader and nils loadlib, so scripts
  ## have no native-code escape hatch.
  result = luaL_newstate()
  if result.isNil:
    raise LuaError.newException("could not create the lua state")
  openLib(result, "", luaopen_base)
  openLib(result, "package", luaopen_package)
  openLib(result, "table", luaopen_table)
  openLib(result, "string", luaopen_string)
  openLib(result, "math", luaopen_math)
  openLib(result, "bit", luaopen_bit)
  harden(result)

proc loadScript*(L: LuaState, code: string, name = "script"): bool =
  ## Compile a script chunk. False when compilation fails; the message stays
  ## on top of the stack until the caller pops or resets it.
  luaL_loadbuffer(L, code, csize_t(code.len), name) == 0

proc runScript*(L: LuaState, code: string, name = "script") =
  ## Load and run a script chunk. Raises LuaError with the Lua error message
  ## when the chunk fails to compile or run; the state stays usable.
  if not loadScript(L, code, name):
    let message = luaStackMessage(L)
    lua_pop(L, 1)
    raise LuaError.newException(message)
  if lua_pcall(L, 0, 0, 0) != 0:
    let message = luaStackMessage(L)
    lua_pop(L, 1)
    raise LuaError.newException(message)

proc evalString*(L: LuaState, code: string): string =
  ## Run `code` and return its string result. Raises LuaError when the chunk
  ## fails or the result is not a string.
  if not loadScript(L, code, "eval"):
    let message = luaStackMessage(L)
    lua_pop(L, 1)
    raise LuaError.newException(message)
  if lua_pcall(L, 0, 1, 0) != 0:
    let message = luaStackMessage(L)
    lua_pop(L, 1)
    raise LuaError.newException(message)
  if lua_type(L, -1) != luaTString:
    lua_pop(L, 1)
    raise LuaError.newException("the chunk did not return a string")
  result = $lua_tolstring(L, -1, nil)
  lua_pop(L, 1)

proc registerFunction*(L: LuaState, name: string, fn: lua_CFunction) =
  ## Expose a Nim C function as a Lua global.
  lua_pushcfunction(L, fn)
  lua_setglobal(L, name)

proc setRegistryPointer*(L: LuaState, key: string, p: pointer) =
  ## Store an opaque Nim pointer in the registry under `key`. The registry is
  ## invisible to scripts; C callbacks use it to reach their Nim owner.
  lua_pushlightuserdata(L, p)
  lua_setfield(L, luaRegistryIndex, key)

proc getRegistryPointer*(L: LuaState, key: string): pointer =
  ## Read the opaque pointer stored under `key`, or nil when absent.
  lua_getfield(L, luaRegistryIndex, key)
  result = lua_touserdata(L, -1)
  lua_pop(L, 1)

proc pushString*(L: LuaState, s: string) =
  ## Push a string value.
  lua_pushlstring(L, s, csize_t(s.len))

proc pushJson*(L: LuaState, node: JsonNode) =
  ## Push a JSON value as a Lua table, string, number, boolean, or nil.
  case node.kind
  of JString:
    pushString(L, node.getStr)
  of JInt:
    lua_pushinteger(L, node.getInt.lua_Integer)
  of JFloat:
    lua_pushnumber(L, node.getFloat.lua_Number)
  of JBool:
    lua_pushboolean(L, cint(node.getBool))
  of JNull:
    lua_pushnil(L)
  of JObject:
    lua_createtable(L, 0, cint(node.len))
    for key, value in node:
      pushString(L, key)
      pushJson(L, value)
      lua_settable(L, -3)
  of JArray:
    lua_createtable(L, cint(node.len), 0)
    var i = 1
    for value in node:
      pushJson(L, value)
      lua_rawseti(L, -2, cint(i))
      inc i

proc jsonOfStack*(L: LuaState, idx: cint): JsonNode =
  ## Convert the Lua value at `idx` into a JSON value: booleans, numbers,
  ## strings, and tables (arrays when the keys are 1..n). Other kinds become
  ## null. The value stays on the stack.
  case lua_type(L, idx)
  of luaTBoolean:
    result = newJBool(lua_toboolean(L, idx) != 0)
  of luaTNumber:
    let n = lua_tonumber(L, idx)
    if n == round(n):
      result = newJInt(n.int64)
    else:
      result = newJFloat(n)
  of luaTString:
    result = newJString($lua_tolstring(L, idx, nil))
  of luaTTable:
    var pairs: seq[tuple[key: string, value: JsonNode]]
    var isArray = true
    var i = 0
    var tableIdx = idx
    if tableIdx < 0:
      tableIdx = lua_gettop(L) + tableIdx + 1
    lua_pushnil(L)
    while lua_next(L, tableIdx) != 0:
      inc i
      case lua_type(L, -2)
      of luaTString:
        isArray = false
        pairs.add (key: $lua_tolstring(L, -2, nil), value: jsonOfStack(L, -1))
      of luaTNumber:
        if lua_tointeger(L, -2) == i:
          pairs.add (key: $i, value: jsonOfStack(L, -1))
        else:
          isArray = false
          pairs.add (key: $lua_tointeger(L, -2), value: jsonOfStack(L, -1))
      else:
        isArray = false
        pairs.add (key: "key" & $i, value: jsonOfStack(L, -1))
      lua_pop(L, 1)
    if isArray:
      result = newJArray()
      for p in pairs:
        result.add p.value
    else:
      result = newJObject()
      for p in pairs:
        result[p.key] = p.value
  else:
    result = newJNull()
