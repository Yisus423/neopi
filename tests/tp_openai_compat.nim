## Tests for the OpenAI-compatible wire mapping: the SSE data payloads →
## the neopi StreamEvents and the accumulated Response. The hand-written
## chunks pin the wire shape; the two captured OpenRouter fixtures replay
## the real stream end-to-end (L1 — keyless, no network).
import std/[json, strutils]
import chronos
import chronos/timer
import neopi/openai_compat
import neopi/wire
import neopi/provider except CancelledError
import sse
import unittest2

proc feedAll(body: string): tuple[acc: OaiAccum, events: seq[StreamEvent]] =
  ## The L1 replay: the SSE body → the incremental parser → the mapping.
  ## The stream loop's own end semantics: one seFinished after the done.
  var parser = initSSEParser()
  for ev in parser.feed(body):
    if ev.data.len > 0:
      result.events.add mapOaiChunk(ev.data, result.acc)
  if result.acc.done:
    result.events.add StreamEvent(kind: seFinished)

suite "the openai wire mapping":
  test "the text content chunks map to seTextDelta":
    var acc: OaiAccum
    let events = mapOaiChunk(
      "{\"choices\":[{\"delta\":{\"content\":\"hola\"}}]}", acc)
    check events.len == 1
    check events[0].kind == seTextDelta
    check events[0].text == "hola"

  test "the reasoning chunks are dropped (the contract preserved)":
    var acc: OaiAccum
    let events = mapOaiChunk(
      "{\"choices\":[{\"delta\":{\"reasoning\":\"pensando\"}}]}", acc)
    check events.len == 0

  test "the empty content deltas emit nothing":
    var acc: OaiAccum
    let events = mapOaiChunk(
      "{\"choices\":[{\"delta\":{\"content\":\"\",\"role\":\"assistant\"}}]}", acc)
    check events.len == 0

  test "the tool call fragments map and reassemble by index":
    var acc: OaiAccum
    let start = mapOaiChunk("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0," &
      "\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"write\"," &
      "\"arguments\":\"\"}}]}}]}", acc)
    check start.len == 1
    check start[0].kind == seToolCallDelta
    check start[0].toolCallId == "call_1"
    check start[0].toolName == "write"
    check start[0].toolArgs == ""
    let frag = mapOaiChunk("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0," &
      "\"function\":{\"arguments\":\"{\\\"path\\\": \"}}]}}]}", acc)
    check frag.len == 1
    check frag[0].kind == seToolCallDelta
    check frag[0].toolCallId == ""
    check frag[0].toolArgs == "{\"path\": "
    discard mapOaiChunk("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0," &
      "\"function\":{\"arguments\":\"\\\"x.txt\\\"}\"}}]}}]}", acc)
    check acc.toolCalls.len == 1
    check acc.toolCalls[0].id == "call_1"
    check acc.toolCalls[0].name == "write"
    check acc.toolCalls[0].args == "{\"path\": \"x.txt\"}"

  test "the finish reason maps: stop, tool_calls, length":
    var acc: OaiAccum
    discard mapOaiChunk(
      "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}", acc)
    check acc.finishReason == frStop
    acc = OaiAccum()
    discard mapOaiChunk(
      "{\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}", acc)
    check acc.finishReason == frToolUse
    acc = OaiAccum()
    discard mapOaiChunk(
      "{\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}", acc)
    check acc.finishReason == frMaxTokens

  test "the usage arrives in its own chunk":
    var acc: OaiAccum
    discard mapOaiChunk("{\"choices\":[],\"usage\":{\"prompt_tokens\":30," &
      "\"completion_tokens\":353}}", acc)
    check acc.inputTokens == 30
    check acc.outputTokens == 353

  test "the [DONE] sentinel marks the stream done":
    var acc: OaiAccum
    let events = mapOaiChunk("[DONE]", acc)
    check events.len == 0
    check acc.done

  test "the request id accumulates from the chunks":
    var acc: OaiAccum
    discard mapOaiChunk("{\"id\":\"gen-1\",\"choices\":[]}", acc)
    check acc.requestId == "gen-1"

  test "L1: the real captured text stream replays end-to-end":
    let (acc, events) = feedAll(readFile("tests/fixtures/openrouter-text-stream.txt"))
    check acc.text.len > 0
    check acc.finishReason == frStop
    check acc.inputTokens == 30
    check acc.outputTokens == 353
    check acc.requestId.len > 0
    check acc.done
    check events.len > 0
    check events[^1].kind == seFinished
    # Every event before the finish is a text delta with content.
    for e in events[0 ..< ^1]:
      check e.kind == seTextDelta
      check e.text.len > 0

  test "L1: the real captured tool stream reassembles the tool call":
    let (acc, events) = feedAll(readFile("tests/fixtures/openrouter-tool-stream.txt"))
    check acc.finishReason == frToolUse
    check acc.requestId.len > 0
    check acc.done
    let calls = acc.toToolCalls()
    check calls.len == 1
    check calls[0].id == "call_88fe0e24997a4c0bb4408661"
    check calls[0].name == "write"
    check calls[0].args == parseJson("{\"path\": \"notas/x.txt\", \"content\": \"hola\"}")
    # The fragments reached the callback too.
    var sawStart = false
    for e in events:
      if e.kind == seToolCallDelta and e.toolCallId == "call_88fe0e24997a4c0bb4408661":
        sawStart = true
    check sawStart

type SlowFakeWireResponse = ref object of WireResponse
  ## The deliberately silent body: the timeout test races against it.
  delay: timer.Duration

method next*(r: SlowFakeWireResponse): Future[string] {.async.} =
  await sleepAsync(r.delay)
  return ""

proc newSlowResponse(delay: timer.Duration): SlowFakeWireResponse =
  SlowFakeWireResponse(status: 200, delay: delay)

type FailingTransport = ref object of Transport
  ## The always-failing transport: the failure-wrapping test's seam.

method fetch*(t: FailingTransport, req: WireRequest): Future[WireResponse] {.
    async.} =
  raise newException(IOError, "boom")

suite "the openai provider on the wire":
  test "the request builder shapes the chat completions payload":
    let req = buildChatRequest("m", @[
      Message(role: roleUser, text: "go")],
      system = "be brief", tools = @[Tool(name: "write",
        description: "writes", inputSchema: parseJson("{}"))])
    check req["model"].getStr == "m"
    check req["stream"].getBool
    check req["messages"][0]["role"].getStr == "system"
    check req["messages"][0]["content"].getStr == "be brief"
    check req["messages"][1]["role"].getStr == "user"
    check req["tools"][0]["function"]["name"].getStr == "write"
    # Without tools or system the keys stay out.
    let bare = buildChatRequest("m", @[])
    check not bare.hasKey("tools")
    check bare["messages"].len == 0

  test "buildChatRequest emits the assistant tool_calls and the tool result":
    let req = buildChatRequest("m", @[
      Message(role: roleAssistant, text: "",
        toolCalls: @[(id: "call-1", name: "add", args: %*{"a": 2, "b": 3})]),
      Message(role: roleTool, text: "5", toolCallId: "call-1")])
    let assistant = req["messages"][0]
    check assistant["role"].getStr == "assistant"
    check assistant["tool_calls"][0]["id"].getStr == "call-1"
    check assistant["tool_calls"][0]["type"].getStr == "function"
    check assistant["tool_calls"][0]["function"]["name"].getStr == "add"
    let tool = req["messages"][1]
    check tool["role"].getStr == "tool"
    check tool["tool_call_id"].getStr == "call-1"

  test "streamChat wraps a transport failure in a retryable ProviderError":
    let failing = FailingTransport()
    try:
      discard streamChat(failing, "https://x/v1", "k", "m", @[],
        proc (e: StreamEvent): bool = true)
      fail()
    except ProviderError as e:
      check e.retryable == true

  test "the chat headers carry the bearer key":
    let headers = chatHeaders("test-key")
    check headers[0] == ("Authorization", "Bearer test-key")
    check headers[1] == ("Content-Type", "application/json")

  test "streamChat streams the deltas and returns the response":
    let fake = newFakeTransport()
    fake.canned(200, @[
      "data: {\"id\":\"g1\",\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}\n\n",
      "data: {\"id\":\"g1\",\"choices\":[{\"delta\":{\"content\":\"lo\"}," &
        "\"finish_reason\":\"stop\"}]}\n\n",
      "data: {\"id\":\"g1\",\"choices\":[],\"usage\":{\"prompt_tokens\":9," &
        "\"completion_tokens\":2}}\n\n",
      "data: [DONE]\n\n"])
    var got: seq[StreamEvent] = @[]
    let r = streamChat(fake, "https://x/v1", "test-key", "m",
      @[Message(role: roleUser, text: "hi")],
      proc (e: StreamEvent): bool =
        got.add e
        true)
    check r.text == "hello"
    check r.finishReason == frStop
    check r.inputTokens == 9
    check r.outputTokens == 2
    check r.requestId == "g1"
    # The seFinished fires once at the end, after the deltas.
    check got[^1].kind == seFinished
    check got[0].kind == seTextDelta and got[0].text == "hel"

  test "streamChat cancels when the callback returns false":
    let fake = newFakeTransport()
    fake.canned(200, @[
      "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n",
      "data: {\"choices\":[{\"delta\":{\"content\":\"y\"}}]}\n\n"])
    var cancel = false
    expect provider.CancelledError:
      discard streamChat(fake, "https://x/v1", "test-key", "m", @[],
        proc (e: StreamEvent): bool =
          if e.kind == seTextDelta:
            cancel = true
          not cancel)

  test "streamChat raises on an error status with the body":
    let fake = newFakeTransport()
    fake.canned(429, @["{\"error\":\"rate limited\"}\n"])
    try:
      discard streamChat(fake, "https://x/v1", "test-key", "m", @[],
        proc (e: StreamEvent): bool = true)
      fail()
    except ProviderError as e:
      check "429" in e.msg
      check "rate limited" in e.msg

  test "streamChat assembles the tool call response":
    let fake = newFakeTransport()
    fake.canned(200, @[
      "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":" &
        "\"c1\",\"type\":\"function\",\"function\":{\"name\":\"write\"," &
        "\"arguments\":\"\"}}]}}]}\n\n",
      "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0," &
        "\"function\":{\"arguments\":\"{\\\"path\\\": \\\"a\\\"}\"}}]}}]}\n\n",
      "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
      "data: [DONE]\n\n"])
    let r = streamChat(fake, "https://x/v1", "test-key", "m", @[],
      proc (e: StreamEvent): bool = true)
    check r.finishReason == frToolUse
    check r.toolCalls.len == 1
    check r.toolCalls[0].id == "c1"
    check r.toolCalls[0].name == "write"
    check r.toolCalls[0].args == parseJson("{\"path\": \"a\"}")

  test "streamChat times out on a silent stream":
    let fake = newFakeTransport()
    let slow = newSlowResponse(timer.seconds(60))
    fake.cannedResponse(slow)
    expect ProviderError:
      discard streamChat(fake, "https://x/v1", "test-key", "m", @[],
        proc (e: StreamEvent): bool = true, readTimeoutMs = 10)

suite "the scripted provider transport (L2)":
  test "the scripted steps stream as the real wire":
    let t = newScriptedTransport(@[ScriptStep(text: "hello")])
    var got: seq[StreamEvent] = @[]
    let r = streamChat(t, "https://x/v1", "k", "m",
      @[Message(role: roleUser, text: "q")],
      proc (e: StreamEvent): bool =
        got.add e
        true)
    check r.text == "hello"
    check r.finishReason == frStop
    check got[0].kind == seTextDelta
    check got[0].text == "hello"
    check got[^1].kind == seFinished

  test "the tool call steps reassemble through the full stack":
    let t = newScriptedTransport(@[
      ScriptStep(toolCalls: @[("call-1", "write", %*{"path": "a"})])])
    let r = streamChat(t, "https://x/v1", "k", "m", @[],
      proc (e: StreamEvent): bool = true)
    check r.finishReason == frToolUse
    check r.toolCalls.len == 1
    check r.toolCalls[0].id == "call-1"
    check r.toolCalls[0].name == "write"
    check r.toolCalls[0].args == parseJson("{\"path\": \"a\"}")

  test "the usageInput rides the response":
    let t = newScriptedTransport(@[ScriptStep(text: "ok", usageInput: 42)])
    let r = streamChat(t, "https://x/v1", "k", "m", @[],
      proc (e: StreamEvent): bool = true)
    check r.inputTokens == 42

  test "the out-of-steps raises":
    let t = newScriptedTransport(@[ScriptStep(text: "only")])
    discard streamChat(t, "https://x/v1", "k", "m", @[],
      proc (e: StreamEvent): bool = true)
    try:
      discard streamChat(t, "https://x/v1", "k", "m", @[],
        proc (e: StreamEvent): bool = true)
      fail()
    except ProviderError as e:
      check "out of steps" in e.msg
