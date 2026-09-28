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

return agent
