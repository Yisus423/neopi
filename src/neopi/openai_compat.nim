## The OpenAI-compatible wire mapping: the chat-completions streaming
## chunks (the SSE data payloads) → the neopi StreamEvents plus the
## accumulated Response parts. The reasoning deltas surface as thinking
## events: they are the model's own words, not the message text, so they
## never accumulate into it. The stream loop owns the end semantics: one
## seFinished after the done.
import std/json
import chronos
import neopi/wire
import neopi/primitives except CancelledError
import sse

type
  ToolCallAccum* = object
    ## One tool call reassembled from the streamed fragments (the wire
    ## sends the id and the name in the first fragment, the argument JSON
    ## in fragments after).
    id*: string
    name*: string
    args*: string

  OaiAccum* = object
    ## The accumulator the mapping updates per chunk; it becomes the
    ## Response when the stream ends.
    text*: string
    finishReason*: FinishReason
    inputTokens*: int
    outputTokens*: int
    requestId*: string
    done*: bool
    toolCalls*: seq[ToolCallAccum]

proc field(n: JsonNode, key: string): JsonNode =
  ## A missing key reads as JNull (std/json's getOrDefault returns nil,
  ## and nil has no kind).
  result = n.getOrDefault(key)
  if result.isNil:
    result = newJNull()

proc toToolCalls*(acc: OaiAccum): seq[tuple[id: string, name: string,
    args: JsonNode]] =
  for tc in acc.toolCalls:
    var parsed = newJNull()
    if tc.args.len > 0:
      try:
        parsed = parseJson(tc.args)
      except JsonParsingError, CatchableError:
        discard
    result.add (id: tc.id, name: tc.name, args: parsed)

proc mapOaiChunk*(data: string, acc: var OaiAccum): seq[StreamEvent] =
  ## One SSE data payload → the stream events; the accumulators update.
  ## The "[DONE]" sentinel sets acc.done and emits nothing. The empty
  ## content deltas emit nothing; the reasoning deltas emit a thinking
  ## event.
  result = @[]
  if data == "[DONE]":
    acc.done = true
    return
  let node = parseJson(data)
  if node.hasKey("id"):
    acc.requestId = node["id"].getStr("")
  if node.hasKey("usage") and node["usage"].kind == JObject:
    acc.inputTokens = node["usage"].getOrDefault("prompt_tokens").getInt(0)
    acc.outputTokens = node["usage"].getOrDefault("completion_tokens").getInt(0)
  if not node.hasKey("choices") or node["choices"].len == 0:
    return
  let choice = node["choices"][0]
  let delta = choice.field("delta")
  if delta.kind == JObject:
    let content = delta.field("content")
    if content.kind == JString and content.getStr("").len > 0:
      let text = content.getStr()
      acc.text.add text
      result.add StreamEvent(kind: seTextDelta, text: text)
    let reasoning = delta.field("reasoning")
    if reasoning.kind == JString and reasoning.getStr("").len > 0:
      # The model's own words, kept out of acc.text: thinking is not the
      # message, and the transcript renders it as its own collapsed item.
      result.add StreamEvent(kind: seThinkingDelta, text: reasoning.getStr())
    let toolCalls = delta.field("tool_calls")
    if toolCalls.kind == JArray:
      for tc in toolCalls:
        let idx = tc.field("index").getInt(0)
        while acc.toolCalls.len <= idx:
          acc.toolCalls.add ToolCallAccum()
        let fn = tc.field("function")
        let id = tc.field("id").getStr("")
        let name = if fn.kind == JObject: fn.getOrDefault("name").getStr("") else: ""
        let args = if fn.kind == JObject: fn.getOrDefault("arguments").getStr("") else: ""
        if id.len > 0:
          acc.toolCalls[idx].id = id
        if name.len > 0:
          acc.toolCalls[idx].name = name
        if args.len > 0:
          acc.toolCalls[idx].args.add args
        result.add StreamEvent(kind: seToolCallDelta, toolCallId: id,
          toolName: name, toolArgs: args)
  let finish = choice.field("finish_reason")
  if finish.kind == JString:
    case finish.getStr()
    of "stop":
      acc.finishReason = frStop
    of "tool_calls":
      acc.finishReason = frToolUse
    of "length":
      acc.finishReason = frMaxTokens
    else:
      discard

proc roleStr(r: ChatRole): string =
  ## The wire spelling of the role (the enum's $ gives the identifier).
  case r
  of roleSystem: "system"
  of roleUser: "user"
  of roleAssistant: "assistant"
  of roleTool: "tool"

proc buildChatRequest*(model: string, messages: seq[Message], system = "",
    tools: seq[Tool] = @[], stream = true): JsonNode =
  ## The chat-completions request body. The system message leads when set;
  ## the tools key stays out when there are none (the wire omits it). An
  ## assistant message's requested tool calls ride a `tool_calls` array, and
  ## a tool result message carries its `tool_call_id`; the plain-message
  ## output stays byte-identical.
  var msgs = newJArray()
  if system.len > 0:
    msgs.add %*{"role": "system", "content": system}
  for m in messages:
    var entry = newJObject()
    entry["role"] = %roleStr(m.role)
    entry["content"] = %m.text
    if m.toolCalls.len > 0:
      var calls = newJArray()
      for call in m.toolCalls:
        calls.add %*{"id": call.id, "type": "function", "function":
          {"name": call.name, "arguments": $call.args}}
      entry["tool_calls"] = calls
    if m.toolCallId.len > 0:
      entry["tool_call_id"] = %m.toolCallId
    msgs.add entry
  result = %*{"model": model, "messages": msgs, "stream": stream}
  if tools.len > 0:
    var arr = newJArray()
    for t in tools:
      arr.add %*{"type": "function", "function": {"name": t.name,
        "description": t.description, "parameters": t.inputSchema}}
    result["tools"] = arr

proc chatHeaders*(apiKey: string): seq[(string, string)] =
  ## The auth and content headers. The key arrives here from the caller —
  ## the tests pass dummy keys and assert this exact shape. An EMPTY key is a
  ## keyless provider (a local server, a table entry with `requiresKey: false`):
  ## no Authorization header at all, because `Bearer ` with nothing after it is
  ## not a credential. A keyed provider's wire stays byte-identical.
  if apiKey.len == 0:
    return @[("Content-Type", "application/json")]
  @[("Authorization", "Bearer " & apiKey),
    ("Content-Type", "application/json")]

proc modelsHeaders(apiKey: string): seq[(string, string)] =
  ## The catalog request headers: the bearer key only (a GET carries no
  ## body, so no content type). A keyless provider sends no header at all.
  if apiKey.len == 0:
    return @[]
  @[("Authorization", "Bearer " & apiKey)]

proc buildModelsRequest*(baseUrl, apiKey: string): WireRequest =
  ## The model-catalog request: `GET <baseUrl>/models` with the bearer key.
  ## The base is the provider's (the same one `/chat/completions` uses).
  WireRequest(url: baseUrl & "/models", httpMethod: "GET",
    headers: modelsHeaders(apiKey), body: "")

proc parseModels*(body: string): seq[string] =
  ## The OpenAI-compatible catalog (`{"data": [{"id": "..."}]}`) → the
  ## model ids, in the endpoint's order. A body that is not valid JSON, or
  ## that has no `data` array, raises ProviderError: a failed catalog is
  ## never an empty catalog. Entries without a non-empty string id are
  ## skipped (the endpoint sometimes carries metadata-only rows).
  var node: JsonNode
  try:
    node = parseJson(body)
  except JsonParsingError, CatchableError:
    raise newException(ProviderError, "the model catalog is not valid JSON")
  if node.kind != JObject or not node.hasKey("data") or
      node["data"].kind != JArray:
    raise newException(ProviderError, "the model catalog has no data array")
  for entry in node["data"]:
    let id = entry.field("id")
    if id.kind == JString and id.getStr("").len > 0:
      result.add id.getStr()

proc streamChatAsync*(transport: Transport, baseUrl: string, apiKey: string,
    model: string, messages: seq[Message], onEvent: primitives.StreamCallback,
    system = "", tools: seq[Tool] = @[], readTimeoutMs = 0):
    Future[Response] {.async: (raises: [CatchableError]).} =
  ## One streamed model turn over the wire: the SSE parser and the mapping
  ## consume the body, the callback sees the events (false cancels — the
  ## CancelledError unwinds, expose.nim builds the partial response), and
  ## the accumulated Response returns. readTimeoutMs bounds each body read
  ## (0 disables; a silent stream is the hung-stream failure mode).
  let wireReq = WireRequest(url: baseUrl & "/chat/completions",
    httpMethod: "POST", headers: chatHeaders(apiKey),
    body: $buildChatRequest(model, messages, system, tools))
  var resp: WireResponse
  try:
    resp = await transport.fetch(wireReq)
  except CancelledError:
    raise
  except ProviderError:
    raise
  except CatchableError as e:
    var err = newException(ProviderError, "the transport failed: " & e.msg)
    err.retryable = true
    raise err
  if resp.status != 200:
    var errBody = ""
    for _ in 0 ..< 32:
      let chunk = await resp.next()
      if chunk.len == 0:
        break
      errBody.add chunk
      if errBody.len > 8192:
        break
    var err = newException(ProviderError,
      "the provider returned " & $resp.status & ": " & errBody)
    err.status = resp.status
    err.retryable = resp.status == 429 or resp.status >= 500
    raise err
  var acc: OaiAccum
  var parser = initSSEParser()
  try:
    while true:
      var chunk: string
      if readTimeoutMs > 0:
        let readFut = resp.next()
        let timeoutFut = sleepAsync(readTimeoutMs.milliseconds)
        let winner = await race(FutureBase(readFut), FutureBase(timeoutFut))
        if winner == FutureBase(timeoutFut):
          await readFut.cancelAndWait()
          raise newException(ProviderError,
            "the stream read timed out after " & $readTimeoutMs & "ms")
        await timeoutFut.cancelAndWait()
        chunk = await readFut
      else:
        chunk = await resp.next()
      if chunk.len == 0:
        break
      for ev in parser.feed(chunk):
        if ev.data.len == 0:
          continue
        for e in mapOaiChunk(ev.data, acc):
          if not onEvent(e):
            raise newException(primitives.CancelledError,
              "the stream was cancelled")
      if acc.done:
        break
    discard onEvent(StreamEvent(kind: seFinished))
  finally:
    resp.close()
  return Response(text: acc.text, finishReason: acc.finishReason,
    inputTokens: acc.inputTokens, outputTokens: acc.outputTokens,
    requestId: acc.requestId, toolCalls: acc.toToolCalls())

proc streamChat*(transport: Transport, baseUrl: string, apiKey: string,
    model: string, messages: seq[Message], onEvent: primitives.StreamCallback,
    system = "", tools: seq[Tool] = @[], readTimeoutMs = 0): Response =
  ## The blocking boundary (the shape the Lua surface calls): chronos's
  ## waitFor pumps the loop while the stream runs.
  waitFor streamChatAsync(transport, baseUrl, apiKey, model, messages,
    onEvent, system, tools, readTimeoutMs)

proc listModelsAsync*(transport: Transport, baseUrl: string, apiKey: string):
    Future[seq[string]] {.async: (raises: [CatchableError]).} =
  ## One model-catalog fetch over the wire: `GET <baseUrl>/models` through
  ## the transport, the whole body accumulated and parsed into ids. A
  ## transport failure, a non-200 status, or a malformed body raises
  ## ProviderError (the body rides the non-200 message).
  let wireReq = buildModelsRequest(baseUrl, apiKey)
  var resp: WireResponse
  try:
    resp = await transport.fetch(wireReq)
  except CancelledError:
    raise
  except ProviderError:
    raise
  except CatchableError as e:
    var err = newException(ProviderError, "the transport failed: " & e.msg)
    err.retryable = true
    raise err
  var body = ""
  try:
    while true:
      let chunk = await resp.next()
      if chunk.len == 0:
        break
      body.add chunk
  finally:
    resp.close()
  if resp.status != 200:
    var err = newException(ProviderError,
      "the provider returned " & $resp.status & ": " & body)
    err.status = resp.status
    err.retryable = resp.status == 429 or resp.status >= 500
    raise err
  return parseModels(body)

proc listModels*(transport: Transport, baseUrl: string, apiKey: string):
    seq[string] =
  ## The blocking boundary (the shape the policy layer calls): chronos's
  ## waitFor pumps the loop while the catalog is fetched.
  waitFor listModelsAsync(transport, baseUrl, apiKey)

type ScriptedTransport* = ref object of Transport
  ## The L2 test transport: one scripted reply per fetch, encoded as the
  ## real OpenAI wire (the whole streamChat stack runs under test). Every
  ## request is recorded for the assertions: the second fetch's body is what
  ## the tool round-trip test parses.
  steps: seq[ScriptStep]
  index: int
  requests*: seq[WireRequest]

proc scriptChunks*(step: ScriptStep): seq[string] =
  ## One scripted step → the SSE wire chunks (the inverse of the mapping:
  ## the text becomes a content delta, the tool calls the fragments at their
  ## own index, the finish reason follows the shape, the usage rides its
  ## chunk).
  var finish = "stop"
  if step.toolCalls.len > 0:
    finish = "tool_calls"
    for i, call in step.toolCalls:
      result.add "data: " & ($(%*{"choices": [{"delta": {"tool_calls": [{
        "index": i, "id": call.id, "type": "function", "function": {
        "name": call.name, "arguments": $(call.args)}}]}}]})) & "\n\n"
  if step.text.len > 0:
    result.add "data: " & ($(%*{"choices": [{"delta": {"content":
      step.text}}]})) & "\n\n"
  result.add "data: " & ($(%*{"choices": [{"delta": {},
    "finish_reason": finish}]})) & "\n\n"
  result.add "data: " & ($(%*{"usage": {"prompt_tokens": step.usageInput,
    "completion_tokens": 0}})) & "\n\n"
  result.add "data: [DONE]\n\n"

proc newScriptedTransport*(steps: seq[ScriptStep]): ScriptedTransport =
  ## The scripted transport with no recorded requests yet.
  ScriptedTransport(steps: steps, index: 0, requests: @[])

method fetch*(t: ScriptedTransport, req: WireRequest): Future[WireResponse] {.
    async.} =
  ## Record the request and serve the next scripted step's wire, or raise
  ## when the steps run out.
  t.requests.add req
  if t.index >= t.steps.len:
    raise newException(ProviderError,
      "the scripted provider ran out of steps")
  let step = t.steps[t.index]
  inc t.index
  return newFakeWireResponse(200, scriptChunks(step))
