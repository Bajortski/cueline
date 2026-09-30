local H = require("helpers")
local srt = require("cueline.srt")
local describe, it, eq, near = H.describe, H.it, H.eq, H.near

local sample = {
  "1",
  "00:00:01,000 --> 00:00:02,500",
  "first line",
  "second line",
  "",
  "2",
  "00:00:03,000 --> 00:00:04,000",
  "third",
  "",
  "",
  "3",
  "00:00:05.250 --> 00:00:06,000 X1:10",
  "",
  "4",
  "00:00:07,000 --> 00:00:08,000",
  "last",
}

local function big(n)
  local lines = {}
  for i = 1, n do
    local s = i * 5.5
    vim.list_extend(lines, { tostring(i), srt.format_timing(s, s + 5), "spoken words number " .. i, "and more", "" })
  end
  return lines
end

describe("srt.parse", function()
  local cues = srt.parse(sample)
  it("finds every cue", function()
    eq(4, #cues)
  end)
  it("parses timing (comma and dot separators)", function()
    near(1.0, cues[1].start)
    near(2.5, cues[1].stop)
    near(5.25, cues[3].start)
  end)
  it("joins multi-line text and records 0-based line spans", function()
    eq("first line\nsecond line", cues[1].text)
    eq({ 1, 2, 3 }, { cues[1].ts_lnum, cues[1].first, cues[1].last })
  end)
  it("handles a cue with no text", function()
    eq("", cues[3].text)
    eq(true, cues[3].first > cues[3].last)
  end)
  it("handles a final cue without trailing blank line", function()
    eq("last", cues[4].text)
  end)
  it("splits cues missing the blank separator", function()
    local c = srt.parse({ "00:00:01,000 --> 00:00:02,000", "a", "00:00:03,000 --> 00:00:04,000", "b" })
    eq({ "a", "b" }, { c[1].text, c[2].text })
  end)
end)

describe("srt lookup", function()
  local cues = srt.parse(sample)
  it("at_time finds the playing cue", function()
    eq(1, srt.at_time(cues, 1.0))
    eq(1, srt.at_time(cues, 2.49))
    eq(nil, srt.at_time(cues, 2.5))
    eq(2, srt.at_time(cues, 3.5))
    eq(nil, srt.at_time(cues, 0.2))
    eq(nil, srt.at_time(cues, 99))
  end)
  it("from_time returns the active or next cue", function()
    eq(1, srt.from_time(cues, 0))
    eq(2, srt.from_time(cues, 2.7))
    eq(5, srt.from_time(cues, 99))
  end)
  it("at_line maps index, timestamp and text lines", function()
    eq(1, srt.at_line(cues, 0))
    eq(1, srt.at_line(cues, 1))
    eq(1, srt.at_line(cues, 3))
    eq(nil, srt.at_line(cues, 4))
    eq(2, srt.at_line(cues, 5))
    eq(3, srt.at_line(cues, 11))
  end)
  it("nearest_line falls forward from blank lines", function()
    eq(2, srt.nearest_line(cues, 4))
    eq(3, srt.nearest_line(cues, 9))
  end)
end)

describe("srt formatting", function()
  it("format_ts rounds to milliseconds", function()
    eq("01:02:03,457", srt.format_ts(3723.4567))
    eq("00:00:00,000", srt.format_ts(-3))
  end)
  it("replace_timing keeps trailing position hints", function()
    eq("00:00:05,500 --> 00:00:06,000 X1:10", srt.replace_timing(sample[12], 5.5, 6))
  end)
  it("round-trips through parse_timing", function()
    local a, b = srt.parse_timing(srt.format_timing(28799.999, 28800.25))
    near(28799.999, a, 1e-9)
    near(28800.25, b, 1e-9)
  end)
end)

describe("srt performance (5000 cues)", function()
  local lines = big(5000)
  it("parses in well under 50 ms", function()
    local t0 = vim.uv.hrtime()
    local cues = srt.parse(lines)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    eq(5000, #cues)
    H.truthy(ms < 50, ("parse took %.1f ms"):format(ms))
  end)
  it("looks up 100k positions in under 100 ms", function()
    local cues = srt.parse(lines)
    local t0 = vim.uv.hrtime()
    for i = 1, 100000 do
      srt.at_time(cues, (i * 0.37) % 27500)
    end
    local ms = (vim.uv.hrtime() - t0) / 1e6
    H.truthy(ms < 100, ("lookups took %.1f ms"):format(ms))
    eq(4000, srt.at_time(cues, 4000 * 5.5 + 1))
  end)
end)
