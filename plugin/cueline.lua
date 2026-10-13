if vim.g.loaded_cueline then
  return
end
vim.g.loaded_cueline = true

local function cl()
  return require("cueline")
end

local function which_arg(a)
  return (a == "end" or a == "stop") and "end" or "start"
end

local commands = {
  CuelineConnect = { function(o) cl().connect(o.args ~= "" and o.args or nil) end, { nargs = "?" } },
  CuelineDisconnect = { function() cl().disconnect() end, {} },
  CuelineAttach = { function() cl().attach(0) end, {} },
  CuelineDetach = { function() cl().detach(0) end, {} },
  CuelineSeek = { function() cl().seek() end, {} },
  CuelineReplay = { function() cl().seek(true) end, {} },
  CuelinePause = { function() cl().toggle_pause() end, {} },
  CuelineNudge = { function(o) cl().nudge(o.args ~= "" and o.args or nil) end, { nargs = "?" } },
  CuelineSpeed = { function(o) cl().speed(o.args) end, { nargs = 1 } },
  CuelineOpen = { function(o) cl().open_media(o.args) end, { nargs = "?", complete = "file" } },
  CuelineFollow = {
    function(o)
      local v = ({ on = true, off = false })[o.args]
      cl().follow(v)
    end,
    { nargs = "?", complete = function() return { "on", "off" } end },
  },
  CuelineAdjust = {
    function(o)
      cl().adjust(which_arg(o.fargs[1]), o.fargs[2] or 0)
    end,
    { nargs = "+", complete = function() return { "start", "end" } end },
  },
  CuelineStamp = {
    function(o) cl().stamp(which_arg(o.fargs[1])) end,
    { nargs = 1, complete = function() return { "start", "end" } end },
  },
  CuelineStatus = { function() print(vim.inspect(cl().status())) end, {} },
}

for name, def in pairs(commands) do
  vim.api.nvim_create_user_command(name, def[1], def[2])
end

-- subtitle filetypes cueline attaches to (cueline.buffer.formats has the
-- parser for each); Neovim gives .ass and .ssa files the `ssa` filetype
local filetypes = { srt = true, ssa = true }

local function maybe_attach(buf)
  local c = cl()
  if c.config.auto_attach then
    c.attach(buf)
  end
end

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("cueline_ft", { clear = true }),
  pattern = vim.tbl_keys(filetypes),
  callback = function(ev)
    maybe_attach(ev.buf)
  end,
})

-- lazy-loaded after the buffer's FileType already fired; scheduled so a
-- setup() call that follows plugin loading (lazy.nvim `opts`) applies first
vim.schedule(function()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and filetypes[vim.bo[buf].filetype] then
      maybe_attach(buf)
    end
  end
end)
