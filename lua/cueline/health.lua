local M = {}

local PLUGIN_ID = "net.bajortski.cueline"
local PLUGIN_DIR = vim.fn.expand("~/Library/Application Support/com.colliderli.iina/plugins")

local function check_nvim()
  if vim.fn.has("nvim-0.10") == 1 and vim.uv and vim.base64 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("needs Neovim 0.10+ (vim.uv, vim.base64)")
  end
  if pcall(require, "bit") then
    vim.health.ok("bit ops available")
  else
    vim.health.error("the `bit` module is missing; the WebSocket client needs it")
  end
end

local function find_iina_plugin()
  for name, kind in vim.fs.dir(PLUGIN_DIR) do
    local info = PLUGIN_DIR .. "/" .. name .. "/Info.json"
    local ok, data = pcall(vim.fn.readfile, info)
    if ok and (kind == "directory" or kind == "link") and table.concat(data, "\n"):find(PLUGIN_ID, 1, true) then
      return name
    end
  end
  return nil
end

local function check_iina()
  if vim.uv.fs_stat("/Applications/IINA.app") then
    vim.health.ok("IINA.app found")
  else
    vim.health.warn("IINA.app not in /Applications")
  end
  local name = vim.uv.fs_stat(PLUGIN_DIR) and find_iina_plugin()
  if not name then
    vim.health.warn("IINA cueline plugin not installed", { "iina-plugin link ~/git/cueline/iina" })
    return
  end
  vim.health.ok("IINA plugin installed: " .. name)
  local out = vim.fn.system({ "defaults", "read", "com.colliderli.iina", "PluginEnabled." .. PLUGIN_ID })
  if vim.trim(out) == "1" then
    vim.health.ok("IINA plugin enabled")
  else
    vim.health.warn("IINA plugin may be disabled", { "IINA > Settings > Plugins > enable cueline, then restart IINA" })
  end
end

local function check_export()
  local path, err = require("cueline.export").find(require("cueline").config.ytsubconverter)
  if path then
    vim.health.ok("YTSubConverter: " .. path)
  else
    vim.health.warn(err .. " (only needed for :CuelineExport)", {
      "if macOS blocks it, run: xattr -d com.apple.quarantine /path/to/YTSubConverter.app",
    })
  end
end

local function check_connection()
  local cl = require("cueline")
  local st = cl.status()
  if st.connection == "connected" then
    vim.health.ok(("connected on port %d; player file: %s"):format(st.port, tostring(st.file)))
    return
  end
  local hint = st.last_error and ("last error: " .. tostring(st.last_error)) or "run :CuelineConnect"
  vim.health.info(("not connected (port %d); %s"):format(cl.config.port, hint))
end

local function format_name(buffer, fmt)
  for ft, f in pairs(buffer.formats) do
    if f == fmt then
      return ft
    end
  end
  return "?"
end

local function check_buffers()
  local buffer = require("cueline.buffer")
  local fts = vim.tbl_keys(buffer.formats)
  table.sort(fts)
  vim.health.info("formats (by filetype): " .. table.concat(fts, ", ") .. "; ssa covers .ass and .ssa")
  local n = 0
  for buf, st in pairs(buffer.bufs) do
    n = n + 1
    local name = vim.api.nvim_buf_get_name(buf)
    vim.health.info(("%s (%s): %d cues"):format(name, format_name(buffer, st.fmt), #(st.cues or {})))
  end
  if n == 0 then
    vim.health.info("no subtitle buffers attached")
  end
end

function M.check()
  vim.health.start("cueline: environment")
  check_nvim()
  vim.health.start("cueline: IINA")
  check_iina()
  vim.health.start("cueline: export")
  check_export()
  vim.health.start("cueline: session")
  check_connection()
  check_buffers()
end

return M
