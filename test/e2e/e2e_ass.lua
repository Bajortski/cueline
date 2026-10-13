-- End-to-end for ASS buffers: the buffer is rendered by IINA's libass from a
-- temp file. Checked through mpv's own state (the `track` reports carry its
-- sid and sub-text), not screenshots. Launched by `test/e2e/run.sh ass`.
-- Usage: nvim --headless --clean -l test/e2e/e2e_ass.lua <ass> <media-basename>
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/test/nvim/?.lua;" .. package.path
vim.cmd("runtime plugin/cueline.lua")

local H = require("helpers")
local cl = require("cueline")
local client = require("cueline.client")
local live = require("cueline.live")
local api = vim.api
local it, eq, wait = H.it, H.eq, H.wait

local ass_path, media = _G.arg[1], _G.arg[2]
local port = tonumber(os.getenv("CUELINE_PORT") or "10427")

-- every `track` report from IINA, in order
local reports = {}
local on_track = client.handlers.track
client.handlers.track = function(msg)
  reports[#reports + 1] = msg
  on_track(msg)
end

cl.setup({ port = port, follow_idle_ms = 0, reconnect_ms = 300 })
vim.cmd.edit(ass_path)
vim.bo.filetype = "ssa"
local buf = api.nvim_get_current_buf()

local function row_of(needle)
  for i, l in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:find(needle, 1, true) then
      return i
    end
  end
end

local function sub_text()
  return live.state and live.state.text or ""
end

io.write("e2e (ass) against IINA on port ", port, " with ", media, "\n")

local first

it("connects and IINA loads the buffer as a selected, visible subtitle track", function()
  cl.connect()
  wait(20000, function()
    return client.status == "connected" and cl.player.file and cl.player.file:find(media, 1, true)
  end, "connected + file " .. media)
  wait(5000, function()
    return live.state and live.state.path and live.state.id
  end, "track report with an id")
  first = live.state
  io.write(("    temp %s, track id %s, sid %s, user's sid was %s\n"):format(
    first.path, tostring(first.id), tostring(first.sid), tostring(first.prev_sid)))
  eq(live.sent, first.path, "track is our temp file")
  eq(tostring(first.id), first.sid, "our track is selected")
  eq(true, first.sub_visibility, "subtitles visible")
end)

it("mpv renders the line at the current position", function()
  vim.cmd("CuelinePause")
  wait(3000, function()
    return cl.player.paused == true
  end, "paused")
  api.nvim_win_set_cursor(0, { row_of("Tonight we roll"), 0 })
  vim.cmd("CuelineSeek")
  wait(3000, function()
    return sub_text():find("Tonight we roll for initiative", 1, true) ~= nil
  end, "sub-text has cue 2, got " .. vim.inspect(sub_text()))
  io.write("    sub-text: ", vim.inspect(sub_text()), "\n")
  eq(nil, (cl.shown or ""):find("%S"), "overlay shows nothing for ASS")
end)

it("an unsaved edit reaches libass after the debounce", function()
  local row = row_of("Tonight we roll")
  local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  local t0 = vim.uv.hrtime() / 1e6
  api.nvim_buf_set_lines(buf, row - 1, row, false, { (line:gsub("Tonight", "Tomorrow")) })
  api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  wait(3000, function()
    return sub_text():find("Tomorrow we roll", 1, true) ~= nil
  end, "edited sub-text, got " .. vim.inspect(sub_text()))
  io.write(("    edit -> sub-text in %.0f ms, track id now %s\n"):format(
    vim.uv.hrtime() / 1e6 - t0, tostring(live.state.id)))
  eq(true, vim.bo[buf].modified, "buffer still unsaved")
  eq(tostring(live.state.id), live.state.sid, "still selected after sub-reload")
end)

it("detaching removes the track and restores the user's subtitle", function()
  local path = live.sent
  vim.cmd("CuelineDetach")
  wait(3000, function()
    return live.state and live.state.path == nil
  end, "dropped report")
  io.write(("    sid after drop %s (was %s)\n"):format(tostring(live.state.sid), tostring(first.prev_sid)))
  eq(first.prev_sid, live.state.sid, "previous sid restored")
  eq(nil, vim.uv.fs_stat(path), "temp file deleted")
end)

it("disconnect is clean", function()
  cl.disconnect()
  wait(2000, function()
    return client.status == "disconnected"
  end)
end)

H.finish()
