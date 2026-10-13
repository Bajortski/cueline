-- ASS/SSA parsing, overlapping-cue lookups, and an .ass buffer against a
-- mock IINA server.
local H = require("helpers")
local mock = require("mock_server")
local ass = require("cueline.ass")
local lookup = require("cueline.cues")
local describe, it, eq, near, wait = H.describe, H.it, H.eq, H.near, H.wait

local api = vim.api
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local fixture = vim.fn.readfile(root .. "/test/fixtures/sample.ass")

local function events(format, ...)
  return vim.list_extend({ "[Events]", format }, { ... })
end

describe("ass.parse", function()
  local cues = ass.parse(fixture)
  it("reads Dialogue lines and skips Comment lines", function()
    eq(4, #cues)
    eq({ 15, 16, 18, 19 }, { cues[1].ts_lnum, cues[2].ts_lnum, cues[3].ts_lnum, cues[4].ts_lnum })
    eq({ 15, 15 }, { cues[1].first, cues[1].last })
  end)
  it("parses centisecond timestamps", function()
    near(0.5, cues[1].start)
    near(4.5, cues[1].stop)
    near(15, cues[3].stop)
  end)
  it("keeps raw text, style and layer, and strips overrides from text", function()
    eq("Tonight we roll for {\\i1}initiative{\\i0}", cues[2].raw)
    eq("Tonight we roll for initiative", cues[2].text)
    eq("Welcome back to the show\n(cue 1 second line)", cues[1].text)
    eq("THE TAVERN", cues[3].text)
    eq({ "Sign", 1 }, { cues[3].style, cues[3].layer })
  end)
  it("keeps commas in the text field", function()
    eq("Wait, who brought the dice?", cues[4].text)
  end)
  it("reads Script Info and styles", function()
    eq({ 1920, 1080 }, { cues.script.play_res_x, cues.script.play_res_y })
    eq("cueline sample", cues.script.info.Title)
    eq("64", cues.script.styles.Default.fontsize)
    eq("8", cues.script.styles.Sign.alignment)
    eq("name", cues.script.style_format[1])
  end)
  it("follows a reordered Format line", function()
    local c = ass.parse(events(
      "Format: Start, End, Style, Text",
      "Dialogue: 0:00:01.00,0:00:02.50,Alt,hello, world"
    ))
    eq(1, #c)
    near(1, c[1].start)
    near(2.5, c[1].stop)
    eq({ "Alt", "hello, world", 0 }, { c[1].style, c[1].text, c[1].layer })
  end)
  it("turns \\N, \\n and \\h into plain text", function()
    eq("a\nb\nc d", ass.plain("a\\Nb\\nc\\hd"))
  end)
  it("finds no cues without an [Events] section", function()
    local c = ass.parse({ "[Script Info]", "PlayResX: 640", "Dialogue: 0,0:00:01.00,0:00:02.00,,,0,0,0,,stray" })
    eq(0, #c)
    eq(640, c.script.play_res_x)
  end)
  it("handles CRLF line endings and a BOM", function()
    local lines = {
      "\239\187\191[Script Info]\r",
      "PlayResY: 720\r",
      "[Events]\r",
      "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r",
      "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,crlf text\r",
    }
    local c = ass.parse(lines)
    eq(720, c.script.play_res_y)
    eq(1, #c)
    eq("crlf text", c[1].text)
    eq(
      "Dialogue: 0,0:00:01.50,0:00:02.00,Default,,0,0,0,,crlf text\r",
      ass.replace_timing(lines[5], 1.5, 2, c.script)
    )
  end)
  it("assumes the default field order before a Format line", function()
    local c = ass.parse({ "[Events]", "Dialogue: 2,0:00:01.00,0:00:02.00,Default,,0,0,0,,x" })
    eq({ 1, 2 }, { #c, c[1].layer })
  end)
end)

describe("ass formatting", function()
  it("format_ts rounds to centiseconds", function()
    eq("1:02:03.46", ass.format_ts(3723.4567))
    eq("0:00:00.99", ass.format_ts(0.994))
    eq("0:00:01.00", ass.format_ts(0.995))
    eq("0:00:00.00", ass.format_ts(-3))
    eq("10:00:00.00", ass.format_ts(36000))
  end)
  it("replace_timing rewrites only Start and End", function()
    local line = "Dialogue: 0,0:00:05.50,0:00:09.50,Default,Host,0,0,0,,Tonight, 0:00:01.00 {\\i1}x"
    local want = "Dialogue: 0,0:00:05.25,0:00:10.00,Default,Host,0,0,0,,Tonight, 0:00:01.00 {\\i1}x"
    eq(want, ass.replace_timing(line, 5.25, 10))
  end)
  it("replace_timing follows a reordered Format line", function()
    local line = "Dialogue: 0:00:02.00,Default,0:00:01.00,hi, 0:00:02.00"
    local c = ass.parse(events("Format: End, Style, Start, Text", line))
    near(1, c[1].start)
    eq("hi, 0:00:02.00", c[1].raw)
    eq("Dialogue: 0:00:03.00,Default,0:00:01.50,hi, 0:00:02.00", ass.replace_timing(line, 1.5, 3, c.script))
  end)
  it("round-trips through parse", function()
    for _, cue in ipairs(ass.parse(fixture)) do
      local line = fixture[cue.ts_lnum + 1]
      eq(line, ass.replace_timing(line, cue.start, cue.stop))
      local moved = ass.replace_timing(line, cue.start + 0.123, cue.stop + 1)
      local start, stop = ass.parse_timing(moved)
      near(cue.start + 0.12, start, 1e-9)
      near(cue.stop + 1, stop, 1e-9)
    end
  end)
  it("leaves non-Dialogue lines alone", function()
    eq(fixture[18], ass.replace_timing(fixture[18], 1, 2))
  end)
end)

describe("overlapping cue lookups", function()
  local cues = ass.parse(fixture)
  it("lists every active cue in start order", function()
    eq({}, lookup.active(cues, 0.2))
    eq({ 1 }, lookup.active(cues, 1))
    eq({ 3, 2 }, lookup.active(cues, 6)) -- sign started first, then dialogue
    eq({ 3 }, lookup.active(cues, 10))
    eq({ 3, 4 }, lookup.active(cues, 12))
    eq({}, lookup.active(cues, 15))
  end)
  it("at_time picks the latest-starting active cue", function()
    eq(2, ass.at_time(cues, 6))
    eq(3, ass.at_time(cues, 10))
    eq(4, ass.at_time(cues, 12))
    eq(nil, ass.at_time(cues, 4.8))
  end)
  it("from_time falls forward in start order", function()
    eq(3, ass.from_time(cues, 4.8))
    eq(5, ass.from_time(cues, 99))
  end)
  it("window sends the active cues and the next ones by start", function()
    eq({ 1, 3, 2 }, lookup.window(cues, 0, 2))
    eq({ 3, 2, 4 }, lookup.window(cues, 6, 1))
  end)
  it("at_line maps only Dialogue lines", function()
    eq(nil, ass.at_line(cues, 14))
    eq(1, ass.at_line(cues, 15))
    eq(2, ass.at_line(cues, 16))
    eq(nil, ass.at_line(cues, 17))
    eq(3, ass.nearest_line(cues, 17))
    eq(1, ass.nearest_line(cues, 0))
    eq(nil, ass.nearest_line(cues, 25))
  end)
end)

describe("ass performance (5000 unsorted cues)", function()
  local lines = { "[Events]", "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text" }
  for i = 1, 5000 do
    local s = ((i * 7919) % 5000) * 5.5 -- shuffled starts
    lines[#lines + 1] = ("Dialogue: 0,%s,Default,,0,0,0,,words, number %d"):format(ass.format_timing(s, s + 8), i)
  end
  it("parses and looks up 100k positions quickly", function()
    local t0 = vim.uv.hrtime()
    local cues = ass.parse(lines)
    eq(5000, #cues)
    for i = 1, 100000 do
      lookup.active(cues, (i * 0.37) % 27500)
    end
    local ms = (vim.uv.hrtime() - t0) / 1e6
    H.truthy(ms < 300, ("took %.1f ms"):format(ms))
  end)
end)

---------------------------------------------------------------------------
-- an .ass buffer in the plugin

local cl = require("cueline")
local buffer = require("cueline.buffer")
local client = require("cueline.client")

local server = mock.start(function(msg, s)
  if msg.type == "hello" then
    s.send({ type = "hello", server = "mock", player = { file = "/tmp/sample.mp4", pos = 0, paused = false } })
  end
end)

cl.setup({ port = server.port, follow_idle_ms = 0, lookahead = 1, seek_on_adjust = false })

local buf = api.nvim_create_buf(true, false)
api.nvim_buf_set_name(buf, "/tmp/sample.ass")
api.nvim_buf_set_lines(buf, 0, -1, false, fixture)
api.nvim_set_current_buf(buf)
vim.cmd("filetype on")
vim.cmd("filetype detect")

local function highlighted_rows()
  local rows = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, buffer.ns, 0, -1, {})) do
    rows[#rows + 1] = m[2]
  end
  return rows
end

local function time(pos, paused)
  server.send({ type = "time", pos = pos, paused = paused, speed = 1 })
end

describe("ass buffer", function()
  it("auto-attaches the ssa filetype with the ASS parser", function()
    eq("ssa", vim.bo[buf].filetype)
    H.truthy(buffer.get(buf), "buffer attached")
    eq(ass, buffer.fmt(buf))
    eq(4, #buffer.cues(buf))
  end)
  it("sends plain text to the player", function()
    cl.connect()
    wait(2000, function()
      return server.last("cues") ~= nil
    end, "cue window")
    local items = server.last("cues").items
    eq({ "Welcome back to the show\n(cue 1 second line)", "THE TAVERN" }, { items[1].text, items[2].text })
  end)
  it("highlights every active cue and follows the latest-starting one", function()
    time(6, false)
    wait(1000, function()
      return #highlighted_rows() == 2
    end, "two highlights")
    eq({ 16, 18 }, highlighted_rows())
    eq(17, api.nvim_win_get_cursor(0)[1])
    time(12, false)
    wait(1000, function()
      return vim.deep_equal(highlighted_rows(), { 18, 19 })
    end, "sign + next line")
    eq(20, api.nvim_win_get_cursor(0)[1])
  end)
  it("patches a text edit in place", function()
    time(12, true)
    wait(1000, function()
      return cl.player.paused
    end)
    api.nvim_buf_set_lines(buf, 19, 20, false, { "Dialogue: 0,0:00:10.50,0:00:14.50,Default,Guest,0,0,0,,Who, then?" })
    eq(false, buffer.get(buf).dirty, "no full reparse needed")
    eq("Who, then?", buffer.cues(buf)[4].text)
  end)
  it("adjust keys rewrite the Dialogue line under the cursor", function()
    api.nvim_win_set_cursor(0, { 17, 0 })
    cl.adjust("start", 0.25)
    eq(
      "Dialogue: 0,0:00:05.75,0:00:09.50,Default,Host,0,0,0,,Tonight we roll for {\\i1}initiative{\\i0}",
      api.nvim_buf_get_lines(buf, 16, 17, false)[1]
    )
    cl.adjust("end", -0.004)
    near(9.5, buffer.cues(buf)[2].stop) -- rounds back to the same centisecond
    vim.cmd("CuelineStamp end")
    eq("0:00:12.00", api.nvim_buf_get_lines(buf, 16, 17, false)[1]:match(",0:00:05.75,([^,]+)"))
  end)
  it("seeks to the Dialogue line under the cursor", function()
    api.nvim_win_set_cursor(0, { 19, 0 })
    vim.cmd("CuelineSeek")
    wait(1000, function()
      return server.last("seek") ~= nil
    end)
    near(5, server.last("seek").pos)
  end)
  it(":checkhealth lists the formats", function()
    vim.cmd("checkhealth cueline")
    local text = ""
    wait(2000, function()
      text = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      return text:find("formats", 1, true) ~= nil
    end, "formats line")
    H.truthy(text:find("srt, ssa", 1, true), text)
    vim.cmd("bwipeout!")
  end)
end)

cl.disconnect()
wait(1000, function()
  return client.status == "disconnected"
end)
server.stop()
