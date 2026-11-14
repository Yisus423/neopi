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
