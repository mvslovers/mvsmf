-- The PASS/FAIL/SKIP lines of the shell suites in tests/, for the suites
-- written in Lua (mbt/lua/restauth.lua). Same words, same summary line, so a
-- run reads the same whichever language a suite is in.

local M = {}

function M.new(ctx, title)
  local t = { passed = 0, failed = 0, skipped = 0 }

  function t.pass(label)
    t.passed = t.passed + 1
    ctx.log("  PASS: " .. label)
  end

  function t.fail(label, why)
    t.failed = t.failed + 1
    ctx.log("  FAIL: " .. label)
    if why then ctx.log("        " .. why) end
  end

  function t.skip(label)
    t.skipped = t.skipped + 1
    ctx.log("  SKIP: " .. label)
  end

  function t.eq(expected, actual, label)
    if tostring(actual) == tostring(expected) then
      t.pass(label .. " (" .. tostring(actual) .. ")")
    else
      t.fail(label, "expected '" .. tostring(expected) .. "', got '" ..
             tostring(actual) .. "'")
    end
  end

  function t.ok(cond, label, why)
    if cond then t.pass(label) else t.fail(label, why) end
  end

  function t.section(name)
    ctx.log("")
    ctx.log("--- " .. name .. " ---")
  end

  -- true when nothing failed
  function t.summary()
    ctx.log("")
    ctx.log("========================================")
    ctx.log(string.format(" Total: %d  Passed: %d  Failed: %d  Skipped: %d",
            t.passed + t.failed + t.skipped, t.passed, t.failed, t.skipped))
    ctx.log("========================================")
    return t.failed == 0
  end

  ctx.log("")
  ctx.log("========================================")
  ctx.log(" " .. title)
  ctx.log("========================================")
  return t
end

return M
