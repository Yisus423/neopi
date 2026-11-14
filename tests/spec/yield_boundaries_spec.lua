--- The pinned answer to ROADMAP #19's async question, MEASURED on neopi's own
--- LuaJIT (2.1) instead of argued from memory — and measured here, in the
--- runner that embeds the same VM the binary does, because PUC 5.1 is exactly
--- the Lua that cannot yield across `pcall` and that is why coco exists.
---
--- Two results, and they point in different directions:
---   * a coroutine CAN yield across the `pcall`/`xpcall` every handler is
---     wrapped in, so the CONTAINMENT is not what blocks an async extension;
---   * a coroutine CANNOT yield across a C callback — the shape a Nim FFI
---     function has when it calls back into Lua.
--- The design rule that falls out of it: the yield must happen in a LUA frame
--- (`coroutine.yield` inside a Lua wrapper, which is how neovim's
--- `async.await` is written), never inside a Nim function.
--- @module spec.yield_boundaries

local function resumes(body)
  --- Resume `body` in a fresh coroutine and report what happened: whether the
  --- resume came back, why not, and where the coroutine ended up.
  local co = coroutine.create(body)
  local ok, err = coroutine.resume(co)
  return ok, err, coroutine.status(co)
end

describe("the coroutine yield boundaries (LuaJIT, measured)", function()
  it("a yield CROSSES the pcall every handler is wrapped in", function()
    local ok, _, status = resumes(function()
      pcall(function()
        coroutine.yield()
      end)
    end)
    assert.is_true(ok)
    assert.are.equal("suspended", status)
  end)

  it("a yield CROSSES xpcall and a metatable __index", function()
    local ok, _, status = resumes(function()
      xpcall(function()
        coroutine.yield()
      end, function() end)
    end)
    assert.is_true(ok)
    assert.are.equal("suspended", status)

    local okIndex, _, indexStatus = resumes(function()
      local t = setmetatable({}, {__index = function()
        coroutine.yield()
      end})
      local _ = t.anything
    end)
    assert.is_true(okIndex)
    assert.are.equal("suspended", indexStatus)
  end)

  it("a yield CANNOT cross a C callback — the Nim FFI function's shape", function()
    -- This is the wall, and it is why the yield has to be the LUA frame's job.
    local ok, err = resumes(function()
      local _ = ("x"):gsub("x", function()
        coroutine.yield()
      end)
    end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("C%-call boundary"))

    local okSort, sortErr = resumes(function()
      table.sort({2, 1}, function()
        coroutine.yield()
      end)
    end)
    assert.is_false(okSort)
    assert.is_truthy(tostring(sortErr):find("C%-call boundary"))
  end)
end)
