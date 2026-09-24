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
--- @field _rejected table<string, boolean> Names Director refused to add, or to rename to, in this load.
--- @field _unhide table<string, boolean> Live names an older build left hidden, shown again at their next update.
--- @field _unheld table<integer, boolean> Ids another variable sat on at restore, held once it is gone.
--- @field _emptyWarned boolean? Whether this load has logged that "" is kept as a plain value.
--- @field _stale boolean? Ids not yet learned from Director in this load, because it could not be read.
--- @field _unreadWarned boolean? Whether this load has logged that Director's variables could not be read.
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

--- How long after restore the ids it could not learn are learned, if a timer set in OnDriverInit runs.
local RECHECK_MS = 1000

--- Name a variable of ours holds while another variable is added at the id its name spells (a "_"
--- is added while a variable, or the name being added, has it).
local ASIDE_NAME = "__values_aside__"

--- @class Value
--- @field index integer Restore order for older builds, ascending in id order.
--- @field id integer? The Director variable id this name keeps once it has been a variable.
--- @field varType VariableType? Optional variable type if registered as a variable
--- @field value string|integer|number|boolean|nil The stored value
--- @field suffix string? Optional suffix for property display (e.g., " °C", " %")
--- @field writable boolean? Whether the variable accepts writes from programming. Persisted so restore can recreate the C4 variable with the correct readOnly flag.
--- @field deleted boolean? No live variable of its own; older builds add a hidden placeholder for it.
--- @field placeholder boolean? An id no name owns any more (left behind, or another's), kept reserved.
--- @field unverified boolean? An id taken from restore order because Director could not be read.

--- Whether this OS can rename a variable, so one can be created at a chosen id (OS 4.0+).
local function canRename()
  return C4.SetVariableName ~= nil
end

--- Renames a variable, false when Director refuses or raises.
local function rename(id, name)
  local ok, renamed = pcall(C4.SetVariableName, C4, id, name)
  if not ok then
    log:error("Renaming variable %s to %s failed: %s", id, name, renamed)
  end
  return ok and renamed == true
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

--- Whether the record is or has been a variable, as opposed to a plain value that never was one.
local function wasEverVariable(record)
  return record.id ~= nil or record.deleted or record.varType ~= nil
end

--- Drops each deleted record left with no id: it has nothing to keep.
local function dropIdless(values)
  for name, record in pairs(values) do
    if record.id == nil and not holdsValue(record) then
      values[name] = nil
    end
  end
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

--- The id a numeric-looking name's variable has when Director cannot list them: the one it spells,
--- where a variable is named by it and no other record is.
local function spelledId(values, name)
  local id = parsedId(name)
  if id ~= nil and Variables[tostring(id)] ~= nil and (values[tostring(id)] == nil or tostring(id) == name) then
    return id
  end
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

--- The name and record that hold the id, if any.
local function ownerOf(values, id)
  for name, record in pairs(values) do
    if record.id == id then
      return name, record
    end
  end
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

--- Each record's id and state, as one comparable string.
local function recordSignature(values)
  local parts = {}
  for name, record in pairs(values) do
    local fields = { name, tostring(record.id), tostring(record.deleted), tostring(record.placeholder) }
    table.insert(fields, tostring(record.unverified))
    table.insert(parts, table.concat(fields, "\1"))
  end
  table.sort(parts)
  return table.concat(parts, "\2")
end

--- A key for a reserved id; its decimal name lets an older build restore it at that id.
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
  instance._unhide = {}
  instance._unheld = {}
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
  if existing == nil then
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
  if name == "" and varType ~= nil then
    -- A rename to "" does not take (4.3.0), so "" could never keep an id: it is never a variable.
    if not self._emptyWarned then
      log:warn("A value with an empty name is kept as a plain value, not a variable")
      self._emptyWarned = true
    end
    varType = nil
  end

  local values = self:_load()
  self:_recheck(values)
  if values[name] ~= nil and values[name].placeholder then
    -- An id no name owns sits under this key; it stays reserved under another.
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
  self:_recheck(values)
  local record = values[name]
  if record == nil then
    log:debug("Value %s does not exist; ignoring delete", name)
    return
  end

  log:debug("Deleting value %s", name)

  -- Remove the OVC handler
  OVC[ovcKey(name)] = nil
  self._callbacks[name] = nil

  if holdsValue(record) then
    local wasVariable = isLive(record)
    if wasVariable then
      self:_removeVariable(values, name, record, record.varType)
    end
    if record.id == nil then
      values[name] = nil
    else
      record.deleted = true
      record.value = nil
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
--- Call it first in OnDriverInit, and add variables only through lib/values, never C4:AddVariable.
--- @return void
function Values:restoreValues()
  log:trace("Values:restoreValues()")
  local values = self:_load()
  self._unhide, self._unheld, self._stale = {}, {}, false
  local before = recordSignature(values)
  local restarted, director = self:_regime(values)

  self:_learn(values, restarted, director)
  if recordSignature(values) ~= before then
    self:_saveValues(values, true)
    before = recordSignature(values)
  end

  if canRename() then
    self:_restoreRenamed(values)
  else
    self:_restoreByName(values, restarted)
  end
  if recordSignature(values) ~= before then
    self:_saveValues(values, true)
  end
  -- Director may be unreadable in OnDriverInit only: ids are learned once it is over, or at the first change.
  if self._stale then
    delay(RECHECK_MS):next(function()
      self:_recheck(self:_load())
    end)
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

--- Resets all values: removes every variable and value, but a name that has been a variable keeps
--- its id, so getValue still returns its record, deleted and with no value.
function Values:reset()
  log:trace("Values:reset()")
  local values = self:_load()
  self:_recheck(values)
  local names = {}
  for name in pairs(values) do
    table.insert(names, name)
  end
  for _, name in ipairs(names) do
    local record = values[name]
    log:debug("Removing value '%s'", name)
    OVC[ovcKey(name)] = nil
    if isLive(record) then
      self:_removeVariable(values, name, record, record.varType)
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

--- What to address a record's variable by: its id, else its name while Director shows it and
--- does not read the name as another id. Nil when there is no variable to address.
--- @private
function Values:_target(name, record)
  if record.id ~= nil and not record.unverified then
    return record.id
  elseif not looksNumeric(name) and Variables[name] ~= nil then
    return name
  end
end

--- After a restore that could not read Director, learns every id from it as a driver update does,
--- once it can say, and writes the result at once.
--- @private
--- @return boolean? learned
function Values:_recheck(values)
  if not self._stale then
    return
  end
  local director = self:_directorVariables()
  if director == nil then
    return
  end
  self._stale = false -- a list that leaves out a name Director shows is not asked for again in this load
  if not self:_learnIds(values, director, {}) then
    return
  end
  dropIdless(values)
  self:_saveValues(values, true)
  return true
end

--- Brings Director in line with a record after an update.
--- @private
--- @return boolean durable True when a variable, a record's id or the set of records changed.
function Values:_applyVariable(values, name, record, existing, strValue)
  local wasVariable = isLive(existing)
  if record.varType == nil then
    if wasVariable then
      OVC[ovcKey(name)] = nil
      self._callbacks[name] = nil
      self:_removeVariable(values, name, record, existing.varType)
    end
    record.deleted = record.id ~= nil or nil
    return wasVariable
  end

  local present = Variables[directorName(name, record)]
  if present ~= nil and (wasVariable or record.id == nil) and not self._unhide[name] then
    local idBefore = record.id
    if record.id == nil then
      local found = self:_findVariable(name)
      local holderName, holder
      if found ~= nil then
        holderName, holder = ownerOf(values, found.id)
      end
      if found ~= nil and (found.hidden or (holder ~= nil and not holder.placeholder)) then
        present = nil -- an older build's placeholder, or at another name's id: a variable of its own
      elseif found ~= nil then
        if holderName ~= nil then
          values[holderName] = nil -- reserved at the switch as not ours
        end
        record.id = found.id -- Director already has a visible variable of this name: take it over at its id
      end
    end
    if present ~= nil then
      local target = self:_target(name, record)
      if present ~= strValue and target ~= nil then
        C4:SetVariable(target, strValue)
      end
      return record.id ~= idBefore or not wasVariable
    end
  end

  record.deleted = nil
  self._unhide[name] = nil
  local left
  if not canRename() and existing ~= nil and existing.id ~= nil and not wasVariable then
    left = self:_leaveBehind(values, name, record, existing.varType)
  end
  local claimed = record.id == nil and self:_claimNumbered(values, name, record)
  local created = self:_createVariable(values, name, record, strValue)
  if left ~= nil and record.id ~= nil then
    log:warn(
      "%s returns at id %s; its id %s stays held, so programming on it must be pointed at the new one",
      name,
      record.id,
      left
    )
  end
  return created or left ~= nil or claimed
end

--- Below the first id only a numeric-looking name can own an id, so a variable there named
--- by the id this name spells is this name's, left by an older build that lost its record.
--- @private
function Values:_claimNumbered(values, name, record)
  local id = parsedId(name)
  if id == nil or id >= FIRST_ID then
    return false
  end
  local ownerName, owner = ownerOf(values, id)
  local named = values[tostring(id)]
  if owner ~= nil and not owner.placeholder then
    return false -- another name's id
  elseif owner == nil and (Variables[tostring(id)] == nil or (named ~= nil and named.id ~= nil)) then
    return false -- nothing there, or the variable named by the id is another record's, renamed at its own id
  end
  if ownerName ~= nil then
    values[ownerName] = nil
  end
  if Variables[tostring(id)] ~= nil then
    C4:DeleteVariable(id)
  end
  record.id = id
  return true
end

--- Removes a record's variable. Without a rename its id stays held by a hidden variable,
--- so nothing after it moves.
--- @private
function Values:_removeVariable(values, name, record, varType)
  local target = self:_target(name, record)
  if target ~= nil then
    C4:DeleteVariable(target)
  end
  if canRename() or record.id == nil then
    return
  end
  if record.unverified then
    -- Only a guess from restore order, held if free as the switch holds a deleted name's guess.
    if self:_hold(record.id, varType) then
      record.unverified = nil
    else
      log:warn("The variable id of %s is not known, so nothing holds it", name)
      record.id, record.unverified = nil, nil
    end
  elseif not self:_hold(record.id, varType) then
    log:error("Could not hold variable id %s of %s with a hidden variable", record.id, name)
  end
end

--- Holds an id with a hidden variable added by number.
--- @private
--- @return boolean added False when the id is taken or Director refuses.
function Values:_hold(id, varType)
  local ok, added = pcall(C4.AddVariable, C4, id, "", varType or "STRING", true, true)
  if not ok and varType ~= nil and varType ~= "STRING" then
    ok, added = pcall(C4.AddVariable, C4, id, "", "STRING", true, true)
  end
  if not ok then
    log:error("Holding variable id %s failed: %s", id, added)
    return false
  end
  return added and true or false
end

--- Holds the first free id, where a by-name add would land while nothing below has been deleted.
--- @private
--- @return integer? id
function Values:_holdFree()
  for id = FIRST_ID, FIRST_ID + MAX_ID_TRIES do
    if self:_hold(id) then
      return id
    end
  end
end

--- Keeps an id no name owns reserved under a record of its own.
--- @private
function Values:_reserve(values, id, avoid)
  values[placeholderKey(values, id, avoid)] =
    { index = maxIndex(values) + 1, id = id, varType = "STRING", deleted = true, placeholder = true }
end

--- A name that returns without a rename cannot take its old id back: the id stays held
--- under a record of its own, and the name gets a new one.
--- @private
--- @return integer? left The id it left behind.
function Values:_leaveBehind(values, name, record, varType)
  local id = record.id
  if record.unverified then
    record.id, record.unverified = nil, nil -- only a guess: nothing of ours is known to be there
    return nil
  elseif parsedId(name) == id then
    -- Director puts a numeric name at the id it spells, so its own hold gives way.
    C4:DeleteVariable(id)
    return nil
  end
  values[placeholderKey(values, id, name)] = {
    index = record.index,
    id = id,
    varType = varType or "STRING",
    deleted = true,
    placeholder = true,
  }
  record.id = nil
  if Variables[tostring(id)] == nil then
    -- Not held by number: an older build holds it under the name, or nothing does.
    local found = self:_findVariable(name)
    if (found ~= nil and found.id == id) or (found == nil and Variables[name] ~= nil) then
      C4:DeleteVariable(id)
    end
    if not self:_hold(id, varType) then
      log:error("Could not hold variable id %s of %s with a hidden variable", id, name)
    end
  end
  return id
end

--- Deletes a variable that carries the name but is not the record's (an older build's hidden
--- placeholder, or a stray). Its id stays reserved, and without a rename held.
--- @private
--- @return boolean changed True when a record was added or the record took an id.
function Values:_clearName(values, name, record)
  if Variables[name] == nil then
    return false
  end
  local found = self:_findVariable(name)
  if found == nil then
    if not looksNumeric(name) then
      C4:DeleteVariable(name) -- Director cannot say where it is
    end
    return false
  end
  local _, owner = ownerOf(values, found.id)
  if owner ~= nil and owner ~= record and name == tostring(found.id) then
    return false -- another record's hold, named by its number as this name is
  end
  C4:DeleteVariable(found.id)
  if canRename() and record.id == nil and found.hidden and owner == nil then
    record.id = found.id -- the name's old placeholder: it comes back at that id
    return true
  end
  if owner == nil then
    self:_reserve(values, found.id, name)
  end
  if not canRename() and not self:_hold(found.id) then
    log:error("Could not hold variable id %s of %s with a hidden variable", found.id, name)
  end
  return owner == nil
end

--- Creates a record's variable: at its id with a rename, else by name. "" never gets one.
--- @private
--- @return boolean changed True when a variable was created or an id or record changed.
function Values:_createVariable(values, name, record, strValue)
  if name == "" then
    return false
  elseif canRename() then
    return self:_createRenamed(values, name, record, strValue)
  end
  return self:_createByName(values, name, record, strValue)
end

--- Adds the variable at the record's id (a new one above every id recorded) and names it.
--- @private
function Values:_createRenamed(values, name, record, strValue)
  if self._rejected[name] then
    return false
  end
  local readOnly = not record.writable
  local changed = self:_clearName(values, name, record)
  if
    record.id ~= nil
    and not self:_addAt(values, record.id, name, strValue, record.varType, readOnly, not record.unverified)
  then
    log:error("Variable id %s of %s is taken by another variable; %s gets a new id", record.id, name, name)
    if not record.unverified then
      self:_reserve(values, record.id, name)
    end
    record.id = nil
  end
  if record.id == nil then
    local id = maxId(values) + 1
    for _ = 1, MAX_ID_TRIES do
      if self:_addAt(values, id, name, strValue, record.varType, readOnly, false) then
        record.id = id
        break
      end
      id = id + 1
    end
    if record.id == nil then
      log:error("Found no free variable id for %s", name)
      record.unverified = nil
      return changed
    end
  end
  record.unverified = nil
  return true
end

--- Adds a variable at exactly that id and names it. At a record's own id, one named by its number
--- (an older build's numeric name, or a failed rename) is ours and is named; a hidden one gives way.
--- @private
--- @return boolean added
function Values:_addAt(values, id, name, strValue, varType, readOnly, own)
  local added = C4:AddVariable(id, strValue, varType, readOnly, false)
  if not added and own then
    local director = self:_directorVariables()
    local occupant = director and director[id]
    local named = values[tostring(id)]
    if director == nil and Variables[tostring(id)] ~= nil and (named == nil or named.id == nil or named.id == id) then
      occupant = { name = tostring(id) } -- no other record is named by the id, so that variable is at it
    end
    if occupant ~= nil and not occupant.hidden and occupant.name == tostring(id) then
      C4:SetVariable(id, strValue)
      added = true
    elseif occupant ~= nil and occupant.hidden then
      C4:DeleteVariable(id)
      added = C4:AddVariable(id, strValue, varType, readOnly, false)
    end
  end
  local aside
  if not added then
    -- A variable of ours named like this id blocks the add; it steps aside under a name no variable has.
    local holder, asideName = values[tostring(id)], ASIDE_NAME
    while Variables[asideName] ~= nil or asideName == name do
      asideName = asideName .. "_"
    end
    if
      Variables[tostring(id)] ~= nil
      and isLive(holder)
      and holder.id ~= nil
      and holder.id ~= id
      and rename(holder.id, asideName)
    then
      aside = holder.id
      added = C4:AddVariable(id, strValue, varType, readOnly, false)
    end
  end
  if added and name ~= tostring(id) and not rename(id, name) then
    -- It keeps the id; no second variable is added for the name in this load.
    log:error("Variable %s could not be named %s", id, name)
    self._rejected[name] = true
  end
  if aside ~= nil and not rename(aside, tostring(id)) then
    log:error("Variable %s could not be named %s again", aside, id)
  end
  return added and true or false
end

--- Adds the variable by name, without a rename, and records the id Director gives it.
--- @private
--- @return boolean changed True when a variable was created or an id or record changed.
function Values:_createByName(values, name, record, strValue)
  if self._rejected[name] then
    return false
  end
  local changed = self:_clearName(values, name, record)
  for id in pairs(self._unheld) do
    if self:_hold(id) then
      self._unheld[id] = nil
    end
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
    return changed
  end
  local guessed = false
  if id == nil then
    local found = self:_findVariable(looksNumeric(name) and tostring(parsedId(name)) or name)
    id = found and found.id
    if id == nil and record.id ~= nil then
      id, guessed = record.id, true -- Director cannot say: kept, and learned once it can
      self._stale = true
    end
  end
  if record.id ~= nil and id ~= record.id then
    log:error("Variable %s took id %s, not its id %s", name, id, record.id)
  end
  for other, held in pairs(values) do
    if id ~= nil and held.id == id and held ~= record then
      log:error("Variable %s took id %s, which %s held without a variable", name, id, other)
      held.id, held.unverified = nil, nil
      if holdsValue(held) then
        held.deleted = nil -- a plain value keeps its value, without the id
      else
        values[other] = nil
      end
    end
  end
  record.id = id
  record.unverified = guessed or nil
  return true
end

--- This device's variables from Director as id -> { name, hidden }, or nil if it cannot say.
--- @private
function Values:_directorVariables()
  local ok, variables = pcall(C4.GetDeviceVariables, C4, C4:GetDeviceID())
  local out, failure = {}, nil
  if not ok or type(variables) ~= "table" then
    out, failure = nil, ok and type(variables) or tostring(variables)
  else
    for id, variable in pairs(variables) do
      if tonumber(id) ~= nil and type(variable) == "table" and variable.name ~= nil then
        out[tonumber(id)] = {
          name = tostring(variable.name),
          hidden = variable.hidden == true or variable.hidden == "True",
        }
      end
    end
    if next(out) == nil and next(Variables) ~= nil then
      out, failure = nil, "it lists none of the driver's variables" -- read before any was added
    end
  end
  if out == nil and not self._unreadWarned then
    log:warn("GetDeviceVariables failed: %s", failure)
    self._unreadWarned = true
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

--- Whether Director was restarted: a driver update keeps every variable, an older build's hidden
--- ones and numeric leftovers below the first id included; a restart keeps none.
--- @private
--- @return boolean restarted
--- @return table? director
function Values:_regime(values)
  for name, record in pairs(values) do
    local p = record.id == nil and parsedId(name)
    if Variables[directorName(name, record)] ~= nil or (p and Variables[tostring(p)] ~= nil) then
      return false
    end
  end
  if next(Variables) == nil then
    return true
  end
  local director = self:_directorVariables()
  for id, variable in pairs(director or {}) do
    if variable.hidden or id < FIRST_ID then
      return false, director
    end
  end
  return true, director
end

--- Gives every record the id Director has for it now, on every load after a driver update;
--- on the first load after an older build with no id recorded, also after a restart.
--- @private
function Values:_learn(values, restarted, director)
  local pending, anyId = false, false
  for _, record in pairs(values) do
    if record.id ~= nil then
      anyId = true
    elseif record.deleted or record.varType ~= nil then
      pending = true
    end
  end

  local estimated, rows = olderBuildIds(values)
  if restarted then
    if pending and not anyId then
      self:_restoreAsOlderBuild(rows)
    end
    -- A record an older build wrote has no id: it takes the one that build's restart gives it, if free.
    for _, row in ipairs(rows) do
      local id = estimated[row.name]
      if row.record.id == nil and id ~= nil and ownerOf(values, id) == nil then
        row.record.id = id
      end
    end
    -- Director listed these before restore added any: not lib/values' variables, so their ids stay reserved.
    local others = {}
    for id in pairs(director or {}) do
      if ownerOf(values, id) == nil then
        table.insert(others, id)
      end
    end
    table.sort(others)
    for _, id in ipairs(others) do
      self:_reserve(values, id)
    end
  else
    director = director or self:_directorVariables()
    self._stale = director == nil or not self:_learnIds(values, director, estimated)
    if self._stale and pending then
      log:warn("Director's variables could not be read; variable ids are taken from restore order")
      local held = {}
      for _, record in pairs(values) do
        if record.id ~= nil then
          held[record.id] = true
        end
      end
      -- Without a rename an id must stay held by a variable: a shown name's estimate is checked later,
      -- a deleted name's is held now if free, as the older build's restore would have held it.
      for _, row in ipairs(rows) do
        local id, record = estimated[row.name], row.record
        if record.id == nil and id ~= nil and not held[id] then
          if id == spelledId(values, row.name) then
            record.id = id -- an older build's add by name put it at the id it spells
            held[id] = true
          elseif canRename() or Variables[row.name] ~= nil then
            record.id, record.unverified = id, true
            held[id] = true
          elseif record.deleted and self:_hold(id, record.varType) then
            record.id = id
            held[id] = true
          end
        end
      end
    end
  end

  dropIdless(values)
end

--- On a Director restart with no ids recorded, does what the older build's restore did,
--- and records the id each variable gets.
--- @private
function Values:_restoreAsOlderBuild(rows)
  for _, row in ipairs(rows) do
    local name, record = row.name, row.record
    local ok, added, id
    if name == "" then
      -- The older build added it by name, at the first free id; this build holds that id instead.
      ok, id = true, self:_holdFree()
      added = id ~= nil
    elseif record.deleted then
      ok, added, id = pcall(C4.AddVariable, C4, name, "", record.varType or "STRING", true, true)
    else
      local strValue = variableString(record.value)
      ok, added, id = pcall(C4.AddVariable, C4, name, strValue, record.varType, not record.writable, false)
    end
    if not ok then
      log:error("Restoring variable %s failed: %s", name, added)
    elseif added then
      record.id = id -- where Director cannot say, the restore-order id is given below
    end
  end
end

--- Takes each record's id from Director, changing nothing when Director shows a name it does
--- not list. Every other variable's id is kept reserved under a record of its own.
--- @private
--- @return boolean learned
function Values:_learnIds(values, director, estimated)
  local byName = {}
  for id, variable in pairs(director) do
    byName[variable.name] = id
  end
  local names = {}
  for name, record in pairs(values) do
    -- An older build turning a numeric-looking name plain left its variable, named by the id.
    if wasEverVariable(record) or looksNumeric(name) then
      if Variables[name] ~= nil and byName[name] == nil then
        return false
      end
      table.insert(names, name)
    end
  end
  table.sort(names)

  -- An older build's by-name add of a numeric-looking name lands on the id it spells.
  local function numbered(name)
    local p = parsedId(name)
    if p ~= nil and byName[tostring(p)] == p and (values[tostring(p)] == nil or tostring(p) == name) then
      return p
    end
  end

  local owner, want = {}, {}
  local function claim(name, id)
    if id ~= nil and owner[id] == nil and want[name] == nil then
      owner[id], want[name] = name, id
    end
  end
  -- Where Director shows a live record's name visible now, then a record's recorded id while no
  -- other record is shown there, then where Director shows the rest, then the id restore order gives.
  for _, name in ipairs(names) do
    local id = byName[name]
    if isLive(values[name]) and id ~= nil and not director[id].hidden then
      claim(name, id)
    end
  end
  for _, name in ipairs(names) do
    if not values[name].unverified then
      claim(name, values[name].id)
    end
  end
  for _, name in ipairs(names) do
    claim(name, byName[name] or numbered(name))
  end
  for _, name in ipairs(names) do
    local record = values[name]
    local id = record.unverified and record.id or estimated[name] -- a stored estimate used the older build's order
    if want[name] == nil and id ~= nil and director[id] == nil then
      claim(name, id)
    end
  end

  local lost = {}
  for _, name in ipairs(names) do
    local record = values[name]
    if record.id ~= nil and not record.unverified and record.id ~= want[name] then
      log:info("Variable %s is at id %s, not %s", name, tostring(want[name]), record.id)
      lost[record.id] = true
    end
    record.id, record.unverified = want[name], nil
    if record.varType == nil and record.value ~= nil then
      record.deleted = record.id ~= nil or nil -- a plain value is stored deleted while it keeps an id
    end
    local variable = record.id and director[record.id]
    if record.deleted and record.varType ~= nil and variable and not variable.hidden and variable.name == name then
      record.deleted = nil -- an older build deleted it, then wrote it again: Director shows it
    end
    if
      variable ~= nil
      and not variable.hidden
      and variable.name ~= name
      and not isLive(record)
      and not record.placeholder
    then
      log:warn("Variable id %s of %s is taken by variable %s", record.id, name, variable.name)
    end
    if variable ~= nil and variable.hidden and isLive(record) and canRename() then
      self._unhide[name] = true
    end
  end

  -- An id once recorded, and any other variable's, stays reserved: a hidden one under its name.
  for id in pairs(lost) do
    if owner[id] == nil and director[id] == nil then
      owner[id] = true
      self:_reserve(values, id)
    end
  end
  local others = {}
  for id in pairs(director) do
    if owner[id] == nil then
      table.insert(others, id)
    end
  end
  table.sort(others)
  for _, id in ipairs(others) do
    local variable = director[id]
    if not variable.hidden then
      log:info("Holding variable id %s of variable %s, which is not ours", id, variable.name)
      self:_reserve(values, id)
    else
      log:info("Holding variable id %s of hidden variable %s", id, variable.name)
      if values[variable.name] == nil and id >= FIRST_ID then
        values[variable.name] = { index = maxIndex(values) + 1, id = id, varType = "STRING", deleted = true }
      else
        self:_reserve(values, id) -- below the first id it is named for any name that spells its id
      end
    end
  end
  return true
end

--- Restore with a rename: each variable Director lacks is added at its id and named.
--- @private
function Values:_restoreRenamed(values)
  local names = {}
  for name, record in pairs(values) do
    if isLive(record) then
      table.insert(names, name)
    end
  end
  -- A record with no id gets the next one, so they go in the order an older build restores them.
  table.sort(names, function(a, b)
    local ia, ib = values[a].index or 0, values[b].index or 0
    return ia < ib or (ia == ib and a < b)
  end)
  for _, name in ipairs(names) do
    self:_restoreOne(values, name)
  end
end

--- Restore without a rename, from the first id up: a variable by name lands on its id since every lower id
--- is taken, any other id gets a hidden variable by number. After a driver update only what is missing.
--- @private
function Values:_restoreByName(values, restarted)
  local owner, ids, walkTo = {}, {}, FIRST_ID - 1
  local unplaced = {}
  for name, record in pairs(values) do
    if record.id ~= nil then
      owner[record.id] = name
      table.insert(ids, record.id)
      if isLive(record) and not looksNumeric(name) and record.id > walkTo then
        walkTo = record.id
      end
    elseif isLive(record) then
      table.insert(unplaced, name)
    end
  end
  -- Every id up to the last one a by-name add must land on, then the rest.
  for id = FIRST_ID, walkTo do
    if owner[id] == nil then
      table.insert(ids, id)
    end
  end
  table.sort(ids)
  table.sort(unplaced, function(a, b)
    return (values[a].index or 0) < (values[b].index or 0) or (values[a].index == values[b].index and a < b)
  end)

  for _, id in ipairs(ids) do
    local name = owner[id]
    local record = name and values[name]
    if isLive(record) and name ~= "" then
      self:_restoreOne(values, name)
      -- Not added at its id: held instead, so no later name takes it.
      if record.id == id and Variables[directorName(name, record)] == nil and not self:_hold(id) then
        log:warn("Variable id %s of %s is taken by another variable", id, name)
      end
    elseif record ~= nil or restarted then
      local held = Variables[tostring(id)] ~= nil
      if not held and record ~= nil and Variables[name] ~= nil then
        local found = self:_findVariable(name) -- an older build may have left the name at another id
        held = found ~= nil and found.id == id
      end
      if not held and not self:_hold(id, record and record.varType) then
        -- A placeholder reserves the id of a variable that is not ours, so that one is expected there.
        local report = record ~= nil and record.placeholder and log.debug or log.warn
        report(log, "Variable id %s%s is taken by another variable", id, name and (" of " .. name) or "")
        self._unheld[id] = true
      end
    end
  end

  for _, name in ipairs(unplaced) do
    self:_restoreOne(values, name)
  end
end

--- Restores one live record's variable; a failure is logged and the rest carry on.
--- @private
function Values:_restoreOne(values, name)
  local record = values[name]
  if not isLive(record) then
    return
  end
  local ok, err = pcall(self._restoreVariable, self, values, name, record)
  if not ok then
    log:error("Restoring variable %s failed: %s", name, err)
  end
end

--- Adds a live record's variable if Director lacks it, else brings its value up to date.
--- @private
function Values:_restoreVariable(values, name, record)
  local strValue = variableString(record.value)
  local present = Variables[directorName(name, record)]
  if present == nil and self._unhide[name] then
    present = Variables[tostring(record.id)] -- a numeric name left hidden under its id: shown at its next update
  end
  if present == nil then
    log:debug("Restoring %s variable %s at id %s", record.varType, name, record.id)
    self:_createVariable(values, name, record, strValue)
  elseif present ~= strValue then
    local target = self:_target(name, record)
    if target ~= nil then
      C4:SetVariable(target, strValue)
    end
  end
end

return Values:new()
