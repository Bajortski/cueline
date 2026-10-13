-- SRT parsing and formatting. Pure Lua, no Neovim API, so it can be tested
-- (and benchmarked) on its own.
local lookup = require("cueline.cues")

local M = {}

local TS = "(%d+):(%d%d):(%d%d)[,.](%d%d%d)"
local ARROW = "^%s*" .. TS .. "%s*%-%->%s*" .. TS

local function secs(h, m, s, ms)
  return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + tonumber(ms) / 1000
end

--- Parse a timestamp line. Returns start, stop (seconds) or nil.
function M.parse_timing(line)
  local h1, m1, s1, ms1, h2, m2, s2, ms2 = line:match(ARROW)
  if not h1 then
    return nil
  end
  return secs(h1, m1, s1, ms1), secs(h2, m2, s2, ms2)
end

--- Format seconds as HH:MM:SS,mmm.
function M.format_ts(t)
  if t < 0 then
    t = 0
  end
  local total_ms = math.floor(t * 1000 + 0.5)
  local ms = total_ms % 1000
  local s = math.floor(total_ms / 1000)
  return string.format("%02d:%02d:%02d,%03d", math.floor(s / 3600), math.floor(s / 60) % 60, s % 60, ms)
end

function M.format_timing(start, stop)
  return M.format_ts(start) .. " --> " .. M.format_ts(stop)
end

-- Collect the text lines following a timestamp line. Returns the cue's text
-- and the 1-based index of its last line (the timestamp line if empty).
local function collect_text(lines, ts_idx)
  local i = ts_idx + 1
  local n = #lines
  local parts = {}
  while i <= n and lines[i]:find("%S") do
    -- a following timestamp line with no blank separator starts a new cue
    if lines[i]:find("%-%->") and M.parse_timing(lines[i]) then
      break
    end
    parts[#parts + 1] = lines[i]
    i = i + 1
  end
  return table.concat(parts, "\n"), i - 1
end

--- Parse buffer lines into an ordered cue list.
-- Each cue: { start, stop, text, ts_lnum, first, last } where line numbers
-- are 0-based (extmark friendly): ts_lnum is the timestamp line, first/last
-- span the text lines (first > last when the cue has no text).
function M.parse(lines)
  local cues = {}
  local i, n = 1, #lines
  while i <= n do
    local line = lines[i]
    local start, stop
    if line:find("%-%->") then
      start, stop = M.parse_timing(line)
    end
    if start then
      local text, last = collect_text(lines, i)
      cues[#cues + 1] = { start = start, stop = stop, text = text, ts_lnum = i - 1, first = i, last = last - 1 }
      i = math.max(last, i) + 1
    else
      i = i + 1
    end
  end
  return cues
end

--- Rewrite the timing on a timestamp line, keeping anything after the
-- second timestamp (e.g. position hints).
function M.replace_timing(line, start, stop)
  local rest = select(9, line:match(ARROW .. "(.*)$")) or ""
  return M.format_timing(start, stop) .. rest
end

-- Lookups live in cueline.cues; SRT puts the index number on the line
-- above the timestamp, so that line belongs to the cue too.
M.at_time = lookup.at_time
M.from_time = lookup.from_time

function M.at_line(list, lnum)
  return lookup.at_line(list, lnum, 1)
end

function M.nearest_line(list, lnum)
  return lookup.nearest_line(list, lnum, 1)
end

return M
