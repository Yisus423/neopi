--- pi's `examples/extensions/todo.ts`, reduced to the half ROADMAP #19b made
--- possible: a tool that REMEMBERS.
---
--- pi's pattern, from its examples' README:
---
---   // Write: the tool returns its state beside its output
---   return { content: [{type = "text", text = "Done"}],
---            details = { todos = todos, nextId = nextId } };
---   // Read: reconstruct it from the branch, because the ENTRY carries it
---   pi.on("session_start", async (_event, ctx) => {
---     for (const entry of ctx.sessionManager.getBranch()) {
---       if (entry.type === "message" && entry.message.toolName === "my_tool")
---         const details = entry.message.details;      // ← the state comes back
---   });
---
--- The port:
---   * WRITE — the tool returns a second value, which Lua has always allowed:
---     `return output, {notes = notes}` keeps every tool that returns one value
---     working, so this costs nothing to the ones that came before.
---   * READ — `neopi.session:history()` IS the branch (pi's `getBranch()`), and
---     it is readable ON DEMAND. That is the one place this port is simpler
---     than its original: pi needs a `session_start` hook because it keeps the
---     state in memory, while here the state IS the session and reading it can
---     happen whenever a tool needs it.
--- @module examples.state

--- The notes the session already recorded, oldest first: the last `remember`
--- call's details ARE the state, which is what makes a fork work — a fork
--- copies entries, so it copies the state with them.
local function remembered()
  local notes = {}
  for _, entry in ipairs(neopi.session:history()) do
    if entry.type == "toolResult" and entry.toolName == "remember" and
        type(entry.details) == "table" and type(entry.details.notes) == "table" then
      notes = entry.details.notes
    end
  end
  return notes
end

neopi.registerTool("remember", "Add a note to the list this session keeps", {
  type = "object",
  properties = {
    note = {type = "string", description = "The note to remember"},
  },
  required = {"note"},
}, function(args)
  local notes = remembered()
  notes[#notes + 1] = tostring(args.note)
  -- The output the model reads, and the state the NEXT turn will read back.
  return "remembered: " .. tostring(#notes) .. " note(s)\n",
    {notes = notes}
end)

neopi.registerCommand("remembered", "list what this session remembers",
  function(_)
    local notes = remembered()
    if #notes == 0 then
      return "nothing remembered yet"
    end
    return table.concat(notes, "\n")
  end)
