--- A persistence utility module for storing and retrieving values with optional encryption.
--- This module provides a simple key-value store interface with caching capabilities.
---
--- ## Migrations
---
--- Persist supports one-time data migrations between driver versions. This is useful when the
--- structure of persisted data needs to change (e.g., converting integer keys to string keys).
---
--- To define migrations, create a `src/migrations.lua` file that returns a table mapping persist
--- keys to migration functions:
---
--- ```lua
--- -- src/migrations.lua
--- return {
---   ["MyData"] = function(value)
---     -- transform value from old format to new format
---     return transformedValue
---   end,
--- }
--- ```
---
--- Migrations are loaded automatically on the first `get()` call via `pcall(require, "migrations")`.
--- Each migration runs once per key, transforms the value, persists the result, and removes itself.
--- If no `migrations.lua` file exists, persist operates normally with no migrations.
---
--- ## Write-behind
---
--- Every `set()` writes to the controller's storage at once. A key that changes often
--- can opt in to write-behind: its writes made inside `defer()` update the cache at
--- once and reach storage at most once per interval. Writes outside `defer()`, and
--- deletes, still go out at once; `flush()` writes whatever is pending. The scope
--- covers everything `defer()` runs synchronously, including promise callbacks it
--- resolves, so a write there that must be durable needs a `flush()`.
---
--- ```lua
--- persist:setWriteBehind("Readings", 60000)
--- persist:defer(handleFrame, frame) -- sets of "Readings" in here wait
--- persist:flush() -- e.g. from OnDriverDestroyed
--- ```
---
--- ## Storage format
---
--- Every value is stored as base64 of its JSON, which for a table is what `Serialize`
--- writes, so a string, number or boolean reads back as itself after a reload. Builds
--- before this one stored those raw; a raw string still reads back as that string, and
--- the key takes the new form at its next `set()`. A value JSON cannot carry (a NaN, or
--- a string that is not UTF-8 text) is logged and not stored.

local log = require("lib.logging")

require("drivers-common-public.global.lib")
require("lib.utils")

--- A utility class for storing and retrieving values from the controller's persistence store.
--- @class Persist
--- @field _persist table<string, any> A table to store the cached values.
--- @field _writeBehind table<string, number> Flush interval in milliseconds per write-behind key.
--- @field _pending table<string, boolean> The encrypted flag per key with a write waiting for a flush.
--- @field _armed table<string, boolean> Keys whose flush timer is running.
--- @field _deferDepth integer How many `defer()` calls are running.
local Persist = {}
Persist.__index = Persist

--- Sentinel representing an empty value in the persistence store.
--- @type table
local EMPTY = {}

--- Migration functions loaded from the driver's `migrations.lua` module.
--- Populated lazily on first get() call. Each entry maps a persist key to a function that
--- transforms the old value format into the new format.
--- @type table<string, fun(value: any): any>
local MIGRATIONS = {}

--- Whether migrations have been loaded from the driver's migrations module.
--- @type boolean
local migrationsLoaded = false

--- Encodes a value for storage as base64 of its JSON.
--- @param value any The value.
--- @return string|nil stored The stored form, or nil for a NaN or a string that is not UTF-8 text.
local function encode(value)
  if value ~= value then
    return nil
  end
  local json = JSON:encode(value)
  if type(value) == "string" and value:find("[\128-\255]") then
    -- JSON:decode rejects bytes that are not UTF-8, so such a string would not read back.
    local ok, decoded = pcall(JSON.decode, JSON, json)
    if not ok or decoded ~= value then
      return nil
    end
  end
  return C4:Base64Encode(json)
end

--- Decodes a stored value.
--- @param stored any What PersistGetValue returned.
--- @return any value The value, or nil if there is none.
local function decode(stored)
  local value = Deserialize(stored)
  if value == nil then
    -- An older build's raw string: C4:Base64Decode gives "" for one with a space, comma or dot.
    return stored
  end
  return value
end

--- Creates a new instance of the Persist class.
--- @return Persist persist A new instance of the Persist class.
function Persist:new()
  log:trace("Persist:new()")
  local instance = setmetatable({}, self)
  instance._persist = {}
  instance._writeBehind = {}
  instance._pending = {}
  instance._armed = {}
  instance._deferDepth = 0
  return instance
end

--- Loads driver-specific migrations from `migrations.lua` if present.
--- Called automatically on first get(). Safe to call multiple times (no-op after first call).
--- @private
local function loadMigrations()
  if migrationsLoaded then
    return
  end
  migrationsLoaded = true
  local ok, m = pcall(require, "migrations")
  if ok and type(m) == "table" then
    for key, fn in pairs(m) do
      MIGRATIONS[key] = fn
    end
  end
end

--- Retrieves a value from the persistence store.
--- On first call, loads any driver-specific migrations from `migrations.lua`.
--- If a migration exists for the requested key, it runs once, persists the transformed value,
--- and removes itself.
--- @param key string The key to retrieve the value for.
--- @param default? any The default value to return if the key doesn't exist (optional).
--- @param encrypted? boolean Whether the value is encrypted (optional).
--- @return any value The retrieved value, or the default if the key doesn't exist.
function Persist:get(key, default, encrypted)
  log:trace("Persist:get(%s, %s, %s)", key, default, encrypted)
  loadMigrations()
  local value = self:_get(key, default, encrypted)

  if type(MIGRATIONS[key]) == "function" then
    value = MIGRATIONS[key](value)
    MIGRATIONS[key] = nil
    self:set(key, value, encrypted)
  end

  return value
end

--- Internal get implementation with caching.
--- @private
--- @param key string The key to retrieve.
--- @param default any The default value if key is not found.
--- @param encrypted boolean? Whether the value is encrypted.
--- @return any value The retrieved value or default.
function Persist:_get(key, default, encrypted)
  log:trace("Persist:_get(%s, %s, %s)", key, default, encrypted)
  if default == nil then
    default = EMPTY
  end
  local value = self._persist[key]

  if value == nil then
    value = decode(PersistGetValue(key, encrypted))
    if value == nil then
      value = default
    end
    self._persist[key] = value
  end

  if value == EMPTY or value == nil then
    return default
  elseif type(value) == "table" then
    return TableDeepCopy(value)
  else
    return value
  end
end

--- Sets a value in the persistence store. Inside `defer()`, a write-behind key's
--- value is cached at once and written at its next flush.
--- @param key string The key to set the value for.
--- @param value any The value to store. If nil, the key will be deleted.
--- @param encrypted? boolean Whether to encrypt the value (optional).
--- @return void
function Persist:set(key, value, encrypted)
  log:trace("Persist:set(%s, %s, %s)", key, value, encrypted)
  if value == nil then
    self._persist[key] = EMPTY
    self._pending[key] = nil -- a later flush must not bring the key back
    PersistDeleteValue(key)
  else
    if type(value) == "table" then
      self._persist[key] = TableDeepCopy(value)
    else
      self._persist[key] = value
    end
    if self._deferDepth > 0 and self._writeBehind[key] then
      -- Serialized at flush, so a burst of sets encodes the value once.
      self._pending[key] = encrypted == true
      self:_armFlush(key)
    else
      self._pending[key] = nil -- the whole value is written, pending changes included
      self:_write(key, encrypted)
    end
  end
end

--- Opts a key in to write-behind: its sets made inside `defer()` reach storage at
--- most once per `ms`.
--- @param key string The key.
--- @param ms number The flush interval in milliseconds.
--- @return void
function Persist:setWriteBehind(key, ms)
  log:trace("Persist:setWriteBehind(%s, %s)", key, ms)
  self._writeBehind[key] = ms
end

--- Closes a `defer()` scope, then returns or rethrows what pcall gave it.
--- @private
local function leaveDefer(self, ok, ...)
  self._deferDepth = self._deferDepth - 1
  if not ok then
    error((...), 0)
  end
  return ...
end

--- Calls `fn(...)` with sets of write-behind keys held for their next flush.
--- Scopes nest; an error from `fn` is rethrown after the scope closes.
--- @param fn function The function to call.
--- @param ... any Arguments for `fn`.
--- @return any ... What `fn` returns.
function Persist:defer(fn, ...)
  log:trace("Persist:defer(%s)", fn)
  self._deferDepth = self._deferDepth + 1
  return leaveDefer(self, pcall(fn, ...))
end

--- Writes pending write-behind values to storage now.
--- @param key string? The key to flush, or nil for every key.
--- @return void
function Persist:flush(key)
  log:trace("Persist:flush(%s)", key)
  for pendingKey, encrypted in pairs(self._pending) do
    if key == nil or pendingKey == key then
      self._pending[pendingKey] = nil
      self:_write(pendingKey, encrypted)
    end
  end
end

--- Writes a key's cached value to storage.
--- @private
--- @param key string The key.
--- @param encrypted boolean? Whether to encrypt the value.
--- @return void
function Persist:_write(key, encrypted)
  local stored = encode(self._persist[key])
  if stored == nil then
    log:error("Persist: %s is a NaN or a string that is not UTF-8 text, and cannot be stored", key)
    -- Deleted so that a reload reads the default, not the value this set replaced.
    PersistDeleteValue(key)
  else
    PersistSetValue(key, stored, encrypted)
  end
end

--- Starts the key's flush timer unless it is already running.
--- @private
--- @param key string The key.
--- @return void
function Persist:_armFlush(key)
  if self._armed[key] then
    return
  end
  self._armed[key] = true
  delay(self._writeBehind[key]):next(function()
    self._armed[key] = nil
    self:flush(key)
  end)
end

--- Deletes a value from the persistence store.
--- @param key string The key to delete.
--- @return void
function Persist:delete(key)
  log:trace("Persist:delete(%s)", key)
  self:set(key, nil)
end

--- Resets/clears specified keys from the persistence store.
--- @param keys string[] Array of keys to delete.
--- @return void
function Persist:reset(keys)
  log:trace("Persist:reset(%s)", keys)
  for _, key in ipairs(keys) do
    self:delete(key)
  end
end

return Persist:new()
