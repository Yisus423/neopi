--- D4 of ROADMAP #19b: a tool's `details` — pi's state persistence — reach the
--- session ENTRY and come back off the branch, which is what lets a tool
--- remember things between turns (and survive a fork, because the entry travels
--- with the branch and not with the tool's memory).
---
--- The READ side is `neopi.session:history()`, pi's `getBranch()` equivalent —
--- no new reader was needed for this slice, and that is worth pinning too.
--- @module spec.tool_details

describe("a tool result's details", function()
  it("round-trip through the session and come back on the history", function()
    neopi.session:append("toolResult", {
      toolCallId = "c-details",
      toolName = "audit-todo",
      output = "added: write the spec\n",
      isError = false,
      details = {todos = {"write the spec"}, nextId = 2},
    })

    local found
    for _, entry in ipairs(neopi.session:history()) do
      if entry.type == "toolResult" and entry.toolCallId == "c-details" then
        found = entry
      end
    end
    assert.is_not_nil(found)
    assert.are.equal("write the spec", found.details.todos[1])
    assert.are.equal(2, found.details.nextId)
  end)

  it("the example LOADS and reads its own state back", function()
    -- The example is executable documentation, so it is executed: the tool
    -- writes, the ENTRY carries the state, and the command reads it back off
    -- the branch. The two appends are what the runtime's loop does with the
    -- tool's second return value (the spec drives them directly because a real
    -- turn needs a provider).
    dofile("examples/extensions/state.lua")

    local remember
    for _, tool in ipairs(neopi.registeredTools()) do
      if tool.name == "remember" then remember = tool end
    end
    assert.is_not_nil(remember)

    assert.are.equal("nothing remembered yet",
      neopi.runCommand("/remembered"))

    local out1, details1 = remember.execute({note = "first"})
    assert.is_truthy(out1:find("1 note"))
    neopi.session:append("toolResult", {toolCallId = "c-first",
      toolName = "remember", output = out1, isError = false,
      details = details1})

    -- The SECOND call reads the state the first one left behind: that is the
    -- whole point of the field.
    local out2, details2 = remember.execute({note = "second"})
    assert.is_truthy(out2:find("2 note"))
    neopi.session:append("toolResult", {toolCallId = "c-second",
      toolName = "remember", output = out2, isError = false,
      details = details2})

    assert.are.equal("first\nsecond", neopi.runCommand("/remembered"))
  end)

  it("an absent state reads as an EMPTY object, never nil", function()
    -- The same discipline `toolArgs` earned: the node is handed around, and a
    -- nil one is a crash waiting for its first reader (the transcript today,
    -- an extension's reconstruction tomorrow).
    neopi.session:append("toolResult", {
      toolCallId = "c-nodetails",
      toolName = "bash",
      output = "hi\n",
      isError = false,
    })

    local found
    for _, entry in ipairs(neopi.session:history()) do
      if entry.type == "toolResult" and entry.toolCallId == "c-nodetails" then
        found = entry
      end
    end
    assert.is_not_nil(found)
    assert.is_not_nil(found.details)
    assert.are.equal(0, #found.details)
  end)
end)
