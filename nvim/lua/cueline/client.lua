-- Connection to the IINA plugin: connect/reconnect, JSON encode/decode and
-- table-driven dispatch of incoming messages.
local ws = require("cueline.ws")

local M = {}

M.status = "disconnected" -- disconnected | connecting | connected
M.conn = nil
M.last_error = nil
M.handlers = {} -- type -> function(msg), filled in by init.lua
M.opts = { host = "127.0.0.1", port = 10427, reconnect = true, reconnect_ms = 2000 }

local want_connected = false
local retry_timer = nil

local function stop_retry()
  if retry_timer then
    retry_timer:stop()
    retry_timer:close()
    retry_timer = nil
  end
end

--- Decode and dispatch one incoming message.
function M.dispatch(text)
  local ok, msg = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(msg) ~= "table" or type(msg.type) ~= "string" then
    return false
  end
  local h = M.handlers[msg.type]
  if h then
    h(msg)
  end
  return true
end

function M.send(msg)
  if M.status ~= "connected" then
    return false
  end
  return M.conn:send(vim.json.encode(msg))
end

local connect

local function schedule_retry()
  if not (want_connected and M.opts.reconnect) or retry_timer then
    return
  end
  retry_timer = vim.uv.new_timer()
  retry_timer:start(M.opts.reconnect_ms, 0, vim.schedule_wrap(function()
    stop_retry()
    if want_connected and M.status == "disconnected" then
      connect()
    end
  end))
end

local function on_close(reason)
  local was = M.status
  M.status = "disconnected"
  M.conn = nil
  M.last_error = reason
  if M.handlers._closed then
    M.handlers._closed(was, reason)
  end
  schedule_retry()
end

connect = function()
  M.status = "connecting"
  M.conn = ws.connect(M.opts.host, M.opts.port, {
    on_open = function()
      M.status = "connected"
      M.last_error = nil
      if M.handlers._opened then
        M.handlers._opened()
      end
    end,
    on_message = M.dispatch,
    on_close = on_close,
  })
end

function M.connect(opts)
  M.opts = vim.tbl_extend("force", M.opts, opts or {})
  want_connected = true
  stop_retry()
  if M.status ~= "disconnected" then
    return
  end
  connect()
end

function M.disconnect()
  want_connected = false
  stop_retry()
  if M.conn then
    M.conn:close("user disconnect")
  end
end

function M.wants_connection()
  return want_connected
end

return M
