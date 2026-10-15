--- The busted spec for the neopi.ui primitives: without the TUI they are
--- no-ops (the registry pointer stays nil) — the headless contract. The
--- spec runs inside the busted runner's live Lua state with the core
--- exposed and exposeUi applied (busted_main's setup).
--- @module spec.ui

describe("neopi.ui", function()
  it("the three slots are no-ops without the TUI", function()
    -- The primitives exist always (exposed at extensibility time) and are
    -- no-ops without the TUI: they return nil and raise no error.
    assert.are.equal(nil, neopi.ui.header("ignored"))
    assert.are.equal(nil, neopi.ui.status("key", "ignored"))
    assert.are.equal(nil, neopi.ui.widget("w", "ignored"))
    -- A missing or nil line list clears: the same call shape, still a no-op.
    assert.are.equal(nil, neopi.ui.header())
    assert.are.equal(nil, neopi.ui.header(nil))
    assert.are.equal(nil, neopi.ui.status("key"))
    assert.are.equal(nil, neopi.ui.status("key", nil))
    assert.are.equal(nil, neopi.ui.widget("w"))
    assert.are.equal(nil, neopi.ui.widget("w", nil))
  end)

  it("the header takes one line, several, or nothing", function()
    assert.are.equal(nil, neopi.ui.header("one"))
    assert.are.equal(nil, neopi.ui.header({"one", "two"}))
    assert.has_error(function() neopi.ui.header(123) end)
    assert.has_error(function() neopi.ui.header({"one", 2}) end)
  end)

  it("the status needs a key and takes a string or nil", function()
    assert.has_error(function() neopi.ui.status(123) end)
    assert.has_error(function() neopi.ui.status("key", 123) end)
  end)

  it("the widget takes lines and only the placement option", function()
    assert.are.equal(nil, neopi.ui.widget("w", {"a", "b"}))
    assert.are.equal(nil,
      neopi.ui.widget("w", "a", {placement = "belowEditor"}))
    assert.has_error(function() neopi.ui.widget(123) end)
    assert.has_error(function() neopi.ui.widget("w", 123) end)
    -- An unknown placement or an unknown option is refused instead of
    -- silently falling back to the default.
    assert.has_error(function()
      neopi.ui.widget("w", "a", {placement = "sideways"})
    end)
    assert.has_error(function()
      neopi.ui.widget("w", "a", {colour = "red"})
    end)
  end)

  it("the transient, working and title slots are no-ops without the TUI", function()
    -- The headless flag is the one read an extension can act on.
    assert.are.equal(false, neopi.hasUI)
    assert.are.equal(nil, neopi.ui.notify("ignored"))
    assert.are.equal(nil, neopi.ui.notify("ignored", "error"))
    assert.are.equal(nil, neopi.ui.working("thinking"))
    assert.are.equal(nil, neopi.ui.title("neopi"))
    -- Clearing is the missing or nil argument, the same shape everywhere.
    assert.are.equal(nil, neopi.ui.notify())
    assert.are.equal(nil, neopi.ui.notify(nil))
    assert.are.equal(nil, neopi.ui.working())
    assert.are.equal(nil, neopi.ui.working(nil))
    assert.are.equal(nil, neopi.ui.title())
    assert.are.equal(nil, neopi.ui.title(nil))
  end)

  it("the transient line refuses an unknown level", function()
    assert.has_error(function() neopi.ui.notify(123) end)
    assert.has_error(function() neopi.ui.notify("x", 123) end)
    -- A typo in the level must not silently become "info": the severity is
    -- what the row is painted with.
    assert.has_error(function() neopi.ui.notify("x", "sideways") end)
    assert.has_error(function() neopi.ui.working(123) end)
    assert.has_error(function() neopi.ui.title(123) end)
  end)

  it("the dialogs answer at once when there is no TUI to ask", function()
    -- A Lua handler cannot wait, and with no UI there is nobody to ask: the
    -- callback fires immediately with the "no answer" value, so an extension's
    -- flow never hangs on a question that cannot be shown.
    local selected = "unset"
    assert.are.equal(nil, neopi.ui.select("pick one", {"alpha", "beta"},
      function(answer) selected = answer end))
    assert.are.equal(nil, selected)
    local confirmed = "unset"
    assert.are.equal(nil, neopi.ui.confirm("sure?", "really do it",
      function(answer) confirmed = answer end))
    assert.are.equal(false, confirmed)
  end)

  it("the dialogs validate their shape", function()
    assert.has_error(function() neopi.ui.select("pick one") end)
    assert.has_error(function() neopi.ui.select("pick one", {}) end)
    assert.has_error(function() neopi.ui.select("pick one", {"alpha"}, nil) end)
    assert.has_error(function() neopi.ui.select(123, {"a"}, function() end) end)
    assert.has_error(function() neopi.ui.select("pick one", {1, 2}, function() end) end)
    assert.has_error(function() neopi.ui.confirm("sure?") end)
    assert.has_error(function() neopi.ui.confirm("sure?", "really") end)
    assert.has_error(function() neopi.ui.confirm(123, "really", function() end) end)
  end)
end)
