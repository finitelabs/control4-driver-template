-- lib.light.fade: the length of a change by fade kind, the curve, progress, and the re-time rule.

local T = require("testlib")
local Fade = require("lib.light.fade")

--- @type LightFade
local DEVICE = { kind = "device", curve = "linear", preOn = false, retimes = false, maxMs = 65535 }
--- @type LightFade
local RETIMES = { kind = "device", curve = "linear", preOn = false, retimes = true, maxMs = 65535 }
--- @type LightFade
local SMOOTH = { kind = "device", curve = "smootherstep", preOn = true, maxMs = 65535 }
--- @type LightFade
local OWN = { kind = "own", maxMs = 65535, own = { onMs = 300, offMs = 400, changeMs = 200 } }
--- @type LightFade
local WALK = { kind = "walk", maxMs = 60000, stepMs = 100 }

T.section("length: the time the library models a change as taking")
for _, case in ipairs({
  { "device takes the time asked", DEVICE, false, true, 1500, 1500 },
  { "device clamps to maxMs", DEVICE, true, true, 90000, 65535 },
  { "device rounds down a fraction", DEVICE, true, true, 12.7, 12 },
  { "device takes no negative time", DEVICE, true, false, -5, 0 },
  { "device off to off moves nothing", DEVICE, false, false, 1500, 0 },
  { "own off to on runs onMs", OWN, false, true, 5000, 300 },
  { "own on to off runs offMs", OWN, true, false, 5000, 400 },
  { "own on to another level runs changeMs", OWN, true, true, 5000, 200 },
  { "own off to off moves nothing", OWN, false, false, 5000, 0 },
  { "own ignores a rate of 0", OWN, false, true, 0, 300 },
  { "walk takes the time asked", WALK, false, true, 1000, 1000 },
  { "walk clamps to its maxMs", WALK, false, true, 70000, 60000 },
  { "walk off to off moves nothing", WALK, false, false, 1000, 0 },
}) do
  T.eq(case[1], Fade.length(case[2], case[3], case[4], case[5]), case[6])
end

T.section("transition: what a command asks of the device")
T.eq("a device fade asks the change's length", Fade.transition(DEVICE, 700), 700)
T.eq("an own fade asks none", Fade.transition(OWN, 300), 0)
T.eq("a walk asks none", Fade.transition(WALK, 1000), 0)

T.section("retimes: only a device fade that declares it takes the other aspect along")
T.eq("device with retimes", Fade.retimes(RETIMES), true)
T.eq("device without", Fade.retimes(DEVICE), false)
T.eq("own", Fade.retimes(OWN), false)
T.eq("walk", Fade.retimes(WALK), false)

T.section("the curve")
T.eq("linear at a third", Fade.eased(DEVICE, 1 / 3), 1 / 3)
T.eq("smootherstep starts at 0", Fade.eased(SMOOTH, 0), 0)
T.eq("smootherstep is half way at half time", Fade.eased(SMOOTH, 0.5), 0.5)
T.eq("smootherstep ends at 1", Fade.eased(SMOOTH, 1), 1)
T.check("smootherstep is slow at the start", Fade.eased(SMOOTH, 0.1) < 0.1)
T.eq("progress clamps below 0", Fade.eased(DEVICE, -1), 0)
T.eq("progress clamps above 1", Fade.eased(DEVICE, 2), 1)
local rising = true
for i = 1, 20 do
  rising = rising and Fade.eased(SMOOTH, i / 20) >= Fade.eased(SMOOTH, (i - 1) / 20)
end
T.check("smootherstep never goes back", rising)

T.section("progress, time left and the values along a change")
T.eq("a change of no time is done", Fade.progress(DEVICE, 1000, 0, 1000), 1)
T.eq("before it starts", Fade.progress(DEVICE, 1000, 400, 900), 0)
T.eq("a quarter in", Fade.progress(DEVICE, 1000, 400, 1100), 0.25)
T.eq("after it ends", Fade.progress(DEVICE, 1000, 400, 2000), 1)
T.eq("time left part way", Fade.left(1000, 400, 1100), 300)
T.eq("no time left after the end", Fade.left(1000, 400, 1500), 0)
T.eq("a level along", Fade.between(0.2, 0.6, 0.25), 0.3)

local RED = { x = 0.64, y = 0.33, mode = "xy" }
local BLUE = { x = 0.15, y = 0.06, mode = "xy" }
local WARM = { x = 0.46, y = 0.41, mode = "cct" }
local COOL = { x = 0.31, y = 0.32, mode = "cct" }
T.eq("a color at the start is the start", Fade.color(RED, BLUE, 0), RED)
T.eq("a color at the end is the end", Fade.color(RED, BLUE, 1), BLUE)
local mid = Fade.color(RED, BLUE, 0.5)
T.eq("a color half way, straight across xy", { mid.x, mid.y, mid.mode }, { 0.395, 0.195, "xy" })
T.eq("between two whites the mode stays", Fade.color(WARM, COOL, 0.5).mode, "cct")
T.eq("from a full color toward a white the light is in color until it arrives", Fade.color(RED, COOL, 0.9).mode, "xy")
T.eq("and white once there", Fade.color(RED, COOL, 1).mode, "cct")

T.finish()
