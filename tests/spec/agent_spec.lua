--- The first busted spec for neopi: the agent loop runs a scripted-model
--- session end-to-end in-process (no network). The spec runs inside the
--- neopi binary's live Lua state with the core exposed: neopi.provider,
--- neopi.session, neopi.fs, and the runtime loaded.
--- @module spec.agent

describe("agent loop", function()
  it("runs a scripted session end-to-end: tool call, tool result, final text", function()
    -- The scripted provider: the first request answers with a write tool
    -- call, the second with the final text.
    neopi.provider.setScripted({
      {
        toolCalls = {
          {id = "call-1", name = "write", args = {path = "notes/hello.txt", content = "hi"}},
        },
      },
      {text = "done"},
    })

    local session = neopi.session
    local agent = require("agent")
    session:append("user", {text = "go"})
    local response = agent.run(session, {model = "scripted", maxSteps = 4})

    -- The loop returned the final response.
    assert.are.equal("done", response.text)
    assert.are.equal("stop", response.stopReason)

    -- The write tool ran through the confined primitives and the parent
    -- directory was created.
    assert.are.equal("hi", neopi.fs.read("notes/hello.txt"))

    -- The session recorded every entry: user, assistant (toolUse),
    -- toolResult, assistant (final text).
    local history = session:history()
    local expected = {"user", "assistant", "toolResult", "assistant"}
    assert.are.equal(#expected, #history)
    for i, kind in ipairs(expected) do
      assert.are.equal(kind, history[i].type)
    end
    assert.are.equal("call-1", history[3].toolCallId)
    assert.are.equal("write", history[3].toolName)
    assert.are.equal("Successfully wrote to notes/hello.txt", history[3].output)
  end)

  it("the loop honors maxSteps and reports the step cap", function()
    neopi.provider.setScripted({
      {toolCalls = {{id = "c1", name = "echo", args = {text = "x"}}}},
      {toolCalls = {{id = "c2", name = "echo", args = {text = "x"}}}},
      {toolCalls = {{id = "c3", name = "echo", args = {text = "x"}}}},
    })

    local session = neopi.session
    local agent = require("agent")
    session:append("user", {text = "go"})
    local response = agent.run(session, {model = "scripted", maxSteps = 2})

    -- The loop hit its step cap while the model still asked for tools.
    assert.are.equal("stepLimit", response.stopReason)
  end)

  it("the steering queue enters after the current assistant turn", function()
    -- The steering queue (pi's model): the messages typed during the run
    -- enter after the current assistant turn and ask for another turn.
    neopi.provider.setScripted({
      {text = "first answer"},
      {text = "steered answer"},
    })

    local session = neopi.session
    local agent = require("agent")
    neopi.steeringQueue = {"check the file"}
    session:append("user", {text = "go"})
    local response = agent.run(session, {model = "scripted", maxSteps = 4})

    -- The first answer landed; the steering message entered after it and
    -- asked for another turn, which produced the steered answer.
    assert.are.equal("steered answer", response.text)

    -- The session recorded the steering user entry between the answers.
    -- The busted specs share one live session, so the check is tail-based:
    -- the last four entries are this test's.
    local history = session:history()
    local n = #history
    assert.are.equal("assistant", history[n].type)
    assert.are.equal("steered answer", history[n].text)
    assert.are.equal("user", history[n - 1].type)
    assert.are.equal("check the file", history[n - 1].text)
    assert.are.equal("assistant", history[n - 2].type)
    assert.are.equal("first answer", history[n - 2].text)
    assert.are.equal("user", history[n - 3].type)

    -- The queue is empty after the run (drained each turn); cleanup so the
    -- queue does not leak into the other specs.
    assert.are.equal(0, #neopi.steeringQueue)
    neopi.steeringQueue = nil
  end)

  it("compaction on demand refuses without a model", function()
    -- The model is the caller's: the command's interface owns which one
    -- summarizes, so a missing one is a mistake worth hearing about.
    local agent = require("agent")
    assert.has_error(function()
      agent.compactNow(neopi.session, {})
    end)
  end)

  it("compaction on demand reports why it did nothing", function()
    -- A budget no branch can reach, so the answer is deterministic whatever
    -- the specs before this one left in the shared session: the walk finds no
    -- cut point and the command says so instead of inventing a compaction.
    -- (This test appends one small entry and compacts nothing.)
    neopi.provider.setScripted({{text = "the summary"}})
    local session = neopi.session
    local agent = require("agent")
    session:append("user", {text = "tiny"})

    local result = agent.compactNow(session,
      {model = "scripted", keepRecentTokens = 10000000})

    assert.is_false(result.ok)
    assert.are.equal("nothingToCompact", result.reason)
    -- Nothing landed: a refusal is not an entry.
    local history = session:history()
    assert.are_not.equal("compaction", history[#history].type)
  end)

  -- This one MUTATES the shared session (it appends a compaction entry, which
  -- the projection then honors for every spec after this file), so it stays
  -- last in the file.
  it("compaction on demand summarizes what sits before the cut point", function()
    -- The `/compact` path: the policy the trigger runs, callable directly.
    -- The cut point comes from the same walk (backwards, accumulating the
    -- entries' estimates) that the loop's trigger uses.
    neopi.provider.setScripted({{text = "the summary"}})
    local session = neopi.session
    local agent = require("agent")
    session:append("user", {text = "an earlier turn"})
    session:append("assistant", {text = "an answer", model = "scripted",
      provider = "scripted", usageInput = 30000, usageOutput = 5,
      stopReason = "stop"})

    local result = agent.compactNow(session,
      {model = "scripted", keepRecentTokens = 20000})

    assert.is_true(result.ok)
    assert.is_true(result.summarized >= 1)
    local history = session:history()
    local last = history[#history]
    -- The compaction entry landed last, carrying the summary and the cut: the
    -- entry the walk stopped on, which the projection keeps from here on.
    assert.are.equal("compaction", last.type)
    assert.are.equal("the summary", last.summary)
    assert.are.equal(history[#history - 1].id, last.firstKeptId)
    assert.are.equal(result.firstKeptId, last.firstKeptId)
  end)
end)
