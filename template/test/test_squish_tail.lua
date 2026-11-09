-- src/squish-tail.lua, which gen-squishy adds after driver.lua in every squishy: once late init returns, the
-- package.preload copy of each module loaded is gone, and every other preload entry is kept.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_squish_tail.lua

local T = require("testlib")

-- run_test.sh runs from test/ and make test from the root; both put src/?.lua on LUA_PATH.
local TAIL = assert(package.searchpath("squish-tail", package.path))

local function module()
  return {}
end

local function seed()
  for _, name in ipairs({ "tail.atLoad", "tail.inLateInit", "tail.never", "tail.cLoader" }) do
    package.loaded[name] = nil
  end
  package.preload["tail.atLoad"] = module
  package.preload["tail.inLateInit"] = module
  package.preload["tail.never"] = module
  package.preload["tail.cLoader"] = print
  require("tail.atLoad")
  package.loaded["tail.cLoader"] = {}
end

T.section("Late init runs as the driver wrote it, then the loaded modules' copies go")
seed()
local seen = {}
function OnDriverLateInit(...)
  seen.args = { ... }
  seen.during = package.preload["tail.atLoad"] ~= nil
  require("tail.inLateInit")
  return "done", nil, 3
end
dofile(TAIL)
local a, _, c = OnDriverLateInit("DIT_STARTUP", "x")
T.eq("late init gets its arguments", table.concat(seen.args, ","), "DIT_STARTUP,x")
T.truthy("the copies are there while late init runs", seen.during)
T.eq("late init's first result comes back", a, "done")
T.eq("and its last, past a nil", c, 3)
T.falsy("a module loaded before late init loses its copy", package.preload["tail.atLoad"])
T.falsy("a module loaded during late init loses its copy", package.preload["tail.inLateInit"])
T.eq("a module never loaded keeps its copy", package.preload["tail.never"], module)
T.eq("a C loader stays, though its module is loaded", package.preload["tail.cLoader"], print)
T.truthy("a module that lost its copy is still loaded", package.loaded["tail.atLoad"])

T.section("A driver with no late init gets one that only drops the copies")
seed()
OnDriverLateInit = nil
dofile(TAIL)
T.eq("the tail defines OnDriverLateInit", type(OnDriverLateInit), "function")
T.eq("it returns nothing", select("#", OnDriverLateInit()), 0)
T.falsy("the loaded module's copy goes", package.preload["tail.atLoad"])
T.eq("the module never loaded keeps its copy", package.preload["tail.never"], module)

T.section("A late init that raises keeps its error, and the copies")
seed()
function OnDriverLateInit()
  error("late init failed")
end
dofile(TAIL)
T.raises("the error reaches Director", function()
  OnDriverLateInit()
end, "late init failed")
T.eq("the copies stay where late init did not finish", package.preload["tail.atLoad"], module)

for _, name in ipairs({ "tail.atLoad", "tail.inLateInit", "tail.never", "tail.cLoader" }) do
  package.preload[name], package.loaded[name] = nil, nil
end
OnDriverLateInit = nil
T.finish()
