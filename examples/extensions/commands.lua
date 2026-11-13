--- pi's `examples/extensions/commands.ts`, carried onto neopi: an extension adds
--- a `/command` and the composer's dispatcher runs it.
---
--- The original:
---
---   pi.registerCommand("hello", {
---     description: "Say hello",
---     handler: async (args, ctx) => { ctx.ui.notify("Hello!", "info"); },
---   });
---
--- and the port:
---
---   neopi.registerCommand("hello", "Say hello", function(args) ... end)
---
--- THE SHAPE THAT CHANGES (the audit's finding): the options object becomes the
--- same three things positionally, and the `ctx` is not passed — neopi's
--- extensions reach the slots through the globals (`neopi.ui`, `neopi.session`),
--- which means two extensions share that state instead of each carrying its own.
--- For this example it makes no difference; for a port that keeps per-extension
--- state it is the thing to watch.
---
--- The args are pi's too: the rest of the input after `/name`, empty when there
--- is none.
--- @module examples.commands

neopi.registerCommand("hello", "Say hello", function(args)
  local who = args ~= "" and args or "there"
  neopi.ui.notify("Hello, " .. who .. "!")
  return "greeted " .. who
end)
