-- Tiny busted-style harness for `nvim --headless -l`. No dependencies.
local H = { passed = 0, failed = 0, current = "" }

function H.describe(name, fn)
  H.current = name
  fn()
end

function H.it(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    H.passed = H.passed + 1
    io.write("  ok   ", H.current, " :: ", name, "\n")
  else
    H.failed = H.failed + 1
    io.write("  FAIL ", H.current, " :: ", name, "\n", tostring(err), "\n")
  end
end

function H.eq(want, got, msg)
  if not vim.deep_equal(want, got) then
    error(("%sexpected %s, got %s"):format(msg and (msg .. ": ") or "", vim.inspect(want), vim.inspect(got)), 2)
  end
end

function H.truthy(v, msg)
  if not v then
    error(msg or "expected truthy value", 2)
  end
end

function H.near(want, got, tol, msg)
  if type(got) ~= "number" or math.abs(want - got) > (tol or 1e-6) then
    error(("%sexpected ~%s, got %s"):format(msg and (msg .. ": ") or "", tostring(want), tostring(got)), 2)
  end
end

--- Wait (pumping the event loop) until cond() is truthy.
function H.wait(ms, cond, msg)
  if not vim.wait(ms, cond, 10) then
    error("timed out: " .. (msg or "condition"), 2)
  end
end

function H.finish()
  io.write(("\n%d passed, %d failed\n"):format(H.passed, H.failed))
  os.exit(H.failed == 0 and 0 or 1)
end

return H
