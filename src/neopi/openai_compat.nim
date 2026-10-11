## The OpenAI-compatible wire mapping: the chat-completions streaming
## chunks (the SSE data payloads) → the neopi StreamEvents plus the
## accumulated Response parts. The reasoning deltas are dropped: the
## neopi StreamEvent contract has no thinking kind today (the TUI slice
## decides the extension). The stream loop owns the end semantics: one
## seFinished after the done.
import std/json
import neopi/provider

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
  ## The accumulated fragments → the response tool calls. The argument
  ## fragments join into one JSON value; an unparsable accumulation
  ## surfaces as JNull (the engine reports a tool failure instead of
  ## aborting the run).
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
