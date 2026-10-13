-- Usage: nvim --headless --clean -l test/nvim/run.lua [test files...]
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/test/nvim/?.lua;" .. package.path
vim.cmd("runtime plugin/cueline.lua")

local files = _G.arg and #_G.arg > 0 and _G.arg or { "test_srt", "test_ws", "test_plugin", "test_ass", "test_live" }
for _, f in ipairs(files) do
  io.write(f, "\n")
  dofile(root .. "/test/nvim/" .. f:gsub("%.lua$", "") .. ".lua")
end
require("helpers").finish()
