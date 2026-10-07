-- How lib/values.lua, lib/events.lua, lib/conditionals.lua, and lib/bindings.lua
-- scale with the number of records they hold, and what callers can still rely on:
--   * adding a record copies only that record, not the whole table, so the work
--     per record stays flat as the table grows;
--   * with write-behind, a batch of adds inside persist:defer() reaches storage
--     once per library, new variables included;
--   * an upsertConditional that changes nothing writes nothing;
--   * getters and the records the add calls return are still copies, so changing
--     them never changes the store.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_lib_scale.lua

local T = require("testlib")

require("c4_shim")

local writes = {}
local realSet = C4.PersistSetValue
function C4:PersistSetValue(key, value, encrypted)
  writes[key] = (writes[key] or 0) + 1
  return realSet(self, key, value, encrypted)
end

--- Fresh library instances over empty storage.
local function load()
  ShimFireTimers()
  T.unload("^lib%.")
  for _, key in ipairs({ "Values", "Events", "Conditionals", "ConnectionBindings" }) do
    C4:PersistDeleteValue(key)
  end
  writes = {}
  return {
    persist = require("lib.persist"),
    values = require("lib.values"),
    events = require("lib.events"),
    conditionals = require("lib.conditionals"),
    bindings = require("lib.bindings"),
  }
end

--- Adds `count` records to every library, starting at `first`.
local function addRecords(libs, first, count)
  for i = first, first + count - 1 do
    libs.values:update("Value " .. i, i, "NUMBER")
    libs.events:getOrAddEvent("NS", "event" .. i, "Event " .. i, "description")
    libs.conditionals:upsertConditional("NS", "cond" .. i, {
      type = "BOOL",
      condition_statement = "Condition " .. i,
      description = "NAME condition is STRING",
      true_text = "Yes",
      false_text = "No",
    }, function()
      return true
    end)
    libs.bindings:getOrAddDynamicBinding("NS", "binding" .. i, "CONTROL", true, "Binding " .. i, "IR_OUT")
  end
end

--- Table entries copied (TableDeepCopy calls, nested ones included) while `fn` runs.
local function copiesDuring(fn)
  local count = 0
  local real = TableDeepCopy
  TableDeepCopy = function(t, seen)
    count = count + 1
    return real(t, seen)
  end
  local ok, err = pcall(fn)
  TableDeepCopy = real
  assert(ok, err)
  return count
end

T.section("Work per record stays flat as the tables grow")
do
  local libs = load()
  addRecords(libs, 1, 200)
  local early = copiesDuring(function()
    addRecords(libs, 201, 50)
  end)
  addRecords(libs, 251, 300)
  local late = copiesDuring(function()
    addRecords(libs, 551, 50)
  end)
  -- Copying whole tables would make the late batch (tables near 600) about
  -- three times the early one (tables near 200).
  T.check("adding to a 3x larger table costs about the same", late < early * 1.5, early .. " then " .. late)
end

T.section("A batch inside persist:defer() writes each library once")
do
  local libs = load()
  libs.values:setWriteBehind(60000)
  libs.events:setWriteBehind(60000)
  libs.conditionals:setWriteBehind(60000)
  libs.bindings:setWriteBehind(60000)
  libs.persist:defer(function()
    addRecords(libs, 1, 100)
    T.eq("nothing written during the batch", writes["Values"], nil)
  end)
  T.eq("new variables reach storage once, as the scope closes", writes["Values"], 1)
  libs.persist:flush()
  T.eq("events once", writes["Events"], 1)
  T.eq("conditionals once", writes["Conditionals"], 1)
  T.eq("bindings once", writes["ConnectionBindings"], 1)
  T.eq("everything stored", TableLength(Deserialize(C4:PersistGetValue("Events")).NS), 100)
end

T.section("Outside persist:defer() every change still writes at once")
do
  local libs = load()
  libs.values:setWriteBehind(60000)
  libs.events:setWriteBehind(60000)
  addRecords(libs, 1, 3)
  T.eq("values", writes["Values"], 3)
  T.eq("events", writes["Events"], 3)
end

T.section("An unchanged conditional writes nothing")
do
  local libs = load()
  addRecords(libs, 1, 2)
  writes = {}
  local calls = 0
  addRecords(libs, 1, 2)
  T.eq("re-registering writes nothing", writes["Conditionals"], nil)
  libs.conditionals:upsertConditional("NS", "cond1", {
    type = "BOOL",
    condition_statement = "Renamed",
    description = "NAME condition is STRING",
    true_text = "Yes",
    false_text = "No",
  }, function()
    calls = calls + 1
    return false
  end)
  T.eq("a change writes", writes["Conditionals"], 1)
  local name = libs.conditionals:getConditionals().NS.cond1.name
  TC[name]()
  T.eq("the newest test function is installed", calls, 1)
end

T.section("Getters and returned records are still copies")
do
  local libs = load()
  addRecords(libs, 1, 1)
  libs.events:getEvents().NS.event1.name = "changed"
  T.eq("getEvents()", libs.events:getEvents().NS.event1.name, "Event 1")
  libs.events:getOrAddEvent("NS", "event1", "Event 1", "description").eventId = 999
  T.eq("getOrAddEvent()", libs.events:getEvents().NS.event1.eventId, 10)
  libs.conditionals:getConditionals().NS.cond1.true_text = "changed"
  T.eq("getConditionals()", libs.conditionals:getConditionals().NS.cond1.true_text, "Yes")
  GetConditionals()["10"].true_text = "changed"
  T.eq("GetConditionals()", libs.conditionals:getConditionals().NS.cond1.true_text, "Yes")
  libs.bindings:getDynamicBinding("NS", "binding1").displayName = "changed"
  T.eq("getDynamicBinding()", libs.bindings:getDynamicBinding("NS", "binding1").displayName, "Binding 1")
  libs.bindings:getDynamicBindings("NS").binding1.displayName = "changed"
  T.eq("getDynamicBindings()", libs.bindings:getBindings().NS.binding1.displayName, "Binding 1")
  libs.bindings:getOrAddDynamicBinding("NS", "binding1", "CONTROL", true, "Binding 1", "IR_OUT").bindingId = 1
  T.eq("getOrAddDynamicBinding()", libs.bindings:getBindings().NS.binding1.bindingId, 10)
  libs.values:getValues()["Value 1"].value = 99
  T.eq("getValues()", libs.values:getValue("Value 1").value, 1)
  libs.values:getValue("Value 1").value = 99
  T.eq("getValue()", libs.values:getValues()["Value 1"].value, 1)
end

T.finish()
