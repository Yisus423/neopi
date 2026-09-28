--- The first real neopi extension: the notes extension registers save_note
--- (a tool that appends a line to NOTES.md through the confined neopi.fs —
--- the append semantics is the extension's policy) and a tool_call hook
--- that blocks a dangerous tool, and the end-to-end loop run proves the
--- registered tool the model calls and the hook's protection. The spec runs
--- inside the neopi binary's live Lua state with the core exposed
--- (neopi.provider, neopi.session, neopi.fs, and the runtime loaded); the
--- session is shared across the specs of one run, so its assertions are
--- relative to the tip.
--- @module spec.notes

describe("notes extension", function()
  it("registers save_note, appends a line end-to-end, and blocks danger", function()
    -- The extension: save_note appends a line to NOTES.md (read the
    -- existing content, append the line, write back).
    neopi.registerTool("save_note", "Append a note line to NOTES.md", {
      type = "object",
      properties = {
        text = {type = "string", description = "The note text to append"},
      },
      required = {"text"},
    }, function(args)
      local existing = ""
      local ok, current = pcall(neopi.fs.read, "NOTES.md")
      if ok then
        existing = current
      end
      neopi.fs.write("NOTES.md", existing .. args.text .. "\n")
      return "note saved: " .. args.text
    end)

    -- The danger tool registered too (with a marker execute): the hook must
    -- block it before the execute runs, so the marker never fires.
    neopi.registerTool("danger", "A dangerous tool", {
      type = "object",
      properties = {},
    }, function(args)
      dangerRan = true
      return "danger ran"
    end)

    -- The protection hook: a tool named "danger" is blocked with a reason.
    -- Handlers key on the payload: every registered handler fires for every
    -- emitted event (the current emit contract), so the hook checks
    -- payload.tool rather than assuming it only sees tool_call events.
    neopi.on("tool_call", function(payload)
      if payload.tool == "danger" then
        return false, "danger is blocked by the notes extension"
      end
    end)

    -- The scripted model: calls save_note and the danger tool, then answers.
    neopi.provider.setScripted({
      {
        toolCalls = {
          {id = "call-1", name = "save_note", args = {text = "hello from the model"}},
          {id = "call-2", name = "danger", args = {}},
        },
      },
      {text = "done"},
    })

    local session = neopi.session
    local agent = require("agent")
    local before = #session:history()
    session:append("user", {text = "go"})
    local response = agent.run(session, {model = "scripted", maxSteps = 4})

    -- The loop returned the final response.
    assert.are.equal("done", response.text)
    assert.are.equal("stop", response.stopReason)

    -- save_note ran through the registered tools: NOTES.md has the line.
    assert.are.equal("hello from the model\n", neopi.fs.read("NOTES.md"))

    -- The hook blocked the danger call: the marker never fired.
    assert.is_nil(dangerRan)

    -- The session recorded every entry of this run: user, assistant
    -- (toolUse), the two tool results (save_note ok, danger blocked), and
    -- the assistant's final text.
    local history = session:history()
    assert.are.equal(before + 5, #history)
    local start = #history - 4
    local expected = {"user", "assistant", "toolResult", "toolResult", "assistant"}
    for i, kind in ipairs(expected) do
      assert.are.equal(kind, history[start + i - 1].type)
    end
    assert.are.equal("save_note", history[start + 2].toolName)
    assert.are.equal("note saved: hello from the model", history[start + 2].output)
    assert.falsy(history[start + 2].isError)
    assert.are.equal("danger", history[start + 3].toolName)
    assert.are.equal("danger is blocked by the notes extension",
      history[start + 3].output)
    assert.truthy(history[start + 3].isError)
  end)

  it("exposes the outcome table: allowed, reason, patched, and payload", function()
    -- The emit API the loop uses: a handler's verdict comes back as a table
    -- with the outcome fields. false blocks with a reason, a table return
    -- patches the payload, and nil passes the event through unchanged.
    neopi.on("notes_probe", function(payload)
      if payload.block then
        return false, "probe blocked"
      end
      if payload.patch then
        return {payload = payload, extra = true}
      end
      return nil
    end)

    local blocked = neopi.emit("notes_probe", {block = true})
    assert.are.equal(false, blocked.allowed)
    assert.are.equal("probe blocked", blocked.reason)
    assert.are.equal(false, blocked.patched)
    assert.is_nil(blocked.payload)

    local patched = neopi.emit("notes_probe", {patch = true, value = 1})
    assert.are.equal(true, patched.allowed)
    assert.are.equal(true, patched.patched)
    assert.are.equal(1, patched.payload.payload.value)
    assert.are.equal(true, patched.payload.extra)

    local allowed = neopi.emit("notes_probe", {})
    assert.are.equal(true, allowed.allowed)
    assert.are.equal(false, allowed.patched)
  end)
end)
