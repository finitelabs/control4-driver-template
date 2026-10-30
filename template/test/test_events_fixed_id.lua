-- getOrAddEvent in lib/events.lua with a fixed ID: a driver.xml event made dynamic keeps the ID
-- programming is bound to, through a restart, while allocated IDs still start at 10.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_events_fixed_id.lua

local T = require("testlib")

require("c4_shim")

local deletes = {}
local realDelete = C4.DeleteEvent
function C4:DeleteEvent(id)
  table.insert(deletes, id)
  return realDelete(self, id)
end

local fired = {}
function C4:FireEventByID(id)
  table.insert(fired, id)
end

-- A restart: fresh modules over the same storage, then restoreEvents() as at OnDriverLateInit.
local function restart()
  ShimPersistLand()
  T.unload("^lib%.")
  ShimResetEvents()
  local events = require("lib.events")
  events:restoreEvents()
  return events
end

local events = require("lib.events")

T.section("a fixed ID is the event's ID, and allocation still starts at 10")
local low = events:getOrAddEvent("Status", "battery_low", "Battery Low", "When NAME battery is low", 1)
local press = events:getOrAddEvent("Buttons", "single", "Single", "When NAME Single is pressed")
T.eq("the fixed ID", low.eventId, 1)
T.eq("declared under it", ShimEvents()[1].name, "Battery Low")
T.eq("the first allocated ID", press.eventId, 10)
events:fire("Status", "battery_low")
T.eq("fired by its ID", fired, { 1 })

T.section("offered again, it keeps its ID")
local again = events:getOrAddEvent("Status", "battery_low", "Battery Low", "When NAME battery is low", 1)
T.eq("the same ID", again.eventId, 1)

T.section("a restart declares it under its ID and deletes nothing outside the allocated range")
deletes = {}
events = restart()
T.eq("the fixed event", ShimEvents()[1].name, "Battery Low")
T.eq("the allocated event", ShimEvents()[10].name, "Single")
local below = {}
for _, id in ipairs(deletes) do
  if id < 10 then
    below[#below + 1] = id
  end
end
T.eq("no ID below 10 deleted", below, {})

T.section("deleted, its ID goes")
deletes = {}
events:deleteEvent("Status", "battery_low")
T.eq("deleted under its ID", deletes, { 1 })
T.eq("and no longer declared", ShimEvents()[1], nil)
events = restart()
T.eq("nor after a restart", ShimEvents()[1], nil)

T.section("a fixed ID in the allocated range is refused")
local inRange = events:getOrAddEvent("Status", "trouble", "Trouble", "When NAME failure is imminent", 10)
T.eq("nothing returned", inRange, nil)
T.eq("the allocated event untouched", ShimEvents()[10].name, "Single")
T.eq("nothing stored", events:getEvents().Status, nil)

T.finish()
