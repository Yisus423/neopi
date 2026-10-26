import std/json
import std/options
import neopi/openai_compat
import neopi/provider
import unittest2

suite "provider primitives":
  test "scripted generate returns the response text":
    let m = scriptedProvider(@[ScriptStep(text: "hello")]).model("test")
    check m.generate("say hi").text == "hello"

  test "generate accepts system, user, and assistant messages":
    let m = scriptedProvider(@[ScriptStep(text: "ok")]).model("test")
    let messages = @[
      Message(role: roleSystem, text: "You are terse."),
      Message(role: roleUser, text: "hi"),
      Message(role: roleAssistant, text: "hello"),
      Message(role: roleUser, text: "bye")]
    check m.generate(messages).text == "ok"

  test "generate without messages raises ProviderError":
    let m = scriptedProvider(@[ScriptStep(text: "ok")]).model("test")
    expect ProviderError:
      discard m.generate(@[])

  test "finish reason and usage metadata flow through":
    let m = scriptedProvider(@[ScriptStep(text: "ok")]).model("test")
    let r = m.generate("hi")
    check r.finishReason == frStop
    check r.inputTokens == 0
    check r.outputTokens == 0

  test "tool round-trip executes the callback and returns the final text":
    let m = scriptedProvider(@[
      ScriptStep(toolCalls: @[("call-1", "add", %*{"a": 2, "b": 3})]),
      ScriptStep(text: "2 + 3 is 5")]).model("test")
    let addTool = Tool(
      name: "add",
      description: "Add two numbers",
      inputSchema: %*{"type": "object",
        "properties": {"a": {"type": "number"}, "b": {"type": "number"}},
        "required": ["a", "b"]},
      execute: proc (args: JsonNode): string =
        $(args["a"].getInt + args["b"].getInt))
    let r = m.generate("what is 2 plus 3?", tools = @[addTool], maxSteps = 2)
    check r.text == "2 + 3 is 5"

  test "the tool round-trip replays the calls on the wire":
    let t = newScriptedTransport(@[
      ScriptStep(toolCalls: @[("call-1", "add", %*{"a": 2, "b": 3})]),
      ScriptStep(text: "2 + 3 is 5")])
    let m = openAI("dummy-key", baseUrl = "https://example.test/v1",
      transport = t).model("test")
    let addTool = Tool(
      name: "add",
      description: "Add two numbers",
      inputSchema: %*{"type": "object",
        "properties": {"a": {"type": "number"}, "b": {"type": "number"}},
        "required": ["a", "b"]},
      execute: proc (args: JsonNode): string =
        $(args["a"].getInt + args["b"].getInt))
    let r = m.generate("what is 2 plus 3?", tools = @[addTool], maxSteps = 2)
    check r.text == "2 + 3 is 5"
    check t.requests.len == 2
    let body = parseJson(t.requests[1].body)
    let msgs = body["messages"]
    let last = msgs.len - 1
    let toolMsg = msgs[last]
    check toolMsg["role"].getStr == "tool"
    check toolMsg["tool_call_id"].getStr == "call-1"
    check toolMsg["content"].getStr == "5"
    let assistant = msgs[last - 1]
    check assistant["role"].getStr == "assistant"
    check assistant["tool_calls"][0]["function"]["name"].getStr == "add"

  test "a raising tool callback reports a failure to the model":
    let m = scriptedProvider(@[
      ScriptStep(toolCalls: @[("call-1", "boom", %*{})]),
      ScriptStep(text: "recovered")]).model("test")
    let boom = Tool(
      name: "boom",
      description: "Always fails",
      inputSchema: %*{"type": "object", "properties": {}},
      execute: proc (args: JsonNode): string =
        raise newException(ValueError, "exploded"))
    let r = m.generate("go", tools = @[boom], maxSteps = 2)
    check r.text == "recovered"

  test "stream emits text deltas and finishes":
    let m = scriptedProvider(@[ScriptStep(text: "hello world")]).model("test")
    var got: seq[string]
    var finished = false
    let r = m.stream("hi", proc (e: StreamEvent): bool =
      case e.kind
      of seTextDelta: got.add e.text
      of seFinished: finished = true
      else: discard
      true)
    check r.text == "hello world"
    check got == @["hello world"]
    check finished

  test "stream cancellation raises CancelledError":
    let m = scriptedProvider(@[ScriptStep(text: "hello")]).model("test")
    expect CancelledError:
      discard m.stream("hi", proc (e: StreamEvent): bool = e.kind != seTextDelta)

  test "streaming with messages works":
    let m = scriptedProvider(@[ScriptStep(text: "done")]).model("test")
    var deltas = 0
    let r = m.stream(@[Message(role: roleUser, text: "hi")],
      proc (e: StreamEvent): bool =
        if e.kind == seTextDelta: inc deltas
        true)
    check r.text == "done"
    check deltas == 1

suite "the provider table":
  test "the table carries the built-in providers with an endpoint and a key variable":
    let specs = knownProviders()
    check specs.len == 8
    var ids: seq[string]
    for spec in specs:
      ids.add spec.id
      check spec.baseUrl.len > 0
      check spec.envVar.len > 0
    check ids == @["openai", "openrouter", "deepseek", "groq", "together",
      "cerebras", "ollama", "llamacpp"]
    for i in 0 ..< ids.len:
      for j in i + 1 ..< ids.len:
        check ids[i] != ids[j]

  test "findProvider answers a hit and a miss":
    check findProvider("groq").isSome
    check findProvider("groq").get.baseUrl == "https://api.groq.com/openai/v1"
    check findProvider("nope").isNone

  test "only the local entries are the keyless ones":
    check findProvider("ollama").get.requiresKey == false
    check findProvider("llamacpp").get.requiresKey == false
    check findProvider("openrouter").get.requiresKey == true

  test "newProvider takes the entry's endpoint and honors the override":
    let spec = findProvider("groq").get
    check newProvider(spec, "k").name == "groq"
    check newProvider(spec, "k").baseUrl == "https://api.groq.com/openai/v1"
    check newProvider(spec, "k", "https://proxy.test/v1").baseUrl ==
      "https://proxy.test/v1"

  test "openAI and openRouter keep their name and endpoint":
    # The exported pair the six test files inject through: unchanged.
    check openAI("k").name == "openai"
    check openAI("k").baseUrl == "https://api.openai.com/v1"
    check openRouter("k").name == "openrouter"
    check openRouter("k").baseUrl == "https://openrouter.ai/api/v1"
