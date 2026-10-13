-- :CuelineExport against a fake YTSubConverter that mimics its CLI.
local H = require("helpers")
local describe, it, eq, truthy, wait = H.describe, H.it, H.eq, H.truthy, H.wait

local api, fn, uv = vim.api, vim.fn, vim.uv
local cl = require("cueline")
local export = require("cueline.export")

local dir = fn.tempname()
fn.mkdir(dir, "p")
dir = uv.fs_realpath(dir)

-- Fake converters. Each logs its arguments, so tests can see the temp input.
local log = dir .. "/args.log"
local function fake(name, body)
  local path = dir .. "/" .. name
  fn.writefile({ "#!/bin/sh", 'printf "%s\\n" "$@" > "' .. log .. '"', body }, path)
  uv.fs_chmod(path, tonumber("755", 8))
  return path
end

local fakes = {
  ok = fake("ok", 'cp "$1" "$2"'),
  error = fake("error", 'echo "Error occurred: Unrecognized line in .ass: garbage"; exit 0'),
  silent = fake("silent", "exit 0"),
  missing = fake("missing", 'echo "Specified source file not found"; exit 0'),
}

local ass = {
  "[Script Info]",
  "ScriptType: v4.00+",
  "",
  "[Events]",
  "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
  "Dialogue: 0,0:00:00.50,0:00:04.50,Default,,0,0,0,,hello",
}

local function read(path)
  local ok, lines = pcall(fn.readfile, path)
  return ok and lines or nil
end

local function make_buf(name, lines)
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(buf, name)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

--- Run an export to completion; returns ok, message.
local function run(buf, arg)
  local result
  export.export(buf, arg, function(ok, msg)
    result = { ok, msg }
  end)
  wait(5000, function() return result ~= nil end, "export to finish")
  return result[1], result[2]
end

local function use(bin)
  cl.setup({ ytsubconverter = bin })
end

describe("export", function()
  it("converts to .ytt next to the buffer's file by default", function()
    use(fakes.ok)
    local buf = make_buf(dir .. "/show.ass", ass)
    local ok, msg = run(buf)
    truthy(ok, msg)
    eq("exported " .. dir .. "/show.ytt", msg)
    eq(ass, read(dir .. "/show.ytt"))
  end)

  it("exports unsaved edits, not the file on disk", function()
    use(fakes.ok)
    local path = dir .. "/edited.ass"
    fn.writefile(ass, path)
    local buf = make_buf(path, ass)
    api.nvim_buf_set_lines(buf, -2, -1, false, { "Dialogue: 0,0:00:00.50,0:00:04.50,Default,,0,0,0,,edited" })
    truthy(vim.bo[buf].modified, "buffer should be modified")
    truthy(run(buf))
    eq("Dialogue: 0,0:00:00.50,0:00:04.50,Default,,0,0,0,,edited", read(dir .. "/edited.ytt")[6])
    eq(ass, read(path), "file on disk untouched")
  end)

  it("writes to an explicit path, relative to cwd", function()
    use(fakes.ok)
    fn.mkdir(dir .. "/out", "p")
    local buf = make_buf(dir .. "/rel.ass", ass)
    local cwd = fn.getcwd()
    fn.chdir(dir)
    local ok, msg = run(buf, "out/custom.srv3")
    fn.chdir(cwd)
    truthy(ok, msg)
    eq(ass, read(dir .. "/out/custom.srv3"))
    eq(nil, read(dir .. "/rel.ytt"))
    -- the converter is handed an output with the requested extension
    truthy(read(log)[2]:match("%.srv3$"), "temp output keeps the extension")
  end)

  it("expands ~ in the output path", function()
    eq(vim.fs.normalize("~") .. "/subs/x.ytt", export.output_path("/a/b.ass", "~/subs/x.ytt"))
  end)

  it("converts srt buffers through an .srt temp file, and removes it", function()
    use(fakes.ok)
    local srt = { "1", "00:00:01,000 --> 00:00:02,000", "hi", "" }
    local buf = make_buf(dir .. "/talk.srt", srt)
    truthy(run(buf))
    local input = read(log)[1]
    truthy(input:match("%.srt$"), "temp input is .srt: " .. input)
    eq(nil, uv.fs_stat(input), "temp input removed")
    eq(srt, read(dir .. "/talk.ytt"))
  end)

  it("reports an error the converter prints with exit 0, keeping the old output", function()
    local buf = make_buf(dir .. "/broken.ass", ass)
    fn.writefile({ "old" }, dir .. "/broken.ytt")
    use(fakes.error)
    local ok, msg = run(buf)
    eq(false, ok)
    eq("export failed: Error occurred: Unrecognized line in .ass: garbage", msg)
    eq({ "old" }, read(dir .. "/broken.ytt"))
    eq(nil, uv.fs_stat(read(log)[1]), "temp input removed")
  end)

  it("reports a 'not found' message from the converter", function()
    use(fakes.missing)
    local ok, msg = run(make_buf(dir .. "/nf.ass", ass))
    eq(false, ok)
    eq("export failed: Specified source file not found", msg)
  end)

  it("fails when the converter writes nothing", function()
    use(fakes.silent)
    local ok, msg = run(make_buf(dir .. "/silent.ass", ass))
    eq(false, ok)
    eq("export failed: YTSubConverter wrote no output", msg)
    eq(nil, read(dir .. "/silent.ytt"))
  end)

  it("needs an output path for unnamed buffers", function()
    use(fakes.ok)
    local buf = api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = "ssa"
    local ok, msg = run(buf)
    eq(false, ok)
    truthy(msg:find("pass an output path"), msg)
  end)
end)

describe("export: finding YTSubConverter", function()
  local saved = export.candidates

  it("names the option when the configured path isn't executable", function()
    use(dir .. "/nope")
    local ok, msg = run(make_buf(dir .. "/a.ass", ass))
    eq(false, ok)
    truthy(msg:find("`ytsubconverter`", 1, true), msg)
  end)

  it("says where to get it when nothing is found", function()
    use(nil)
    export.candidates = { function() return "" end, function() return dir .. "/nope" end }
    local path, err = export.find(nil)
    export.candidates = saved
    eq(nil, path)
    truthy(err:find("`ytsubconverter`", 1, true), err)
    truthy(err:find(export.download_url, 1, true), err)
  end)

  it("takes the first candidate that is executable", function()
    export.candidates = {
      function() return "" end,
      function() return dir .. "/nope" end,
      function() return fakes.ok end,
      function() return fakes.error end,
    }
    local path = export.find(nil)
    export.candidates = saved
    eq(fakes.ok, path)
  end)

  it(":CuelineExport runs the export", function()
    use(fakes.ok)
    local buf = make_buf(dir .. "/cmd.ass", ass)
    api.nvim_set_current_buf(buf)
    vim.cmd("CuelineExport")
    wait(5000, function() return read(dir .. "/cmd.ytt") ~= nil end, "command output")
    eq(ass, read(dir .. "/cmd.ytt"))
  end)
end)

fn.delete(dir, "rf")
