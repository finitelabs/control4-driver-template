--- This module provides functionality for managing and persisting conditionals.

local log = require("lib.logging")
local persist = require("lib.persist")

require("drivers-common-public.global.lib")
require("lib.utils")

--- @class Conditionals
--- A class representing conditionals.
local Conditionals = {}
Conditionals.__index = Conditionals

--- The key used to persist conditionals.
--- @type string
local CONDITIONALS_PERSIST_KEY = "Conditionals"

--- The starting ID for conditionals.
--- @type number
local CONDITIONAL_ID_START = 10

--- @class ConditionalConfig
--- @field type string
--- @field condition_statement string
--- @field description string

--- @class Conditional:ConditionalConfig
--- @field conditionalId number
--- @field name string

--- Whether two stored records hold the same data.
--- @param a any
--- @param b any
--- @return boolean same True if equal, field by field.
local function sameRecord(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not sameRecord(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

--- Creates a new instance of the `Conditionals` class.
--- @return Conditionals conditionals A new instance of the `Conditionals` class.
function Conditionals:new()
  log:trace("Conditionals:new()")
  local instance = setmetatable({}, self)
  return instance
end

--- Upserts a conditional into the conditionals table. Storage is written only
--- when the conditional is new or has changed; the test function is always set.
--- @param namespace string The namespace for the conditional.
--- @param key string The key for the conditional.
--- @param conditional ConditionalConfig The conditional object to upsert.
--- @param testFunction function The test function associated with the conditional.
--- @return Conditional conditional The upserted conditional.
function Conditionals:upsertConditional(namespace, key, conditional, testFunction)
  log:trace("Conditionals:upsertConditional(%s, %s, %s, <testFunction>)", namespace, key, conditional)
  local conditionals = self:_peekConditionals()
  local existing = Select(conditionals, namespace, key)
  --- @type number
  local conditionalId = Select(existing, "conditionalId") or self:_getNextConditionalId(conditionals)

  --- @type Conditional
  conditional = TableDeepCopy(conditional)

  conditional.conditionalId = conditionalId
  conditional.name = "CONDITIONAL_" .. conditionalId

  TC[conditional.name] = testFunction

  if not sameRecord(existing, conditional) then
    conditionals[namespace] = conditionals[namespace] or {}
    conditionals[namespace][key] = conditional
    self:_saveConditionals(conditionals)
  end
  return TableDeepCopy(conditional)
end

--- Deletes a conditional from the conditionals table.
--- @param namespace string The namespace of the conditional.
--- @param key string The key of the conditional.
function Conditionals:deleteConditional(namespace, key)
  log:trace("Conditionals:deleteConditional(%s, %s)", namespace, key)
  local conditionals = self:_peekConditionals()
  --- @type Conditional|nil
  local conditional = Select(conditionals, namespace, key)
  if IsEmpty(conditional) then
    return
  end
  --- @cast conditional -nil

  conditionals[namespace][key] = nil
  if IsEmpty(conditionals[namespace]) then
    conditionals[namespace] = nil
  end
  if IsEmpty(conditionals) then
    --- @diagnostic disable-next-line: assign-type-mismatch
    conditionals = nil
  end

  TC[conditional.name] = nil

  self:_saveConditionals(conditionals)
end

--- Gets the next available conditional ID.
--- @private
--- @param conditionals table<string, table<string, Conditional>>? The conditionals table, if the caller has it.
--- @return number conditionalId The next available conditional ID.
function Conditionals:_getNextConditionalId(conditionals)
  log:trace("Conditionals:_getNextConditionalId()")
  local currentConditionals = {}
  for _, keys in pairs(conditionals or self:_peekConditionals()) do
    for _, conditional in pairs(keys) do
      currentConditionals[conditional.conditionalId] = true
    end
  end
  local nextId = CONDITIONAL_ID_START
  while currentConditionals[nextId] ~= nil do
    nextId = nextId + 1
  end
  return nextId
end

--- Retrieves all conditionals from persistent storage.
--- @return table<string, table<string, Conditional>> conditionals A table containing all conditionals.
--- @diagnostic disable-next-line: unused
function Conditionals:getConditionals()
  log:trace("Conditionals:getConditionals()")
  return persist:get(CONDITIONALS_PERSIST_KEY, {}) or {}
end

--- The stored conditionals table itself, not a copy (see persist:peek).
--- @private
--- @return table<string, table<string, Conditional>> conditionals The conditionals table.
function Conditionals:_peekConditionals()
  local conditionals = persist:peek(CONDITIONALS_PERSIST_KEY, {})
  return type(conditionals) == "table" and conditionals or {}
end

--- Saves the conditionals to persistent storage. The table is stored as it is,
--- so it must not be changed afterwards except to save it again.
--- @private
--- @param conditionals table<string, table<string, Conditional>>? The conditionals table to save.
--- @diagnostic disable-next-line: unused
function Conditionals:_saveConditionals(conditionals)
  log:trace("Conditionals:_saveConditionals(%s)", conditionals)
  persist:commit(CONDITIONALS_PERSIST_KEY, not IsEmpty(conditionals) and conditionals or nil)
end

--- Opts the conditionals in to write-behind (see lib.persist): a change made
--- inside `persist:defer()` reaches storage at most once per `ms`.
--- @param ms number The flush interval in milliseconds.
--- @return void
function Conditionals:setWriteBehind(ms)
  log:trace("Conditionals:setWriteBehind(%s)", ms)
  persist:setWriteBehind(CONDITIONALS_PERSIST_KEY, ms)
end

--- Writes any change still waiting under write-behind to storage now.
--- @return void
function Conditionals:flush()
  log:trace("Conditionals:flush()")
  persist:flush(CONDITIONALS_PERSIST_KEY)
end

--- Resets all conditionals, removing them from the system and clearing persisted storage.
function Conditionals:reset()
  log:trace("Conditionals:reset()")
  for _, nsConditionals in pairs(self:_peekConditionals()) do
    for _, conditional in pairs(nsConditionals) do
      log:debug("Removing conditional '%s' (id=%s)", conditional.name, conditional.conditionalId)
      TC[conditional.name] = nil
    end
  end
  self:_saveConditionals(nil)
end

local conditionals = Conditionals:new()

--- Retrieves all conditionals in a program-friendly format.
--- @return table<string, Conditional> conditionals A table of conditionals indexed by their ID as strings.
function GetConditionals()
  log:trace("GetConditionals()")
  local progConditionals = {}
  for _, keys in pairs(conditionals:_peekConditionals()) do
    for _, conditional in pairs(keys) do
      progConditionals[tostring(conditional.conditionalId)] = TableDeepCopy(conditional)
    end
  end
  return progConditionals
end

return conditionals
