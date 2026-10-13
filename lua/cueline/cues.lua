-- Format-independent cue lookups. A cue list is what a format module's parse
-- returns: cues in buffer order, each { start, stop, text, ts_lnum, first,
-- last } with 0-based line numbers. Pure Lua, no Neovim API.
--
-- Time lookups go through a start-sorted index built lazily on the list, so
-- they work for unsorted, overlapping cues (ASS signs over dialogue) as well
-- as the usual sorted SRT case. Parsing always makes a fresh list, so the
-- cached index never goes stale; text-only patches keep it valid.
local M = {}

--- Index of the last element whose `key` (or the element itself when key is
-- nil) is <= value, in a list ordered by it; 0 if none.
function M.upper(list, key, value)
  local lo, hi = 1, #list
  local found = 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local v = list[mid]
    if key then
      v = v[key]
    end
    if v <= value then
      found = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return found
end

--- Start-sorted index for a cue list: order[k] is a cue index (ties keep
-- buffer order), starts[k] its start and reach[k] the latest stop among
-- order[1..k], which bounds how far back an active cue can be.
function M.index(cues)
  local idx = rawget(cues, "_index")
  if idx then
    return idx
  end
  local order = {}
  for i = 1, #cues do
    order[i] = i
  end
  table.sort(order, function(a, b)
    local sa, sb = cues[a].start, cues[b].start
    if sa ~= sb then
      return sa < sb
    end
    return a < b
  end)
  local starts, reach, far = {}, {}, -math.huge
  for k, i in ipairs(order) do
    starts[k] = cues[i].start
    far = math.max(far, cues[i].stop)
    reach[k] = far
  end
  idx = { order = order, starts = starts, reach = reach }
  cues._index = idx
  return idx
end

--- Cue indices active at time t (start <= t < stop), earliest start first.
-- Also returns the index position of the last cue starting at or before t.
function M.active(cues, t)
  local idx = M.index(cues)
  local p = M.upper(idx.starts, nil, t)
  local out = {}
  local k = p
  while k > 0 and idx.reach[k] > t do
    local i = idx.order[k]
    if t < cues[i].stop then
      table.insert(out, 1, i)
    end
    k = k - 1
  end
  return out, p
end

--- Latest-starting cue active at t, or nil. Same as the last of active(),
-- without building the list.
function M.at_time(cues, t)
  local idx = M.index(cues)
  local k = M.upper(idx.starts, nil, t)
  while k > 0 and idx.reach[k] > t do
    local i = idx.order[k]
    if t < cues[i].stop then
      return i
    end
    k = k - 1
  end
  return nil
end

--- The cue playing at t, else the next cue to start after t (#cues + 1 when
-- past the end).
function M.from_time(cues, t)
  local i = M.at_time(cues, t)
  if i then
    return i
  end
  local idx = M.index(cues)
  return idx.order[M.upper(idx.starts, nil, t) + 1] or #cues + 1
end

--- Cues for the player around t: everything active, then the next `ahead`
-- to start (one more when nothing is active, so a gap still gets ahead + 1).
function M.window(cues, t, ahead)
  local out, p = M.active(cues, t)
  local order = M.index(cues).order
  local last = math.min(#order, p + ahead + (#out == 0 and 1 or 0))
  for k = p + 1, last do
    out[#out + 1] = order[k]
  end
  return out
end

--- Cue index owning 0-based line `lnum`, or nil between cues. `lead` is how
-- many lines above the timestamp line belong to the cue (1 for SRT's index
-- number, 0 when the timing sits on the cue's own line).
function M.at_line(cues, lnum, lead)
  local i = M.upper(cues, "ts_lnum", lnum + lead)
  local cue = cues[i]
  if not cue then
    return nil
  end
  if lnum >= cue.ts_lnum - lead and lnum <= math.max(cue.last, cue.ts_lnum) then
    -- a lead line still inside the previous cue belongs to that cue
    if lnum < cue.ts_lnum and i > 1 and cues[i - 1].last >= lnum then
      return i - 1
    end
    return i
  end
  return nil
end

--- Nearest cue at or after 0-based line lnum (for cursor on blank lines).
function M.nearest_line(cues, lnum, lead)
  local i = M.at_line(cues, lnum, lead)
  if i then
    return i
  end
  local j = M.upper(cues, "ts_lnum", lnum) + 1
  if j <= #cues then
    return j
  end
  return nil
end

return M
