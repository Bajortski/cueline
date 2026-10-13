-- The runtime ssa syntax expects the standard ten event fields (nine commas
-- before Text). Files may trim the [Events] Format: line, so match however
-- many fields this file declares; re-checked on write in case it changes.
local buf = vim.api.nvim_get_current_buf()

local function event_commas()
  local in_events = false
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local section = line:match("^%s*%[(.-)%]%s*$")
    if section then
      in_events = section:lower() == "events"
    elseif in_events and line:match("^%s*Format%s*:") then
      local _, commas = line:gsub(",", "")
      return commas
    end
  end
  return 9
end

-- force: the syntax file was (re)sourced, so the stock rule is back
local function apply(force)
  if vim.b[buf].current_syntax ~= "ssa" then
    return
  end
  local n = event_commas()
  if not force and n == vim.b[buf].cueline_ssa_commas then
    return
  end
  vim.b[buf].cueline_ssa_commas = n
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("syntax clear ssaDialogueFields")
    vim.cmd(
      ([[syntax match ssaDialogueFields /\([^,]*,\)\{%d\}/ contained transparent skipwhite contains=ssaField,ssaDelimiter nextgroup=ssaText]]):format(
        n
      )
    )
  end)
end

apply(true)
vim.api.nvim_create_autocmd("BufWritePost", {
  buffer = buf,
  group = vim.api.nvim_create_augroup("cueline_ssa_syntax_" .. buf, { clear = true }),
  callback = function()
    apply(false)
  end,
})
