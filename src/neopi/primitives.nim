## The provider-layer primitives: the caller-facing types and exceptions the
## provider contract is written in. They live here so the protocol module
## (openai_compat) can name them without importing the policy module
## (provider), which imports it back; provider.nim re-exports this module so
## `import neopi/provider` keeps the whole surface.
##
## The surface is primitives on purpose (the neovim-model boundary): the core
## exposes primitives, and composition such as agents and conversations happens
## above this layer.
import std/json

type
  ProviderError* = object of CatchableError
    ## Raised for provider, transport, or request failures.
    overflow*: bool   ## True when the request exceeded the context window.
    retryable*: bool  ## True for 429 / 5xx / transport failures.
    status*: int      ## HTTP status, or 0 when there was no response.

  CancelledError* = object of ProviderError
    ## Raised when the caller cancels a stream or request.

  ChatRole* = enum
    ## Message author role sent to the model.
    roleSystem = "system"
    roleUser = "user"
    roleAssistant = "assistant"
    roleTool = "tool"

  ToolCall* = tuple[id, name: string, args: JsonNode]
    ## One tool call the model requested: the call id, the tool name, and the
    ## parsed arguments.

  Message* = object
    ## One role and its text. An assistant message may also carry the tool
    ## calls it requested (`toolCalls`), and a tool result message carries the
    ## id of the call it answers (`toolCallId`); both ride this same type so
    ## the tool round-trip's messages stay ordinary `Message` values.
    role*: ChatRole
    text*: string
    toolCalls*: seq[ToolCall]
    toolCallId*: string

  FinishReason* = enum
    ## Why the model stopped.
    frUnknown
    frEndTurn
    frToolUse
    frMaxTokens
    frStop
    frStepLimit
    frCancelled

  Response* = object
    ## One generated answer with its usage metadata and the tool calls the
    ## model requested (empty when the model answered without tools).
    text*: string
    finishReason*: FinishReason
    inputTokens*: int
    outputTokens*: int
    requestId*: string
    toolCalls*: seq[ToolCall]

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

  StreamCallback* = proc (e: StreamEvent): bool {.closure, gcsafe,
      raises: [CatchableError].}
    ## Receives stream events. Return false to cancel the stream, which raises
    ## CancelledError once the provider call unwinds. A callback may raise
    ## (the Lua sinks surface their handler errors Nim-side; the stream's
    ## caller contains them).

  ScriptStep* = object
    ## One scripted provider reply for application tests. A step with `text`
    ## replies with that text; otherwise it replies with its tool calls.
    ## `usageInput` overrides the reply's reported input tokens (0 keeps the
    ## default zero), so the agent loop's compaction trigger sees a real
    ## token estimate in tests.
    text*: string
    usageInput*: int
    toolCalls*: seq[ToolCall]
