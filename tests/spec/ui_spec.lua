--- The busted spec for the neopi.ui primitives: without the TUI they are
--- no-ops (the registry pointer stays nil) — the headless contract. The
--- spec runs inside the busted runner's live Lua state with the core
--- exposed and exposeUi applied (busted_main's setup).
--- @module spec.ui

describe("neopi.ui", function()
  it("status and widget are no-ops without the TUI", function()
    -- The primitives exist always (exposed at extensibility time) and are
    -- no-ops without the TUI: they return nil and raise no error.
    assert.are.equal(nil, neopi.ui.status("ignored"))
    assert.are.equal(nil, neopi.ui.widget("w", "ignored"))
  end)

  it("status rejects non-string arguments", function()
    assert.has_error(function() neopi.ui.status(123) end)
    assert.has_error(function() neopi.ui.widget("w") end)
  end)
end)
