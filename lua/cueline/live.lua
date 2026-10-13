-- Live libass preview for ASS buffers: the whole buffer, unsaved edits
-- included, is written to a temp file that IINA loads as a subtitle track and
-- reloads after every (debounced) change.
local buffer = require("cueline.buffer")
local ass = require("cueline.ass")
local client = require("cueline.client")

local api, fn, uv = vim.api, vim.fn, vim.uv
local M = {}

M.debounce_ms = 150
M.files = {} -- buf -> temp file path
M.sent = nil -- path IINA was last told to show
M.state = nil -- last `track` report from IINA

local timer = nil

local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function is_ass(buf)
  return buf and api.nvim_buf_is_valid(buf) and buffer.fmt(buf) == ass
end

--- Temp file for buf, created on first use.
function M.path(buf)
  if not M.files[buf] then
    local ext = fn.fnamemodify(api.nvim_buf_get_name(buf), ":e"):lower() == "ssa" and ".ssa" or ".ass"
    M.files[buf] = fn.tempname() .. "-cueline" .. ext
  end
  return M.files[buf]
end

--- Write buf to its temp file atomically, so IINA never reads half a file.
function M.write(buf)
  local path = M.path(buf)
  local tmp = path .. ".tmp"
  if fn.writefile(api.nvim_buf_get_lines(buf, 0, -1, false), tmp) ~= 0 then
    return nil
  end
  assert(uv.fs_rename(tmp, path))
  return path
end

local function send_path(path)
  M.sent = path
  client.send({ type = "track", path = path or vim.NIL })
end

--- Bring IINA in line with buf: write and (re)load its track if it's an ASS
-- buffer, otherwise drop any track we loaded.
function M.sync(buf)
  stop_timer()
  if client.status ~= "connected" then
    return
  end
  if is_ass(buf) then
    send_path(M.write(buf))
  elseif M.sent then
    send_path(nil)
  end
end

--- buf became the tracked buffer: show its track, or drop ours if it has
-- none, unless that's already what IINA shows.
function M.switch(buf)
  local mine = is_ass(buf)
  if (mine and (M.files[buf] == nil or M.files[buf] ~= M.sent)) or (not mine and M.sent) then
    M.sync(buf)
  end
end

--- Debounced sync, for edits.
function M.schedule(buf)
  if client.status ~= "connected" or not is_ass(buf) then
    return
  end
  stop_timer()
  timer = uv.new_timer()
  timer:start(M.debounce_ms, 0, vim.schedule_wrap(function()
    M.sync(buf)
  end))
end

local function remove(buf)
  local path = M.files[buf]
  if path then
    os.remove(path)
    M.files[buf] = nil
  end
  return path
end

--- buf is no longer attached: drop its track and delete its temp file.
function M.drop(buf)
  stop_timer()
  local path = remove(buf)
  if path and path == M.sent then
    send_path(nil)
    M.sent = nil
  end
end

--- Connection closed: IINA drops the track itself; delete the temp files.
function M.reset()
  stop_timer()
  M.sent = nil
  M.state = nil
  for buf in pairs(M.files) do
    remove(buf)
  end
end

api.nvim_create_autocmd("VimLeavePre", {
  group = api.nvim_create_augroup("cueline_live", { clear = true }),
  callback = M.reset,
})

return M
