-- End-to-end: headless Neovim + cueline against a real IINA running the
-- plugin. Launched by test/e2e/run.sh, which starts and stops IINA.
-- Usage: nvim --headless --clean -l test/e2e/e2e.lua <srt> <media-basename>
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/test/nvim/?.lua;" .. package.path
vim.cmd("runtime plugin/cueline.lua")

local H = require("helpers")
local cl = require("cueline")
local client = require("cueline.client")
local buffer = require("cueline.buffer")
local api = vim.api
local it, eq, wait = H.it, H.eq, H.wait

local srt_path, media = _G.arg[1], _G.arg[2]
local port = tonumber(os.getenv("CUELINE_PORT") or "10427")

-- record every incoming message
local log = {}
for name, h in pairs(client.handlers) do
  if not name:match("^_") then
    client.handlers[name] = function(msg)
      msg._t = vim.uv.hrtime() / 1e6
      table.insert(log, msg)
      h(msg)
    end
  end
end

local function count(type_, since)
  local n = 0
  for _, m in ipairs(log) do
    n = n + ((m.type == type_ and m._t >= (since or 0)) and 1 or 0)
  end
  return n
end

local function now()
  return vim.uv.hrtime() / 1e6
end

cl.setup({ port = port, follow_idle_ms = 0, reconnect_ms = 300 })
vim.cmd.edit(srt_path)
vim.bo.filetype = "srt"
local buf = api.nvim_get_current_buf()

local function cue_row(text)
  for i, l in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l == text then
      return i
    end
  end
end

io.write("e2e against IINA on port ", port, " with ", media, "\n")

it("connects to the IINA plugin and sees the media file", function()
  cl.connect()
  wait(20000, function()
    return client.status == "connected" and cl.player.file and cl.player.file:find(media, 1, true)
  end, "connected + file " .. media)
  io.write("    player file: ", cl.player.file, "\n")
end)

it("receives time updates at ~10 Hz while playing", function()
  wait(10000, function()
    return cl.player.paused == false
  end, "playing")
  vim.wait(1000) -- let playback settle after startup
  local t0, p0 = now(), cl.position()
  vim.wait(2000)
  local n = count("time", t0)
  local elapsed = (now() - t0) / 1000
  local advanced = cl.position() - p0
  io.write(("    %d time msgs in %.2f s, estimated position advanced %.2f s\n"):format(n, elapsed, advanced))
  -- ~8 Hz for video; mpv updates audio-only time-pos less often (nvim extrapolates)
  H.truthy(n >= 4 and n <= 24, "rate out of range: " .. n)
  H.truthy(math.abs(advanced - elapsed) < 0.2, "position estimate drifted from wall clock")
end)

it(":CuelineSeek seeks the player to the cue under the cursor", function()
  api.nvim_win_set_cursor(0, { cue_row("That is a natural one"), 0 })
  vim.cmd("CuelineSeek")
  wait(3000, function()
    return cl.player.pos >= 30.5 and cl.player.pos < 31.5
  end, "pos near 30.5")
  io.write(("    pos after seek: %.3f\n"):format(cl.player.pos))
end)

it("highlights the playing cue and the player renders it", function()
  wait(3000, function()
    return cl.shown == "That is a natural one\n(cue 7 second line)"
  end, "overlay shows cue 7")
  local marks = api.nvim_buf_get_extmarks(buf, buffer.ns, 0, -1, {})
  eq(cue_row("That is a natural one") - 2, marks[1] and marks[1][2], "extmark on cue 7 timestamp line")
  io.write("    IINA subtitle track hidden: ", tostring(cl.subs_hidden), "\n")
end)

it("an edit in Neovim shows up in the player immediately", function()
  local row = cue_row("That is a natural one")
  local t0 = now()
  api.nvim_buf_set_lines(buf, row - 1, row, false, { "That is a natural one (edited)" })
  api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  wait(2000, function()
    return cl.shown == "That is a natural one (edited)\n(cue 7 second line)"
  end, "edited text rendered")
  io.write(("    edit -> rendered ack in %.0f ms\n"):format(now() - t0))
end)

it(":CuelinePause pauses and position holds", function()
  -- mpv quirk: pausing an audio-only file within ~150 ms of a seek leaves
  -- time-pos creeping forward for a second; play a moment first
  vim.wait(1000)
  vim.cmd("CuelinePause")
  wait(2000, function()
    return cl.player.paused == true
  end, "paused")
  local p0 = cl.position()
  vim.wait(300)
  local p = cl.position()
  vim.wait(600)
  io.write(("    paused at %.3f, settled %.3f, 600 ms later %.3f\n"):format(p0, p, cl.position()))
  H.truthy(math.abs(cl.position() - p) < 0.05, "position moved while paused")
end)

it("while paused, the cue under the cursor is previewed", function()
  api.nvim_win_set_cursor(0, { cue_row("Tonight we roll for initiative"), 0 })
  api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  wait(2000, function()
    return cl.shown == "Tonight we roll for initiative"
  end, "cursor preview rendered")
end)

it(":CuelineNudge moves the position", function()
  local p = cl.position()
  vim.cmd("CuelineNudge 2")
  wait(2000, function()
    return math.abs(cl.position() - (p + 2)) < 0.1
  end, "nudged +2 s")
  io.write(("    %.3f -> %.3f\n"):format(p, cl.position()))
end)

it(":CuelineReplay plays from the cue start", function()
  api.nvim_win_set_cursor(0, { cue_row("Roll a d20 for perception"), 0 })
  vim.cmd("CuelineReplay")
  wait(3000, function()
    return cl.player.paused == false and cl.player.pos >= 25.5 and cl.player.pos < 27
  end, "playing from 25.5")
  wait(3000, function()
    return cl.shown == "Roll a d20 for perception"
  end, "cue 6 rendered while playing")
end)

it("disconnect is clean", function()
  cl.disconnect()
  wait(2000, function()
    return client.status == "disconnected"
  end)
end)

H.finish()
