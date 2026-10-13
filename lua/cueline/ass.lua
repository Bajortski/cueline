-- ASS/SSA (Advanced SubStation Alpha) parsing and formatting, with the same
-- interface as cueline.srt. Pure Lua, no Neovim API.
--
-- Each `Dialogue:` line in [Events] is one cue, so ts_lnum, first and last
-- are all that line. Field order comes from the section's `Format:` line;
-- Text is always the last field and keeps its commas.
local lookup = require("cueline.cues")

local M = {}

-- smallest timing step the format can store
M.step = 0.01

local DEFAULT_EVENT_FORMAT =
  { "layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text" }

local TS = "(%d+):(%d+):(%d+)%.(%d+)"

local function trim(s)
  return (s:match("^%s*(.-)%s*$"))
end

local function secs(h, m, s, frac)
  return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + tonumber("0." .. frac)
end

--- Parse one timestamp field (H:MM:SS.cc). Returns seconds or nil.
function M.parse_ts(field)
  local h, m, s, frac = trim(field):match("^" .. TS .. "$")
  return h and secs(h, m, s, frac) or nil
end

--- Format seconds as H:MM:SS.cc.
function M.format_ts(t)
  if t < 0 then
    t = 0
  end
  local cs = math.floor(t * 100 + 0.5)
  local s = math.floor(cs / 100)
  return string.format("%d:%02d:%02d.%02d", math.floor(s / 3600), math.floor(s / 60) % 60, s % 60, cs % 100)
end

--- "start,end" as it would appear in a Dialogue line.
function M.format_timing(start, stop)
  return M.format_ts(start) .. "," .. M.format_ts(stop)
end

-- Comma-separated field names from a Format: value, lowercased.
local function field_names(value)
  local names = {}
  for name in (value .. ","):gmatch("([^,]*),") do
    names[#names + 1] = trim(name):lower()
  end
  return names
end

-- Byte spans { first, last } of the n fields starting at pos; only the first
-- n - 1 commas split, so the last field keeps any commas of its own.
local function field_spans(line, pos, n)
  local spans = {}
  for _ = 1, n - 1 do
    local comma = line:find(",", pos, true)
    if not comma then
      return nil
    end
    spans[#spans + 1] = { pos, comma - 1 }
    pos = comma + 1
  end
  spans[n] = { pos, #line }
  return spans
end

-- "Kind: value" -> kind, value, and the byte position where value starts.
local function key_value(line)
  local key, pos = line:match("^%s*([^:%[;]+):%s*()")
  if not key then
    return nil
  end
  return trim(key), line:sub(pos), pos
end

-- Fields of a Dialogue line as { name = value } plus their spans, or nil.
local function dialogue_fields(line, names)
  local kind, _, pos = key_value(line)
  if kind ~= "Dialogue" then
    return nil
  end
  local spans = field_spans(line, pos, #names)
  if not spans then
    return nil
  end
  local fields = {}
  for k, name in ipairs(names) do
    fields[name] = line:sub(spans[k][1], spans[k][2])
  end
  fields.text = fields.text:gsub("\r$", "")
  return fields, spans
end

--- Override blocks stripped and \N, \n, \h turned into plain text, for
-- players that only show plain captions.
function M.plain(raw)
  local s = raw:gsub("{[^}]*}", ""):gsub("\\[Nn]", "\n"):gsub("\\h", " ")
  return s
end

-- Event format of a parse result's script table, or the V4+ default.
local function event_format(script)
  return script and script.event_format or DEFAULT_EVENT_FORMAT
end

--- Parse a Dialogue line. Returns start, stop (seconds) or nil.
function M.parse_timing(line, script)
  local f = dialogue_fields(line, event_format(script))
  if not f then
    return nil
  end
  local start, stop = M.parse_ts(f.start or ""), M.parse_ts(f["end"] or "")
  if not (start and stop) then
    return nil
  end
  return start, stop
end

-- Cue from a Dialogue line (lnum 0-based), or nil.
local function make_cue(line, lnum, names)
  local f = dialogue_fields(line, names)
  local start = f and M.parse_ts(f.start or "")
  local stop = f and M.parse_ts(f["end"] or "")
  if not (start and stop) then
    return nil
  end
  return {
    start = start,
    stop = stop,
    text = M.plain(f.text),
    raw = f.text,
    style = trim(f.style or ""),
    layer = tonumber(f.layer) or 0,
    fields = f,
    ts_lnum = lnum,
    first = lnum,
    last = lnum,
  }
end

---------------------------------------------------------------------------
-- section handlers (table-driven): each gets the parse state, the line and
-- its 0-based number

local function script_info(st, line)
  local key, value = key_value(line)
  if key then
    st.script.info[key] = trim(value)
  end
end

local function styles(st, line)
  local key, value = key_value(line)
  if key == "Format" then
    st.script.style_format = field_names(value)
  elseif key == "Style" then
    local names = st.script.style_format or {}
    local style, k = {}, 0
    for v in (value .. ","):gmatch("([^,]*),") do
      k = k + 1
      style[names[k] or k] = trim(v)
    end
    local name = style.name or style[1]
    if name then
      st.script.styles[name] = style
    end
  end
end

local function events(st, line, lnum)
  local key, value = key_value(line)
  if key == "Format" then
    st.script.event_format = field_names(value)
  elseif key == "Dialogue" then
    local cue = make_cue(line, lnum, event_format(st.script))
    st.cues[#st.cues + 1] = cue
  end
end

local sections = {
  ["script info"] = script_info,
  ["v4+ styles"] = styles,
  ["v4 styles"] = styles,
  ["v4 styles+"] = styles,
  ["events"] = events,
}

local function header(line)
  local name = line:match("^%s*%[(.-)%]%s*$")
  return name and name:lower()
end

--- Parse buffer lines into a cue list in buffer order (not necessarily
-- sorted by time; ASS cues often overlap). Each cue: { start, stop, text,
-- raw, style, layer, fields, ts_lnum, first, last }, text being plain().
-- The list also carries `script`: { info, play_res_x, play_res_y,
-- style_format, styles = { [name] = { field = value } }, event_format }.
function M.parse(lines)
  local st = { cues = {}, script = { info = {}, styles = {} } }
  local handler = nil
  for i, line in ipairs(lines) do
    if i == 1 then
      line = line:gsub("^\239\187\191", "")
    end
    line = line:gsub("\r$", "")
    local name = header(line)
    if name then
      handler = sections[name]
    elseif handler then
      handler(st, line, i - 1)
    end
  end
  local script = st.script
  script.play_res_x = tonumber(script.info.PlayResX)
  script.play_res_y = tonumber(script.info.PlayResY)
  st.cues.script = script
  return st.cues
end

--- Rewrite the Start and End fields of a Dialogue line, leaving every other
-- byte as it was. `script` is the parse result's script table (for the
-- field order); the V4+ default order is assumed without it.
function M.replace_timing(line, start, stop, script)
  local names = event_format(script)
  local kind, _, pos = key_value(line)
  local spans = kind == "Dialogue" and field_spans(line, pos, #names)
  if not spans then
    return line
  end
  local edits = {}
  for k, name in ipairs(names) do
    local t = ({ start = start, ["end"] = stop })[name]
    if t then
      edits[#edits + 1] = { spans[k], M.format_ts(t) }
    end
  end
  -- right to left so earlier spans stay put
  table.sort(edits, function(a, b)
    return a[1][1] > b[1][1]
  end)
  for _, e in ipairs(edits) do
    local field = line:sub(e[1][1], e[1][2]):gsub(TS, e[2], 1)
    line = line:sub(1, e[1][1] - 1) .. field .. line:sub(e[1][2] + 1)
  end
  return line
end

--- Apply an in-place edit of a cue's line when only its text, style or
-- other non-timing fields changed. Returns true when the cue was updated.
function M.patch(list, cue, lines)
  local new = #lines == 1 and make_cue((lines[1]:gsub("\r$", "")), cue.ts_lnum, event_format(list.script))
  if not new or new.start ~= cue.start or new.stop ~= cue.stop then
    return false
  end
  for k, v in pairs(new) do
    cue[k] = v
  end
  return true
end

M.at_time = lookup.at_time
M.from_time = lookup.from_time

function M.at_line(list, lnum)
  return lookup.at_line(list, lnum, 0)
end

function M.nearest_line(list, lnum)
  return lookup.nearest_line(list, lnum, 0)
end

return M
