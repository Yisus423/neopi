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
end)
