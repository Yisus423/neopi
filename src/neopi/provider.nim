## Minimal provider primitives for neopi's core: generate, stream, and
## model-callable tools.
##
## This module is neopi's anti-corruption layer over nimgent. Nimgent types and
## exceptions stay inside this file; callers see neopi-owned types only. The
## surface is primitives on purpose (the neovim-model boundary): the core
## exposes primitives, and composition such as agents and conversations happens
## above this layer.

import std/json
import nimgent as ng
import nimgent/providers/openai as ngOpenAI
import nimgent/providers/openrouter as ngOpenRouter
import nimgent/testing as ngTesting

type
  ProviderError* = object of CatchableError
    ## Raised for provider, transport, or request failures.
    overflow*: bool   ## True when the request exceeded the context window.
    retryable*: bool  ## True for 429 / 5xx / transport failures.
    status*: int      ## HTTP status, or 0 when there was no response.

  CancelledError* = object of ProviderError
    ## Raised when the caller cancels a stream or request.

  Provider* = object
    ## A provider configuration and its backing adapter. `impl` stays private:
    ## swapping nimgent for another backend must not touch callers.
    name*: string
    apiKey*: string
    baseUrl*: string
    impl: ng.Provider

  Model* = object
    ## A provider plus the model identifier to request.
    provider*: Provider
    id*: string

  ChatRole* = enum
    ## Message author role sent to the model.
    roleSystem = "system"
    roleUser = "user"
    roleAssistant = "assistant"

  Message* = object
    ## One role and its text.
    role*: ChatRole
    text*: string

  FinishReason* = enum
    ## Why the model stopped.
    frUnknown
    frEndTurn
    frToolUse
    frMaxTokens
    frStop
    frStepLimit

  Response* = object
    ## One generated answer with its usage metadata.
    text*: string
    finishReason*: FinishReason
    inputTokens*: int
    outputTokens*: int
    requestId*: string

  Tool* = object
    ## A model-callable tool: JSON Schema in, callback result back. A callback
    ## that raises reports a tool failure to the model instead of aborting.
    name*: string
    description*: string
    inputSchema*: JsonNode
    execute*: proc (args: JsonNode): string {.closure.}

  StreamEventKind* = enum
    ## Kind of normalized streaming event. Thinking deltas are not surfaced yet.
    seTextDelta
    seToolCallDelta
    seFinished

  StreamEvent* = object
    ## One streaming event: text, a tool-call fragment, or completion.
    case kind*: StreamEventKind
    of seTextDelta:
      text*: string
    of seToolCallDelta:
      toolCallId*: string
      toolName*: string
      toolArgs*: string  ## Argument fragment; empty when only the name arrived.
    of seFinished:
      discard

  StreamCallback* = proc (e: StreamEvent): bool {.closure.}
    ## Receives stream events. Return false to cancel the stream, which raises
    ## CancelledError once the provider call unwinds.

  ScriptStep* = object
    ## One scripted provider reply for application tests. A step with `text`
    ## replies with that text; otherwise it replies with its tool calls.
    text*: string
    toolCalls*: seq[tuple[id: string, name: string, args: JsonNode]]

proc openAI*(apiKey: string, baseUrl = ""): Provider =
  ## OpenAI-compatible provider. `baseUrl` overrides the endpoint, so any
  ## compatible gateway (OpenRouter, DeepInfra, a local server) works.
  Provider(name: "openai", apiKey: apiKey, baseUrl: baseUrl,
    impl: ngOpenAI.openAI(apiKey, baseUrl))

proc openRouter*(apiKey: string): Provider =
  ## OpenRouter provider using its OpenAI-compatible chat completions API.
  Provider(name: "openrouter", apiKey: apiKey,
    impl: ngOpenRouter.openRouter(apiKey))

proc scriptedProvider*(steps: seq[ScriptStep]): Provider =
  ## Deterministic provider for tests: one scripted reply per request.
  var scripted: seq[ng.ProviderResponse]
  for step in steps:
    if step.text.len > 0:
      scripted.add ngTesting.textResponse(step.text)
    else:
      var blocks: seq[ng.ContentBlock]
      for call in step.toolCalls:
        blocks.add ng.toolUse(call.id, call.name, call.args)
      scripted.add ng.ProviderResponse(content: blocks, finishReason: ng.frToolUse)
  Provider(name: "fake", apiKey: "", baseUrl: "",
    impl: ngTestIng.FakeProvider(name: "fake", responses: scripted))

proc model*(p: Provider, id: string): Model =
  ## Create a model reference for a provider and model ID.
  Model(provider: p, id: id)

proc splitSystem(messages: seq[Message]): tuple[system: string, rest: seq[ng.Message]] =
  ## Split system-role texts out of the message list. Nimgent accepts one
  ## system prompt string, so several system messages join with newlines.
  for msg in messages:
    case msg.role
    of roleSystem:
      if result.system.len > 0: result.system.add "\n"
      result.system.add msg.text
    of roleUser:
      result.rest.add ng.userMessage(msg.text)
    of roleAssistant:
      result.rest.add ng.assistantMessage(msg.text)

proc mappedTools(tools: seq[Tool]): seq[ng.Tool] =
  ## Map neopi tools onto nimgent runtime-schema tools. A callback result
  ## becomes both the provider-facing output and the retained JSON value.
  for t in tools:
    let tool = t  # explicit copy: a lent loop view cannot be captured
    result.add ng.rawTool(tool.name, tool.description, tool.inputSchema,
      proc (context: ng.ToolContext, input: JsonNode): ng.ToolResult =
        let output = tool.execute(input)
        ng.ToolResult(output: output, value: %output))

proc toFinishReason(reason: ng.FinishReason): FinishReason =
  ## Map a nimgent finish reason onto the neopi enum.
  case reason
  of ng.frEndTurn: frEndTurn
  of ng.frToolUse: frToolUse
  of ng.frMaxTokens: frMaxTokens
  of ng.frStop: frStop
  of ng.frStepLimit: frStepLimit
  of ng.frUnknown: frUnknown

proc toResponse(r: ng.ProviderResponse): Response =
  ## Map a nimgent response onto the neopi response shape.
  Response(text: ng.text(r), finishReason: toFinishReason(r.finishReason),
    inputTokens: r.usage.inputTokens, outputTokens: r.usage.outputTokens,
    requestId: r.requestId)

proc adaptStream(cb: StreamCallback): ng.StreamCallback =
  ## Map nimgent stream events onto the neopi callback. Thinking deltas and
  ## wake events are not surfaced yet; they neither emit nor cancel.
  proc (ev: ng.StreamEvent): bool =
    case ev.kind
    of ng.seTextDelta:
      cb(StreamEvent(kind: seTextDelta, text: ev.text))
    of ng.seToolCallDelta:
      cb(StreamEvent(kind: seToolCallDelta, toolCallId: ev.toolCallId,
        toolName: ev.toolName, toolArgs: ev.toolArgs))
    of ng.seFinished:
      cb(StreamEvent(kind: seFinished))
    else:
      true

proc translate(e: ref CatchableError) {.noinline, noreturn.} =
  ## Re-raise a failure as a neopi-owned exception at the boundary. Failures
  ## nimgent does not own pass through unchanged.
  if e of ng.CancelledError:
    raise newException(CancelledError, e.msg)
  if e of ng.ProviderError:
    let source = cast[ref ng.ProviderError](e)
    let translated = newException(ProviderError, e.msg)
    translated.overflow = source.overflow
    translated.retryable = source.retryable
    translated.status = source.status
    raise translated
  raise e

proc generate*(m: Model, prompt: string, tools: seq[Tool] = @[],
               maxSteps: Positive = 1, system = ""): Response =
  ## One text completion, with tool round-trips when the model calls a tool.
  ## `maxSteps` caps model turns; 1 means no continuation after a tool call.
  try:
    toResponse(ng.generateText(
      ng.LanguageModel(provider: m.provider.impl, id: m.id),
      prompt = prompt, system = system, tools = mappedTools(tools),
      maxSteps = maxSteps))
  except CatchableError as e:
    translate(e)

proc generate*(m: Model, messages: seq[Message], tools: seq[Tool] = @[],
               maxSteps: Positive = 1): Response =
  ## One text completion from an ordered message list.
  let split = splitSystem(messages)
  try:
    toResponse(ng.generateText(
      ng.LanguageModel(provider: m.provider.impl, id: m.id),
      messages = split.rest, system = split.system,
      tools = mappedTools(tools), maxSteps = maxSteps))
  except CatchableError as e:
    translate(e)

proc stream*(m: Model, prompt: string, onEvent: StreamCallback,
             tools: seq[Tool] = @[], maxSteps: Positive = 1, system = ""): Response =
  ## Stream text deltas, with tool round-trips when the model calls a tool.
  ## The response holds the full text once the stream finishes.
  try:
    toResponse(ng.streamText(
      ng.LanguageModel(provider: m.provider.impl, id: m.id),
      adaptStream(onEvent), prompt = prompt, system = system,
      tools = mappedTools(tools), maxSteps = maxSteps))
  except CatchableError as e:
    translate(e)

proc stream*(m: Model, messages: seq[Message], onEvent: StreamCallback,
             tools: seq[Tool] = @[], maxSteps: Positive = 1): Response =
  ## Stream text deltas from an ordered message list.
  let split = splitSystem(messages)
  try:
    toResponse(ng.streamText(
      ng.LanguageModel(provider: m.provider.impl, id: m.id),
      adaptStream(onEvent), messages = split.rest, system = split.system,
      tools = mappedTools(tools), maxSteps = maxSteps))
  except CatchableError as e:
    translate(e)
