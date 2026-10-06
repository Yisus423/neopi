--- The agent.runTurn specs: one turn per call — the loop body extracted so
--- the TUI can drive turns and keep the keys alive between them. agent.run
--- stays the headless driver over runTurn (the same contract as ever).
--- @module spec.run_turn

describe("agent.runTurn", function()
  it("one turn per call: the toolUse response runs its tools and continues", function()
    -- The scripted provider: the first request answers with a write tool
    -- call, the second with the final text. Two runTurn calls drive the
    -- same session the loop would.
    neopi.provider.setScripted({
      {
        toolCalls = {
          {id = "call-1", name = "write", args = {path = "notes/turn.txt", content = "one"}},
        },
      },
      {text = "second turn"},
    })

    local session = neopi.session
    local agent = require("agent")
    session:append("user", {text = "go"})

    -- The first turn: the toolUse response — the tool executes inside the
    -- turn and the response asks for another one.
    local response = agent.runTurn(session, {model = "scripted"})
    assert.are.equal(true, response.continueLoop)
    assert.are.equal("one", neopi.fs.read("notes/turn.txt"))

    -- The turn's own entries: assistant (toolUse) then its toolResult. The
    -- busted specs share one live session, so the check is tail-based.
    local history = session:history()
    local n = #history
    assert.are.equal("toolResult", history[n].type)
    assert.are.equal("call-1", history[n].toolCallId)
    assert.are.equal("assistant", history[n - 1].type)

    -- The second turn: the final text — the drive stops (no tools ran).
    local second = agent.runTurn(session, {model = "scripted"})
    assert.are.equal(false, second.continueLoop)
    assert.are.equal("second turn", second.text)
    assert.are.equal("stop", second.stopReason)
  end)

  it("the steering drains after the turn's assistant entry and continues", function()
    -- The steering queued before the turn enters after the assistant
    -- append (pi's model) and asks for another turn — continueLoop true
    -- even though the response itself stopped.
    neopi.provider.setScripted({
      {text = "first answer"},
      {text = "steered answer"},
    })

    local session = neopi.session
    local agent = require("agent")
    neopi.steeringQueue = {"steered msg"}
    session:append("user", {text = "go"})
    local response = agent.runTurn(session, {model = "scripted"})

    assert.are.equal(true, response.continueLoop)

    -- The steering user entry right after the assistant entry.
    local history = session:history()
    local n = #history
    assert.are.equal("user", history[n].type)
    assert.are.equal("steered msg", history[n].text)
    assert.are.equal("assistant", history[n - 1].type)
    assert.are.equal("first answer", history[n - 1].text)

    -- The next turn consumes the steering prompt and stops.
    local second = agent.runTurn(session, {model = "scripted"})
    assert.are.equal(false, second.continueLoop)
    assert.are.equal("steered answer", second.text)

    -- Cleanup so the queue does not leak into the other specs.
    assert.are.equal(0, #neopi.steeringQueue)
    neopi.steeringQueue = nil
  end)

  it("agent.run keeps its contract: the headless loop with the step cap", function()
    -- The driver runs one turn at a time until the model stops; the
    -- scripted provider keeps asking for tools until the cap.
    neopi.provider.setScripted({
      {toolCalls = {{id = "c1", name = "echo", args = {text = "x"}}}},
      {toolCalls = {{id = "c2", name = "echo", args = {text = "x"}}}},
    })

    local session = neopi.session
    local agent = require("agent")
    session:append("user", {text = "go"})
    local response = agent.run(session, {model = "scripted", maxSteps = 2})

    assert.are.equal("stepLimit", response.stopReason)
  end)
end)
