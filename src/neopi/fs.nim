## Confined filesystem primitives for neopi's extensibility.
##
## The `neopi.fs` table gives extension scripts read, write, exists, and list
## access inside the workspace root, and nothing outside it. The workspace
## root travels as a closure upvalue, so every operation resolves the
## requested path against it; absolute requests outside the root and `..`
## escapes are rejected with a Lua error. Known limit: confinement is lexical
## (`normalizedPath` does not resolve symlinks), so a symlink inside the
## workspace pointing outside it is followed.

import std/os
from std/strutils import startsWith
import neopi/lua
from neopi/hooks import lua_error

# Same file-scope typedef as lua.nim/hooks.nim: this module's generated C
# calls into the Lua state directly, and no C headers exist to declare the
# opaque state type.
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

# stacktrace off: lua_error longjmps out of the Nim C-callback frames below;
# with frames on it skips the frame pops and corrupts the runtime frame
# stack (the next nimFrame call segfaults). These bridge modules are thin —
# the loss of in-module stack traces is the price of the containment.
{.push stacktrace: off.}

proc raiseLuaError(L: LuaState, message: string) {.noreturn.} =
  ## Push `message` and raise it as a Lua error; lua_error longjmps to the
  ## enclosing pcall, so control never returns here.
  lua_pushstring(L, message)
  discard lua_error(L)

proc rootOf(L: LuaState): string =
  ## The workspace root carried as the closure's first upvalue.
  $lua_tolstring(L, luaUpvalueIndex(1), nil)

proc pathArg(L: LuaState): string =
  ## Validate a one-string-argument operation and return its path argument.
  if lua_gettop(L) != 1 or lua_type(L, 1) != luaTString:
    raiseLuaError(L, "expected one string path argument")
  result = $lua_tolstring(L, 1, nil)

proc confinedPath(L: LuaState, root, requested: string): string =
  ## Resolve `requested` against the workspace root `root`; an escape — an
  ## absolute request outside the root or a `..` that leaves it — pushes the
  ## message and raises it as a Lua error (never returns). Confinement is
  ## lexical: normalizedPath does not resolve symlinks.
  let normalizedRoot = normalizedPath(root)
  let joined =
    if isAbsolute(requested): requested
    else: normalizedRoot / requested
  let normalized = normalizedPath(joined)
  let sep = $DirSep
  let prefix =
    if normalizedRoot == sep: normalizedRoot
    else: normalizedRoot & sep
  if normalized != normalizedRoot and not normalized.startsWith(prefix):
    raiseLuaError(L, "path escapes the workspace root: " & requested)
  result = normalized

proc luaFsRead(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.fs.read(path)`: the file content as a string, or a Lua
  ## error when the path escapes the workspace or the file cannot be read.
  let path = confinedPath(L, rootOf(L), pathArg(L))
  var content = ""
  var failure = ""
  try:
    content = readFile(path)
  except OSError, IOError:
    failure = "fs.read failed: " & getCurrentExceptionMsg()
  if failure.len > 0:
    raiseLuaError(L, failure)
  pushString(L, content)
  result = 1

proc luaFsWrite(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.fs.write(path, content)`: writes the content (plain
  ## writeFile: parent directories are not created), or a Lua error when the
  ## path escapes the workspace or the write fails.
  if lua_gettop(L) != 2 or lua_type(L, 1) != luaTString or
      lua_type(L, 2) != luaTString:
    raiseLuaError(L, "neopi.fs.write expects (path: string, content: string)")
  let path = confinedPath(L, rootOf(L), $lua_tolstring(L, 1, nil))
  let content = $lua_tolstring(L, 2, nil)
  var failure = ""
  try:
    writeFile(path, content)
  except OSError, IOError:
    failure = "fs.write failed: " & getCurrentExceptionMsg()
  if failure.len > 0:
    raiseLuaError(L, failure)
  lua_pushnil(L)
  result = 1

proc luaFsExists(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.fs.exists(path)`: true for an existing file or
  ## directory inside the workspace, false otherwise.
  let path = confinedPath(L, rootOf(L), pathArg(L))
  lua_pushboolean(L, cint(fileExists(path) or dirExists(path)))
  result = 1

proc luaFsList(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.fs.list(path)`: the entry names of the directory as an
  ## array table (names only, not full paths), or a Lua error when the path
  ## escapes the workspace or the directory cannot be read.
  let path = confinedPath(L, rootOf(L), pathArg(L))
  var names: seq[string]
  var failure = ""
  try:
    for entry in walkDir(path):
      names.add extractFilename(entry.path)
  except OSError, IOError:
    failure = "fs.list failed: " & getCurrentExceptionMsg()
  if failure.len > 0:
    raiseLuaError(L, failure)
  lua_createtable(L, cint(names.len), 0)
  for i, name in names:
    pushString(L, name)
    lua_rawseti(L, -2, cint(i + 1))
  result = 1

proc exposeOp(L: LuaState, name: string, fn: lua_CFunction, root: string) =
  ## Expose one op as a closure carrying `root` as its first upvalue.
  pushString(L, root)
  lua_pushcclosure(L, fn, 1)
  lua_setfield(L, -2, name)

proc exposeFs*(L: LuaState, workspaceRoot: string) =
  ## Expose the confined `neopi.fs` table inside the existing `neopi` table:
  ## read, write, exists, and list, each a closure carrying `workspaceRoot`
  ## as its first upvalue. Requires `neopi` to exist (newHookBus creates it).
  lua_getfield(L, luaGlobalsIndex, "neopi")
  if lua_type(L, -1) != luaTTable:
    lua_pop(L, 1)
    raise LuaError.newException(
      "exposeFs requires the neopi table (call newHookBus first)")
  lua_createtable(L, 0, 4)
  exposeOp(L, "read", luaFsRead, workspaceRoot)
  exposeOp(L, "write", luaFsWrite, workspaceRoot)
  exposeOp(L, "exists", luaFsExists, workspaceRoot)
  exposeOp(L, "list", luaFsList, workspaceRoot)
  lua_setfield(L, -2, "fs")
  lua_pop(L, 1)
{.pop.}
