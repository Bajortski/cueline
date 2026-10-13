-- cueline: export the buffer to YouTube's styled timed text (.ytt / srv3)
-- with YTSubConverter's headless CLI.
--
-- The converter always exits 0 and reports errors on stdout, so success is
-- judged by its output file appearing and stdout staying free of errors. It
-- writes into a private temp dir; the result is copied over the real output
-- only on success, so a failed export never clobbers a previous one.
local M = {}

local api, fn, uv = vim.api, vim.fn, vim.uv

M.download_url = "https://github.com/arcusmaximus/YTSubConverter/releases"

local APP_BIN = "YTSubConverter.app/Contents/MacOS/YTSubConverter"

--- Where to look when the `ytsubconverter` option is unset, in order.
M.candidates = {
  function() return fn.exepath("YTSubConverter") end,
  function() return "/Applications/" .. APP_BIN end,
  function() return fn.expand("~/Applications/") .. APP_BIN end,
}

-- buffer extension or filetype -> extension the converter reads
local input_exts = { srt = "srt", ass = "ass", ssa = "ass" }

-- stdout lines that mean the conversion failed
local error_patterns = { "[Ee]rror", "not found" }

local function executable(p)
  return p ~= nil and p ~= "" and fn.executable(p) == 1
end

--- Resolve the converter: the configured path, else the first candidate
--- that exists. Returns path, or nil and an error message.
function M.find(configured)
  if configured then
    local p = vim.fs.normalize(configured)
    if executable(p) then
      return p
    end
    return nil, ("`ytsubconverter` is set to %s, which isn't an executable"):format(configured)
  end
  for _, candidate in ipairs(M.candidates) do
    local p = candidate()
    if executable(p) then
      return p
    end
  end
  return nil, ("YTSubConverter not found. Install it from %s, or set the `ytsubconverter` option to its path"):format(
    M.download_url
  )
end

--- Output path: `arg` (with ~ and $VARS expanded, relative to cwd), else the
--- buffer's file with a .ytt extension.
function M.output_path(name, arg)
  if arg and arg ~= "" then
    return fn.fnamemodify(vim.fs.normalize(arg), ":p")
  end
  if name == "" then
    return nil
  end
  return fn.fnamemodify(name, ":p:r") .. ".ytt"
end

local function input_ext(buf, name)
  return input_exts[fn.fnamemodify(name, ":e"):lower()] or input_exts[vim.bo[buf].filetype]
end

--- Everything a conversion needs, with the buffer written to a temp file.
local function prepare(buf, arg)
  local bin, err = M.find(require("cueline").config.ytsubconverter)
  if not bin then
    return nil, err
  end
  local name = api.nvim_buf_get_name(buf)
  local ext = input_ext(buf, name)
  if not ext then
    return nil, "export needs an .ass, .ssa or .srt buffer"
  end
  local out = M.output_path(name, arg)
  if not out then
    return nil, "buffer has no file name; pass an output path to :CuelineExport"
  end
  local dir = fn.tempname()
  fn.mkdir(dir, "p")
  local out_ext = fn.fnamemodify(out, ":e")
  local job = {
    bin = bin,
    dir = dir,
    input = dir .. "/input." .. ext,
    tmp_out = dir .. "/output" .. (out_ext ~= "" and ("." .. out_ext) or ""),
    out = out,
  }
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  -- YTSubConverter needs every standard event field
  fn.writefile(ext == "srt" and lines or require("cueline.ass").normalize(lines), job.input)
  return job
end

local function stdout_error(stdout)
  for _, line in ipairs(vim.split(stdout or "", "\n", { trimempty = true })) do
    for _, pat in ipairs(error_patterns) do
      if line:find(pat) then
        return vim.trim(stdout)
      end
    end
  end
  return nil
end

local function failure(res, tmp_out)
  local err = stdout_error(res.stdout)
  if err then
    return err
  end
  local said = vim.trim((res.stdout or "") .. "\n" .. (res.stderr or ""))
  said = said ~= "" and (": " .. said) or ""
  if res.code ~= 0 or res.signal ~= 0 then
    return ("YTSubConverter exited with code %d%s"):format(res.code, said)
  end
  if not uv.fs_stat(tmp_out) then
    return "YTSubConverter wrote no output" .. said
  end
  return nil
end

local function finish(job, res, done)
  local err = failure(res, job.tmp_out)
  if not err then
    local ok, cerr = uv.fs_copyfile(job.tmp_out, job.out)
    err = not ok and ("couldn't write " .. job.out .. ": " .. tostring(cerr)) or nil
  end
  fn.delete(job.dir, "rf")
  if err then
    done(false, "export failed: " .. err)
  else
    done(true, "exported " .. job.out)
  end
end

--- Convert buffer `buf`'s current contents (unsaved edits included) to `arg`,
--- or next to its file as .ytt. Runs asynchronously; notifies the result and
--- then calls on_done(ok, message) if given.
function M.export(buf, arg, on_done)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local function done(ok, msg)
    vim.notify("cueline: " .. msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    if on_done then
      on_done(ok, msg)
    end
  end
  local job, err = prepare(buf, arg)
  if not job then
    return done(false, err)
  end
  local ok, spawn_err = pcall(vim.system, { job.bin, job.input, job.tmp_out }, { text = true, timeout = 60000 },
    function(res)
      vim.schedule(function()
        finish(job, res, done)
      end)
    end)
  if not ok then
    fn.delete(job.dir, "rf")
    done(false, "export failed: " .. tostring(spawn_err))
  end
end

return M
