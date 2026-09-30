-- Per-buffer cue index: parsing, incremental text updates and the active-cue
-- highlight.
local srt = require("cueline.srt")

local api = vim.api
local M = {}

M.ns = api.nvim_create_namespace("cueline")

---@type table<integer, {cues: table, dirty: boolean, active: number?, mark: integer?}>
M.bufs = {}

function M.get(buf)
  return M.bufs[buf]
end

local function reparse(st, buf)
  st.cues = srt.parse(api.nvim_buf_get_lines(buf, 0, -1, false))
  st.dirty = false
end

--- Cue list for buf, reparsed lazily if structure changed.
function M.cues(buf)
  local st = M.bufs[buf]
  if not st then
    return nil
  end
  if st.dirty then
    reparse(st, buf)
  end
  return st.cues
end

local function is_text_line(line)
  return line:find("%S") ~= nil and not srt.parse_timing(line)
end

-- Try to apply an edit of lines [first, last) (same line count) as a pure
-- text change inside one cue. Returns the patched cue index or nil.
local function patch_text(st, buf, first, last)
  local i = srt.at_line(st.cues, first)
  local cue = st.cues[i or 0]
  if not cue or first < cue.first or last - 1 > cue.last then
    return nil
  end
  local lines = api.nvim_buf_get_lines(buf, cue.first, cue.last + 1, false)
  for _, l in ipairs(lines) do
    if not is_text_line(l) then
      return nil
    end
  end
  cue.text = table.concat(lines, "\n")
  return i
end

local function on_lines(_, buf, _, first, last, new_last)
  local st = M.bufs[buf]
  if not st then
    return true -- detach
  end
  local patched = not st.dirty and last == new_last and patch_text(st, buf, first, last)
  if not patched then
    st.dirty = true
  end
end

function M.attach(buf)
  if M.bufs[buf] then
    return M.bufs[buf]
  end
  local st = { dirty = true }
  M.bufs[buf] = st
  reparse(st, buf)
  api.nvim_buf_attach(buf, false, {
    on_lines = on_lines,
    on_detach = function()
      M.bufs[buf] = nil
    end,
    on_reload = function()
      local s = M.bufs[buf]
      if s then
        s.dirty = true
      end
    end,
  })
  return st
end

function M.detach(buf)
  if M.bufs[buf] then
    M.clear_highlight(buf)
    M.bufs[buf] = nil
  end
end

function M.clear_highlight(buf)
  local st = M.bufs[buf]
  if st and st.mark then
    pcall(api.nvim_buf_del_extmark, buf, M.ns, st.mark)
    st.mark = nil
  end
  if st then
    st.hl_key = nil
  end
end

--- Highlight cue i (or clear when nil). Cheap no-op when unchanged.
function M.highlight(buf, i)
  local st = M.bufs[buf]
  local cue = i and st.cues[i]
  local key = cue and (cue.ts_lnum .. ":" .. cue.last) or nil
  if key == st.hl_key then
    return
  end
  M.clear_highlight(buf)
  if not cue then
    return
  end
  local last = math.max(cue.last, cue.ts_lnum)
  st.mark = api.nvim_buf_set_extmark(buf, M.ns, cue.ts_lnum, 0, {
    end_row = last + 1,
    end_col = 0,
    hl_group = "CuelineActive",
    hl_eol = true,
    sign_text = "▶",
    sign_hl_group = "CuelineSign",
    priority = 150,
    strict = false,
  })
  st.hl_key = key
end

return M
