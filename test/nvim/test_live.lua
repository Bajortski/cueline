-- Live libass preview: ASS buffers are written to a temp file that IINA is
-- told to load (`track`), debounced on edits and cleaned up afterwards.
local H = require("helpers")
local mock = require("mock_server")
local describe, it, eq, wait = H.describe, H.it, H.eq, H.wait

local api, uv = vim.api, vim.uv
local cl = require("cueline")
local client = require("cueline.client")
local live = require("cueline.live")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local fixture = vim.fn.readfile(root .. "/test/fixtures/sample.ass")

local server = mock.start(function(msg, s)
  if msg.type == "hello" then
    s.send({ type = "hello", server = "mock", player = { file = "/tmp/sample.mp4", pos = 0, paused = true } })
  end
end)

cl.setup({ port = server.port, follow_idle_ms = 0 })

local buf = api.nvim_create_buf(true, false)
api.nvim_buf_set_name(buf, "/tmp/live-sample.ass")
api.nvim_buf_set_lines(buf, 0, -1, false, fixture)
api.nvim_set_current_buf(buf)
vim.cmd("filetype on")
vim.cmd("filetype detect")

local function tracks()
  return server.count("track")
end

local function edit(row, text)
  api.nvim_buf_set_lines(buf, row, row + 1, false, { text })
  api.nvim_exec_autocmds("TextChanged", { buffer = buf })
end

local DIALOGUE = "Dialogue: 0,0:00:05.50,0:00:09.50,Default,Host,0,0,0,,"

describe("live track", function()
  local path
  it("writes the buffer and sends its path on connect", function()
    cl.connect()
    wait(2000, function()
      return tracks() > 0
    end, "track message")
    path = server.last("track").path
    H.truthy(type(path) == "string" and path:match("%.ass$"), "temp .ass path")
    eq(fixture, vim.fn.readfile(path))
    eq(nil, uv.fs_stat(path .. ".tmp"), "no leftover .tmp")
  end)
  it("debounces edits into one write with the unsaved text", function()
    local n = tracks()
    edit(16, DIALOGUE .. "one")
    edit(16, DIALOGUE .. "two")
    edit(16, DIALOGUE .. "three")
    vim.wait(60)
    eq(n, tracks(), "nothing sent inside the debounce")
    wait(1000, function()
      return tracks() == n + 1
    end, "one track message")
    vim.wait(300)
    eq(n + 1, tracks(), "only one")
    eq(path, server.last("track").path, "same file reused")
    eq(DIALOGUE .. "three", vim.fn.readfile(path)[17])
    eq(true, vim.bo[buf].modified, "still unsaved")
  end)
  it("stores IINA's track reports", function()
    server.send({ type = "track", path = path, id = 4, sid = "4", text = "three" })
    wait(1000, function()
      return live.state and live.state.id == 4
    end)
  end)
  it("switching to an srt buffer drops the track; back again reloads it", function()
    local srt = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(srt, "/tmp/live-other.srt")
    api.nvim_buf_set_lines(srt, 0, -1, false, { "1", "00:00:01,000 --> 00:00:02,000", "hi" })
    api.nvim_set_current_buf(srt)
    vim.bo[srt].filetype = "srt"
    wait(1000, function()
      return server.last("track").path == vim.NIL
    end, "track dropped")
    api.nvim_set_current_buf(buf)
    wait(1000, function()
      return server.last("track").path == path
    end, "track back")
    api.nvim_buf_delete(srt, { force = true })
  end)
  it("detach drops the track and deletes the temp file", function()
    cl.detach(buf)
    wait(1000, function()
      return server.last("track").path == vim.NIL
    end, "track dropped")
    eq(nil, uv.fs_stat(path))
  end)
  it("disconnect deletes temp files", function()
    cl.attach(buf)
    wait(1000, function()
      return type(server.last("track").path) == "string"
    end, "track again")
    local p = server.last("track").path
    H.truthy(uv.fs_stat(p), "written")
    cl.disconnect()
    wait(1000, function()
      return client.status == "disconnected"
    end)
    eq(nil, uv.fs_stat(p))
  end)
end)

server.stop()
