## The provider policy layer: the Provider/Model objects, the tool
## round-trip loop, and the hook gates, streaming through openai_compat
## over the injectable wire transport. The caller-facing types and
## exceptions live in neopi/primitives (the protocol module names them
## without importing this one); this module re-exports them, so
## `import neopi/provider` keeps the whole surface.
##
## The surface is primitives on purpose (the neovim-model boundary): the core
## exposes primitives, and composition such as agents and conversations happens
## above this layer.

import std/json
import std/options
import neopi/hooks
import neopi/primitives
import neopi/openai_compat
import neopi/wire

export primitives

# Same file-scope typedef as lua.nim/hooks.nim: provider.nim's generated C
# materializes the HookBus object, whose field holds the opaque state type.
{.emit: """/*TYPESECTION*/ typedef struct lua_State lua_State;""".}

const
  defaultOpenAiBase* = "https://api.openai.com/v1"
    ## The OpenAI chat-completions base URL. `openAI` appends
    ## "/chat/completions"; pass `baseUrl` to point at a compatible gateway.
  defaultOpenRouterBase* = "https://openrouter.ai/api/v1"
    ## The OpenRouter chat-completions base URL.
  defaultReadTimeoutMs = 300_000
    ## The per-read bound on the stream. The previous layer bounded a whole
    ## request at 300s; 5 silent minutes per read keeps that spirit while
    ## letting a progressing stream keep going.

type
  Provider* = object
    ## A provider configuration and its backing wire transport. `transport`
    ## stays private: swapping the backend must not touch callers. Build a
    ## Provider with `openAI`/`openRouter`/`scriptedProvider`, which always set
    ## it; the optional `transport` argument on the first two is the injection
    ## seam the L1/L2 tests use.
    name*: string
    apiKey*: string
    baseUrl*: string
    transport: Transport

  Model* = object
    ## A provider plus the model identifier to request.
    provider*: Provider
    id*: string

  ProviderSpec* = object
    ## One entry of the built-in provider table: the identity (`id`, which is
    ## also the `Provider.name` the status line and the footer show), the
    ## endpoint the OpenAI-compatible wire is appended to, the environment
    ## variable the key comes from, and whether a key is REQUIRED to start.
    ## A keyless entry keeps its variable: `requiresKey: false` relaxes the
    ## requirement, not the credential, so a local server started with a key
    ## still receives it.
    id*: string
    baseUrl*: string
    envVar*: string
    requiresKey*: bool

const
  # The two entries the constructors below name directly. The table and
  # `openAI`/`openRouter` read this same spec, so they cannot drift apart.
  openAiSpec = ProviderSpec(id: "openai", baseUrl: defaultOpenAiBase,
    envVar: "OPENAI_API_KEY", requiresKey: true)
  openRouterSpec = ProviderSpec(id: "openrouter", baseUrl: defaultOpenRouterBase,
    envVar: "OPENROUTER_API_KEY", requiresKey: true)

proc knownProviders*(): seq[ProviderSpec] =
  ## The built-in provider table: the OpenAI-compatible endpoints this build
  ## knows, each with the variable its key comes from. `openai` and `openrouter`
  ## are the two neopi exercises; `deepseek`, `groq`, `together` and `cerebras`
  ## are the four endpoints a real client reaches with this same wire (pi's
  ## providers for them use its `openai-completions` implementation), and the
  ## last two are local servers that need no key. `--base-url` reaches anything
  ## else, so the table is a convenience and never the only way in.
  @[openAiSpec, openRouterSpec,
    ProviderSpec(id: "deepseek", baseUrl: "https://api.deepseek.com",
      envVar: "DEEPSEEK_API_KEY", requiresKey: true),
    ProviderSpec(id: "groq", baseUrl: "https://api.groq.com/openai/v1",
      envVar: "GROQ_API_KEY", requiresKey: true),
    ProviderSpec(id: "together", baseUrl: "https://api.together.ai/v1",
      envVar: "TOGETHER_API_KEY", requiresKey: true),
    ProviderSpec(id: "cerebras", baseUrl: "https://api.cerebras.ai/v1",
      envVar: "CEREBRAS_API_KEY", requiresKey: true),
    ProviderSpec(id: "ollama", baseUrl: "http://localhost:11434/v1",
      envVar: "OLLAMA_API_KEY", requiresKey: false),
    ProviderSpec(id: "llamacpp", baseUrl: "http://127.0.0.1:8080/v1",
      envVar: "LLAMACPP_API_KEY", requiresKey: false)]

proc findProvider*(id: string): Option[ProviderSpec] =
  ## The table entry for `id`, or `none` when this build does not carry it.
  for spec in knownProviders():
    if spec.id == id:
      return some(spec)
  none(ProviderSpec)

proc newProvider*(spec: ProviderSpec, apiKey: string, baseUrl = "",
    transport: Transport = nil): Provider =
  ## The provider a table entry describes. A non-empty `baseUrl` overrides the
  ## entry's endpoint (a gateway whose URL differs, or a provider the table does
  ## not carry); `transport` injects the wire transport (the pi `client` option
  ## pattern) and nil uses the production chronos transport. An EMPTY `apiKey`
  ## is a keyless provider: the wire sends no Authorization header at all.
  let url = if baseUrl.len > 0: baseUrl else: spec.baseUrl
  let wire = if transport.isNil: Transport(newChronosTransport()) else: transport
  Provider(name: spec.id, apiKey: apiKey, baseUrl: url, transport: wire)

proc openAI*(apiKey: string, baseUrl = "", transport: Transport = nil): Provider =
  ## OpenAI-compatible provider over chat completions. `baseUrl` overrides the
  ## endpoint (a BASE url; "/chat/completions" is appended), so any compatible
  ## gateway (OpenRouter, DeepInfra, a local server) works. `transport`
  ## injects the wire transport (the pi `client` option pattern); nil uses the
  ## production chronos transport. neopi speaks chat completions; the switch
  ## from the Responses API is intentional. The endpoint comes from the table
  ## entry, so this and `--provider openai` cannot drift apart.
  newProvider(openAiSpec, apiKey, baseUrl, transport)

proc openRouter*(apiKey: string, transport: Transport = nil): Provider =
  ## OpenRouter provider over its OpenAI-compatible chat completions API.
  ## `transport` injects the wire transport; nil uses the production chronos
  ## transport. The endpoint comes from the table entry.
  newProvider(openRouterSpec, apiKey, "", transport)

proc scriptedProvider*(steps: seq[ScriptStep]): Provider =
  ## Deterministic provider for tests: one scripted reply per request, served
  ## through the full streamChat stack over an in-memory transport. The name
  ## stays "fake" (the exposure tests assert it).
  Provider(name: "fake", transport: newScriptedTransport(steps))

proc model*(p: Provider, id: string): Model =
  ## Create a model reference for a provider and model ID.
  Model(provider: p, id: id)

proc listModels*(p: Provider): seq[string] =
  ## The provider's real model catalog: `GET <baseUrl>/models` over the
  ## provider's own transport, parsed into model ids. A transport failure,
  ## a non-200 status, or a malformed body raises ProviderError. The
  ## transport stays private: the caller holds a Provider and receives ids.
  listModels(p.transport, p.baseUrl, p.apiKey)

proc splitSystem(messages: seq[Message]): tuple[system: string, rest: seq[Message]] =
  ## Split system-role texts out of the message list. The wire carries one
  ## system prompt string, so several system messages join with newlines;
  ## every other message (including a tool result) passes through untouched.
  for msg in messages:
    case msg.role
    of roleSystem:
      if result.system.len > 0: result.system.add "\n"
      result.system.add msg.text
    of roleUser, roleAssistant, roleTool:
      result.rest.add msg

proc canExecute(tools: seq[Tool]): bool =
  ## True when at least one tool carries an execute callback (the tool loop
  ## can continue only then).
  for t in tools:
    if not t.execute.isNil:
      return true

proc findTool(tools: seq[Tool], name: string): int =
  ## The index of the tool named `name`, or -1 when it is not registered.
  result = -1
  for i, t in tools:
    if t.name == name:
      return i

proc invokeTool(tool: Tool, bus: HookBus, input: JsonNode): string =
  ## Execute one tool through the hook gates. With a bus, `tool_call` can
  ## block (the model sees the denial reason — this is the bash approval gate)
  ## or rewrite the arguments before the callback, and `tool_result` can
  ## rewrite the output after it. A Lua hook error or a raising callback is
  ## reported to the model as the failure text, never aborting the turn (the
  ## failure-as-tool-result contract).
  try:
    var effective = input
    if not bus.isNil:
      var payload = %*{"tool": tool.name}
      payload["args"] = input
      let verdict = bus.emit("tool_call", payload)
      if not verdict.allowed:
        return verdict.reason
      if verdict.patched and not verdict.payload.isNil and
          verdict.payload.hasKey("args"):
        effective = verdict.payload["args"]
    let output = tool.execute(effective)
    var sent = output
    if not bus.isNil:
      let verdict = bus.emit("tool_result",
        %*{"tool": tool.name, "output": output})
      if verdict.patched and not verdict.payload.isNil and
          verdict.payload.hasKey("output"):
        sent = verdict.payload["output"].getStr
    return sent
  except CatchableError as e:
    return e.msg

proc executeCall(tools: seq[Tool], bus: HookBus, call: ToolCall): string =
  ## Execute one model-requested call. Unparsable arguments and unknown tool
  ## names report a failure to the model instead of raising.
  if call.args.kind == JNull:
    return "invalid_arguments: the tool arguments are not valid JSON"
  let idx = findTool(tools, call.name)
  if idx < 0:
    return "Unknown tool: " & call.name
  invokeTool(tools[idx], bus, call.args)

proc runTurn(m: Model, system: string, conversation: seq[Message],
             tools: seq[Tool], maxSteps: Positive, bus: HookBus,
             onEvent: StreamCallback): Response =
  ## The tool round-trip loop: stream one model turn, execute the requested
  ## calls while the loop can continue, feed the assistant call and the tool
  ## results back, and stop at `maxSteps` (the cap reports frStepLimit when the
  ## model still asked for tools). In generate mode (`onEvent` nil) no event
  ## is forwarded and no hook fires; in stream mode the per-step finish is
  ## swallowed and exactly one seFinished is emitted for the whole turn. A
  ## cancellation (onEvent returning false) unwinds without any seFinished.
  if conversation.len == 0:
    raise newException(ProviderError, "the request needs at least one message")
  var messages = conversation
  var step = 1
  while true:
    let inner = proc (e: StreamEvent): bool =
      if onEvent.isNil:
        return true
      if e.kind == seFinished:
        return true
      if e.kind == seTextDelta and not bus.isNil:
        discard bus.emit("stream_text", %*{"text": e.text})
      onEvent(e)
    result = streamChat(m.provider.transport, m.provider.baseUrl,
      m.provider.apiKey, m.id, messages, inner, system = system, tools = tools,
      readTimeoutMs = defaultReadTimeoutMs)
    let stop = result.toolCalls.len == 0 or not canExecute(tools)
    if stop or step >= maxSteps:
      if not stop:
        result.finishReason = frStepLimit
      break
    messages.add Message(role: roleAssistant, text: result.text,
      toolCalls: result.toolCalls)
    for call in result.toolCalls:
      messages.add Message(role: roleTool,
        text: executeCall(tools, bus, call), toolCallId: call.id)
    inc step
  if not onEvent.isNil:
    discard onEvent(StreamEvent(kind: seFinished))

proc generate*(m: Model, prompt: string, tools: seq[Tool] = @[],
               maxSteps: Positive = 1, system = "", bus: HookBus = nil): Response =
  ## One text completion, with tool round-trips when the model calls a tool.
  ## `maxSteps` caps model turns; 1 means no continuation after a tool call.
  ## With a bus, tool calls and results fire the `tool_call`/`tool_result`
  ## hooks.
  runTurn(m, system, @[Message(role: roleUser, text: prompt)], tools, maxSteps,
    bus, nil)

proc generate*(m: Model, messages: seq[Message], tools: seq[Tool] = @[],
               maxSteps: Positive = 1, bus: HookBus = nil): Response =
  ## One text completion from an ordered message list. With a bus, tool calls
  ## and results fire the `tool_call`/`tool_result` hooks.
  let split = splitSystem(messages)
  runTurn(m, split.system, split.rest, tools, maxSteps, bus, nil)

proc stream*(m: Model, prompt: string, onEvent: StreamCallback,
             tools: seq[Tool] = @[], maxSteps: Positive = 1, system = "",
             bus: HookBus = nil): Response =
  ## Stream text deltas, with tool round-trips when the model calls a tool.
  ## The response holds the full text once the stream finishes. With a bus,
  ## text deltas fire the observe-only `stream_text` hook.
  runTurn(m, system, @[Message(role: roleUser, text: prompt)], tools, maxSteps,
    bus, onEvent)

proc stream*(m: Model, messages: seq[Message], onEvent: StreamCallback,
             tools: seq[Tool] = @[], maxSteps: Positive = 1,
             bus: HookBus = nil): Response =
  ## Stream text deltas from an ordered message list. With a bus, text
  ## deltas fire the observe-only `stream_text` hook.
  let split = splitSystem(messages)
  runTurn(m, split.system, split.rest, tools, maxSteps, bus, onEvent)
