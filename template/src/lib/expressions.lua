--- Expressions over device variables: `PARAM{device,variable}` tokens, evaluation
--- in the sandbox, and watches that recompute an expression when a variable it
--- references changes.
---
--- Each watched variable has one listener, ref counted across expressions. A change
--- only schedules work: a trailing-edge debounce timer per expression does the
--- recompute, so chatty variables coalesce.
---
--- Director sends a driver no listener events for its own variables. A driver whose
--- expressions read its own variables calls notifyVariableChanged after writing them.

local log = require("lib.logging")
local sandbox = require("lib.expression-sandbox")

require("drivers-common-public.global.handlers")
require("drivers-common-public.global.timer")
require("lib.utils")

--- Lua pattern matching a PARAM{device,variable} token, capturing the two ids
--- with surrounding whitespace trimmed.
local PARAM_PATTERN = "PARAM%s*{%s*(.-)%s*,%s*(.-)%s*}"

--- Placeholder emitted when a PARAM{} token references a missing variable.
local ERROR_VARIABLE_NOT_FOUND = "ERROR_VARIABLE_NOT_FOUND"

--- Devices removed from the project since the driver loaded. An id doesn't come back.
--- @type table<integer, boolean>
local removedDevices = {}

--- @class ExpressionReference
--- @field deviceId integer
--- @field variableId integer

--- @class MissingReference
--- @field device string The token's device.
--- @field variable string The token's variable.

--- @class ExpressionEvaluation
--- @field rendered string The template with each token as `[Device > Variable]`.
--- @field substituted string The template with each token's current value.
--- @field result? any The result, when it evaluated.
--- @field error? string Why it didn't.

--- @class Expressions
--- @field _refs table<string, table<string, boolean>> varKey -> set of expression names
--- @field _byExpression table<string, string[]> expression name -> list of varKeys
--- @field _missing table<string, integer> expression name -> references last found missing
--- @field _retries table<string, integer> expression name -> retries used
--- @field _debounceMs number
--- @field _retryMs number
--- @field _retryAttempts integer
--- @field _getExpressions fun(): table<string, table>
--- @field _extractRefs fun(template: string): ExpressionReference[], MissingReference[]?
--- @field _recompute fun(name: string)
local Expressions = {}
Expressions.__index = Expressions

--- How long a variable that isn't there yet is waited for, between tries and in tries:
--- ten minutes covers a Director restart, when each driver adds its variables again.
Expressions.RETRY_MS = 30000
Expressions.RETRY_ATTEMPTS = 20

---------------------------------------------------------------------------
-- Tokens
---------------------------------------------------------------------------

--- Find a token's variable on a device. C4:GetVariable requires a numeric variable
--- id, so a name is looked up against the device's variables, and a numeric
--- reference is mapped back to its name for display.
--- @param deviceId integer
--- @param variable string The variable id or name.
--- @return integer|nil variableId The numeric id, or nil if a name isn't found.
--- @return string name The variable name, falling back to the raw reference.
--- @return boolean listed Whether the device lists that variable now.
local function resolveVariable(deviceId, variable)
  local ok, vars = pcall(function()
    return C4:GetDeviceVariables(deviceId)
  end)
  vars = (ok and type(vars) == "table") and vars or {}
  local asId = tonumber(variable)
  for id, v in pairs(vars) do
    if type(v) == "table" then
      if asId and tonumber(id) == asId then
        return asId, v.name or variable, true
      elseif not asId and v.name == variable then
        return tonumber(id), variable, true
      end
    end
  end
  return asId, variable, false
end

--- Say why a token has no value.
--- @param device string The token's device.
--- @param variable string The token's variable.
--- @return string reason
local function missingReason(device, variable)
  local deviceId = tonumber(device)
  if deviceId and removedDevices[deviceId] then
    return string.format("device %s was removed from the project", device)
  end
  local found = false
  if deviceId then
    local listedOk, devices = pcall(function()
      return C4:GetDevices({ DeviceIds = tostring(deviceId) })
    end)
    local varsOk, vars = pcall(function()
      return C4:GetDeviceVariables(deviceId)
    end)
    -- C4:GetDevices doesn't list an agent, such as the one holding Composer's globals: its variables say it's there.
    found = (listedOk and type(devices) == "table" and devices[deviceId] ~= nil)
      or (varsOk and type(vars) == "table" and next(vars) ~= nil)
  end
  if not found then
    return string.format("device %s not found", device)
  end
  return string.format("variable %s not found on device %s", variable, device)
end

--- Read the variable a token references.
--- @param device string The token's device.
--- @param variable string The token's variable.
--- @return any|nil value
local function readVariable(device, variable)
  local deviceId = tonumber(device)
  if not deviceId or removedDevices[deviceId] then
    return nil
  end
  local variableId = resolveVariable(deviceId, variable)
  if not variableId then
    return nil
  end
  local ok, value = pcall(function()
    return C4:GetVariable(deviceId, variableId)
  end)
  if not ok then
    return nil
  end
  return value
end

--- The variables a template references.
--- @param template string
--- @return ExpressionReference[] refs Each one that has a numeric id. A numeric token the device doesn't list yet is included, since its id is known.
--- @return MissingReference[] missing Each token the device doesn't list yet, numeric or by name. A removed device's aren't waited for.
function Expressions.references(template)
  local refs, missing = {}, {}
  for device, variable in template:gmatch(PARAM_PATTERN) do
    local deviceId = tonumber(device)
    if deviceId and not removedDevices[deviceId] then
      local variableId, _, listed = resolveVariable(deviceId, variable)
      if variableId then
        refs[#refs + 1] = { deviceId = deviceId, variableId = variableId }
      end
      if not listed then
        missing[#missing + 1] = { device = device, variable = variable }
      end
    end
  end
  return refs, missing
end

--- Replace every PARAM{} token with its variable's current value, or with
--- ERROR_VARIABLE_NOT_FOUND when it has none.
--- @param template string
--- @return string result
--- @return string|nil problem Why the first token that has no value doesn't.
function Expressions.substitute(template)
  local problem
  local result = template:gsub(PARAM_PATTERN, function(device, variable)
    local value = readVariable(device, variable)
    if value == nil then
      local reason = missingReason(device, variable)
      log:warn("Expression reference not found: %s", reason)
      problem = problem or reason
      return ERROR_VARIABLE_NOT_FOUND
    end
    return tostring(value)
  end)
  return result, problem
end

--- Replace every PARAM{} token with `[Device > Variable]`, to show what an
--- expression references at a glance.
--- @param template string
--- @return string rendered
function Expressions.render(template)
  return (
    template:gsub(PARAM_PATTERN, function(device, variable)
      local deviceId = tonumber(device)
      local deviceLabel = "Device " .. device
      local variableLabel = variable
      if deviceId then
        local dev = GetDevice(deviceId)
        if dev and not IsEmpty(dev.displayName) then
          deviceLabel = dev.displayName
        end
        local _, name = resolveVariable(deviceId, variable)
        variableLabel = name
      end
      return string.format("[%s > %s]", deviceLabel, variableLabel)
    end)
  )
end

--- Evaluate a template without touching anything.
--- @param mode string "equation" for a number, "condition" for true or false, "string" for the substituted text.
--- @param template string
--- @return ExpressionEvaluation evaluation
function Expressions.evaluate(mode, template)
  template = template or ""
  local substituted, problem = Expressions.substitute(template)
  local evaluation = { rendered = Expressions.render(template), substituted = substituted }
  if problem then
    evaluation.error = problem
  elseif mode == "string" then
    evaluation.result = substituted
  else
    local result, err = sandbox.eval(substituted)
    local want = mode == "condition" and "boolean" or "number"
    if err then
      evaluation.error = err
    elseif type(result) ~= want then
      evaluation.error = string.format("result is not a %s (got %s)", want, type(result))
    else
      evaluation.result = result
    end
  end
  return evaluation
end

---------------------------------------------------------------------------
-- Device Browser
---------------------------------------------------------------------------

--- Whether a proxy merely restates the device that declares it. A proxy named for
--- itself, such as a security panel's areas, stays its own entry.
--- @param proxy table|nil
--- @param owner table
--- @return boolean
local function isRestatedProxy(proxy, owner)
  return proxy ~= nil and tostring(proxy.deviceName) == tostring(owner.deviceName)
end

--- Section heading for a member of a merged entry, taken from the proxy's .c4i.
--- @param dev table
--- @param isOwner boolean
--- @return string
local function proxySectionLabel(dev, isOwner)
  if isOwner then
    return "Device"
  end
  local file = tostring((dev or {}).driverFileName or "")
  local base = file:match("^(.*)%.c4i$") or file:match("^(.*)%.c4z$")
  return IsEmpty(base) and "Proxy" or base
end

--- The devices with variables, for a page to pick from, by room and name. A driver
--- and the proxy it declares are separate project items sharing a room and name, so
--- they are one entry. A project can hold many items of a driver, so a name that is
--- still not unique in its room gets the device id appended.
--- @return { id: integer, name: string, roomName: string }[] devices
function Expressions.devices()
  log:trace("Expressions.devices()")
  local devices = {}
  local allDevices = C4:GetDevices() or {}

  -- Proxy id -> owning driver id, for proxies that only restate their owner.
  local ownerOf = {}
  for id, dev in pairs(allDevices) do
    for proxyId in pairs(dev.proxies or {}) do
      local pid = tonumber(proxyId) or proxyId
      if isRestatedProxy(allDevices[pid], dev) then
        ownerOf[pid] = id
      end
    end
  end

  -- Collapse chains so a proxy of a proxy still lands in an entry.
  local rootOf, membersOf = {}, {}
  for id in pairs(allDevices) do
    local root, seen = id, { [id] = true }
    while ownerOf[root] ~= nil and not seen[ownerOf[root]] do
      root = ownerOf[root]
      seen[root] = true
    end
    rootOf[id] = root
    membersOf[root] = membersOf[root] or {}
    table.insert(membersOf[root], id)
  end

  for id, dev in pairs(allDevices) do
    if rootOf[id] == id then
      local hasVariables = false
      for _, mid in ipairs(membersOf[id]) do
        local ok, memberVars = pcall(C4.GetDeviceVariables, C4, mid)
        if ok and memberVars ~= nil and next(memberVars) ~= nil then
          hasVariables = true
          break
        end
      end
      if hasVariables then
        devices[#devices + 1] = {
          id = id,
          name = dev.deviceName or ("Device " .. id),
          roomName = dev.roomName or "",
        }
      end
    end
  end
  local labelCounts = {}
  for _, d in ipairs(devices) do
    local label = d.roomName .. " > " .. d.name
    labelCounts[label] = (labelCounts[label] or 0) + 1
  end
  for _, d in ipairs(devices) do
    if labelCounts[d.roomName .. " > " .. d.name] > 1 then
      d.name = string.format("%s (%s)", d.name, d.id)
    end
  end
  table.sort(devices, function(a, b)
    if a.roomName ~= b.roomName then
      return a.roomName < b.roomName
    end
    return a.name < b.name
  end)
  return devices
end

--- A device's variables, for a page to pick from: its own first, then those of the
--- proxies that restate it.
--- @param deviceId integer|string
--- @return { id: integer, deviceId: integer, section: string, order: integer, name: string, type: string, value: any }[]|nil variables Nil when the id isn't a number.
function Expressions.deviceVariables(deviceId)
  log:trace("Expressions.deviceVariables(%s)", deviceId)
  local devId = tonumber(deviceId)
  if not devId then
    return nil
  end

  local entry = C4:GetDevices({ DeviceIds = tostring(devId) })[devId] or {}
  local members = { { id = devId, section = proxySectionLabel(entry, true), order = 1 } }
  local queue, seen = { { id = devId, dev = entry } }, { [devId] = true }
  while #queue > 0 do
    local cur = table.remove(queue, 1)
    -- pairs() over proxies has no defined order, and sections shouldn't change between calls.
    local childIds = {}
    for proxyId in pairs((cur.dev or {}).proxies or {}) do
      childIds[#childIds + 1] = tonumber(proxyId) or proxyId
    end
    table.sort(childIds)
    for _, pid in ipairs(childIds) do
      local proxy = C4:GetDevices({ DeviceIds = tostring(pid) })[pid]
      if not seen[pid] and isRestatedProxy(proxy, cur.dev) then
        seen[pid] = true
        members[#members + 1] = { id = pid, section = proxySectionLabel(proxy, false), order = #members + 1 }
        queue[#queue + 1] = { id = pid, dev = proxy }
      end
    end
  end

  local vars = {}
  for _, member in ipairs(members) do
    local ok, deviceVars = pcall(C4.GetDeviceVariables, C4, member.id)
    if ok and deviceVars then
      for varId, varInfo in pairs(deviceVars) do
        vars[#vars + 1] = {
          id = tonumber(varId),
          deviceId = member.id,
          section = member.section,
          order = member.order,
          name = varInfo.name or ("var" .. varId),
          type = varInfo.type or "STRING",
          value = varInfo.value,
        }
      end
    end
  end
  -- Order on the member's position, not its label: a proxy's .c4i can be named Device,
  -- and LuaJIT's table.sort doesn't reject the cycle that tie makes.
  table.sort(vars, function(a, b)
    if a.order ~= b.order then
      return a.order < b.order
    end
    return a.name < b.name
  end)
  return vars
end

---------------------------------------------------------------------------
-- Watches
---------------------------------------------------------------------------

--- Build the ref key for a device/variable pair.
--- @param deviceId number
--- @param variableId number
--- @return string key e.g. "100:1002"
local function varKey(deviceId, variableId)
  return tostring(deviceId) .. ":" .. tostring(variableId)
end

--- Parse a ref key back into its numeric components.
--- @param key string
--- @return number|nil deviceId
--- @return number|nil variableId
local function parseVarKey(key)
  local devStr, varStr = key:match("^(%d+):(%d+)$")
  if not devStr then
    return nil, nil
  end
  return tonumber(devStr), tonumber(varStr)
end

--- Debounce timer name for an expression.
--- @param name string
--- @return string
local function debounceTimerName(name)
  return "ExprDebounce::" .. name
end

--- Retry timer name for an expression.
--- @param name string
--- @return string
local function retryTimerName(name)
  return "ExprRetry::" .. name
end

--- Create a watch engine.
--- @param opts table Constructor options:
---   - getExpressions: fun(): table<string, table> map of name -> { template, auto }; only auto ones are watched
---   - recompute: fun(name: string) recompute a named expression
---   - extractRefs: fun(template: string): ExpressionReference[], MissingReference[]? defaults to Expressions.references
---   - debounceMs: number? debounce window in milliseconds (default 1000)
---   - retryMs: number? time between tries for a variable that isn't there yet (default RETRY_MS)
---   - retryAttempts: integer? how many tries (default RETRY_ATTEMPTS)
--- @return Expressions
function Expressions:new(opts)
  log:trace("Expressions:new(opts)")
  opts = opts or {}
  local instance = setmetatable({}, self)
  instance._refs = {}
  instance._byExpression = {}
  instance._missing = {}
  instance._retries = {}
  instance._debounceMs = opts.debounceMs or 1000
  instance._retryMs = opts.retryMs or Expressions.RETRY_MS
  instance._retryAttempts = opts.retryAttempts or Expressions.RETRY_ATTEMPTS
  instance._getExpressions = assert(opts.getExpressions, "getExpressions is required")
  instance._extractRefs = opts.extractRefs or Expressions.references
  instance._recompute = assert(opts.recompute, "recompute is required")
  return instance
end

--- Callback invoked when a watched variable's value changes. The change itself does
--- no work.
--- @param deviceId number
--- @param variableId number
function Expressions:_onVariableChanged(deviceId, variableId)
  log:trace("Expressions:_onVariableChanged(%s, %s)", deviceId, variableId)
  local names = self._refs[varKey(deviceId, variableId)]
  if not names then
    return
  end
  for name in pairs(names) do
    self:_scheduleRecompute(name)
  end
end

--- Arm (or re-arm) the trailing-edge debounce timer for an expression. SetTimer
--- cancels any existing timer with the same name, so every change pushes the
--- recompute out by the debounce window.
--- @param name string
function Expressions:_scheduleRecompute(name)
  SetTimer(debounceTimerName(name), self._debounceMs, function()
    local ok, err = pcall(self._recompute, name)
    if not ok then
      log:error("Debounced recompute of '%s' failed: %s", name, err)
    end
  end)
end

--- Register the C4 listener for a variable. Registering again replaces the last.
--- @param key string
function Expressions:_registerListener(key)
  local deviceId, variableId = parseVarKey(key)
  if not deviceId or not variableId then
    return
  end
  RegisterVariableListener(deviceId, variableId, function(devId, varId, _value)
    self:_onVariableChanged(devId, varId)
  end)
  log:info("Watching variable %s", key)
end

--- Unregister the C4 listener for a variable that has no remaining references.
--- @param key string
function Expressions:_unregisterListener(key)
  local deviceId, variableId = parseVarKey(key)
  if not deviceId or not variableId then
    return
  end
  pcall(UnregisterVariableListener, deviceId, variableId)
  log:info("Stopped watching variable %s (no remaining references)", key)
end

--- Watch what an expression references now, and try again later for what isn't there yet.
--- @param name string
--- @param config table
function Expressions:_watchReferences(name, config)
  local refs, missing = self._extractRefs(config.template or "")
  local missingCount = #(missing or {})
  local wasMissing = self._missing[name]
  local appeared = wasMissing ~= nil and missingCount < wasMissing

  local keys = self._byExpression[name] or {}
  local have = {}
  for _, key in ipairs(keys) do
    have[key] = true
  end
  for _, ref in ipairs(refs) do
    local key = varKey(ref.deviceId, ref.variableId)
    if not have[key] then
      have[key] = true
      keys[#keys + 1] = key
      local isFirstRef = self._refs[key] == nil
      self._refs[key] = self._refs[key] or {}
      self._refs[key][name] = true
      if isFirstRef then
        self:_registerListener(key)
      end
    elseif appeared then
      -- A listener set before a numeric id's variable existed may not have taken.
      self:_registerListener(key)
    end
  end
  self._byExpression[name] = keys

  if appeared then
    self:_scheduleRecompute(name)
  end
  self._missing[name] = missingCount > 0 and missingCount or nil
  if missingCount > 0 then
    self:_scheduleRetry(name)
  else
    self._retries[name] = nil
    CancelTimer(retryTimerName(name))
  end
end

--- Try an expression's missing references again, a limited number of times: another
--- driver's variable doesn't exist until that driver adds it.
--- @param name string
function Expressions:_scheduleRetry(name)
  local used = self._retries[name] or 0
  if used >= self._retryAttempts then
    log:warn("Expression '%s' still references %d missing variable(s); no more retries", name, self._missing[name] or 0)
    self._retries[name] = nil
    return
  end
  self._retries[name] = used + 1
  SetTimer(retryTimerName(name), self._retryMs, function()
    local config = self._getExpressions()[name]
    if config and toboolean(config.auto) then
      self:_watchReferences(name, config)
    end
  end)
end

--- Subscribe an expression to its referenced variables. Only expressions with
--- auto recompute enabled are watched. Call refreshExpression() after an edit.
--- @param name string
function Expressions:subscribeExpression(name)
  log:trace("Expressions:subscribeExpression('%s')", name)
  local config = self._getExpressions()[name]
  if not config or not toboolean(config.auto) then
    return
  end
  self._retries[name] = nil
  self._missing[name] = nil
  self:_watchReferences(name, config)
end

--- Unsubscribe an expression from all of its watched variables. Listeners with no
--- remaining references are unregistered.
--- @param name string
function Expressions:unsubscribeExpression(name)
  log:trace("Expressions:unsubscribeExpression('%s')", name)
  for _, key in ipairs(self._byExpression[name] or {}) do
    local refs = self._refs[key]
    if refs then
      refs[name] = nil
      if not next(refs) then
        self._refs[key] = nil
        self:_unregisterListener(key)
      end
    end
  end
  self._byExpression[name] = nil
  self._missing[name] = nil
  self._retries[name] = nil
  CancelTimer(debounceTimerName(name))
  CancelTimer(retryTimerName(name))
end

--- Refresh an expression's subscriptions after a config change.
--- @param name string
function Expressions:refreshExpression(name)
  log:trace("Expressions:refreshExpression('%s')", name)
  self:unsubscribeExpression(name)
  self:subscribeExpression(name)
end

--- Subscribe every configured expression. Called at late init to restore watches
--- after a restart.
function Expressions:resubscribeAll()
  log:trace("Expressions:resubscribeAll()")
  local count = 0
  for name in pairs(self._getExpressions()) do
    self:subscribeExpression(name)
    count = count + 1
  end
  log:info("resubscribeAll: restored watches for %d expression(s)", count)
end

--- Number of variables an expression is currently watching.
--- @param name string
--- @return number
function Expressions:watchedCount(name)
  return #(self._byExpression[name] or {})
end

--- Notify the engine of a variable change it cannot observe through a C4 listener:
--- a driver's own variables send it none, so the driver calls this after writing
--- them. The writer is excluded to avoid self-referential loops.
--- @param deviceId number
--- @param variableId number
--- @param excludeName string? Expression to skip (the one that wrote the value).
function Expressions:notifyVariableChanged(deviceId, variableId, excludeName)
  log:trace("Expressions:notifyVariableChanged(%s, %s, %s)", deviceId, variableId, excludeName)
  local names = self._refs[varKey(deviceId, variableId)]
  if not names then
    return
  end
  for name in pairs(names) do
    if name ~= excludeName then
      self:_scheduleRecompute(name)
    end
  end
end

--- A device left the project: stop watching it, and recompute the expressions that
--- referenced it, whose evaluation now gives an error result.
--- @param deviceId number
--- @return string[] affected Names of expressions that referenced the device.
function Expressions:handleDeviceRemoved(deviceId)
  log:trace("Expressions:handleDeviceRemoved(%s)", deviceId)
  deviceId = tonumber(deviceId) or deviceId
  removedDevices[deviceId] = true
  local affected = {}
  local prefix = tostring(deviceId) .. ":"
  for key, refs in pairs(self._refs) do
    if key:sub(1, #prefix) == prefix then
      self:_unregisterListener(key)
      for name in pairs(refs) do
        affected[name] = true
        local keys = self._byExpression[name] or {}
        for i = #keys, 1, -1 do
          if keys[i] == key then
            table.remove(keys, i)
          end
        end
      end
      self._refs[key] = nil
    end
  end

  local names = {}
  for name in pairs(affected) do
    names[#names + 1] = name
    self:_scheduleRecompute(name)
  end
  table.sort(names)
  if #names > 0 then
    log:warn("Device %s removed: expression(s) %s reference it", deviceId, table.concat(names, ", "))
  end
  return names
end

return Expressions
