-- Protocol round-trips between cueline.nvim and a mock IINA server.
local H = require("helpers")
local mock = require("mock_server")
local describe, it, eq, near, wait = H.describe, H.it, H.eq, H.near, H.wait

local api = vim.api
local cl = require("cueline")
local buffer = require("cueline.buffer")
local client = require("cueline.client")

local sample = {
  "1",
  "00:00:01,000 --> 00:00:02,500",
  "first line",
  "second line",
  "",
  "2",
  "00:00:03,000 --> 00:00:04,000",
  "third",
  "",
  "3",
  "00:00:05,000 --> 00:00:06,000",
  "fourth",
  "",
  "4",
  "00:00:07,000 --> 00:00:08,000",
  "last",
}

local server = mock.start(function(msg, s)
  if msg.type == "hello" then
    s.send({ type = "hello", server = "mock", player = { file = "/tmp/sample.mp4", pos = 0, paused = false } })
  end
end)

cl.setup({ port = server.port, follow_idle_ms = 0, reconnect_ms = 100, lookahead = 2 })

local buf = api.nvim_create_buf(true, false)
api.nvim_buf_set_name(buf, "/tmp/sample.srt")
api.nvim_buf_set_lines(buf, 0, -1, false, sample)
api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = "srt"

local function extmark_rows()
  local marks = api.nvim_buf_get_extmarks(buf, buffer.ns, 0, -1, { details = true })
  if #marks == 0 then
    return nil
  end
  return { marks[1][2], marks[1][4].end_row }
end

local function time(pos, paused)
  server.send({ type = "time", pos = pos, paused = paused or false, speed = 1 })
end

local function last_cue_text(type_)
  local m = server.last(type_)
  if type_ == "cues" then
    return m and m.items[1] and m.items[1].text
  end
  return m and m.text
end

describe("attach", function()
  it("auto-attaches srt buffers", function()
    H.truthy(buffer.get(buf), "buffer attached")
    eq(4, #buffer.cues(buf))
  end)
  it("sets buffer-local keymaps", function()
    H.truthy(vim.fn.maparg("<CR>", "n", false, true).buffer == 1)
  end)
end)

describe("connection", function()
  it("connects, says hello and pushes config + cue window", function()
    cl.connect()
    wait(2000, function()
      return server.last("cues") ~= nil
    end, "cue window")
    eq("connected", client.status)
    eq("cueline.nvim", server.last("hello").client)
    eq(true, server.last("config").hide_subs)
    local items = server.last("cues").items
    eq(3, #items) -- active/next + lookahead 2
    eq("first line\nsecond line", items[1].text)
    near(1.0, items[1].start)
    near(2.5, items[1]["end"])
  end)
end)

describe("playback -> nvim", function()
  it("highlights the playing cue and follows it", function()
    time(3.5)
    wait(1000, function()
      return extmark_rows() and extmark_rows()[1] == 6
    end, "highlight on cue 2")
    eq({ 6, 8 }, extmark_rows())
    eq(8, api.nvim_win_get_cursor(0)[1])
    wait(1000, function()
      return last_cue_text("cues") == "third"
    end, "window moved to cue 2")
  end)
  it("clears the highlight in gaps", function()
    time(4.5)
    wait(1000, function()
      return extmark_rows() == nil
    end, "no highlight")
    wait(1000, function()
      return last_cue_text("cues") == "fourth" -- window starts at the next cue
    end, "window at next cue")
  end)
  it("tracks player state", function()
    server.send({ type = "state", pos = 4.5, paused = true, speed = 1 })
    wait(1000, function()
      return cl.player.paused == true
    end)
  end)
end)

describe("editing -> player", function()
  it("patches a text edit incrementally and previews it", function()
    time(3.2, false)
    wait(1000, function()
      return cl.player.paused == false and last_cue_text("cues") == "third"
    end)
    api.nvim_buf_set_lines(buf, 7, 8, false, { "third, corrected" })
    eq(false, buffer.get(buf).dirty, "no full reparse needed")
    api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    wait(1000, function()
      return last_cue_text("cues") == "third, corrected"
    end, "edited text sent")
  end)
  it("falls back to a full reparse on structural edits", function()
    api.nvim_buf_set_lines(buf, 16, 16, false, { "", "5", "00:00:09,000 --> 00:00:10,000", "added" })
    eq(true, buffer.get(buf).dirty)
    api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eq(5, #buffer.cues(buf))
  end)
  it("previews the cue under the cursor while paused", function()
    time(3.2, true)
    wait(1000, function()
      return cl.player.paused
    end)
    api.nvim_win_set_cursor(0, { 16, 0 })
    api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    wait(1000, function()
      return last_cue_text("cue") == "last"
    end, "sticky preview")
    eq(true, server.last("cue").sticky)
  end)
end)

describe("commands -> player", function()
  it(":CuelineSeek seeks to the cue under the cursor", function()
    vim.cmd("CuelineSeek")
    wait(1000, function()
      return server.last("seek") ~= nil
    end)
    near(7.0, server.last("seek").pos)
  end)
  it(":CuelinePause, :CuelineNudge and :CuelineSpeed", function()
    vim.cmd("CuelinePause")
    vim.cmd("CuelineNudge -2")
    vim.cmd("CuelineSpeed 1.5")
    wait(1000, function()
      return server.last("speed") ~= nil
    end)
    eq(1, server.count("toggle-pause"))
    near(-2, server.last("nudge").delta)
    near(1.5, server.last("speed").speed)
  end)
  it(":CuelineAdjust rewrites the timestamp and seeks to the new start", function()
    local seeks = server.count("seek")
    vim.cmd("CuelineAdjust start 0.25")
    eq("00:00:07,250 --> 00:00:08,000", api.nvim_buf_get_lines(buf, 14, 15, false)[1])
    wait(1000, function()
      return server.count("seek") == seeks + 1
    end)
    near(7.25, server.last("seek").pos)
    vim.cmd("CuelineAdjust end -0.5")
    eq("00:00:07,250 --> 00:00:07,500", api.nvim_buf_get_lines(buf, 14, 15, false)[1])
  end)
  it(":CuelineStamp end uses the player position", function()
    time(7.9, true)
    wait(1000, function()
      return cl.player.pos == 7.9
    end)
    vim.cmd("CuelineStamp end")
    eq("00:00:07,250 --> 00:00:07,900", api.nvim_buf_get_lines(buf, 14, 15, false)[1])
  end)
  it("finds media next to the transcript or in ../audio", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/transcripts", "p")
    vim.fn.mkdir(dir .. "/audio", "p")
    vim.fn.writefile({}, dir .. "/audio/part-01.m4a")
    eq(vim.fs.normalize(dir .. "/audio/part-01.m4a"), cl.find_media(dir .. "/transcripts/part-01.srt"))
    eq(nil, cl.find_media(dir .. "/transcripts/part-02.srt"))
  end)
end)

describe("reconnect", function()
  it("reconnects after the server drops the connection", function()
    local hellos = server.count("hello")
    server.drop_clients()
    wait(3000, function()
      return server.count("hello") > hellos and client.status == "connected"
    end, "reconnected")
  end)
  it(":CuelineDisconnect stops reconnecting", function()
    vim.cmd("CuelineDisconnect")
    wait(1000, function()
      return client.status == "disconnected"
    end)
    local hellos = server.count("hello")
    vim.wait(400)
    eq(hellos, server.count("hello"))
  end)
end)

describe("health", function()
  it(":checkhealth cueline runs", function()
    vim.cmd("checkhealth cueline")
    local function text()
      return table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    end
    -- newer Neovim fills the report asynchronously
    vim.wait(5000, function() return text():find("cueline: session", 1, true) ~= nil end, 20)
    H.truthy(text():find("cueline: environment", 1, true), text())
    H.truthy(text():find("cueline: export", 1, true), text())
    vim.cmd("bwipeout!")
  end)
end)

server.stop()
