-- In-process mock of the IINA plugin's WebSocket server, for protocol tests.
local ws = require("cueline.ws")
local uv = vim.uv

local M = {}

local RESPONSE = table.concat({
  "HTTP/1.1 101 Switching Protocols",
  "Upgrade: websocket",
  "Connection: Upgrade",
  "Sec-WebSocket-Accept: unchecked",
  "",
  "",
}, "\r\n")

--- Start a server on an ephemeral port. `on_message(msg, server)` is called
-- for each decoded JSON message (after it is appended to server.received).
function M.start(on_message)
  local server = { received = {}, clients = {} }
  local tcp = uv.new_tcp()
  assert(tcp:bind("127.0.0.1", 0))
  server.port = tcp:getsockname().port

  local function handle(client, frames)
    for _, f in ipairs(frames) do
      if f.opcode == ws.OP.text or f.opcode == ws.OP.binary then
        local msg = vim.json.decode(f.payload)
        table.insert(server.received, msg)
        if on_message then
          on_message(msg, server)
        end
      elseif f.opcode == ws.OP.close then
        client:close()
      end
    end
  end

  tcp:listen(8, function()
    local client = uv.new_tcp()
    tcp:accept(client)
    local hbuf, dec, open = "", ws.decoder(), false
    table.insert(server.clients, client)
    client:read_start(vim.schedule_wrap(function(err, chunk)
      if err or not chunk then
        if not client:is_closing() then
          client:close()
        end
        return
      end
      if open then
        return handle(client, dec.feed(chunk))
      end
      hbuf = hbuf .. chunk
      if hbuf:find("\r\n\r\n", 1, true) then
        open = true
        client:write(RESPONSE)
        handle(client, dec.feed(hbuf:sub(hbuf:find("\r\n\r\n", 1, true) + 4)))
      end
    end))
  end)

  function server.send(msg)
    local frame = ws.encode(ws.OP.binary, vim.json.encode(msg), false) -- IINA sends binary frames
    for _, c in ipairs(server.clients) do
      if not c:is_closing() then
        c:write(frame)
      end
    end
  end

  function server.drop_clients()
    for _, c in ipairs(server.clients) do
      if not c:is_closing() then
        c:close()
      end
    end
    server.clients = {}
  end

  function server.last(type_)
    for i = #server.received, 1, -1 do
      if server.received[i].type == type_ then
        return server.received[i]
      end
    end
  end

  function server.count(type_)
    local n = 0
    for _, m in ipairs(server.received) do
      n = n + (m.type == type_ and 1 or 0)
    end
    return n
  end

  function server.stop()
    server.drop_clients()
    tcp:close()
  end

  return server
end

return M
