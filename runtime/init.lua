--- The neopi runtime entry: assembles the runtime pieces and returns the
--- agent table. The Nim binary loads this file after extending package.path
--- with the runtime directory, so the runtime modules resolve through it;
--- callers either capture this return value or require the modules through
--- package.loaded.
--- @module runtime.init

local agent = require("agent")

-- The registered tools: the runtime-owned registry (the nvim model — the
-- runtime owns the registry, the core only reads it). Extensions register
-- entries with neopi.registerTool; the core reads them through
-- neopi.registeredTools() when the generate merges the tool list.
local registry = {}

--- Register a tool the model can call: validates the four arguments (name
--- and description strings, a JSON schema table, an execute function) and
--- appends {name, description, schema, execute} to the runtime-owned
--- registry. A clear Lua error otherwise. Returns nothing.
--- @param name string -- the tool name the model calls
--- @param description string -- the tool description the model sees
--- @param schema table -- the JSON schema of the tool's arguments
--- @param execute fun(args: table): string -- the tool body; returns the output
function neopi.registerTool(name, description, schema, execute)
  if type(name) ~= "string" or type(description) ~= "string" or
      type(schema) ~= "table" or type(execute) ~= "function" then
    error("neopi.registerTool expects (name: string, description: string, " ..
      "schema: table, execute: function)", 0)
  end
  registry[#registry + 1] = {
    name = name,
    description = description,
    schema = schema,
    execute = execute,
  }
end

--- The registered tools, in registration order. The live registry table:
--- the core reads it, and a mutated view changes what the next generate
--- merges.
--- @return table[] -- array of {name = string, description = string,
---   schema = table, execute = function}
function neopi.registeredTools()
  return registry
end

--- The registered commands: the runtime-owned registry (the tools' model
--- — the runtime owns it, the core only runs it). Extensions register
--- entries with neopi.registerCommand; the user runs them with /name in
--- the composer, and the TUI dispatches through neopi.runCommand.
local commands = {}

--- Register a command the user can run with /name in the composer:
--- validates the three arguments (name and description strings, an execute
--- function) and appends {name, description, execute} to the runtime-owned
--- registry. A clear Lua error otherwise. Returns nothing.
--- @param name string -- the command name the user types after /
--- @param description string -- the command description the user sees
--- @param execute fun(args: string) -- the command body; the args are the
---   rest of the input after /name
function neopi.registerCommand(name, description, execute)
  if type(name) ~= "string" or type(description) ~= "string" or
      type(execute) ~= "function" then
    error("neopi.registerCommand expects (name: string, description: string, " ..
      "execute: function)", 0)
  end
  commands[#commands + 1] = {
    name = name,
    description = description,
    execute = execute,
  }
end

--- The registered commands, in registration order. The live registry table:
--- the core reads it, and a mutated view changes what the next /name runs.
--- @return table[] -- array of {name = string, description = string,
---   execute = function}
function neopi.registeredCommands()
  return commands
end

--- Run a command the user typed: parse the /-prefixed input (the name and
--- the rest), find the command in the registry, and call its execute with
--- the arguments string. Returns the command's output (or nil). A clear
--- Lua error for a non-command input or an unknown command.
--- @param input string -- the /-prefixed composer input
--- @return any -- the command's output
function neopi.runCommand(input)
  if type(input) ~= "string" then
    error("neopi.runCommand expects (input: string)", 0)
  end
  local name = input:match("^/(%S+)")
  if not name then
    error("commands start with /name", 0)
  end
  local args = input:match("^/%S+%s*(.*)$") or ""
  for _, cmd in ipairs(commands) do
    if cmd.name == name then
      return cmd.execute(args)
    end
  end
  error("unknown command /" .. name, 0)
end

return agent
