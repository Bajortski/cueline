-- Minimal WebSocket client (RFC 6455) on vim.uv TCP: client handshake,
-- masked outgoing frames, fragmented/unmasked incoming frames, ping/pong and
-- close. Enough to talk to IINA's `ws` plugin server on localhost; no TLS,
-- no extensions. Framing functions are pure so they can be unit tested.
local bit = require("bit")
local band, bor, bxor, rshift, lshift = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift

local M = {}

M.OP = { cont = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10 }

local CHUNK = 4096

--- XOR `data` with the 4-byte `mask` (same operation masks and unmasks).
function M.apply_mask(data, mask)
  local m = { mask:byte(1, 4) }
  local out, buf = {}, {}
  local len = #data
  for base = 1, len, CHUNK do
    local last = math.min(base + CHUNK - 1, len)
    local bytes = { data:byte(base, last) }
    for i = 1, #bytes do
      buf[i] = bxor(bytes[i], m[(base + i - 2) % 4 + 1])
    end
    for i = #bytes + 1, #buf do
      buf[i] = nil
    end
    out[#out + 1] = string.char(unpack(buf))
  end
  return table.concat(out)
end

local function length_bytes(len, mask_bit)
  if len < 126 then
    return string.char(bor(mask_bit, len))
  elseif len < 65536 then
    return string.char(bor(mask_bit, 126), rshift(len, 8), band(len, 0xff))
  end
  local hi = math.floor(len / 4294967296)
  local lo = len % 4294967296
  return string.char(
    bor(mask_bit, 127),
    band(rshift(hi, 24), 0xff), band(rshift(hi, 16), 0xff), band(rshift(hi, 8), 0xff), band(hi, 0xff),
    math.floor(lo / 16777216) % 256, math.floor(lo / 65536) % 256, math.floor(lo / 256) % 256, lo % 256
  )
end

--- Encode one final frame. Client frames must be masked; pass `mask` (4 bytes)
-- for deterministic tests, or false for an unmasked (server-style) frame.
function M.encode(opcode, payload, mask)
  payload = payload or ""
  if mask == nil then
    mask = vim.uv.random(4)
  end
  if not mask then
    return string.char(bor(0x80, opcode)) .. length_bytes(#payload, 0) .. payload
  end
  return string.char(bor(0x80, opcode)) .. length_bytes(#payload, 0x80) .. mask .. M.apply_mask(payload, mask)
end

-- Parse a frame header at the start of `buf`. Returns a header table or nil
-- when more bytes are needed.
local function parse_header(buf)
  if #buf < 2 then
    return nil
  end
  local b1, b2 = buf:byte(1, 2)
  local h = { fin = band(b1, 0x80) ~= 0, opcode = band(b1, 0x0f), masked = band(b2, 0x80) ~= 0 }
  local len, pos = band(b2, 0x7f), 3
  if len == 126 then
    if #buf < 4 then
      return nil
    end
    local x, y = buf:byte(3, 4)
    len, pos = bor(lshift(x, 8), y), 5
  elseif len == 127 then
    if #buf < 10 then
      return nil
    end
    len = 0
    for i = 3, 10 do
      len = len * 256 + buf:byte(i)
    end
    pos = 11
  end
  h.len = len
  if h.masked then
    h.mask = buf:sub(pos, pos + 3)
    pos = pos + 4
  end
  h.payload_at = pos
  if #buf < pos + len - 1 then
    return nil
  end
  return h
end

--- Incremental frame decoder. `feed(bytes)` returns a list of complete
-- messages { opcode = n, payload = s }, reassembling fragmented data frames.
function M.decoder()
  local buf = ""
  local frag_op, frags = nil, {}
  local self = {}

  local function emit_data(out, h, payload)
    if h.opcode ~= M.OP.cont then
      frag_op, frags = h.opcode, {}
    end
    frags[#frags + 1] = payload
    if h.fin then
      out[#out + 1] = { opcode = frag_op, payload = table.concat(frags) }
      frag_op, frags = nil, {}
    end
  end

  function self.feed(data)
    buf = buf .. data
    local out = {}
    while true do
      local h = parse_header(buf)
      if not h then
        break
      end
      local payload = buf:sub(h.payload_at, h.payload_at + h.len - 1)
      buf = buf:sub(h.payload_at + h.len)
      if h.masked then
        payload = M.apply_mask(payload, h.mask)
      end
      if h.opcode >= 8 then
        out[#out + 1] = { opcode = h.opcode, payload = payload }
      else
        emit_data(out, h, payload)
      end
    end
    return out
  end

  return self
end

--- Build the HTTP upgrade request.
function M.handshake_request(host, port, key)
  return table.concat({
    "GET / HTTP/1.1",
    ("Host: %s:%d"):format(host, port),
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " .. key,
    "Sec-WebSocket-Version: 13",
    "",
    "",
  }, "\r\n")
end

--- Split a buffered handshake response. Returns (ok, leftover) once the
-- header block is complete, nil while incomplete.
function M.parse_handshake(buf)
  local stop = buf:find("\r\n\r\n", 1, true)
  if not stop then
    return nil
  end
  local ok = buf:match("^HTTP/1%.1 101") ~= nil
  return ok, buf:sub(stop + 4)
end

-- Handlers for incoming frames, keyed by opcode. `c` is the connection.
local frame_handlers = {
  [M.OP.text] = function(c, f)
    c.handlers.on_message(f.payload)
  end,
  -- IINA's server sends everything as binary frames holding UTF-8 text
  [M.OP.binary] = function(c, f)
    c.handlers.on_message(f.payload)
  end,
  [M.OP.ping] = function(c, f)
    c:_write(M.encode(M.OP.pong, f.payload))
  end,
  [M.OP.pong] = function() end,
  [M.OP.close] = function(c)
    c:close()
  end,
}

local Conn = {}
Conn.__index = Conn

function Conn:_write(data)
  if self.tcp and not self.tcp:is_closing() then
    self.tcp:write(data)
  end
end

function Conn:send(text)
  if self.state ~= "open" then
    return false
  end
  self:_write(M.encode(M.OP.text, text))
  return true
end

function Conn:close(reason)
  if self.state == "closed" then
    return
  end
  local was = self.state
  self.state = "closed"
  if was == "open" then
    self:_write(M.encode(M.OP.close, ""))
  end
  if self.tcp and not self.tcp:is_closing() then
    self.tcp:read_stop()
    self.tcp:close()
  end
  self.handlers.on_close(reason or "closed")
end

function Conn:_on_frames(frames)
  for _, f in ipairs(frames) do
    local h = frame_handlers[f.opcode]
    if h then
      h(self, f)
    end
  end
end

function Conn:_on_handshake_data(chunk)
  self.hbuf = self.hbuf .. chunk
  local ok, rest = M.parse_handshake(self.hbuf)
  if ok == nil then
    return
  end
  if not ok then
    return self:close("handshake rejected: " .. (self.hbuf:match("^[^\r\n]*") or "?"))
  end
  self.state = "open"
  self.hbuf = nil
  self.handlers.on_open()
  self:_on_frames(self.decoder.feed(rest))
end

function Conn:_on_read(err, chunk)
  if err or not chunk then
    return self:close(err or "eof")
  end
  if self.state == "handshake" then
    return self:_on_handshake_data(chunk)
  end
  self:_on_frames(self.decoder.feed(chunk))
end

local function noop() end

--- Connect to ws://host:port/. handlers: on_open(), on_message(text),
-- on_close(reason). Handlers run on the main loop (vim.schedule'd).
function M.connect(host, port, handlers)
  local c = setmetatable({ state = "connecting", hbuf = "", decoder = M.decoder() }, Conn)
  c.handlers = {
    on_open = handlers.on_open or noop,
    on_message = handlers.on_message or noop,
    on_close = handlers.on_close or noop,
  }
  c.tcp = vim.uv.new_tcp()
  c.tcp:connect(host, port, vim.schedule_wrap(function(err)
    if err then
      return c:close(err)
    end
    if c.state == "closed" then
      return
    end
    c.state = "handshake"
    local key = vim.base64.encode(vim.uv.random(16))
    c:_write(M.handshake_request(host, port, key))
    c.tcp:read_start(vim.schedule_wrap(function(rerr, chunk)
      if c.state ~= "closed" then
        c:_on_read(rerr, chunk)
      end
    end))
  end))
  return c
end

return M
