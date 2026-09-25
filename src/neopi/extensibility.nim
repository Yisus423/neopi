## Assembly of neopi's extensibility surface: the hook bus, the confined fs
## primitives, and the spawn-per-call process primitive on one embedded Lua
## interpreter.
##
## `newExtensibility` owns the interpreter: extension scripts register
## handlers with `neopi.on`, compute in Lua only, and reach side effects
## exclusively through the confined `neopi.fs` and `neopi.process` tables.

import std/json
import neopi/lua
import neopi/hooks
import neopi/fs
import neopi/process

# Same file-scope typedef as lua.nim/hooks.nim/provider.nim: the emit closure
# materializes the HookBus object, whose field holds the opaque state type.
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

type
  Extensibility* = ref object
    ## Owns the extensibility surface: the hook bus and the workspace root
    ## the confined primitives resolve against.
    bus*: HookBus
    workspaceRoot*: string

proc newExtensibility*(workspaceRoot: string): Extensibility =
  ## Assemble the hook bus, the confined fs primitives, and the process
  ## primitive on the same embedded interpreter. With an empty
  ## `workspaceRoot`, only the hooks exist.
  result = Extensibility(bus: newHookBus(), workspaceRoot: workspaceRoot)
  if workspaceRoot.len == 0:
    return
  let bus = result.bus
  let busEmit = proc (event: string, payload: JsonNode): HookOutcome =
    bus.emit(event, payload)
  exposeFs(bus.state, workspaceRoot)
  exposeProcess(bus.state, workspaceRoot, busEmit)
