## The OpenAI-compatible wire mapping: the chat-completions streaming
## chunks (the SSE data payloads) → the neopi StreamEvents plus the
## accumulated Response parts. The reasoning deltas are dropped: the
## neopi StreamEvent contract has no thinking kind today (the TUI slice
## decides the extension). The stream loop owns the end semantics: one
## seFinished after the done.
import std/json
import chronos
import neopi/wire
import neopi/provider except CancelledError
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
  ## content deltas and the reasoning deltas emit nothing.
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

proc buildChatRequest*(model: string, messages: seq[Message], system = "",
    tools: seq[Tool] = @[], stream = true): JsonNode =
  ## The chat-completions request body. The system message leads when set;
  ## the tools key stays out when there are none (the wire omits it).
  var msgs = newJArray()
  if system.len > 0:
    msgs.add %*{"role": "system", "content": system}
  for m in messages:
    msgs.add %*{"role": roleStr(m.role), "content": m.text}
  result = %*{"model": model, "messages": msgs, "stream": stream}
  if tools.len > 0:
    var arr = newJArray()
    for t in tools:
      arr.add %*{"type": "function", "function": {"name": t.name,
        "description": t.description, "parameters": t.inputSchema}}
    result["tools"] = arr

proc chatHeaders*(apiKey: string): seq[(string, string)] =
  ## The auth and content headers. The key arrives here from the caller —
  ## the tests pass dummy keys and assert this exact shape.
  @[("Authorization", "Bearer " & apiKey),
    ("Content-Type", "application/json")]

proc streamChatAsync*(transport: Transport, baseUrl: string, apiKey: string,
    model: string, messages: seq[Message], onEvent: provider.StreamCallback,
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
  let resp = await transport.fetch(wireReq)
  if resp.status != 200:
    var errBody = ""
    for _ in 0 ..< 32:
      let chunk = await resp.next()
      if chunk.len == 0:
        break
      errBody.add chunk
      if errBody.len > 8192:
        break
    raise newException(ProviderError,
      "the provider returned " & $resp.status & ": " & errBody)
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
            raise newException(provider.CancelledError, "the stream was cancelled")
      if acc.done:
        break
    discard onEvent(StreamEvent(kind: seFinished))
  finally:
    resp.close()
  return Response(text: acc.text, finishReason: acc.finishReason,
    inputTokens: acc.inputTokens, outputTokens: acc.outputTokens,
    requestId: acc.requestId, toolCalls: acc.toToolCalls())

proc streamChat*(transport: Transport, baseUrl: string, apiKey: string,
    model: string, messages: seq[Message], onEvent: provider.StreamCallback,
    system = "", tools: seq[Tool] = @[], readTimeoutMs = 0): Response =
  ## The blocking boundary (the shape the Lua surface calls): chronos's
  ## waitFor pumps the loop while the stream runs.
  waitFor streamChatAsync(transport, baseUrl, apiKey, model, messages,
    onEvent, system, tools, readTimeoutMs)
