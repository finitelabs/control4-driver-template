-- lib.light.range: the Min and Max On Level line, its round trip, device steps and the slack a report may
-- sit within.

local T = require("testlib")

local Range = require("lib.light.range")

T.section("toDevice and toLevel: the line through the range, both ways")
do
  for _, case in ipairs({
    -- level, lo, hi, device brightness
    { 0, 1, 100, 0 },
    { 1, 1, 100, 0.01 },
    { 100, 1, 100, 1 },
    { 50, 1, 100, 0.5 },
    { 1, 20, 80, 0.2 },
    { 100, 20, 80, 0.8 },
    { 50, 20, 80, (20 + 49 * 60 / 99) / 100 },
  }) do
    local level, lo, hi, want = case[1], case[2], case[3], case[4]
    local got = Range.toDevice(level, lo, hi)
    T.check(string.format("level %d on [%d, %d]", level, lo, hi), math.abs(got - want) < 1e-12, got)
    if level > 0 then
      T.eq(string.format("and back on [%d, %d]", lo, hi), Range.toLevel(got, lo, hi), level)
    end
  end
  for lo = 1, 60, 7 do
    for hi = lo + 1, 100, 9 do
      local trips = true
      for level = 1, 100 do
        trips = trips and Range.toLevel(Range.toDevice(level, lo, hi), lo, hi) == level
      end
      T.check(string.format("every level round-trips on [%d, %d]", lo, hi), trips)
    end
  end
end

T.section("toLevel past the range reads as its end; nil reads as full")
do
  T.eq("below the Min On", Range.toLevel(0.05, 20, 80), 1)
  T.eq("above the Max On", Range.toLevel(0.95, 20, 80), 100)
  T.eq("nil brightness", Range.toLevel(nil, 1, 100), 100)
  T.eq("a range with no width", Range.toLevel(0.5, 50, 50), 100)
end

T.section("linePlace and lineBrightness are each other's inverse")
do
  T.eq("no width has no place", Range.linePlace(0.5, 40, 40), nil)
  for _, at in ipairs({ -10, 1, 37.5, 100, 140 }) do
    local b = Range.lineBrightness(at, 10, 90)
    T.check("at " .. at, math.abs(Range.linePlace(b, 10, 90) - at) < 1e-9)
  end
end

T.section("step: the device step a brightness goes out at")
do
  T.eq("254 steps at half", Range.step(0.5, 254), 127)
  T.eq("100 steps", Range.step(0.333, 100), 33)
  T.eq("255 steps at full", Range.step(1, 255), 255)
  T.eq("continuous", Range.step(0.4321, nil), 0.4321)
end

T.section("slack and sameLevel: half a device step, spread over a narrow range")
do
  T.eq("full range, 254 steps", Range.slack(1, 100, 254), 0)
  T.eq("full range, 100 steps", Range.slack(1, 100, 100), 1)
  T.eq("narrow range, 100 steps", Range.slack(40, 50, 100), 5)
  T.eq("continuous", Range.slack(1, 100, nil), 0)
  T.eq("no width", Range.slack(50, 50, 255), 100)
  T.eq("same level", Range.sameLevel(40, 40, 1, 100, nil), true)
  T.eq("within the slack", Range.sameLevel(40, 44, 40, 50, 100), true)
  T.eq("past it", Range.sameLevel(40, 46, 40, 50, 100), false)
  T.eq("off and on differ", Range.sameLevel(0, 1, 40, 50, 100), false)
end

T.finish()
