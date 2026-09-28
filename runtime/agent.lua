--- The agent loop: turn orchestration over the exposed core primitives.
--- Each turn builds the request from the session history and the runtime
--- tools (the generate merges the runtime registry's registered ones into
--- the tool list the model sees), calls neopi.provider.generate (one model
--- turn per call), appends the assistant entry, executes the tool calls
--- when the model requested them, and records the tool results in the
--- session. The loop returns the final response table.
--- @module runtime.agent

local toolset = require("tools")

local agent = {}

--- Map the session history onto provider messages (the projection): user
--- and assistant entries contribute their text, tool results contribute
--- their output as a user message (tool results travel as user-message
--- content in the core's round-trip model), and entries with no text
--- contribute nothing. A compaction entry projects its summary as a
--- system-role message and skips the entries before its firstKeptId; on
--- repeated compactions the latest compaction entry wins (its summary
--- replaces the earlier ones in the projection).
--- @param entries table[] -- the active branch's entries (JSONL-shaped tables)
--- @return table[] -- array of {role = string, text = string}
local function toMessages(entries)
  local summary, firstKeptId
  for _, e in ipairs(entries) do
    if e.type == "compaction" then
      summary = e.summary
      firstKeptId = e.firstKeptId
    end
  end
  local messages = {}
  if summary then
    messages[#messages + 1] = {role = "system", text = summary}
  end
  for _, e in ipairs(entries) do
    local kept = e.type ~= "compaction" and
      (firstKeptId == nil or e.id == nil or e.id >= firstKeptId)
    if kept and e.type == "toolResult" then
      messages[#messages + 1] = {role = "user", text = e.output or ""}
    elseif kept and (e.type == "user" or e.type == "assistant") and e.text and
        e.text ~= "" then
      messages[#messages + 1] = {role = e.type, text = e.text}
    end
  end
  return messages
end

--- Token estimate for one entry: the assistant's reported usage input when
--- available, else a rough estimate over its text or output (~4 chars per
--- token; at least 1).
--- @param e table -- one JSONL-shaped entry
--- @return number -- the estimated token count
local function estimateTokens(e)
  if e.type == "assistant" and e.usageInput then
    return e.usageInput
  end
  local content = e.text or e.output or ""
  return math.max(1, math.floor(#content / 4))
end

--- Walk the branch backwards from the tip, accumulating token estimates, and
--- return the cut point: the first user or assistant entry (walking
--- backwards) where the accumulated estimate reaches keepRecentTokens. Tool
--- results are never cut points, so a cut keeps every tool result with its
--- tool call. Returns nil when the whole branch fits in keepRecentTokens.
--- @param entries table[] -- the active branch's entries (JSONL-shaped tables)
--- @param keepRecentTokens number -- the token budget the kept region must reach
--- @return number|nil -- the cut point's entry id, or nil
local function findCutPoint(entries, keepRecentTokens)
  local accumulated = 0
  for i = #entries, 1, -1 do
    local e = entries[i]
    accumulated = accumulated + estimateTokens(e)
    if (e.type == "user" or e.type == "assistant") and
        accumulated >= keepRecentTokens then
      return e.id
    end
  end
  return nil
end

--- Truncate a string to `limit` characters, marking the cut.
--- @param s string -- the string to truncate
--- @param limit number -- the maximum length
--- @return string -- the truncated string
local function truncate(s, limit)
  if #s <= limit then
    return s
  end
  return string.sub(s, 1, limit) .. "...[truncated]"
end

--- Serialize the summarized region for the summarization request: one line
--- per entry with pi's labels; tool results truncated to 2000 chars.
--- Compaction entries contribute nothing (they are not conversation turns).
--- @param entries table[] -- the entries before the cut point
--- @return string -- the serialized conversation
local function serializeConversation(entries)
  local lines = {}
  local i = 1
  while i <= #entries do
    local e = entries[i]
    if e.type == "user" then
      lines[#lines + 1] = "[User]: " .. (e.text or "")
    elseif e.type == "assistant" then
      if e.text and e.text ~= "" then
        lines[#lines + 1] = "[Assistant]: " .. e.text
      else
        -- A tool request: the entry records no calls; the names travel on
        -- the tool results that follow it.
        local names = {}
        local j = i + 1
        while j <= #entries and entries[j].type == "toolResult" do
          names[#names + 1] = entries[j].toolName or "unknown"
          j = j + 1
        end
        lines[#lines + 1] = "[Assistant tool calls]: " ..
          table.concat(names, ", ")
      end
    elseif e.type == "toolResult" then
      lines[#lines + 1] = "[Tool result]: " .. truncate(e.output or "", 2000)
    end
    i = i + 1
  end
  return table.concat(lines, "\n")
end

--- The summarization prompt (pi's format): the structured sections plus the
--- serialized conversation as critical context.
--- @param serialized string -- the serialized conversation
--- @return string -- the prompt for the summarization request
local function summaryPrompt(serialized)
  return table.concat({
    "You are summarizing a coding-agent session so work can continue in a fresh context.",
    "",
    "Write the summary with these sections:",
    "",
    "Goal: what the user asked for.",
    "Progress: what was done so far and with what outcome.",
    "Next Steps: what remains, in order.",
    "",
    "Critical Context:",
    serialized,
  }, "\n")
end

--- Compact the session: summarize the conversation before the cut point and
--- append the compaction entry. Best-effort: a failed or empty summary call
--- appends nothing and the loop continues with the oversized context.
--- @param session table -- the neopi.session handle (append/history)
--- @param model string -- the model id for the summarization request
--- @param keepRecentTokens number -- the token budget the kept region must reach
--- @param contextTokens number -- the estimated context size before compaction
--- @return boolean -- whether a compaction entry was appended
local function compact(session, model, keepRecentTokens, contextTokens)
  local entries = session:history()
  local cut = findCutPoint(entries, keepRecentTokens)
  if not cut then
    return false
  end
  local summarized = {}
  for _, e in ipairs(entries) do
    if e.id and e.id < cut then
      summarized[#summarized + 1] = e
    end
  end
  local serialized = serializeConversation(summarized)
  if serialized == "" then
    return false
  end
  local ok, response = pcall(neopi.provider.generate, {
    model = model,
    messages = {{role = "user", text = summaryPrompt(serialized)}},
  })
  if not ok then
    return false
  end
  local summary = response.text or ""
  if summary == "" then
    return false
  end
  session:append("compaction", {
    summary = summary,
    firstKeptId = cut,
    tokensBefore = contextTokens,
  })
  return true
end

--- Execute one tool call with the runtime tools and the registered tools,
--- returning the output and the error flag. The lookup checks the runtime
--- toolset first and falls back to neopi.registeredTools() (the registry's
--- entries, whose execute is a Lua function called directly); the fallback
--- is skipped when the runtime entry is not loaded (no registeredTools in
--- the state). Every execution fires the tool_call hook before it and the
--- tool_result hook after it through neopi.emit (the mappedTools pattern,
--- applied uniformly to the runtime and the registered tools): a block
--- keeps the tool from running (the reason is the failed result), a patched
--- payload's args replace the model's arguments, and a patched tool_result
--- payload's output rewrites the output the model sees. A tool or hook
--- error becomes a failed tool result for the model (the core's tool
--- protocol), never a loop abort.
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
    local registered = {}
    if type(neopi.registeredTools) == "function" then
      registered = neopi.registeredTools()
    end
    for _, t in ipairs(registered) do
      if t.name == name then
        tool = t
        break
      end
    end
  end
  if not tool then
    return "unknown tool: " .. tostring(name), true
  end
  local effective = args
  local ok, verdict = pcall(neopi.emit, "tool_call", {tool = name, args = args})
  if not ok then
    return "hook error: " .. tostring(verdict), true
  end
  if not verdict.allowed then
    if verdict.reason and verdict.reason ~= "" then
      return verdict.reason, true
    end
    return "tool blocked", true
  end
  if verdict.patched and type(verdict.payload) == "table" and
      verdict.payload.args ~= nil then
    effective = verdict.payload.args
  end
  local ran, result = pcall(tool.execute, effective)
  if not ran then
    return tostring(result), true
  end
  local output = tostring(result)
  local sent, outcome = pcall(neopi.emit, "tool_result",
    {tool = name, output = output})
  if sent and type(outcome) == "table" and outcome.patched and
      type(outcome.payload) == "table" and outcome.payload.output ~= nil then
    output = tostring(outcome.payload.output)
  end
  return output, false
end

--- Run the agent loop: build the request from the session history and the
--- runtime tools, call the provider one model turn at a time, append the
--- assistant entry, execute tool calls while the model requests them, and
--- record every entry in the session. After each turn's tool results and
--- before the next request (pi's prepareNextTurn point), the compaction
--- trigger checks the context size: when it exceeds
--- contextWindow - reserveTokens, the conversation before the cut point is
--- summarized into a compaction entry (at most once per check).
--- @param session table -- the neopi.session handle (append/history/navigate)
--- @param config table -- {model = string, system = string?, maxSteps = number?,
---   contextWindow = number?, reserveTokens = number?, keepRecentTokens = number?}
--- @return table -- the final response
---   {text, stopReason, usage = {input, output}, toolCalls, provider}
function agent.run(session, config)
  local maxSteps = config.maxSteps or 8
  local contextWindow = config.contextWindow or 128000
  local reserveTokens = config.reserveTokens or 16384
  local keepRecentTokens = config.keepRecentTokens or 20000
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
    -- The compaction trigger (pi's prepareNextTurn point): the last
    -- response's usage.input approximates the context size. At most one
    -- compaction per check; the next turn rebuilds from the projection.
    local contextTokens = (response.usage and response.usage.input) or 0
    if contextTokens > contextWindow - reserveTokens then
      compact(session, config.model, keepRecentTokens, contextTokens)
    end
  end
  -- The loop hit its step cap with the model still asking for tools; the
  -- core's own loop spells this frStepLimit.
  response.stopReason = "stepLimit"
  return response
end

return agent
