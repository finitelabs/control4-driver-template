-- Tests for lib/expressions.lua and lib/expression-sandbox.lua: PARAM{} tokens,
-- evaluation and its errors, what the sandbox reaches, debounced and ref-counted
-- watches, a device leaving the project, and waiting for a variable another driver
-- hasn't added yet.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_expressions.lua

local T = require("testlib")

require("c4_shim")

local Expressions = require("lib.expressions")
local sandbox = require("lib.expression-sandbox")

local listens, stops = {}, {}
local realListen, realStop = C4.RegisterVariableListener, C4.UnregisterVariableListener
function C4:RegisterVariableListener(deviceId, variableId)
  listens[#listens + 1] = deviceId .. ":" .. variableId
  return realListen(self, deviceId, variableId)
end
function C4:UnregisterVariableListener(deviceId, variableId)
  stops[#stops + 1] = deviceId .. ":" .. variableId
  return realStop(self, deviceId, variableId)
end

local function count(list, wanted)
  local n = 0
  for _, item in ipairs(list) do
    if item == wanted then
      n = n + 1
    end
  end
  return n
end

local function setDevices()
  ShimSetDevices({
    [100] = {
      deviceName = "Battery",
      roomName = "Garage",
      variables = {
        ["1001"] = { name = "LEVEL", value = "42", type = "NUMBER" },
        ["1002"] = { name = "STATE", value = "Charging", type = "STRING" },
      },
    },
    [200] = { deviceName = "Meter", roomName = "Garage", variables = { ["7"] = { name = "WATTS", value = "1500" } } },
    [300] = { deviceName = "Empty", roomName = "Attic" },
    [100001] = { variables = { ["2301"] = { name = "GLOBAL_LIMIT", value = "90" } } },
  })
end

--- An engine over a table of expressions, counting recomputes per name.
local function newEngine(expressions, opts)
  local recomputed = {}
  local options = {
    getExpressions = function()
      return expressions
    end,
    recompute = function(name)
      recomputed[name] = (recomputed[name] or 0) + 1
    end,
  }
  for key, value in pairs(opts or {}) do
    options[key] = value
  end
  return Expressions:new(options), recomputed
end

setDevices()

T.section("Tokens")
local refs, missing = Expressions.references("PARAM{100,1001} + PARAM{ 100 , STATE } + PARAM{200,NOPE}")
T.eq("a numeric and a named token resolve", #refs, 2)
T.eq("the numeric one keeps its id", refs[1].variableId, 1001)
T.eq("the named one finds its id, spaces and all", refs[2].variableId, 1002)
T.eq("one by a name the device lacks is missing", #missing, 1)
T.eq("and names what it wanted", missing[1].variable, "NOPE")
T.eq("a token not listed yet has an id if it's numeric", #Expressions.references("PARAM{200,99}"), 1)
T.eq("and is still missing", #select(2, Expressions.references("PARAM{200,99}")), 1)

local text, problem = Expressions.substitute("PARAM{100,LEVEL}% and PARAM{100,1002}")
T.eq("values replace the tokens", text, "42% and Charging")
T.eq("with no problem", problem, nil)
T.contains("a token renders as its names", Expressions.render("PARAM{100,1001}"), "LEVEL]")

T.section("Evaluation")
T.eq("an equation gives a number", Expressions.evaluate("equation", "PARAM{100,LEVEL} * 2").result, 84)
T.eq("a condition gives true or false", Expressions.evaluate("condition", "PARAM{100,LEVEL} < 50").result, true)
T.eq("and false counts as a result", Expressions.evaluate("condition", "PARAM{100,LEVEL} > 50").result, false)
T.eq("a string is its substitution", Expressions.evaluate("string", "at PARAM{100,LEVEL}").result, "at 42")
T.eq("a global variable's agent reads too", Expressions.evaluate("equation", "PARAM{100001,GLOBAL_LIMIT}").result, 90)
T.eq("Essentials' helpers work", Expressions.evaluate("equation", "round(c2f(PARAM{100,LEVEL} - 42), 1)").result, 32)

local evaluation = Expressions.evaluate("equation", "PARAM{100,LEVEL} +")
T.contains("a syntax error says so", evaluation.error, "compile error")
T.eq("and has no result", evaluation.result, nil)
T.contains("a runtime error says so", Expressions.evaluate("equation", "nothing.here").error, "runtime error")
T.contains(
  "a missing device is named",
  Expressions.evaluate("equation", "PARAM{999,LEVEL} + 1").error,
  "device 999 not found"
)
T.contains(
  "a device with no such variable is told apart",
  Expressions.evaluate("equation", "PARAM{100,NOPE} + 1").error,
  "variable NOPE not found on device 100"
)
T.contains(
  "so is one on a device with no variables at all",
  Expressions.evaluate("equation", "PARAM{300,NOPE}").error,
  "variable NOPE not found on device 300"
)
T.contains(
  "a device that isn't a number is missing",
  Expressions.evaluate("string", "PARAM{abc,X}").error,
  "device abc"
)
T.contains(
  "the text marks what's missing",
  Expressions.evaluate("equation", "PARAM{999,LEVEL} + 1").substituted,
  "ERROR_VARIABLE_NOT_FOUND"
)
T.contains(
  "an equation that isn't a number says so",
  Expressions.evaluate("equation", '"text"').error,
  "not a number (got string)"
)
T.contains(
  "a condition that isn't true or false says so",
  Expressions.evaluate("condition", "1").error,
  "not a boolean (got number)"
)

T.section("What the sandbox reaches")
for _, name in ipairs({ "io", "os", "require", "loadstring", "load", "dofile", "getfenv", "setfenv", "_G", "debug" }) do
  local result = sandbox.eval(name)
  T.eq(name .. " isn't reachable", result, nil)
end
T.eq("string.dump isn't reachable", sandbox.eval("string.dump"), nil)
T.eq('and nor is it through a string, ("").dump', sandbox.eval('("").dump'), nil)
T.truthy("while the driver keeps its own", string.dump)
local _, thrown = sandbox.eval("error('boom')")
T.contains("an error in an expression is reported", thrown, "boom")
T.truthy("and the driver still keeps its string.dump", string.dump)
local realFormat = string.format
local _, changing = sandbox.eval("(function() string.format = nil end)()")
T.contains("an expression can't change the string table", changing, "can't change")
T.eq("which stays whole", string.format, realFormat)
local realFloor = math.floor
local _, mathChange = sandbox.eval("(function() math.floor = nil end)()")
T.contains("nor the math table", mathChange, "can't change")
T.eq("which stays whole too", math.floor, realFloor)
T.eq("reading them still works", sandbox.eval('string.upper("a") .. math.floor(1.5)'), "A1")
local _, stay = sandbox.eval("(function() leaked = 1 end)()")
T.eq("a global an expression sets doesn't error", stay, nil)
T.eq("and doesn't reach the driver", leaked, nil) -- luacheck: ignore

T.section("Debounce")
local storm = { power = { template = "PARAM{200,WATTS}", auto = true } }
local engine, recomputed = newEngine(storm)
engine:subscribeExpression("power")
T.eq("a watch registers its variable's listener", count(listens, "200:7"), 1)
OnWatchedVariableChanged(200, 7, "1")
OnWatchedVariableChanged(200, 7, "2")
OnWatchedVariableChanged(200, 7, "3")
T.eq("a change only schedules work", recomputed.power, nil)
ShimFireTimers()
T.eq("a burst of changes is one recompute", recomputed.power, 1)
ShimFireTimers()
T.eq("and nothing is left over", recomputed.power, 1)
engine:unsubscribeExpression("power")

T.section("A failing recompute")
local failing = Expressions:new({
  getExpressions = function()
    return { bad = { template = "PARAM{200,WATTS}", auto = true } }
  end,
  recompute = function()
    error("nope")
  end,
})
failing:subscribeExpression("bad")
OnWatchedVariableChanged(200, 7, "1")
T.truthy(
  "stays inside the engine",
  pcall(function()
    ShimFireTimers()
  end)
)
failing:unsubscribeExpression("bad")

T.section("Ref counts")
listens, stops = {}, {}
local shared = {
  one = { template = "PARAM{100,LEVEL}", auto = true },
  two = { template = "PARAM{100,LEVEL} + PARAM{100,1001} + PARAM{200,WATTS}", auto = true },
  off = { template = "PARAM{300,1}", auto = false },
}
local counted, counts = newEngine(shared)
counted:resubscribeAll()
T.eq("two expressions share one listener", count(listens, "100:1001"), 1)
T.eq("a token used twice counts once", counted:watchedCount("two"), 2)
T.eq("one that isn't auto isn't watched", counted:watchedCount("off"), 0)
counted:subscribeExpression("gone")
T.eq("nor is one that doesn't exist", counted:watchedCount("gone"), 0)
OnWatchedVariableChanged(100, 1001, "1")
ShimFireTimers()
T.eq("a change recomputes the first", counts.one, 1)
T.eq("and the second", counts.two, 1)
local stopsBefore = count(stops, "100:1001")
counted:unsubscribeExpression("one")
T.eq("unwatching one keeps the shared listener", count(stops, "100:1001"), stopsBefore)
OnWatchedVariableChanged(100, 1001, "2")
ShimFireTimers()
T.eq("the other still recomputes", counts.two, 2)
T.eq("and the unwatched one doesn't", counts.one, 1)
counted:unsubscribeExpression("two")
T.eq("the last one out stops the listener", count(stops, "100:1001"), stopsBefore + 1)
OnWatchedVariableChanged(100, 1001, "3")
ShimFireTimers()
T.eq("after which a change does nothing", counts.two, 2)
counted:subscribeExpression("one")
T.eq("watching again listens again", counted:watchedCount("one"), 1)
shared.one.template = "PARAM{200,WATTS}"
counted:refreshExpression("one")
OnWatchedVariableChanged(200, 7, "9")
ShimFireTimers()
T.eq("an edit moves the watch", counts.one, 2)
counted:unsubscribeExpression("one")

T.section("A driver's own variables send no events")
local own, ownCounts = newEngine({
  writer = { template = "PARAM{200,WATTS}", auto = true },
  reader = { template = "PARAM{200,WATTS} + 1", auto = true },
})
own:resubscribeAll()
own:notifyVariableChanged(200, 7, "writer")
ShimFireTimers()
T.eq("the driver's notice reaches a reader", ownCounts.reader, 1)
T.eq("but not the expression that wrote it", ownCounts.writer, nil)
own:unsubscribeExpression("writer")
own:unsubscribeExpression("reader")

T.section("A device leaves the project")
ShimSetDevices({
  [400] = { deviceName = "Leaving", variables = { ["1"] = { name = "A", value = "1" } } },
  [500] = { deviceName = "Staying", variables = { ["2"] = { name = "B", value = "2" } } },
})
listens, stops = {}, {}
local leaving, leavingCounts = newEngine({
  uses = { template = "PARAM{400,A} + PARAM{500,B}", auto = true },
  other = { template = "PARAM{500,B}", auto = true },
})
leaving:resubscribeAll()
local affected = leaving:handleDeviceRemoved("400")
T.eq("it names the expressions that used it", table.concat(affected, ","), "uses")
-- One stop comes with the vendored register, which clears before it sets.
T.eq("and stops listening to it", count(stops, "400:1"), 2)
ShimFireTimers()
T.eq("they recompute", leavingCounts.uses, 1)
T.eq("others don't", leavingCounts.other, nil)
T.eq("what's left stays watched", leaving:watchedCount("uses"), 1)
T.contains(
  "evaluating gives an error result, even before Director forgets it",
  Expressions.evaluate("equation", "PARAM{400,A} + 1").error,
  "device 400 was removed from the project"
)
T.eq("the rest still evaluates", Expressions.evaluate("equation", "PARAM{500,B} + 1").result, 3)
local _, stillMissing = Expressions.references("PARAM{400,A}")
T.eq("and it isn't waited for", #stillMissing, 0)
leaving:unsubscribeExpression("uses")
leaving:unsubscribeExpression("other")

T.section("A variable another driver hasn't added yet")
ShimSetDevices({ [600] = { deviceName = "Late", variables = {} } })
listens, stops = {}, {}
local late, lateCounts = newEngine({ byName = { template = "PARAM{600,VALUE}", auto = true } })
late:subscribeExpression("byName")
T.eq("it can't be watched yet", late:watchedCount("byName"), 0)
ShimFireTimers()
T.eq("still can't after a try", late:watchedCount("byName"), 0)
T.eq("and nothing recomputes", lateCounts.byName, nil)
ShimSetDevices({ [600] = { deviceName = "Late", variables = { ["5"] = { name = "VALUE", value = "8" } } } })
ShimFireTimers()
T.eq("once it exists it's watched", late:watchedCount("byName"), 1)
T.eq("with a listener", count(listens, "600:5"), 1)
ShimFireTimers()
T.eq("and the expression catches up", lateCounts.byName, 1)
ShimFireTimers()
T.eq("the tries stop", lateCounts.byName, 1)
OnWatchedVariableChanged(600, 5, "9")
ShimFireTimers()
T.eq("and its changes recompute it", lateCounts.byName, 2)
late:unsubscribeExpression("byName")

ShimSetDevices({ [610] = { deviceName = "Late", variables = {} } })
listens, stops = {}, {}
local numeric, numericCounts = newEngine({ byId = { template = "PARAM{610,5}", auto = true } })
numeric:subscribeExpression("byId")
T.eq("a numeric id is watched at once, as it has an id", numeric:watchedCount("byId"), 1)
T.eq("with a listener", count(listens, "610:5"), 1)
ShimSetDevices({ [610] = { deviceName = "Late", variables = { ["5"] = { name = "VALUE", value = "8" } } } })
ShimFireTimers()
T.eq("once it exists the listener is set again", count(listens, "610:5"), 2)
ShimFireTimers()
T.eq("and the expression catches up", numericCounts.byId, 1)
numeric:unsubscribeExpression("byId")

ShimSetDevices({ [620] = { deviceName = "Never", variables = {} } })
local never, neverCounts = newEngine({ never = { template = "PARAM{620,VALUE}", auto = true } }, { retryAttempts = 3 })
local arms = 0
local realSetTimer = SetTimer
SetTimer = function(name, ...) -- luacheck: ignore
  if tostring(name):find("ExprRetry", 1, true) then
    arms = arms + 1
  end
  return realSetTimer(name, ...)
end
never:subscribeExpression("never")
for _ = 1, 10 do
  ShimFireTimers()
end
T.eq("one that never comes stops being tried", arms, 3)
T.eq("without recomputing", neverCounts.never, nil)
never:unsubscribeExpression("never")

arms = 0
local dropped = newEngine({ dropped = { template = "PARAM{620,VALUE}", auto = true } }, { retryAttempts = 3 })
dropped:subscribeExpression("dropped")
dropped:unsubscribeExpression("dropped")
for _ = 1, 3 do
  ShimFireTimers()
end
T.eq("unwatching one ends its tries", arms, 1)

arms = 0
ShimSetDevices({ [630] = { deviceName = "Removed", variables = {} } })
local removedLate = newEngine({ removed = { template = "PARAM{630,VALUE}", auto = true } }, { retryAttempts = 5 })
removedLate:subscribeExpression("removed")
removedLate:handleDeviceRemoved(630)
for _ = 1, 3 do
  ShimFireTimers()
end
T.eq("a device that left isn't tried for long", arms, 1)
removedLate:unsubscribeExpression("removed")
SetTimer = realSetTimer -- luacheck: ignore

T.section("The device browser")
ShimSetDevices({
  [700] = {
    deviceName = "Light",
    roomName = "Hall",
    proxies = { [701] = true },
    variables = { ["1"] = { name = "OWN" } },
  },
  [701] = {
    deviceName = "Light",
    roomName = "Hall",
    driverFileName = "light_v2.c4i",
    variables = { ["2"] = { name = "LEVEL" } },
  },
  [710] = { deviceName = "Lamp", roomName = "Attic", variables = { ["1"] = { name = "A" } } },
  [711] = { deviceName = "Lamp", roomName = "Attic", variables = { ["1"] = { name = "B" } } },
  [720] = { deviceName = "Nothing", roomName = "Attic" },
})
local devices = Expressions.devices()
T.eq("a driver and the proxy restating it are one entry, and the empty one is left out", #devices, 3)
T.eq("by room first", devices[1].roomName, "Attic")
T.eq("names that collide get their id", devices[1].name, "Lamp (710)")
T.eq("the proxy's owner stands for both", devices[3].id, 700)
local vars = Expressions.deviceVariables("700")
T.eq("a device's variables include its proxy's", #vars, 2)
T.eq("its own come first", vars[1].name, "OWN")
T.eq("under its own heading", vars[1].section, "Device")
T.eq("the proxy's name its .c4i", vars[2].section, "light_v2")
T.eq("a type is defaulted", vars[1].type, "STRING")
T.eq("an id that isn't a number gives nothing", Expressions.deviceVariables("x"), nil)

T.finish()
