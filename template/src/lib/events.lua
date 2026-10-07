--- The `Events` module provides functionality for managing dynamic events, including creating, retrieving, firing, deleting, and restoring events.
--- Events are stored persistently and are associated with unique IDs.

local log = require("lib.logging")
local persist = require("lib.persist")

require("drivers-common-public.global.lib")
require("lib.utils")

--- @class Events
local Events = {}
Events.__index = Events

--- The key used to persist events in storage.
--- @type string
local EVENTS_PERSIST_KEY = "Events"

--- The starting ID for events.
--- @type number
local EVENT_ID_START = 10

--- The ending ID for events.
--- @type number
local EVENT_ID_END = 999

--- @class Event
--- @field eventId number
--- @field name string
--- @field description string

--- Creates a new `Events` instance.
--- @return Events events A new `Events` instance.
function Events:new()
  log:trace("Events:new()")
  local instance = setmetatable({}, self)
  return instance
end

--- Retrieves or adds an event. If the event does not exist, it creates a new one with a unique ID.
--- @param namespace string The namespace of the event.
--- @param key string The key of the event.
--- @param name string The name of the event.
--- @param description string The description of the event.
--- @return Event|nil event The event object or nil if the event could not be created.
function Events:getOrAddEvent(namespace, key, name, description)
  log:trace("Events:getOrAddEvent(%s, %s, %s, %s)", namespace, key, name, description)
  local events = self:_peekEvents()
  --- @type Event|nil
  local event = Select(events, namespace, key)
  if event == nil then
    local eventId = self:_getNextEventId(events)
    event = {
      eventId = eventId,
      name = name,
      description = description,
    }

    events[namespace] = events[namespace] or {}
    events[namespace][key] = event
    self:_saveEvents(events)
    C4:AddEvent(eventId, name, description)
  end
  return TableDeepCopy(event)
end

--- Fires an event by namespace and key.
--- @param namespace string The namespace of the event.
--- @param key string The key of the event.
function Events:fire(namespace, key)
  log:trace("Events:fire(%s, %s)", namespace, key)
  --- @type number|nil
  local eventId = Select(self:_peekEvents(), namespace, key, "eventId")
  if IsEmpty(eventId) then
    return
  end
  --- @cast eventId -nil
  C4:FireEventByID(eventId)
end

--- Deletes an event by namespace and key. Removes the event from persistent storage and deletes the associated event.
--- @param namespace string The namespace of the event.
--- @param key string The key of the event.
function Events:deleteEvent(namespace, key)
  log:trace("Events:deleteEvent(%s, %s)", namespace, key)
  local events = self:_peekEvents()
  --- @type number|nil
  local eventId = Select(events, namespace, key, "eventId")
  if IsEmpty(eventId) then
    return
  end
  --- @cast eventId -nil
  C4:DeleteEvent(eventId)

  events[namespace][key] = nil
  if IsEmpty(events[namespace]) then
    events[namespace] = nil
  end
  if IsEmpty(events) then
    --- @diagnostic disable-next-line: assign-type-mismatch
    events = nil
  end

  self:_saveEvents(events)
end

--- Restores all events from persistent storage. Ensures that all events are re-added and removes unknown events.
---
--- Call this from OnDriverLateInit: C4:AddEvent is unavailable earlier.
function Events:restoreEvents()
  log:trace("Events:restoreEvents()")
  --- @type table<number, boolean>
  local usedEventIds = {}
  for _, keys in pairs(self:_peekEvents()) do
    for _, event in pairs(keys) do
      usedEventIds[event.eventId] = true
      C4:AddEvent(event.eventId, event.name, event.description)
    end
  end
  for id = EVENT_ID_START, EVENT_ID_END do
    if usedEventIds[id] == nil then
      log:trace("Deleting non-configured event %s, if it exists", id)
      C4:DeleteEvent(id)
    end
  end
end

--- Retrieves the next available event ID. Ensures that the ID is unique and within the allowed range.
--- @private
--- @param events table<string, table<string, Event>>? The events table, if the caller has it.
--- @return number eventId The next available event ID.
function Events:_getNextEventId(events)
  log:trace("Events:_getNextEventId()")
  --- @type table<number, boolean>
  local currentEvents = {}
  for _, keys in pairs(events or self:_peekEvents()) do
    for _, event in pairs(keys) do
      currentEvents[event.eventId] = true
    end
  end
  local nextId = EVENT_ID_START
  while currentEvents[nextId] ~= nil do
    nextId = nextId + 1
  end
  return nextId
end

--- Retrieves all events from persistent storage.
--- @return table<string, table<string, Event>> events A table of all events mapped by namespace then key.
--- @diagnostic disable-next-line: unused
function Events:getEvents()
  log:trace("Events:getEvents()")
  return persist:get(EVENTS_PERSIST_KEY, {}) or {}
end

--- The stored events table itself, not a copy (see persist:peek).
--- @private
--- @return table<string, table<string, Event>> events The events table.
function Events:_peekEvents()
  local events = persist:peek(EVENTS_PERSIST_KEY, {})
  return type(events) == "table" and events or {}
end

--- Saves the events to persistent storage. The table is stored as it is, so it
--- must not be changed afterwards except to save it again.
--- @private
--- @param events table<string, table<string, Event>>? The events table to save.
--- @diagnostic disable-next-line: unused
function Events:_saveEvents(events)
  log:trace("Events:_saveEvents(%s)", events)
  persist:commit(EVENTS_PERSIST_KEY, not IsEmpty(events) and events or nil)
end

--- Opts the events in to write-behind (see lib.persist): a change made inside
--- `persist:defer()` reaches storage at most once per `ms`.
--- @param ms number The flush interval in milliseconds.
--- @return void
function Events:setWriteBehind(ms)
  log:trace("Events:setWriteBehind(%s)", ms)
  persist:setWriteBehind(EVENTS_PERSIST_KEY, ms)
end

--- Writes any change still waiting under write-behind to storage now.
--- @return void
function Events:flush()
  log:trace("Events:flush()")
  persist:flush(EVENTS_PERSIST_KEY)
end

--- Resets all dynamic events, removing them from the system and clearing persisted storage.
function Events:reset()
  log:trace("Events:reset()")
  for _, nsEvents in pairs(self:_peekEvents()) do
    for _, event in pairs(nsEvents) do
      log:debug("Removing event '%s' (id=%s)", event.name, event.eventId)
      C4:DeleteEvent(event.eventId)
    end
  end
  self:_saveEvents(nil)
end

return Events:new()
