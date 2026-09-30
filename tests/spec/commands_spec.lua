--- The busted spec for the agent commands: the runtime-owned registry and
--- the / dispatcher. The spec runs inside the busted runner's live Lua
--- state with the runtime loaded (busted_main's setup).
--- @module spec.commands

describe("agent commands", function()
  it("registers a command and runs it with the args", function()
    neopi.registerCommand("echo", "echo the args", function(args)
      return "echoed: " .. args
    end)

    -- The registry holds the command.
    local registered = neopi.registeredCommands()
    assert.are.equal(1, #registered)
    assert.are.equal("echo", registered[1].name)
    assert.are.equal("echo the args", registered[1].description)

    -- The dispatcher runs it with the rest of the input.
    assert.are.equal("echoed: hi there", neopi.runCommand("/echo hi there"))
  end)

  it("rejects the invalid registrations and the bad inputs", function()
    assert.has_error(function() neopi.registerCommand(123, "d", function() end) end)
    assert.has_error(function() neopi.registerCommand("n", "d", "not a function") end)
    assert.has_error(function() neopi.runCommand("no slash") end)
    assert.has_error(function() neopi.runCommand("/nosuch") end)
  end)

  it("hands the empty args when the command has none", function()
    neopi.registerCommand("ping", "return pong", function(args)
      return "args: [" .. args .. "]"
    end)
    assert.are.equal("args: []", neopi.runCommand("/ping"))
  end)
end)
