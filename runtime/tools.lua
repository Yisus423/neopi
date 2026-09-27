--- The runtime agent tools: bash, read, edit, and write over the confined
--- neopi.fs and neopi.process primitives. These are the agent's tools: read
--- returns the raw content, write writes it, edit does exact-text
--- replacement with the same error contracts as the Nim agent tools, and
--- bash runs a command and returns its output. Every tool takes the model's
--- args table as its single argument (the shape the provider protocol and
--- the agent loop hand over); errors raise Lua errors, which the agent loop
--- records as failed tool results for the model instead of aborting.
--- @module runtime.tools

local tools = {}

--- Read a file's content (raw, no line numbers, no truncation).
--- @param args table -- {path = string}
--- @return string -- the file content
function tools.read(args)
  return neopi.fs.read(args.path)
end

--- Write content to a file (plain write: parent directories are not
--- created).
--- @param args table -- {path = string, content = string}
--- @return string -- the success note
function tools.write(args)
  local dir = args.path:match("^(.*)/")
  if dir then
    neopi.fs.mkdir(dir)
  end
  neopi.fs.write(args.path, args.content)
  return "Successfully wrote to " .. args.path
end

--- Edit a single file using exact text replacement. oldText must match a
--- unique, non-overlapping region of the file: 0 matches is not found, more
--- than 1 is ambiguous, and identical text makes no change. Exact match
--- only: no fuzzy matching and no CRLF normalization.
--- @param args table -- {path = string, oldText = string, newText = string}
--- @return string -- the success note
function tools.edit(args)
  local path = args.path
  if args.oldText == "" or args.oldText == nil then
    error("oldText must not be empty in " .. tostring(path), 0)
  end
  local content = neopi.fs.read(path)
  local matches = 0
  local from = 1
  while true do
    local at = string.find(content, args.oldText, from, true)
    if not at then break end
    matches = matches + 1
    from = at + #args.oldText
  end
  if matches == 0 then
    error("oldText not found in " .. tostring(path), 0)
  end
  if matches > 1 then
    error("oldText matches " .. matches .. " times in " .. tostring(path) ..
      " — provide more context to make it unique", 0)
  end
  if args.oldText == args.newText then
    error("no changes made to " .. tostring(path), 0)
  end
  local at = string.find(content, args.oldText, 1, true)
  local updated = string.sub(content, 1, at - 1) .. args.newText ..
    string.sub(content, at + #args.oldText)
  neopi.fs.write(path, updated)
  return "Edited " .. tostring(path) .. ": 1 replacement"
end

--- Execute a bash command in the workspace root.
--- @param args table -- {command = string}
--- @return string -- stdout and stderr; a non-zero exit code is appended
function tools.bash(args)
  local outcome = neopi.process.run(args.command)
  local output = outcome.output
  if outcome.code ~= 0 then
    if #output > 0 and string.sub(output, -1) ~= "\n" then
      output = output .. "\n"
    end
    output = output .. "[exit code: " .. tostring(outcome.code) .. "]"
  end
  return output
end

--- Build one model-facing tool definition: the JSON schema (what the model
--- sees) wrapped in the object shape neopi.provider.generate expects.
--- @param properties table -- the properties table of the schema
--- @param required string[] -- the required property names
--- @return table -- {type = "object", properties = ..., required = ...}
local function schema(properties, required)
  return {type = "object", properties = properties, required = required}
end

--- The runtime's agent tools, in the order the model sees them. Each entry
--- is {name, description, schema, execute} — the config.tools shape — and
--- execute receives the model's args table.
--- @return table[] -- array of {name, description, schema, execute}
function tools.agentTools()
  return {
    {name = "read",
     description = "Read file contents. Returns the raw file content " ..
       "(no truncation, no line numbers).",
     schema = schema(
       {path = {type = "string",
         description = "Path to the file to read (relative or absolute)"}},
       {"path"}),
     execute = tools.read},
    {name = "write",
     description = "Write content to a file. Creates the file if it doesn't " ..
       "exist, overwrites if it does. Parent directories are not created.",
     schema = schema(
       {path = {type = "string",
         description = "Path to the file to write (relative or absolute)"},
        content = {type = "string",
         description = "Content to write to the file"}},
       {"path", "content"}),
     execute = tools.write},
    {name = "edit",
     description = "Edit a single file using exact text replacement. oldText " ..
       "must match a unique, non-overlapping region of the file.",
     schema = schema(
       {path = {type = "string",
         description = "Path to the file to edit (relative or absolute)"},
        oldText = {type = "string", description = "Exact text to replace"},
        newText = {type = "string", description = "Replacement text"}},
       {"path", "oldText", "newText"}),
     execute = tools.edit},
    {name = "bash",
     description = "Execute a bash command in the workspace root. Returns " ..
       "stdout and stderr; a non-zero exit code is appended to the output.",
     schema = schema(
       {command = {type = "string",
         description = "The bash command to execute"}},
       {"command"}),
     execute = tools.bash},
  }
end

return tools
