-- Per-buffer cue index: parsing, incremental text updates and the active-cue
-- highlight.
local srt = require("cueline.srt")
local ass = require("cueline.ass")

local api = vim.api
local M = {}

M.ns = api.nvim_create_namespace("cueline")

--- Format module per filetype. Each has parse, parse_timing, format_ts,
-- format_timing, replace_timing, patch, at_time, from_time, at_line,
-- nearest_line and step.
M.formats = { srt = srt, ssa = ass }

-- fallback for :CuelineAttach on a buffer whose filetype isn't one of ours
local by_ext = { srt = srt, ass = ass, ssa = ass }

---@type table<integer, {fmt: table, cues: table, dirty: boolean, active: number?, marks: integer[]?}>
M.bufs = {}

function M.get(buf)
  return M.bufs[buf]
end

local function reparse(st, buf)
  st.cues = st.fmt.parse(api.nvim_buf_get_lines(buf, 0, -1, false))
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

--- Format module for buf: by filetype, else by file extension, else SRT.
function M.format_for(buf)
  local ext = vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":e"):lower()
  return M.formats[vim.bo[buf].filetype] or by_ext[ext] or srt
end

--- Format module of an attached buffer.
function M.fmt(buf)
  local st = M.bufs[buf]
  return st and st.fmt
end

-- Try to apply an edit of lines [first, last) (same line count) as a pure
-- text change inside one cue. Returns the patched cue index or nil.
local function patch_text(st, buf, first, last)
  local i = st.fmt.at_line(st.cues, first)
  local cue = st.cues[i or 0]
  if not cue or first < cue.first or last - 1 > cue.last then
    return nil
  end
  local lines = api.nvim_buf_get_lines(buf, cue.first, cue.last + 1, false)
  return st.fmt.patch(st.cues, cue, lines) and i or nil
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
  local st = { dirty = true, fmt = M.format_for(buf) }
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
  if not st then
    return
  end
  for _, mark in ipairs(st.marks or {}) do
    pcall(api.nvim_buf_del_extmark, buf, M.ns, mark)
  end
  st.marks = nil
  st.hl_key = nil
end

local function mark_cue(buf, cue)
  return api.nvim_buf_set_extmark(buf, M.ns, cue.ts_lnum, 0, {
    end_row = math.max(cue.last, cue.ts_lnum) + 1,
    end_col = 0,
    hl_group = "CuelineActive",
    hl_eol = true,
    sign_text = "▶",
    sign_hl_group = "CuelineSign",
    priority = 150,
    strict = false,
  })
end

--- Highlight the cues whose indices are in `list` (clear when nil or
-- empty). Cheap no-op when unchanged.
function M.highlight(buf, list)
  local st = M.bufs[buf]
  local cues = {}
  local keys = {}
  for _, i in ipairs(list or {}) do
    local cue = st.cues[i]
    if cue then
      cues[#cues + 1] = cue
      keys[#keys + 1] = cue.ts_lnum .. ":" .. cue.last
    end
  end
  local key = table.concat(keys, ",")
  if key == st.hl_key then
    return
  end
  M.clear_highlight(buf)
  st.marks = {}
  for k, cue in ipairs(cues) do
    st.marks[k] = mark_cue(buf, cue)
  end
  st.hl_key = key
end

return M
