import std/json
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
