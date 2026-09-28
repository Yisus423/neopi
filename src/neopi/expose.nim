## The provider and session exposures on neopi's extensibility state: the
## Lua-callable `neopi.provider` and `neopi.session` tables.
##
## `neopi.provider.generate(config)` runs ONE model turn (maxSteps 1): the
## config carries the model, the message list, and the optional Lua-defined
## tools; the response surfaces the text, the stop reason, the usage, and the
## tool calls the model requested. The tool list the model sees merges the
## config's tools with the runtime registry's registered ones (the
## neopi.registerTool entries, read through neopi.registeredTools() at the
## start of every generate); the execute function refs are luaL_ref'd for
## the call and luaL_unref'd after the response is built, so the registry
## does not grow per generate call. The Lua loop in the runtime layer owns
## the turn orchestration and the tool executions, so nimgent never runs its
## tool loop here — the ref-based execute closures are the Tool-type
## plumbing that makes Lua tools callable through the provider protocol (the
## hooks pattern reversed: Lua tool, Nim glue). A Lua error in a tool raises
## Nim-side, where nimgent's execOne catches it and reports a tool failure to
## the model.
##
## `neopi.provider.setScripted(steps)` swaps the backing provider for a
## deterministic scripted one (the nimgent scriptedModel pattern) — the test
## surface for in-process specs without network. The swap lasts for the
## process lifetime; there is no unswap.
##
## `neopi.session` wraps the Nim Session: `append(kind, payload)`,
## `history()`, and `navigate(id)`, called with colon syntax (the bound table
## is the first argument). The session pointer travels as a registry
## lightuserdata; the extensibility holds the Nim reference, so the pointer
## stays valid for the extensibility's lifetime (the Nim binary owns it for
## the process lifetime).
##
## `neopi.emit(event, payload)` completes the hook API: extensions register
## handlers with `neopi.on` and can emit events through `neopi.emit` — the
## pi pattern of extensions publishing events. The emit reads the HookBus
## from the registry (the same pattern as neopi.on's handler) and returns
## the outcome as a table; the agent loop fires the tool_call/tool_result
## hooks through it for every tool execution.

import std/[json, options]
import neopi/lua
import neopi/hooks
import neopi/provider
import neopi/session

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

type
  ProviderContext = object
    ## Per-interpreter context carried as the generate and setScripted
    ## closures' shared upvalue: the current backing provider, swapped by
    ## setScripted. Created once with `create`; the ORC refcounts of its
    ## fields are never released (the GC does not know the raw allocation),
    ## so the backing lives as long as the closures do — the process
    ## lifetime.
    provider: Option[Provider]

const providerRegistryKey = "neopi.provider.context"
const sessionRegistryKey = "neopi.session"

func payloadInt(payload: JsonNode, key: string): int =
  ## An optional integer field of the payload: 0 when absent or not a number.
  if payload.hasKey(key) and payload[key].kind in {JInt, JFloat}:
    if payload[key].kind == JInt: payload[key].getInt
    else: int(payload[key].getFloat)
  else:
    0

func payloadString(payload: JsonNode, key: string): string =
  ## An optional string field of the payload: "" when absent or not a string.
  if payload.hasKey(key) and payload[key].kind == JString:
    payload[key].getStr
  else:
    ""

func payloadBool(payload: JsonNode, key: string): bool =
  ## An optional boolean field of the payload: false when absent or not a
  ## boolean.
  payload.hasKey(key) and payload[key].kind == JBool and payload[key].getBool

func stopReasonOf(r: Response): string =
  ## The response's stop reason in the Lua layer's spelling: a response that
  ## stopped for tool use reports "toolUse" (nimgent spells the step-limit
  ## stop `frStepLimit` when the tool loop cannot continue, and the Lua loop
  ## keys on the tool call itself); other reasons map from the finish reason.
  if r.toolCalls.len > 0:
    return "toolUse"
  case r.finishReason
  of frEndTurn: "endTurn"
  of frToolUse: "toolUse"
  of frMaxTokens: "maxTokens"
  of frStop: "stop"
  of frStepLimit: "stepLimit"
  of frUnknown: "unknown"

proc makeLuaToolExecute(L: LuaState,
                        fnRef: cint): proc (args: JsonNode): string {.closure.} =
  ## The neopi Tool execute callback for a Lua-defined tool: call the stored
  ## Lua function through pcall with the args JSON pushed and return its
  ## string result. A Lua error (or a non-string result) raises Nim-side,
  ## where nimgent's execOne catches it and reports a tool failure to the
  ## model. The ref is only valid for the generate call that created it: the
  ## generate luaL_unref's it after the response is built, and the closure
  ## dies with the tools seq.
  return proc (args: JsonNode): string =
    pushJson(L, args)
    if lua_pcall(L, 1, 1, 0) != 0:
      let message = luaStackMessage(L)
      lua_pop(L, 1)
      raise newException(LuaError, message)
    if lua_type(L, -1) != luaTString:
      lua_pop(L, 1)
      raise newException(LuaError,
        "the tool's execute function did not return a string")
    result = $lua_tolstring(L, -1, nil)
    lua_pop(L, 1)

proc registeredToolsOf(L: LuaState, fnRefs: var seq[cint]): seq[Tool] =
  ## The runtime registry's registered tools: call `neopi.registeredTools()`
  ## (the runtime entry registers it on the neopi table) and map each
  ## {name, description, schema, execute} entry onto a Tool — the execute
  ## function ref via luaL_ref, collected into `fnRefs` for the
  ## post-response unref, and the closure through makeLuaToolExecute. The
  ## merge appends in registration order after the config's tools, so the
  ## model sees both. Returns the empty seq when the runtime is not loaded
  ## (no `neopi.registeredTools` in the state): the registry does not exist
  ## yet. A non-table result from an existing function is a broken registry
  ## and raises.
  lua_getfield(L, luaGlobalsIndex, "neopi")
  if lua_type(L, -1) != luaTTable:
    lua_pop(L, 1)
    return
  lua_getfield(L, -1, "registeredTools")
  if lua_type(L, -1) != luaTFunction:
    lua_pop(L, 2)
    return
  # lua_call pops the function and pushes its result; the neopi table stays
  # below and the final pop releases it with the array.
  if lua_pcall(L, 0, 1, 0) != 0:
    let message = luaStackMessage(L)
    lua_pop(L, 1)
    raiseLuaError(L, "neopi.registeredTools failed: " & message)
  if lua_type(L, -1) != luaTTable:
    lua_pop(L, 1)
    raiseLuaError(L,
      "neopi.registeredTools must return an array of tool tables")
  let arrIdx = lua_gettop(L)
  let count = int(lua_objlen(L, arrIdx))
  for i in 1 .. count:
    lua_rawgeti(L, arrIdx, cint(i))
    let toolIdx = lua_gettop(L)
    if lua_type(L, toolIdx) != luaTTable:
      lua_pop(L, 1)
      raiseLuaError(L,
        "neopi.registeredTools: each entry must be {name, description, " &
        "schema, execute}")
    lua_getfield(L, toolIdx, "name")
    if lua_type(L, -1) != luaTString:
      lua_pop(L, 2)
      raiseLuaError(L,
        "neopi.registeredTools: each tool needs a name string")
    let name = $lua_tolstring(L, -1, nil)
    lua_getfield(L, toolIdx, "description")
    let description =
      if lua_type(L, -1) == luaTString: $lua_tolstring(L, -1, nil)
      else: ""
    lua_getfield(L, toolIdx, "schema")
    let schema = jsonOfStack(L, -1)
    lua_getfield(L, toolIdx, "execute")
    if lua_type(L, -1) != luaTFunction:
      lua_pop(L, 5)
      raiseLuaError(L,
        "neopi.registeredTools: tool \"" & name &
        "\" needs an execute function")
    # luaL_ref pops the execute function and stores it in the registry for
    # the generate call; the unref below releases it after the response.
    let fnRef = luaL_ref(L, luaRegistryIndex)
    fnRefs.add fnRef
    result.add Tool(name: name, description: description,
      inputSchema: schema, execute: makeLuaToolExecute(L, fnRef))
    lua_pop(L, 4)
  lua_pop(L, 2)

proc luaProviderGenerate(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.provider.generate(config)`: one model turn over the
  ## current backing provider. The config is
  ## {model = string, messages = [{role, text}], system = string (optional),
  ## tools = [{name, description, schema, execute = function}] (optional)};
  ## the tool list the model sees merges the config's tools with the runtime
  ## registry's registered ones; the response is {text, stopReason,
  ## usage = {input, output}, toolCalls = [{id, name, args}], provider}. A
  ## Lua error surfaces for an invalid config, a missing backing, or a
  ## provider failure. The execute function refs are released after the
  ## response is built; a validation error longjmps out of this callback and
  ## leaks the refs created so far (they live until the state closes).
  let context = cast[ptr ProviderContext](lua_touserdata(L, luaUpvalueIndex(1)))
  if lua_gettop(L) != 1 or lua_type(L, 1) != luaTTable:
    raiseLuaError(L, "neopi.provider.generate expects a config table")
  let base = lua_gettop(L)
  lua_getfield(L, 1, "model")
  if lua_type(L, -1) != luaTString:
    raiseLuaError(L, "neopi.provider.generate: config.model must be a string")
  let modelId = $lua_tolstring(L, -1, nil)
  lua_getfield(L, 1, "messages")
  if lua_type(L, -1) != luaTTable:
    raiseLuaError(L,
      "neopi.provider.generate: config.messages must be an array of {role, text}")
  let messagesJson = jsonOfStack(L, -1)
  if messagesJson.kind != JArray:
    raiseLuaError(L,
      "neopi.provider.generate: config.messages must be an array of {role, text}")
  var messages: seq[Message]
  for msg in messagesJson:
    if msg.kind != JObject or not msg.hasKey("role") or not msg.hasKey("text"):
      raiseLuaError(L,
        "neopi.provider.generate: each message needs {role, text}")
    let role = msg["role"].getStr
    case role
    of "system":
      messages.add Message(role: roleSystem, text: msg["text"].getStr)
    of "user":
      messages.add Message(role: roleUser, text: msg["text"].getStr)
    of "assistant":
      messages.add Message(role: roleAssistant, text: msg["text"].getStr)
    else:
      raiseLuaError(L,
        "neopi.provider.generate: unknown message role \"" & role & "\"")
  var tools: seq[Tool]
  var fnRefs: seq[cint]
  lua_getfield(L, 1, "tools")
  if lua_type(L, -1) != luaTNil:
    if lua_type(L, -1) != luaTTable:
      raiseLuaError(L,
        "neopi.provider.generate: config.tools must be an array of tool tables")
    let toolsIdx = lua_gettop(L)
    let count = int(lua_objlen(L, toolsIdx))
    for i in 1 .. count:
      lua_rawgeti(L, toolsIdx, cint(i))
      let toolIdx = lua_gettop(L)
      if lua_type(L, toolIdx) != luaTTable:
        raiseLuaError(L,
          "neopi.provider.generate: config.tools entries must be tables")
      lua_getfield(L, toolIdx, "name")
      if lua_type(L, -1) != luaTString:
        raiseLuaError(L,
          "neopi.provider.generate: each tool needs a name string")
      let name = $lua_tolstring(L, -1, nil)
      lua_getfield(L, toolIdx, "description")
      let description =
        if lua_type(L, -1) == luaTString: $lua_tolstring(L, -1, nil)
        else: ""
      lua_getfield(L, toolIdx, "schema")
      let schema = jsonOfStack(L, -1)
      lua_getfield(L, toolIdx, "execute")
      if lua_type(L, -1) != luaTFunction:
        raiseLuaError(L,
          "neopi.provider.generate: tool \"" & name &
          "\" needs an execute function")
      # luaL_ref pops the execute function and stores it in the registry;
      # the Tool's execute closure calls it back through pcall.
      let fnRef = luaL_ref(L, luaRegistryIndex)
      fnRefs.add fnRef
      tools.add Tool(name: name, description: description,
        inputSchema: schema, execute: makeLuaToolExecute(L, fnRef))
  lua_settop(L, base)
  # The registered tools merge after the config's tools, with or without a
  # config tools key: the model sees both.
  tools.add registeredToolsOf(L, fnRefs)
  if context.provider.isNone:
    raiseLuaError(L,
      "no provider configured: set the API key in the environment or " &
      "call neopi.provider.setScripted")
  var r: Response
  try:
    r = generate(model(context.provider.get, modelId), messages, tools,
      maxSteps = 1)
  except CatchableError as e:
    for refIndex in fnRefs:
      luaL_unref(L, luaRegistryIndex, refIndex)
    raiseLuaError(L, "neopi.provider.generate failed: " & e.msg)
  lua_createtable(L, 0, 5)
  pushString(L, r.text)
  lua_setfield(L, -2, "text")
  pushString(L, stopReasonOf(r))
  lua_setfield(L, -2, "stopReason")
  lua_createtable(L, 0, 2)
  lua_pushinteger(L, r.inputTokens.lua_Integer)
  lua_setfield(L, -2, "input")
  lua_pushinteger(L, r.outputTokens.lua_Integer)
  lua_setfield(L, -2, "output")
  lua_setfield(L, -2, "usage")
  lua_createtable(L, cint(r.toolCalls.len), 0)
  for i, call in r.toolCalls:
    lua_createtable(L, 0, 3)
    pushString(L, call.id)
    lua_setfield(L, -2, "id")
    pushString(L, call.name)
    lua_setfield(L, -2, "name")
    pushJson(L, call.args)
    lua_setfield(L, -2, "args")
    lua_rawseti(L, -2, cint(i + 1))
  lua_setfield(L, -2, "toolCalls")
  pushString(L, context.provider.get.name)
  lua_setfield(L, -2, "provider")
  # The generate completed: release every execute function ref (the config's
  # tools' and the registered ones') so the registry does not grow per call.
  for refIndex in fnRefs:
    luaL_unref(L, luaRegistryIndex, refIndex)
  result = 1

proc luaProviderSetScripted(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.provider.setScripted(steps)`: swap the backing provider
  ## for a deterministic scripted one (the nimgent scriptedModel pattern) —
  ## the test surface for in-process specs without network. A step with
  ## `text` replies with that text; otherwise it replies with its
  ## `toolCalls` ({id, name, args}). An optional `usageInput` number sets the
  ## reply's reported input tokens (the compaction trigger's token estimate
  ## in tests); without it the reply's usage is zero. The swap lasts for the
  ## process lifetime; there is no unswap.
  let context = cast[ptr ProviderContext](lua_touserdata(L, luaUpvalueIndex(1)))
  if lua_gettop(L) != 1 or lua_type(L, 1) != luaTTable:
    raiseLuaError(L, "neopi.provider.setScripted expects an array of steps")
  let stepsJson = jsonOfStack(L, 1)
  if stepsJson.kind != JArray:
    raiseLuaError(L, "neopi.provider.setScripted expects an array of steps")
  var steps: seq[ScriptStep]
  for step in stepsJson:
    if step.kind != JObject:
      raiseLuaError(L, "neopi.provider.setScripted: each step must be a table")
    var parsed = ScriptStep()
    if step.hasKey("text") and step["text"].kind == JString:
      parsed.text = step["text"].getStr
    parsed.usageInput = payloadInt(step, "usageInput")
    if step.hasKey("toolCalls") and step["toolCalls"].kind == JArray:
      for call in step["toolCalls"]:
        if call.kind != JObject or not call.hasKey("id") or
            not call.hasKey("name") or not call.hasKey("args"):
          raiseLuaError(L,
            "neopi.provider.setScripted: each tool call needs {id, name, args}")
        parsed.toolCalls.add (id: call["id"].getStr, name: call["name"].getStr,
          args: call["args"])
    steps.add parsed
  context[].provider = some(scriptedProvider(steps))
  lua_pushnil(L)
  result = 1

proc exposeProvider*(L: LuaState, backing: Option[Provider]) =
  ## Expose the `neopi.provider` table inside the existing `neopi` table:
  ## generate(config) and setScripted(steps), both closures carrying the
  ## provider context as their first upvalue. Requires `neopi` to exist
  ## (newHookBus creates it).
  let context = create(ProviderContext)
  context.provider = backing
  lua_getfield(L, luaGlobalsIndex, "neopi")
  if lua_type(L, -1) != luaTTable:
    lua_pop(L, 1)
    raise LuaError.newException(
      "exposeProvider requires the neopi table (call newHookBus first)")
  lua_createtable(L, 0, 2)
  lua_pushlightuserdata(L, cast[pointer](context))
  lua_pushcclosure(L, luaProviderGenerate, 1)
  lua_setfield(L, -2, "generate")
  lua_pushlightuserdata(L, cast[pointer](context))
  lua_pushcclosure(L, luaProviderSetScripted, 1)
  lua_setfield(L, -2, "setScripted")
  lua_setfield(L, -2, "provider")
  lua_pop(L, 1)

proc luaEmit(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.emit(event, payload)`: fire the hook bus's handlers for
  ## `event` through the Nim emit (the same containment as every core-side
  ## emit: a handler error aborts only that handler's contribution) and
  ## return the outcome as {allowed = bool, reason = string, patched = bool,
  ## payload = table (present when a handler patched)}. The loop and
  ## extension scripts publish events through it. A Lua error surfaces for
  ## an invalid call or a missing bus.
  let bus = cast[HookBus](getRegistryPointer(L, busRegistryKey))
  if bus.isNil or lua_gettop(L) != 2 or lua_type(L, 1) != luaTString or
      lua_type(L, 2) != luaTTable:
    raiseLuaError(L, "neopi.emit expects (event: string, payload: table)")
  let event = $lua_tolstring(L, 1, nil)
  let outcome = bus.emit(event, jsonOfStack(L, 2))
  lua_createtable(L, 0, 4)
  lua_pushboolean(L, cint(outcome.allowed))
  lua_setfield(L, -2, "allowed")
  pushString(L, outcome.reason)
  lua_setfield(L, -2, "reason")
  lua_pushboolean(L, cint(outcome.patched))
  lua_setfield(L, -2, "patched")
  if outcome.patched and not outcome.payload.isNil:
    pushJson(L, outcome.payload)
    lua_setfield(L, -2, "payload")
  result = 1

proc exposeEmit*(L: LuaState) =
  ## Expose `neopi.emit(event, payload)` on the existing `neopi` table: fire
  ## the hook bus's handlers for the event and return the outcome table.
  ## Requires `neopi` to exist (newHookBus creates it) and the bus pointer
  ## in the registry.
  lua_getfield(L, luaGlobalsIndex, "neopi")
  if lua_type(L, -1) != luaTTable:
    lua_pop(L, 1)
    raise LuaError.newException(
      "exposeEmit requires the neopi table (call newHookBus first)")
  lua_pushcfunction(L, luaEmit)
  lua_setfield(L, -2, "emit")
  lua_pop(L, 1)

proc luaSessionAppend(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.session:append(kind, payload)`: build the SessionEntry
  ## from the kind and the payload table and append it. The id, the parent,
  ## and the timestamp are assigned by the Nim append; the payload carries
  ## the kind-specific fields (text; text, model, provider, usageInput,
  ## usageOutput, stopReason; toolCallId, toolName, output, isError; summary,
  ## firstKeptId, tokensBefore).
  let s = cast[Session](getRegistryPointer(L, sessionRegistryKey))
  if s.isNil or lua_gettop(L) != 3 or lua_type(L, 1) != luaTTable or
      lua_type(L, 2) != luaTString or lua_type(L, 3) != luaTTable:
    raiseLuaError(L,
      "neopi.session.append expects (kind: string, payload: table)")
  let kind = $lua_tolstring(L, 2, nil)
  let payload = jsonOfStack(L, 3)
  if payload.kind != JObject:
    # jsonOfStack turns an empty Lua table into an empty array; the payload
    # must be an object with the kind's fields.
    raiseLuaError(L, "the payload must be a table with the kind's fields")
  var entry: SessionEntry
  case kind
  of "user":
    if not payload.hasKey("text") or payload["text"].kind != JString:
      raiseLuaError(L, "the user payload needs text: string")
    entry = SessionEntry(kind: ekUser, text: payload["text"].getStr)
  of "assistant":
    if not payload.hasKey("text") or not payload.hasKey("model") or
        not payload.hasKey("provider"):
      raiseLuaError(L, "the assistant payload needs text, model, and provider")
    entry = SessionEntry(kind: ekAssistant, text: payload["text"].getStr,
      model: payload["model"].getStr, provider: payload["provider"].getStr,
      usageInput: payloadInt(payload, "usageInput"),
      usageOutput: payloadInt(payload, "usageOutput"),
      stopReason: payloadString(payload, "stopReason"))
  of "toolResult":
    if not payload.hasKey("toolCallId") or not payload.hasKey("toolName") or
        not payload.hasKey("output"):
      raiseLuaError(L,
        "the toolResult payload needs toolCallId, toolName, and output")
    entry = SessionEntry(kind: ekToolResult,
      toolCallId: payload["toolCallId"].getStr,
      toolName: payload["toolName"].getStr, output: payload["output"].getStr,
      isError: payloadBool(payload, "isError"))
  of "compaction":
    if not payload.hasKey("summary") or not payload.hasKey("firstKeptId") or
        not payload.hasKey("tokensBefore"):
      raiseLuaError(L,
        "the compaction payload needs summary, firstKeptId, and tokensBefore")
    entry = SessionEntry(kind: ekCompaction,
      summary: payloadString(payload, "summary"),
      firstKeptId: payloadInt(payload, "firstKeptId"),
      tokensBefore: payloadInt(payload, "tokensBefore"))
  else:
    raiseLuaError(L,
      "unknown entry kind \"" & kind & "\" (user, assistant, toolResult, " &
      "or compaction)")
  try:
    s.append(entry)
  except CatchableError as e:
    raiseLuaError(L, "neopi.session.append failed: " & e.msg)
  lua_pushnil(L)
  result = 1

proc luaSessionHistory(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.session:history()`: the active branch's entries as an
  ## array table, each entry in its JSONL shape (type, id, parentId,
  ## timestamp, then the kind-specific fields).
  let s = cast[Session](getRegistryPointer(L, sessionRegistryKey))
  if s.isNil or lua_gettop(L) != 1 or lua_type(L, 1) != luaTTable:
    raiseLuaError(L, "neopi.session.history takes no arguments")
  let branch = s.history()
  lua_createtable(L, cint(branch.len), 0)
  for i, entry in branch:
    pushJson(L, entryToJson(entry))
    lua_rawseti(L, -2, cint(i + 1))
  result = 1

proc luaSessionNavigate(L: LuaState): cint {.cdecl.} =
  ## Lua-side `neopi.session:navigate(id)`: move the active branch to the
  ## entry with `id` (the Nim navigateTo); the next append branches there.
  let s = cast[Session](getRegistryPointer(L, sessionRegistryKey))
  if s.isNil or lua_gettop(L) != 2 or lua_type(L, 1) != luaTTable or
      lua_type(L, 2) != luaTNumber:
    raiseLuaError(L, "neopi.session.navigate expects (id: number)")
  let id = int(lua_tointeger(L, 2))
  try:
    s.navigateTo(id)
  except CatchableError as e:
    raiseLuaError(L, "neopi.session.navigate failed: " & e.msg)
  lua_pushnil(L)
  result = 1

proc exposeSession*(L: LuaState, session: Session) =
  ## Expose the `neopi.session` table inside the existing `neopi` table:
  ## append, history, and navigate, all bound to the Nim `session` through
  ## the registry pointer. Requires `neopi` to exist (newHookBus creates it).
  setRegistryPointer(L, sessionRegistryKey, cast[pointer](session))
  lua_getfield(L, luaGlobalsIndex, "neopi")
  if lua_type(L, -1) != luaTTable:
    lua_pop(L, 1)
    raise LuaError.newException(
      "exposeSession requires the neopi table (call newHookBus first)")
  lua_createtable(L, 0, 3)
  lua_pushcfunction(L, luaSessionAppend)
  lua_setfield(L, -2, "append")
  lua_pushcfunction(L, luaSessionHistory)
  lua_setfield(L, -2, "history")
  lua_pushcfunction(L, luaSessionNavigate)
  lua_setfield(L, -2, "navigate")
  lua_setfield(L, -2, "session")
  lua_pop(L, 1)
{.pop.}
