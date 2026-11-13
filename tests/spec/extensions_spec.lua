--- The busted spec for ROADMAP #19's first ports: pi's `hello`, `status-line`,
--- `widget-placement` and `commands` carried onto neopi's surface. This is the
--- AUDIT made executable — every `it` names the pi example it comes from, and
--- where a port had to change SHAPE the comment says so, because the shape
--- difference IS the finding.
---
--- It registers by NAME and never counts: the specs share one Lua state, so a
--- count would be an assertion about the neighbours.
--- @module spec.extensions

describe("porting pi's examples (the surface audit)", function()
  it("hello: a tool registers and the registry hands it back", function()
    -- pi (examples/extensions/hello.ts):
    --   pi.registerTool({name, label, description, parameters,
    --     execute(toolCallId, params, signal, onUpdate, ctx) -> {content, details}})
    -- neopi:
    --   neopi.registerTool(name, description, schema, function(args) -> string end)
    -- The port is a re-spelling of the SAME four things; what it loses is the
    -- `label` (the TUI's row name) and the result's `details` (gap 1).
    neopi.registerTool("hello", "Greet someone by name", {
      type = "object",
      properties = {
        name = {type = "string", description = "Name to greet"},
      },
      required = {"name"},
    }, function(args)
      return "Hello, " .. tostring(args.name) .. "!"
    end)

    local found
    for _, tool in ipairs(neopi.registeredTools()) do
      if tool.name == "hello" then found = tool end
    end
    assert.is_not_nil(found)
    assert.are.equal("Greet someone by name", found.description)
    assert.are.equal("object", found.schema.type)
    assert.are.equal("Hello, neopi!", found.execute({name = "neopi"}))
  end)

  it("status-line: a keyed row, and clearing is the missing text", function()
    -- pi: ctx.ui.setStatus("turn", text, {colour = "accent"}). neopi takes the
    -- key and the line; the COLOUR is what the port cannot say (gap 6).
    assert.are.equal(nil, neopi.ui.status("turn", "working"))
    assert.are.equal(nil, neopi.ui.status("turn", nil))
    assert.has_error(function() neopi.ui.status(123) end)
  end)

  it("widget-placement: the same two placements pi has", function()
    -- pi: ctx.ui.setWidget(id, lines, {placement: "aboveEditor" | "belowEditor"}).
    -- neopi spells the same two, and refuses an unknown one instead of falling
    -- back (ui_spec pins that too).
    assert.are.equal(nil,
      neopi.ui.widget("audit-above", {"above"}, {placement = "aboveEditor"}))
    assert.are.equal(nil,
      neopi.ui.widget("audit-below", {"below"}, {placement = "belowEditor"}))
    -- nil clears, the same shape every slot uses.
    assert.are.equal(nil, neopi.ui.widget("audit-above", nil))
    assert.has_error(function()
      neopi.ui.widget("audit-above", "a", {placement = "sideways"})
    end)
  end)

  it("commands: a /command registers and the dispatcher runs it", function()
    -- pi: pi.registerCommand(name, {description, handler(args, ctx)}). neopi
    -- takes the description and the function positionally: a port is a
    -- re-spelling, not a rewrite.
    neopi.registerCommand("audit-greet", "say hello", function(args)
      return "hello " .. (args ~= "" and args or "world")
    end)
    assert.are.equal("hello neopi", neopi.runCommand("/audit-greet neopi"))
    assert.are.equal("hello world", neopi.runCommand("/audit-greet"))

    local found
    for _, command in ipairs(neopi.registeredCommands()) do
      if command.name == "audit-greet" then found = command end
    end
    assert.is_not_nil(found)
    assert.are.equal("say hello", found.description)
  end)
end)
