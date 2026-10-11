## Tests for the OpenAI-compatible wire mapping: the SSE data payloads →
## the neopi StreamEvents and the accumulated Response. The hand-written
## chunks pin the wire shape; the two captured OpenRouter fixtures replay
## the real stream end-to-end (L1 — keyless, no network).
import std/json
import neopi/[openai_compat, provider]
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
