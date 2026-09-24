--- Values module for managing dynamic values with variable and property support.
--- Programming binds to a variable's id, so a name keeps the id it first had for good.

local log = require("lib.logging")
local persist = require("lib.persist")
local constants = require("constants")

require("drivers-common-public.global.lib")
require("drivers-common-public.global.handlers")
require("lib.utils")

--- @class Values
--- @field _callbacks table<string, function?> In-memory registry of OVC callbacks keyed by variable name.
--- @field _rejected table<string, boolean> Names Director refused to add in this load.
--- A class representing a collection of named values with optional variable/property support.
local Values = {}
Values.__index = Values

--- Persistent storage key for values.
--- @type string
local VALUES_PERSIST_KEY = "Values"

--- Director numbers a device's own variables from this id.
local FIRST_ID = 1001

--- How many taken ids a new variable skips before giving up.
local MAX_ID_TRIES = 1000

--- Name a variable of ours holds while another variable is added at the id its name spells.
local ASIDE_NAME = "__values_aside__"

--- @class Value
--- @field index integer Restore order for older builds, ascending in id order.
--- @field id integer? The Director variable id this name keeps once it has been a variable.
--- @field varType VariableType? Optional variable type if registered as a variable
--- @field value string|integer|number|boolean|nil The stored value
--- @field suffix string? Optional suffix for property display (e.g., " °C", " %")
--- @field writable boolean? Whether the variable accepts writes from programming. Persisted so restore can recreate the C4 variable with the correct readOnly flag.
--- @field deleted boolean? No live variable of its own; older builds add a hidden placeholder for it.
--- @field placeholder boolean? An id a returning name left behind, held by a hidden variable.
--- @field unverified boolean? An id taken from restore order because Director could not be read.

--- Whether this OS can rename a variable, so one can be created at a chosen id (OS 4.0+).
local function canRename()
  return C4.SetVariableName ~= nil
end

--- Whether Director reads the name as an id, as it does "1003", "3.5" or " 7".
local function looksNumeric(name)
  local n = tonumber(name)
  return n ~= nil and n == n and n ~= math.huge and n ~= -math.huge
end

--- The id Director reads from a numeric-looking name, or nil.
local function parsedId(name)
  if not looksNumeric(name) then
    return nil
  end
  local n = tonumber(name)
  n = n >= 0 and math.floor(n) or math.ceil(n)
  return n > 0 and n or nil
end

--- Whether the record has a variable of its own that Director should show.
local function isLive(record)
  return record ~= nil and record.varType ~= nil and not record.deleted
end

--- Whether the record holds a value: a variable, or a plain value (with or without an old id).
local function holdsValue(record)
  return not record.deleted or record.value ~= nil
end

local function ovcKey(name)
  -- Convert the name to a valid OVC variable name by replacing spaces with underscores
  return string.gsub(name, "%s+", "_")
end

--- Equality for a stored value. Differs from `==` only for NaN, which is never
--- equal to itself: a driver republishing an unknown reading would otherwise
--- report a change on every push and rewrite persistent storage each time.
local function sameValue(a, b)
  return a == b or (a ~= a and b ~= b)
end

--- The string Director stores for a value. C4 BOOL variables expect "0"/"1", not "true"/"false".
local function variableString(value)
  if value == nil then
    return ""
  elseif type(value) == "boolean" then
    return value and "1" or "0"
  end
  return tostring(value)
end

--- The name Director shows for a record's variable: without a rename, a numeric-looking name
--- is stored under the id Director read from it.
local function directorName(name, record)
  if not canRename() and record.id ~= nil and looksNumeric(name) then
    return tostring(record.id)
  end
  return name
end

--- The highest id any record holds, or the one before the first.
local function maxId(values)
  local max = FIRST_ID - 1
  for _, record in pairs(values) do
    if record.id ~= nil and record.id > max then
      max = record.id
    end
  end
  return max
end

local function maxIndex(values)
  local max = 0
  for _, record in pairs(values) do
    if (record.index or 0) > max then
      max = record.index
    end
  end
  return max
end

--- Renumbers `index` so an older build's restore adds the records in id order.
local function orderIndexes(values)
  local rows = {}
  for name, record in pairs(values) do
    table.insert(rows, { name = name, record = record })
  end
  table.sort(rows, function(a, b)
    local ai, bi = a.record.id, b.record.id
    if (ai ~= nil) ~= (bi ~= nil) then
      return ai ~= nil
    elseif ai ~= nil and ai ~= bi then
      return ai < bi
    elseif (a.record.index or 0) ~= (b.record.index or 0) then
      return (a.record.index or 0) < (b.record.index or 0)
    end
    return a.name < b.name
  end)
  for i, row in ipairs(rows) do
    row.record.index = i
  end
end

--- Each record's id, as one comparable string.
local function idSignature(values)
  local parts = {}
  for name, record in pairs(values) do
    table.insert(parts, name .. "=" .. tostring(record.id))
  end
  table.sort(parts)
  return table.concat(parts, "\n")
end

--- A key for a left-behind id; its decimal name lets an older build restore it at that id.
local function placeholderKey(values, id, avoid)
  local key = tostring(id)
  while values[key] ~= nil or key == avoid do
    key = "#" .. key
  end
  return key
end

--- The ids an older build's restore gives each record on an empty Director: by name, in
--- index order, a hidden placeholder for each deleted record. Numeric names take their own id.
local function olderBuildIds(values)
  local rows = {}
  for name, record in pairs(values) do
    if record.deleted or record.varType ~= nil then
      table.insert(rows, { name = name, record = record })
    end
  end
  table.sort(rows, function(a, b)
    if (a.record.index or 0) ~= (b.record.index or 0) then
      return (a.record.index or 0) < (b.record.index or 0)
    end
    return a.name < b.name
  end)
  local ids, taken, counter = {}, {}, FIRST_ID
  for _, row in ipairs(rows) do
    local id
    if looksNumeric(row.name) then
      id = parsedId(row.name)
    else
      while taken[counter] do
        counter = counter + 1
      end
      id = counter
      counter = counter + 1
    end
    if id ~= nil and not taken[id] then
      taken[id] = true
      ids[row.name] = id
    end
  end
  return ids, rows
end

--- Creates a new Values instance.
--- @return Values values A new Values instance.
function Values:new()
  log:trace("Values:new()")
  local instance = setmetatable({}, self)
  instance._callbacks = {}
  instance._rejected = {}
  return instance
end

--- Register (or clear) the OnVariableChanged callback for a variable. Callback
--- wiring is managed independently of value updates so that inbound state
--- changes never accidentally clear an entity's programming handler.
---
--- Persists the writable flag so future restores recreate the C4 variable with
--- the correct readOnly state. Does NOT delete/recreate an already-created C4
--- variable, since that would orphan any programming attached to it; flipping
--- writable on an existing variable takes effect on the next restart.
--- @param name string The variable name.
--- @param callback (fun(newValue: string|integer|number): void)? The callback, or nil to clear.
function Values:setCallback(name, callback)
  log:trace("Values:setCallback(%s, %s)", name, callback)

  self._callbacks[name] = callback

  OVC[ovcKey(name)] = callback
      and function(newValue)
        log:debug("Variable %s changed to %s", name, newValue)
        callback(newValue)
      end
    or nil

  local values = self:_load()
  local existing = values[name]
  if existing == nil or existing.placeholder then
    return
  end

  local desiredWritable = (callback ~= nil)
  if existing.writable ~= desiredWritable then
    existing.writable = desiredWritable
    self:_saveValues(values)
  end
end

--- Updates a value. If the value does not exist, it will be created. If the
--- `name` is also a property, it will also be updated.
---
--- The `callbackOrWritable` argument (arg 4) controls callback wiring and
--- writability. It is dispatched by type:
---
---   * `nil`      - no change; any previously registered callback/writable
---                  state is left alone. This is what 3-arg callers get.
---   * `false`    - clears the callback (equivalent to
---                  `setCallback(name, nil)`), marking the variable read-only.
---   * `true`     - registers a no-op placeholder callback so the variable is
---                  writable from C4 programming. No change-notification path;
---                  the driver observes updates by reading `Variables[name]`.
---   * function   - registers the callback (equivalent to
---                  `setCallback(name, fn)`) and marks the variable writable.
---
--- When a function (or `true`) is passed, `setCallback` runs before the C4
--- variable is created on this call, so a newly-created variable comes up
--- writable on the very first call. For existing variables, flipping
--- writability takes effect on the next restart (see `setCallback`).
---
--- @param name string The name of the value to update or create. Must be globally unique.
--- @param value string|integer|number|boolean|nil The value to set, can be `nil`.
--- @param varType VariableType? The type of the variable, if `nil` it will not be registered as a variable.
--- @param callbackOrWritable (fun(newValue: string|integer|number): void)|boolean|nil Callback to register, `true` for writable-with-placeholder, `false` to clear, or `nil` for no change.
--- @param propertySuffix string? Optional suffix to append to the property value (e.g., "°C" for temperature units).
--- @return boolean changed True if the value changed, false otherwise.
function Values:update(name, value, varType, callbackOrWritable, propertySuffix)
  log:trace("Values:update(%s, %s, %s, %s, %s)", name, value, varType, callbackOrWritable, propertySuffix)

  if type(callbackOrWritable) == "function" then
    self:setCallback(name, callbackOrWritable)
  elseif callbackOrWritable == true then
    self:setCallback(name, function() end)
  elseif callbackOrWritable == false then
    self:setCallback(name, nil)
  end

  -- Convert value to appropriate type based on varType
  if varType == "BOOL" then
    value = toboolean(value)
  elseif varType == "DEVICE" or varType == "INT" or varType == "ROOM" then
    value = tointeger(value)
  elseif varType == "FLOAT" or varType == "NUMBER" then
    value = tonumber(value)
  else
    value = tostring(value)
  end

  local values = self:_load()
  if values[name] ~= nil and values[name].placeholder then
    -- An id some other name left behind sits under this key; it keeps its id elsewhere.
    local held = values[name]
    values[name] = nil
    values[placeholderKey(values, held.id, name)] = held
  end
  local existing = values[name]

  -- Writable iff a callback is currently registered, or the persisted record
  -- already says so (lets restore recreate the C4 variable correctly before
  -- items have a chance to re-register their callbacks).
  local writable = self._callbacks[name] ~= nil or (existing and existing.writable) or false

  -- Check if the entry has changed
  local changed = not existing
    or not holdsValue(existing)
    or not sameValue(existing.value, value)
    or existing.suffix ~= propertySuffix
    or existing.varType ~= varType
    or existing.writable ~= writable
  local record = existing
  if changed then
    record = {
      index = existing and existing.index or maxIndex(values) + 1,
      id = existing and existing.id,
      unverified = existing and existing.unverified,
      deleted = existing and existing.deleted,
      varType = varType,
      value = value,
      suffix = propertySuffix,
      writable = writable,
    }
    values[name] = record
  end

  -- A change to which variables exist, or to an id, is written now even under write-behind.
  local durable = self:_applyVariable(values, name, record, existing, variableString(value))
  if changed or durable then
    self:_saveValues(values, durable)
  end

  self:_showProperty(name, record)
  return changed
end

--- Deletes a value. A value that has been a variable keeps its id, so the name gets
--- it back when it returns; a plain value that never was one is removed.
--- @param name string The name of the value to delete.
--- @return void
function Values:delete(name)
  log:trace("Values:delete(%s)", name)
  local values = self:_load()
  local record = values[name]
  if record == nil or record.placeholder then
    log:debug("Value %s does not exist; ignoring delete", name)
    return
  end

  log:debug("Deleting value %s", name)

  -- Remove the OVC handler
  OVC[ovcKey(name)] = nil
  self._callbacks[name] = nil

  local wasVariable = isLive(record)
  if record.deleted and record.value == nil then
    -- Already deleted: its id stays held as it is
  else
    if record.id == nil and record.varType == nil then
      values[name] = nil
    else
      record.deleted = true
      record.value = nil
    end
    if wasVariable then
      self:_removeVariable(name, record)
    end
    self:_saveValues(values, wasVariable)
  end

  if Properties[name] ~= nil then
    UpdateProperty(name, "", true)
    -- The best we can do to delete a property is to hide it
    C4:SetPropertyAttribs(name, constants.HIDE_PROPERTY)
  end
end

--- Opts the values in to write-behind (see lib.persist): an update made inside
--- `persist:defer()` reaches storage at most once per `ms`, unless it adds or
--- removes a variable.
--- @param ms number The flush interval in milliseconds.
--- @return void
function Values:setWriteBehind(ms)
  log:trace("Values:setWriteBehind(%s)", ms)
  persist:setWriteBehind(VALUES_PERSIST_KEY, ms)
end

--- Writes any update still waiting under write-behind to storage now.
--- @return void
function Values:flush()
  log:trace("Values:flush()")
  persist:flush(VALUES_PERSIST_KEY)
end

--- Retrieves all values from persistent storage.
--- @return table<string, Value> values A table of all values mapped by their name.
--- @diagnostic disable-next-line: unused
function Values:getValues()
  log:trace("Values:getValues()")
  local values = self:_load()
  for _, record in pairs(values) do
    if record.deleted and record.value ~= nil then
      record.deleted = nil -- a plain value that keeps an old variable's id is not deleted
    end
  end
  return values
end

--- Retrieves a value by name.
--- @param name string The name of the value to retrieve.
--- @return Value|nil value The value associated with the name, or nil if it does not exist.
function Values:getValue(name)
  log:trace("Values:getValue(%s)", name)
  return Select(self:getValues(), name)
end

--- Restores every value, each variable at its id; the first run after an older build keeps Director's ids.
--- Call this from OnDriverInit, before the driver adds any variable of its own.
--- @return void
function Values:restoreValues()
  log:trace("Values:restoreValues()")
  local values = self:_load()
  local restarted = not self:_anyPresent(values)

  if self:_migrate(values, restarted) then
    self:_saveValues(values, true)
  end

  local before = idSignature(values)
  if canRename() then
    self:_restoreRenamed(values)
  else
    self:_restoreByName(values, restarted)
  end
  if idSignature(values) ~= before then
    self:_saveValues(values, true)
  end

  for name, record in pairs(values) do
    if holdsValue(record) then
      local ok, err = pcall(self._showProperty, self, name, record)
      if not ok then
        log:error("Restoring property %s failed: %s", name, err)
      end
    end
  end
end

--- Resets all values: removes every variable and value, but each name keeps its id.
function Values:reset()
  log:trace("Values:reset()")
  local values = self:_load()
  for name, record in pairs(values) do
    log:debug("Removing value '%s'", name)
    OVC[ovcKey(name)] = nil
    if isLive(record) then
      self:_removeVariable(name, record)
    end
    if record.id == nil then
      values[name] = nil
    else
      values[name] = {
        index = record.index,
        id = record.id,
        unverified = record.unverified,
        varType = record.varType,
        placeholder = record.placeholder,
        deleted = true,
      }
    end
  end
  self._callbacks = {}
  self:_saveValues(values, true)
end

--- The stored values, as a copy the caller may change.
--- @private
--- @return table<string, Value> values
function Values:_load()
  return persist:get(VALUES_PERSIST_KEY, {}) or {}
end

--- Saves the values to persistent storage.
--- @private
--- @param values table<string, Value>? The values table to save, nil clears storage.
--- @param durable boolean? Write to storage now even under write-behind.
--- @diagnostic disable-next-line: unused
function Values:_saveValues(values, durable)
  log:trace("Values:_saveValues(%s, %s)", values, durable)
  if durable and values ~= nil then
    orderIndexes(values)
  end
  persist:set(VALUES_PERSIST_KEY, not IsEmpty(values) and values or nil)
  if durable then
    persist:flush(VALUES_PERSIST_KEY)
  end
end

--- Shows the property of that name, if any, with the record's value.
--- @private
function Values:_showProperty(name, record)
  if Properties[name] == nil then
    return
  end
  -- Ensure the property is visible
  C4:SetPropertyAttribs(name, constants.SHOW_PROPERTY)

  -- Format property value with optional suffix
  local strValue = variableString(record.value)
  local propValue = strValue
  if record.suffix and strValue ~= "" then
    propValue = strValue .. record.suffix
  end
  if Properties[name] ~= propValue then
    UpdateProperty(name, propValue, true)
  end
end

--- What to address a record's variable by: its id, unless that id was only estimated.
--- @private
function Values:_target(name, record)
  if record.id ~= nil and not record.unverified then
    return record.id
  end
  return name
end

--- Brings Director in line with a record after an update.
--- @private
--- @return boolean durable True when a variable or an id changed.
function Values:_applyVariable(values, name, record, existing, strValue)
  local wasVariable = isLive(existing)
  if record.varType == nil then
    record.deleted = record.id ~= nil or nil
    if not wasVariable then
      return false
    end
    OVC[ovcKey(name)] = nil
    self._callbacks[name] = nil
    self:_removeVariable(name, existing)
    return true
  end

  local present = Variables[directorName(name, record)]
  if present ~= nil and (wasVariable or existing == nil or existing.id == nil) then
    local idBefore = record.id
    if record.id == nil then
      -- Director already has a visible variable of this name: take it over at its id.
      local found = self:_findVariable(name)
      if found ~= nil and found.hidden then
        present = nil
      elseif found ~= nil then
        record.id = found.id
      end
    end
    if present ~= nil then
      record.deleted = nil
      if present ~= strValue then
        C4:SetVariable(self:_target(name, record), strValue)
      end
      return record.id ~= idBefore or not wasVariable
    end
  end

  record.deleted = nil
  if not canRename() and existing ~= nil and existing.id ~= nil and not wasVariable then
    self:_leaveBehind(values, name, record, existing)
  end
  self:_createVariable(values, name, record, strValue)
  return true
end

--- Removes a record's variable. Without a rename its id stays held by a hidden variable,
--- so nothing after it moves.
--- @private
function Values:_removeVariable(name, record)
  C4:DeleteVariable(self:_target(name, record))
  if not canRename() and record.id ~= nil and not C4:AddVariable(record.id, "", record.varType, true, true) then
    log:error("Could not hold variable id %s of %s with a hidden variable", record.id, name)
  end
end

--- A name that returns without a rename cannot take its old id back: the id stays held
--- under a record of its own, and the name gets a new one.
--- @private
function Values:_leaveBehind(values, name, record, existing)
  local id = existing.id
  if parsedId(name) == id then
    -- Director puts a numeric name at the id it spells, so its own placeholder gives way.
    C4:DeleteVariable(id)
    return
  end
  values[placeholderKey(values, id, name)] = {
    index = existing.index,
    id = id,
    unverified = existing.unverified,
    varType = existing.varType or "STRING",
    deleted = true,
    placeholder = true,
  }
  if Variables[tostring(id)] == nil then
    if Variables[name] ~= nil then
      -- An older build's placeholder carries the name the new variable needs.
      C4:DeleteVariable(self:_target(name, existing))
    end
    C4:AddVariable(id, "", existing.varType or "STRING", true, true)
  end
  record.id = nil
  record.unverified = nil
end

--- Creates a record's variable: at its id with a rename, else by name.
--- @private
function Values:_createVariable(values, name, record, strValue)
  if canRename() then
    self:_createRenamed(values, name, record, strValue)
  else
    self:_createByName(values, name, record, strValue)
  end
end

--- Adds the variable at the record's id (a new one above every id recorded) and names it.
--- @private
function Values:_createRenamed(values, name, record, strValue)
  local readOnly = not record.writable
  if Variables[name] ~= nil then
    -- An older build's hidden placeholder, or a leftover, still carries the name.
    C4:DeleteVariable(self:_target(name, record))
  end
  if record.id ~= nil and not self:_addAt(values, record.id, name, strValue, record.varType, readOnly) then
    log:error("Variable id %s of %s is taken by another variable; %s gets a new id", record.id, name, name)
    record.id = nil
  end
  if record.id == nil then
    local id = math.max(maxId(values), FIRST_ID - 1) + 1
    for _ = 1, MAX_ID_TRIES do
      if self:_addAt(values, id, name, strValue, record.varType, readOnly) then
        record.id = id
        break
      end
      id = id + 1
    end
    if record.id == nil then
      log:error("Found no free variable id for %s", name)
    end
  end
  record.unverified = nil
end

--- Adds a variable at exactly that id and names it.
--- @private
--- @return boolean added
function Values:_addAt(values, id, name, strValue, varType, readOnly)
  local added = C4:AddVariable(id, strValue, varType, readOnly, false)
  local aside
  if not added then
    -- A variable of ours named like this id blocks the add; it steps aside for a moment.
    local holder = values[tostring(id)]
    if
      Variables[tostring(id)] ~= nil
      and isLive(holder)
      and holder.id ~= nil
      and holder.id ~= id
      and C4:SetVariableName(holder.id, ASIDE_NAME)
    then
      aside = holder.id
      added = C4:AddVariable(id, strValue, varType, readOnly, false)
    end
  end
  if added and name ~= tostring(id) and not C4:SetVariableName(id, name) then
    log:error("Variable %s could not be named %s", id, name)
  end
  if aside ~= nil then
    C4:SetVariableName(aside, tostring(id))
  end
  return added and true or false
end

--- Adds the variable by name and records the id Director gives it.
--- @private
--- @return boolean added
function Values:_createByName(values, name, record, strValue)
  if self._rejected[name] then
    return false
  end
  local ok, added, id
  if looksNumeric(name) then
    -- Director reads the name as an id, which it may refuse or raise on.
    ok, added, id = pcall(C4.AddVariable, C4, name, strValue, record.varType, not record.writable, false)
  else
    ok, added, id = true, C4:AddVariable(name, strValue, record.varType, not record.writable, false)
  end
  if not ok or not added then
    self._rejected[name] = true
    log:error("Director did not add variable %s%s", name, ok and "" or (": " .. tostring(added)))
    return false
  end
  if id == nil then
    local found = self:_findVariable(looksNumeric(name) and tostring(parsedId(name)) or name)
    id = found and found.id
  end
  if record.id ~= nil and id ~= record.id then
    log:error("Variable %s took id %s, not its id %s", name, id, record.id)
  end
  for other, held in pairs(values) do
    if id ~= nil and held.id == id and held ~= record then
      log:error("Variable %s took id %s, which %s held without a variable", name, id, other)
      held.id = nil
      if held.deleted and held.value == nil then
        values[other] = nil
      end
    end
  end
  record.id = id
  record.unverified = nil
  return true
end

--- This device's variables from Director as id -> { name, hidden }, or nil if it cannot say.
--- @private
function Values:_directorVariables()
  local ok, variables = pcall(C4.GetDeviceVariables, C4, C4:GetDeviceID())
  if not ok or type(variables) ~= "table" then
    log:warn("GetDeviceVariables failed: %s", ok and type(variables) or variables)
    return nil
  end
  local out = {}
  for id, variable in pairs(variables) do
    if tonumber(id) ~= nil and type(variable) == "table" and variable.name ~= nil then
      out[tonumber(id)] = {
        name = tostring(variable.name),
        hidden = variable.hidden == true or variable.hidden == "True",
      }
    end
  end
  return out
end

--- The id and hidden flag of this device's variable of that name, if Director can say.
--- @private
function Values:_findVariable(name)
  for id, variable in pairs(self:_directorVariables() or {}) do
    if variable.name == name then
      return { id = id, hidden = variable.hidden }
    end
  end
end

--- Whether Director has a variable for any record, which it keeps across a driver update
--- and drops on a Director restart.
--- @private
function Values:_anyPresent(values)
  for name, record in pairs(values) do
    if Variables[directorName(name, record)] ~= nil then
      return true
    elseif record.id ~= nil and not isLive(record) and Variables[tostring(record.id)] ~= nil then
      return true
    end
  end
  return false
end

--- Gives the records an older build left without ids the ids Director has for them now.
--- All or nothing: every record is looked at again.
--- @private
--- @return boolean changed
function Values:_migrate(values, restarted)
  local pending, anyId = false, false
  for name, record in pairs(values) do
    if record.id ~= nil then
      anyId = true
    elseif record.deleted or (record.varType ~= nil and (canRename() or not looksNumeric(name))) then
      pending = true
    end
  end
  if not pending then
    return false
  end

  local estimated, rows = olderBuildIds(values)
  if restarted and not anyId then
    self:_restoreAsOlderBuild(values, estimated, rows)
  elseif not restarted then
    local director = self:_directorVariables()
    if director == nil or not self:_learnIds(values, director, estimated) then
      log:warn("Director's variables could not be read; variable ids are taken from restore order")
      local held = {}
      for _, record in pairs(values) do
        if record.id ~= nil then
          held[record.id] = true
        end
      end
      -- Without a rename an id must stay held by a variable, so only those Director shows count.
      for _, row in ipairs(rows) do
        local id = estimated[row.name]
        if row.record.id == nil and id ~= nil and not held[id] and (canRename() or Variables[row.name] ~= nil) then
          row.record.id, row.record.unverified = id, true
          held[id] = true
        end
      end
    end
  end

  -- A deleted record Director holds no id for has nothing left to keep.
  for name, record in pairs(values) do
    if record.id == nil and record.deleted then
      values[name] = nil
    elseif canRename() and isLive(record) and record.id ~= nil and looksNumeric(name) then
      if Variables[name] == nil and Variables[tostring(record.id)] ~= nil then
        C4:SetVariableName(record.id, name) -- a numeric name Director stored under its id
      end
    end
  end
  log:info("Recorded the variable ids of the values an older build stored")
  return true
end

--- On a Director restart with no ids recorded, does what the older build's restore did,
--- and records the id each variable gets.
--- @private
function Values:_restoreAsOlderBuild(values, estimated, rows)
  for _, row in ipairs(rows) do
    local name, record = row.name, row.record
    local ok, added, id
    if record.deleted then
      ok, added, id = pcall(C4.AddVariable, C4, name, "", record.varType or "STRING", true, true)
    else
      local strValue = variableString(record.value)
      ok, added, id = pcall(C4.AddVariable, C4, name, strValue, record.varType, not record.writable, false)
    end
    if not ok then
      log:error("Restoring variable %s failed: %s", name, added)
    elseif added then
      record.id = id or estimated[name]
    end
  end
end

--- Takes each record's id from Director by name, and holds the id of every hidden variable
--- no record names. False when Director shows a name it does not list.
--- @private
function Values:_learnIds(values, director, estimated)
  local byName = {}
  for id, variable in pairs(director) do
    byName[variable.name] = id
  end
  local learned = {}
  for name, record in pairs(values) do
    local id = byName[name]
    local parsed = parsedId(name)
    if id == nil and parsed ~= nil and director[parsed] ~= nil and director[parsed].name == tostring(parsed) then
      if values[tostring(parsed)] == nil then
        id = parsed -- a numeric name Director stored under its id
      end
    end
    if id == nil and Variables[directorName(name, record)] ~= nil then
      return false
    end
    learned[name] = id
  end
  local claimed, unmatched = {}, {}
  for name, record in pairs(values) do
    if learned[name] ~= nil then
      record.id, record.unverified = learned[name], nil
      claimed[record.id] = true
    else
      table.insert(unmatched, name)
    end
  end

  -- Director lacks these: each keeps an id nobody has, else takes the one a restart would give.
  local function free(id)
    return id ~= nil and director[id] == nil and not claimed[id]
  end
  table.sort(unmatched)
  for _, name in ipairs(unmatched) do
    local record = values[name]
    if free(record.id) then
      claimed[record.id] = true
    else
      record.id = nil
    end
  end
  for _, name in ipairs(unmatched) do
    local record = values[name]
    if record.id == nil and canRename() and free(estimated[name]) then
      record.id, record.unverified = estimated[name], nil
      claimed[record.id] = true
    end
  end

  for id, variable in pairs(director) do
    if not claimed[id] and variable.hidden and values[variable.name] == nil then
      log:info("Holding variable id %s of hidden variable %s", id, variable.name)
      values[variable.name] = { index = 0, id = id, varType = "STRING", deleted = true }
      claimed[id] = true
    end
  end
  return true
end

--- Restore with a rename: each variable Director lacks is added at its id and named.
--- @private
function Values:_restoreRenamed(values)
  local rows = {}
  for name, record in pairs(values) do
    if isLive(record) then
      table.insert(rows, { name = name, record = record })
    end
  end
  table.sort(rows, function(a, b)
    if (a.record.id ~= nil) ~= (b.record.id ~= nil) then
      return a.record.id ~= nil
    elseif a.record.id ~= nil and a.record.id ~= b.record.id then
      return a.record.id < b.record.id
    end
    return a.name < b.name
  end)
  for _, row in ipairs(rows) do
    local ok, err = pcall(self._restoreVariable, self, values, row.name, row.record)
    if not ok then
      log:error("Restoring variable %s failed: %s", row.name, err)
    end
  end
end

--- Restore without a rename, from the first id up: a variable by name lands on its id since every lower id
--- is taken, any other id gets a hidden variable by number. After a driver update only what is missing.
--- @private
function Values:_restoreByName(values, restarted)
  local owner, ids, walkTo = {}, {}, FIRST_ID - 1
  for name, record in pairs(values) do
    if record.id ~= nil then
      owner[record.id] = name
      table.insert(ids, record.id)
      if isLive(record) and not looksNumeric(name) and record.id > walkTo then
        walkTo = record.id
      end
    end
  end
  -- Every id up to the last one a by-name add must land on, then the rest.
  for id = FIRST_ID, walkTo do
    if owner[id] == nil then
      table.insert(ids, id)
    end
  end
  table.sort(ids)

  for _, id in ipairs(ids) do
    local name = owner[id]
    local record = name and values[name]
    if record ~= nil and isLive(record) then
      local ok, err = pcall(self._restoreVariable, self, values, name, record)
      if not ok then
        log:error("Restoring variable %s failed: %s", name, err)
      end
    elseif record ~= nil or restarted then
      local held = Variables[tostring(id)] ~= nil or (record ~= nil and Variables[name] ~= nil)
      if not held then
        local ok, err = pcall(C4.AddVariable, C4, id, "", record and record.varType or "STRING", true, true)
        if not ok then
          log:error("Holding variable id %s failed: %s", id, err)
        end
      end
    end
  end

  local unplaced = {}
  for name, record in pairs(values) do
    if isLive(record) and record.id == nil then
      table.insert(unplaced, name)
    end
  end
  table.sort(unplaced, function(a, b)
    return (values[a].index or 0) < (values[b].index or 0) or (values[a].index == values[b].index and a < b)
  end)
  for _, name in ipairs(unplaced) do
    local ok, err = pcall(self._restoreVariable, self, values, name, values[name])
    if not ok then
      log:error("Restoring variable %s failed: %s", name, err)
    end
  end
end

--- Adds a live record's variable if Director lacks it, else brings its value up to date.
--- @private
function Values:_restoreVariable(values, name, record)
  local strValue = variableString(record.value)
  local present = Variables[directorName(name, record)]
  if present == nil then
    log:debug("Restoring %s variable %s at id %s", record.varType, name, record.id)
    self:_createVariable(values, name, record, strValue)
  elseif present ~= strValue then
    C4:SetVariable(self:_target(name, record), strValue)
  end
end

return Values:new()
