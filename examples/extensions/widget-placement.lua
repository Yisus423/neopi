--- pi's `examples/extensions/widget-placement.ts`, carried onto neopi: a block
--- of lines hugging the editor, above or below it. The original:
---
---   ctx.ui.setWidget("above", ["above the editor"], { placement: "aboveEditor" });
---   ctx.ui.setWidget("below", ["below the editor"], { placement: "belowEditor" });
---
--- and the port, which is nearly word for word:
---
---   neopi.ui.widget("above", {"above the editor"}, {placement = "aboveEditor"})
---   neopi.ui.widget("below", {"below the editor"}, {placement = "belowEditor"})
---
--- THE SHAPE THAT CHANGES: nothing that matters. The key names the slot (two
--- widgets with different keys coexist), the placement is pi's, and an unknown
--- placement is REFUSED instead of silently falling back to a default —
--- the one place neopi is stricter than the original, on purpose.
--- @module examples.widget_placement

neopi.registerCommand("audit-widgets", "place a widget above and below",
  function(_)
    neopi.ui.widget("audit-above", {"above the editor"},
      {placement = "aboveEditor"})
    neopi.ui.widget("audit-below", {"below the editor"},
      {placement = "belowEditor"})
    return "placed"
  end)

neopi.registerCommand("audit-widgets-clear", "take both widgets down",
  function(_)
    neopi.ui.widget("audit-above", nil)
    neopi.ui.widget("audit-below", nil)
    return "cleared"
  end)
