--- The neopi runtime entry: assembles the runtime pieces and returns the
--- agent table. The Nim binary loads this file after extending package.path
--- with the runtime directory, so the runtime modules resolve through it;
--- callers either capture this return value or require the modules through
--- package.loaded.
--- @module runtime.init

local agent = require("agent")

return agent
