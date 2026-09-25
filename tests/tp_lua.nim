import std/json
import neopi/hooks
import neopi/lua
import neopi/provider
import unittest2

# Same file-scope typedef as lua.nim: this module's generated C calls into
# the Lua state directly, and no C headers exist to declare the type.
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

suite "lua state":
  test "newLuaState opens safe libs and keeps ffi closed":
    let L = newLuaState()
    check evalString(L, "return type(ffi)") == "nil"
    check evalString(L, "return type(io)") == "nil"
    check evalString(L, "return type(os)") == "nil"
    check evalString(L, "return type(debug)") == "nil"
    check evalString(L, "return type(string)") == "table"
    check evalString(L, "return type(pcall)") == "function"

  test "a Lua error aborts the script, not the host":
    let L = newLuaState()
    expect LuaError:
      runScript(L, "error('boom')")
    check evalString(L, "return tostring(1 + 1)") == "2"

suite "hooks":
  test "neopi.on registers and emit blocks":
    let bus = newHookBus()
    loadExtension(bus, """
      neopi.on("tool_call", function(p)
        if p.tool == "danger" then
          return false, "danger tools are disabled"
        end
        return true
      end)
    """)
    let blocked = bus.emit("tool_call", %*{"tool": "danger"})
    check not blocked.allowed
    check blocked.reason == "danger tools are disabled"
    check not blocked.patched
    let safe = bus.emit("tool_call", %*{"tool": "safe"})
    check safe.allowed
    check not safe.patched
    let unregistered = bus.emit("tool_result", %*{"tool": "safe", "output": "x"})
    check unregistered.allowed
    check not unregistered.patched

  test "tool_call rewrite":
    let bus = newHookBus()
    loadExtension(bus, """
      neopi.on("tool_call", function(p)
        if p.tool == "add" then
          return {tool = p.tool, args = {a = p.args.a + 10, b = p.args.b}}
        end
        return true
      end)
    """)
    let outcome = bus.emit("tool_call",
      %*{"tool": "add", "args": {"a": 2, "b": 3}})
    check outcome.patched
    check outcome.payload["args"]["a"].getInt == 12
    check outcome.payload["args"]["b"].getInt == 3

  test "tool_result rewrite at the emit level":
    let bus = newHookBus()
    loadExtension(bus, """
      neopi.on("tool_result", function(p)
        return {tool = p.tool, output = "REDACTED:" .. p.output}
      end)
    """)
    let outcome = bus.emit("tool_result", %*{"tool": "add", "output": "5"})
    check outcome.patched
    check outcome.payload["output"].getStr == "REDACTED:5"

suite "hooks through the provider":
  test "end-to-end: a blocked tool gets a denial and the run continues":
    var dangerRan = false
    let bus = newHookBus()
    loadExtension(bus, """
      neopi.on("tool_call", function(p)
        if p.tool == "danger" then
          return false, "danger tools are disabled"
        end
        return true
      end)
    """)
    let provider = scriptedProvider(@[
      ScriptStep(toolCalls: @[("call-1", "danger", %*{})]),
      ScriptStep(toolCalls: @[("call-2", "add", %*{"a": 2, "b": 3})]),
      ScriptStep(text: "done")]).model("test")
    let danger = Tool(
      name: "danger",
      description: "Would be blocked",
      inputSchema: %*{"type": "object", "properties": {}},
      execute: proc (args: JsonNode): string =
        dangerRan = true
        "should not run")
    let add = Tool(
      name: "add",
      description: "Add two numbers",
      inputSchema: %*{"type": "object",
        "properties": {"a": {"type": "number"}, "b": {"type": "number"}},
        "required": ["a", "b"]},
      execute: proc (args: JsonNode): string =
        $(args["a"].getInt + args["b"].getInt))
    let r = provider.generate("go", tools = @[danger, add], maxSteps = 3,
      bus = bus)
    check r.text == "done"
    check not dangerRan

  test "end-to-end: args rewrite changes the tool result":
    let bus = newHookBus()
    loadExtension(bus, """
      neopi.on("tool_call", function(p)
        if p.tool == "add" then
          return {tool = p.tool, args = {a = p.args.a + 10, b = p.args.b}}
        end
        return true
      end)
    """)
    let provider = scriptedProvider(@[
      ScriptStep(toolCalls: @[("call-1", "add", %*{"a": 2, "b": 3})]),
      ScriptStep(text: "2 + 3 is 15")]).model("test")
    let add = Tool(
      name: "add",
      description: "Add two numbers",
      inputSchema: %*{"type": "object",
        "properties": {"a": {"type": "number"}, "b": {"type": "number"}},
        "required": ["a", "b"]},
      execute: proc (args: JsonNode): string =
        $(args["a"].getInt + args["b"].getInt))
    let r = provider.generate("go", tools = @[add], maxSteps = 2, bus = bus)
    check r.text == "2 + 3 is 15"
