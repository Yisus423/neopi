--- The agent loop: turn orchestration over the exposed core primitives.
--- Each turn builds the request from the session history and the runtime
--- tools, calls neopi.provider.generate (one model turn per call), appends
--- the assistant entry, executes the tool calls when the model requested
--- them, and records the tool results in the session. The loop returns the
--- final response table.
--- @module runtime.agent

local toolset = require("tools")

local agent = {}

--- Map the session history onto provider messages: user and assistant
--- entries contribute their text, tool results contribute their output as a
--- user message (tool results travel as user-message content in the core's
--- round-trip model), and entries with no text contribute nothing.
--- @param entries table[] -- the active branch's entries (JSONL-shaped tables)
--- @return table[] -- array of {role = string, text = string}
local function toMessages(entries)
  local messages = {}
  for _, e in ipairs(entries) do
    if e.type == "toolResult" then
      messages[#messages + 1] = {role = "user", text = e.output or ""}
    elseif (e.type == "user" or e.type == "assistant") and e.text and
        e.text ~= "" then
      messages[#messages + 1] = {role = e.type, text = e.text}
    end
  end
  return messages
end

--- Execute one tool call with the runtime tools, returning the output and
--- the error flag. A tool error becomes a failed tool result for the model
--- (the core's tool protocol), never a loop abort.
--- @param name string -- the tool name the model called
--- @param args table -- the call's arguments
--- @return string, boolean -- the output and whether it is an error
local function executeCall(name, args)
  local tool
  for _, t in ipairs(toolset.agentTools()) do
    if t.name == name then
      tool = t
      break
    end
  end
  if not tool then
    return "unknown tool: " .. tostring(name), true
  end
  local ok, result = pcall(tool.execute, args)
  if not ok then
    return tostring(result), true
  end
  return tostring(result), false
end

--- Run the agent loop: build the request from the session history and the
--- runtime tools, call the provider one model turn at a time, append the
--- assistant entry, execute tool calls while the model requests them, and
--- record every entry in the session.
--- @param session table -- the neopi.session handle (append/history/navigate)
--- @param config table -- {model = string, system = string?, maxSteps = number?}
--- @return table -- the final response
---   {text, stopReason, usage = {input, output}, toolCalls, provider}
function agent.run(session, config)
  local maxSteps = config.maxSteps or 8
  local response
  for _ = 1, maxSteps do
    local request = {
      model = config.model,
      messages = toMessages(session:history()),
      tools = toolset.agentTools(),
    }
    if config.system then
      request.system = config.system
    end
    response = neopi.provider.generate(request)
    session:append("assistant", {
      text = response.text or "",
      model = config.model,
      provider = response.provider or "",
      usageInput = (response.usage and response.usage.input) or 0,
      usageOutput = (response.usage and response.usage.output) or 0,
      stopReason = response.stopReason or "unknown",
    })
    if response.stopReason ~= "toolUse" then
      return response
    end
    for _, call in ipairs(response.toolCalls or {}) do
      local output, isError = executeCall(call.name, call.args)
      session:append("toolResult", {
        toolCallId = call.id,
        toolName = call.name,
        output = output,
        isError = isError,
      })
    end
  end
  -- The loop hit its step cap with the model still asking for tools; the
  -- core's own loop spells this frStepLimit.
  response.stopReason = "stepLimit"
  return response
end

return agent
