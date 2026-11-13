--- pi's `examples/extensions/status-line.ts`, carried onto neopi: a turn's
--- progress in the status bar. The original:
---
---   ctx.ui.setStatus("turn", ` ${progress}`, { colour: "accent" });
---
--- and the port:
---
---   neopi.ui.status("turn", " " .. progress)
---
--- THE SHAPE THAT CHANGES (the audit's finding): pi's status takes a themed
--- COLOUR, and neopi's is one line the chrome paints. On a mono terminal that
--- is nothing; with a palette it is the difference between a hint and a shout.
---
--- CLEARING is the same everywhere in neopi: the missing (or nil) text. A status
--- an extension forgets is a row that outlives its turn.
---
--- The original hooks the turn's lifecycle. neopi's events are reached through
--- `neopi.on`, which the runtime does not use yet — read that surface before
--- wiring this to a real turn (the next thing the audit has to look at).
--- @module examples.status_line

-- A command proves the slot without an event to hang it on.
neopi.registerCommand("audit-status", "show a status row, then clear it",
  function(_)
    neopi.ui.status("turn", "the status slot works")
    neopi.ui.status("turn", nil)
    return "status set and cleared"
  end)
