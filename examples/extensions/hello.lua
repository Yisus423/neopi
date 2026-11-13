--- pi's `examples/extensions/hello.ts`, carried onto neopi — the minimum a tool
--- needs. The original:
---
---   pi.registerTool({
---     name: "hello",
---     label: "Greeting",
---     description: "Greet someone by name",
---     parameters: Type.Object({ name: Type.String() }),
---     async execute(toolCallId, params, signal, onUpdate, ctx) {
---       return { content: [{ type: "text", text: `Hello, ${params.name}!` }] };
---     },
---   });
---
--- and the port, which is what the surface actually asks for:
---
---   neopi.registerTool(name, description, schema, function(args) -> string end)
---
--- THE SHAPES THAT CHANGE (the audit's finding, ROADMAP #19): the options
--- object becomes four positional arguments, and the RESULT OBJECT becomes the
--- plain string the model reads. That second one is a loss: pi's `details`
--- travels with the call and is persisted in the session, which is how pi's own
--- tools keep state across a turn and a fork. neopi keeps the text only.
---
--- Load it from `.neopi/init.lua` with `require("hello")`.
--- @module examples.hello

neopi.registerTool("hello", "Greet someone by name", {
  type = "object",
  properties = {
    name = {type = "string", description = "Name to greet"},
  },
  required = {"name"},
}, function(args)
  return "Hello, " .. tostring(args.name) .. "!"
end)
