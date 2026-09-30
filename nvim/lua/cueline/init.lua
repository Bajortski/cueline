-- cueline: transcript (SRT) editing against a live IINA player.
local srt = require("cueline.srt")
local buffer = require("cueline.buffer")
local client = require("cueline.client")

local api, fn, uv = vim.api, vim.fn, vim.uv
local M = {}

M.version = "0.1.0"

local defaults = {
  host = "127.0.0.1",
  port = 10427,
  reconnect = true, -- keep retrying while :CuelineConnect is in effect
  auto_attach = true, -- attach to every buffer with filetype srt
  auto_connect = false, -- connect when the first SRT buffer attaches
  follow = true, -- move the cursor along with playback
  follow_idle_ms = 2500, -- ...but not within this long of your own cursor moves/edits
  preview_on_cursor = true, -- while paused, preview the cue under the cursor
  hide_subs = true, -- hide IINA's own subtitle track while previewing
  lookahead = 3, -- cues sent ahead of playback so the player switches on time
  nudge = 2, -- seconds for the nudge keys
  adjust = 0.1, -- seconds for the timestamp adjust keys
  seek_on_adjust = true, -- after moving a cue's start, seek there to hear it
  media_exts = { "m4a", "mp3", "wav", "flac", "ogg", "opus", "aac", "mp4", "mkv", "mov", "webm", "m4v" },
  media_dirs = { ".", "../audio", "../video", "../media" },
  keymaps = {
    seek = "<CR>",
    replay = "<localleader>r",
    toggle_pause = "<localleader>p",
    follow = "<localleader>f",
    back = "<localleader>h",
    forward = "<localleader>l",
    start_earlier = "<localleader>[",
    start_later = "<localleader>]",
    end_earlier = "<localleader>{",
    end_later = "<localleader>}",
    stamp_start = "<localleader>S",
    stamp_end = "<localleader>E",
  },
}

M.config = vim.deepcopy(defaults)

M.player = { pos = 0, paused = true, speed = 1, file = nil, duration = nil }
M.shown = nil -- last text the player reported as rendered
M.track = nil -- the SRT buffer following the player

local last_sent = nil
local follow_pos = nil -- where follow last put the cursor
local last_user = 0

local function user_activity()
  last_user = uv.now()
end

local function notify(msg, level)
  vim.notify("cueline: " .. msg, level or vim.log.levels.INFO)
end

---------------------------------------------------------------------------
-- tracked buffer and cue lookup

local function track_buf()
  if M.track and buffer.get(M.track) and api.nvim_buf_is_valid(M.track) then
    return M.track
  end
  local cur = api.nvim_get_current_buf()
  if buffer.get(cur) then
    M.track = cur
    return cur
  end
  return nil
end

local function win_for(buf)
  if api.nvim_win_get_buf(0) == buf then
    return api.nvim_get_current_win()
  end
  local wins = fn.win_findbuf(buf)
  return wins[1]
end

--- Cue under the cursor in the tracked buffer: index, cue, buf.
local function cursor_cue()
  local buf = track_buf()
  local win = buf and win_for(buf)
  if not win then
    return nil
  end
  local cues = buffer.cues(buf)
  local i = srt.nearest_line(cues, api.nvim_win_get_cursor(win)[1] - 1)
  return i, cues[i or 0], buf
end

---------------------------------------------------------------------------
-- preview sync: what the player should be showing

local function window_msg(cues)
  local i0 = srt.from_time(cues, M.position())
  local items = {}
  for i = i0, math.min(#cues, i0 + M.config.lookahead) do
    local c = cues[i]
    items[#items + 1] = { id = i, start = c.start, ["end"] = c.stop, text = c.text }
  end
  return { type = "cues", items = items }
end

local function cursor_msg()
  if not (M.player.paused and M.config.preview_on_cursor) then
    return nil
  end
  local i, cue = cursor_cue()
  if not cue then
    return nil
  end
  return { type = "cue", id = i, start = cue.start, ["end"] = cue.stop, text = cue.text, sticky = true }
end

function M.sync_preview(force)
  local buf = track_buf()
  if client.status ~= "connected" or not buf then
    return
  end
  local msg = cursor_msg() or window_msg(buffer.cues(buf))
  local encoded = vim.json.encode(msg)
  if force or encoded ~= last_sent then
    last_sent = encoded
    client.conn:send(encoded)
  end
end

---------------------------------------------------------------------------
-- following playback

local function follow_cursor(buf, cue)
  local win = win_for(buf)
  local mode = api.nvim_get_mode().mode
  if not win or mode:sub(1, 1) ~= "n" or uv.now() - last_user < M.config.follow_idle_ms then
    return
  end
  local row = (cue.last >= cue.first and cue.first or cue.ts_lnum) + 1
  if api.nvim_win_get_cursor(win)[1] == row then
    return
  end
  follow_pos = { win, row }
  api.nvim_win_call(win, function()
    local top, bot = fn.line("w0"), fn.line("w$")
    api.nvim_win_set_cursor(win, { row, 0 })
    if row < top or row > bot then
      vim.cmd("normal! zz")
    end
  end)
end

--- Recompute the active cue for the current player position.
function M.refresh()
  local buf = track_buf()
  if not buf then
    return
  end
  local st = buffer.get(buf)
  local cues = buffer.cues(buf)
  local i = srt.at_time(cues, M.position())
  buffer.highlight(buf, i)
  -- keyed by start time so a reparse alone never counts as a cue change
  local key = i and cues[i].start
  if key ~= st.active then
    st.active = key
    if i and M.config.follow then
      follow_cursor(buf, cues[i])
    end
  end
  M.sync_preview()
end

---------------------------------------------------------------------------
-- incoming messages (table-driven)

local function apply_player(p)
  if type(p) ~= "table" then
    return
  end
  for _, k in ipairs({ "pos", "paused", "speed", "file", "duration" }) do
    if p[k] ~= nil then
      M.player[k] = p[k]
    end
  end
  if p.pos ~= nil then
    M.player.at = uv.now()
  end
end

-- Between reports, extrapolate: IINA reports every ~100 ms for video but
-- only every few hundred ms for audio-only files.
local clock = nil

local function stop_clock()
  if clock then
    clock:stop()
    clock:close()
    clock = nil
  end
end

local function update_clock()
  local run = client.status == "connected" and not M.player.paused
  if run and not clock then
    clock = uv.new_timer()
    clock:start(100, 100, vim.schedule_wrap(M.refresh))
  elseif not run then
    stop_clock()
  end
end

--- Best estimate of the player position now, in seconds.
function M.position()
  local p = M.player
  local pos = p.pos or 0
  if p.paused or not p.at then
    return pos
  end
  pos = pos + (uv.now() - p.at) / 1000 * (p.speed or 1)
  return p.duration and math.min(pos, p.duration) or pos
end

local function stem(path)
  return path and fn.fnamemodify(path, ":t:r") or nil
end

local function check_media()
  local buf = track_buf()
  local want = buf and stem(api.nvim_buf_get_name(buf))
  local have = stem(M.player.file)
  if want and have and want ~= have then
    notify(("player has %s, transcript is %s"):format(have, want), vim.log.levels.WARN)
  end
end

client.handlers = {
  hello = function(msg)
    apply_player(msg.player)
    client.send({ type = "config", hide_subs = M.config.hide_subs })
    update_clock()
    M.refresh()
  end,
  time = function(msg)
    apply_player(msg)
    update_clock()
    M.refresh()
  end,
  state = function(msg)
    apply_player(msg)
    update_clock()
    M.refresh()
  end,
  file = function(msg)
    apply_player(msg)
    check_media()
    M.refresh()
    M.sync_preview(true)
  end,
  shown = function(msg)
    M.shown = msg.text
    M.subs_hidden = msg.subs_hidden
  end,
  error = function(msg)
    notify("player: " .. tostring(msg.message), vim.log.levels.WARN)
  end,
  notice = function(msg)
    M.last_notice = msg.message
    notify(tostring(msg.message), vim.log.levels.WARN)
  end,
  _opened = function()
    notify("connected to IINA on port " .. client.opts.port)
    last_sent = nil
    client.send({ type = "hello", client = "cueline.nvim", version = M.version })
  end,
  _closed = function(was, reason)
    last_sent = nil
    stop_clock()
    if was == "connected" then
      notify("disconnected (" .. tostring(reason) .. ")", vim.log.levels.WARN)
    end
  end,
}

---------------------------------------------------------------------------
-- actions

local function require_connection()
  if client.status ~= "connected" then
    notify("not connected (:CuelineConnect)", vim.log.levels.WARN)
    return false
  end
  return true
end

local function send(msg)
  return require_connection() and client.send(msg)
end

function M.connect(port)
  client.connect({ host = M.config.host, port = tonumber(port) or M.config.port, reconnect = M.config.reconnect })
end

function M.disconnect()
  client.disconnect()
end

function M.seek(play)
  user_activity()
  local _, cue = cursor_cue()
  if not cue then
    return notify("no cue under cursor", vim.log.levels.WARN)
  end
  send({ type = "seek", pos = cue.start, play = play or nil })
end

function M.toggle_pause()
  send({ type = "toggle-pause" })
end

function M.nudge(delta)
  send({ type = "nudge", delta = tonumber(delta) or M.config.nudge })
end

function M.speed(x)
  send({ type = "speed", speed = tonumber(x) or 1 })
end

function M.follow(on)
  if on == nil then
    M.config.follow = not M.config.follow
  else
    M.config.follow = on
  end
  last_user = 0
  notify("follow " .. (M.config.follow and "on" or "off"))
end

-- which = "start" | "end"; value = absolute seconds
local function set_timing(which, value)
  user_activity()
  local i, cue, buf = cursor_cue()
  if not cue then
    return notify("no cue under cursor", vim.log.levels.WARN)
  end
  local start, stop = cue.start, cue.stop
  if which == "start" then
    start = math.max(0, math.min(value, stop - 0.001))
  else
    stop = math.max(value, start + 0.001)
  end
  local line = api.nvim_buf_get_lines(buf, cue.ts_lnum, cue.ts_lnum + 1, false)[1]
  api.nvim_buf_set_lines(buf, cue.ts_lnum, cue.ts_lnum + 1, false, { srt.replace_timing(line, start, stop) })
  buffer.cues(buf) -- reparse now so the refresh below sees the new timing
  if which == "start" and M.config.seek_on_adjust and client.status == "connected" then
    client.send({ type = "seek", pos = start })
  end
  M.refresh()
  return i
end

function M.adjust(which, delta)
  local _, cue = cursor_cue()
  if cue then
    set_timing(which, (which == "start" and cue.start or cue.stop) + (tonumber(delta) or 0))
  end
end

function M.stamp(which)
  if require_connection() then
    set_timing(which, M.position())
  end
end

--- Media file matching an SRT path, or nil.
function M.find_media(path)
  local dir, base = fn.fnamemodify(path, ":p:h"), fn.fnamemodify(path, ":t:r")
  for _, sub in ipairs(M.config.media_dirs) do
    for _, ext in ipairs(M.config.media_exts) do
      local cand = vim.fs.normalize(dir .. "/" .. sub .. "/" .. base .. "." .. ext)
      if uv.fs_stat(cand) then
        return cand
      end
    end
  end
  return nil
end

function M.open_media(path)
  local buf = track_buf() or api.nvim_get_current_buf()
  path = (path and path ~= "") and fn.fnamemodify(path, ":p") or M.find_media(api.nvim_buf_get_name(buf))
  if not path then
    return notify("no matching media found; pass a path", vim.log.levels.WARN)
  end
  if client.status == "connected" then
    return client.send({ type = "open", path = path })
  end
  vim.system({ "open", "-a", "IINA", path })
  M.connect()
end

function M.status()
  local p = M.player
  return {
    connection = client.status,
    last_error = client.last_error,
    port = client.opts.port,
    file = p.file,
    pos = p.pos,
    paused = p.paused,
    follow = M.config.follow,
    track = M.track and api.nvim_buf_get_name(M.track) or nil,
    shown = M.shown,
    subs_hidden = M.subs_hidden,
  }
end

--- Short string for statuslines.
function M.statusline()
  if client.status ~= "connected" then
    return client.wants_connection() and "cue:…" or ""
  end
  return ("%s %s"):format(M.player.paused and "⏸" or "▶", srt.format_ts(M.position()):sub(1, 8))
end

---------------------------------------------------------------------------
-- buffer attach, keymaps, autocmds

local keymap_actions = {
  seek = { M.seek, "Seek player to cue" },
  replay = { function() M.seek(true) end, "Play from cue start" },
  toggle_pause = { M.toggle_pause, "Play/pause" },
  follow = { function() M.follow() end, "Toggle follow" },
  back = { function() M.nudge(-M.config.nudge) end, "Nudge back" },
  forward = { function() M.nudge(M.config.nudge) end, "Nudge forward" },
  start_earlier = { function() M.adjust("start", -M.config.adjust) end, "Cue start earlier" },
  start_later = { function() M.adjust("start", M.config.adjust) end, "Cue start later" },
  end_earlier = { function() M.adjust("end", -M.config.adjust) end, "Cue end earlier" },
  end_later = { function() M.adjust("end", M.config.adjust) end, "Cue end later" },
  stamp_start = { function() M.stamp("start") end, "Set cue start to player time" },
  stamp_end = { function() M.stamp("end") end, "Set cue end to player time" },
}

local function set_keymaps(buf)
  if not M.config.keymaps then
    return
  end
  for name, lhs in pairs(M.config.keymaps) do
    local action = keymap_actions[name]
    if lhs and action then
      vim.keymap.set("n", lhs, action[1], { buffer = buf, desc = "cueline: " .. action[2] })
    end
  end
end

local function on_cursor()
  local win = api.nvim_get_current_win()
  local moved_by_follow = follow_pos and follow_pos[1] == win and follow_pos[2] == api.nvim_win_get_cursor(win)[1]
  if not moved_by_follow then
    follow_pos = nil
    user_activity()
  end
  M.sync_preview()
end

local function on_edit()
  user_activity()
  M.refresh()
end

function M.attach(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if buffer.get(buf) then
    return
  end
  buffer.attach(buf)
  M.track = buf
  set_keymaps(buf)
  local group = api.nvim_create_augroup("cueline_buf_" .. buf, { clear = true })
  local au = function(ev, cb)
    api.nvim_create_autocmd(ev, { group = group, buffer = buf, callback = cb })
  end
  au({ "CursorMoved", "CursorMovedI" }, on_cursor)
  au({ "TextChanged", "TextChangedI" }, on_edit)
  au("BufEnter", function()
    M.track = buf
    M.refresh()
  end)
  au("BufWipeout", function()
    buffer.detach(buf)
    api.nvim_del_augroup_by_id(group)
  end)
  if M.config.auto_connect and client.status == "disconnected" then
    M.connect()
  end
  M.refresh()
end

function M.detach(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  buffer.detach(buf)
  pcall(api.nvim_del_augroup_by_name, "cueline_buf_" .. buf)
end

local function set_highlights()
  api.nvim_set_hl(0, "CuelineActive", { link = "DiffChange", default = true })
  api.nvim_set_hl(0, "CuelineSign", { link = "DiagnosticInfo", default = true })
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  if opts and opts.keymaps == false then
    M.config.keymaps = false
  end
  set_highlights()
  api.nvim_create_autocmd("ColorScheme", {
    group = api.nvim_create_augroup("cueline_hl", { clear = true }),
    callback = set_highlights,
  })
end

set_highlights()

return M
