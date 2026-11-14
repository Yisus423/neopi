--- E4 of ROADMAP #19's audit: the ports of pi's examples that turned out to
--- MAP, and the two that are a WALL. A wall is pinned here on purpose — the
--- spec that asserts the absence is what makes the gap visible the day somebody
--- fills it, because that is the day this file has to be edited.
--- @module spec.hook_bus

describe("pi's hook-shaped examples, ported", function()
  it("event-bus: a FREE event name is already an inter-extension bus", function()
    -- pi's examples/extensions/event-bus.ts uses `pi.events` to talk between
    -- extensions. neopi's `on` takes ANY event name and `emit` fires it, so
    -- the bus needs no new surface at all.
    local heard = nil
    neopi.on("audit-bus", function(payload)
      heard = payload.value
    end)
    local out = neopi.emit("audit-bus", {value = "from the extension"})
    assert.are.equal("from the extension", heard)
    assert.is_true(out.allowed)
    assert.is_false(out.patched)
  end)

  it("event-bus: a handler REWRITES by returning a table, and the bus says so", function()
    -- The verdict is neopi's own: pi's event bus publishes, neopi's also
    -- PATCHES (and can block). That is more than the original offers, which is
    -- worth saying out loud in an audit that otherwise only finds shortfalls.
    neopi.on("audit-rewrite", function(payload)
      return {value = payload.value .. " (rewritten)"}
    end)
    local out = neopi.emit("audit-rewrite", {value = "original"})
    assert.is_true(out.patched)
    assert.are.equal("original (rewritten)", out.payload.value)
  end)

  it("permission-gate: a handler BLOCKS with a reason — decided at once", function()
    -- The half of the gate that DOES port: the decision and the reason. What
    -- cannot port is ASKING first — the answer arrives in a callback, after
    -- the verdict has already been returned (see the async item in the
    -- ROADMAP, and `yield_boundaries_spec.lua` for what a suspension would
    -- need).
    neopi.on("audit-block", function(_payload)
      return false, "rm -rf is not allowed here"
    end)
    local out = neopi.emit("audit-block", {toolName = "bash"})
    assert.is_false(out.allowed)
    assert.are.equal("rm -rf is not allowed here", out.reason)
  end)

  it("input-transform: a handler rewrites the prompt by returning a table", function()
    -- pi's inline-bash.ts expands `!{command}` in the prompt through the
    -- `input` event. The MECHANISM ports exactly: a handler returns the
    -- rewritten payload and the bus reports it as patched.
    neopi.on("input", function(payload)
      return {text = payload.text:gsub("!%{([^}]+)%}", "%1")}
    end)
    local out = neopi.emit("input", {text = "please run !{ls -la}"})
    assert.is_true(out.patched)
    assert.are.equal("please run ls -la", out.payload.text)
  end)

  it("WALL: a tool's result has nowhere to carry `details`", function()
    -- The biggest gap of the audit. pi's execute returns
    -- `{content, details}` and `details` rides the session entry, which is how
    -- todo.ts and tic-tac-toe.ts keep state across a turn and a fork. Here the
    -- tool returns the TEXT and the registry has no field for anything else.
    neopi.registerTool("audit-details", "a tool with state to keep",
      {type = "object"}, function(_args)
        return "the output text — and that is all the session ever sees"
      end)
    local tool
    for _, candidate in ipairs(neopi.registeredTools()) do
      if candidate.name == "audit-details" then tool = candidate end
    end
    assert.is_not_nil(tool)
    assert.are.equal("string", type(tool.execute({})))
    assert.is_nil(tool.details)
  end)

  it("WALL: a session cannot be named or labelled", function()
    -- pi: setSessionName and setLabel (session-name.ts, bookmark.ts), so the
    -- session picker and /tree can name what they show. neopi's surface has
    -- neither, and `/resume` lists a session by its file and its first text.
    assert.is_nil(neopi.setSessionName)
    assert.is_nil(neopi.session.setName)
    assert.is_nil(neopi.session.setLabel)
  end)
end)
