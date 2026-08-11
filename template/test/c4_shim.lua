--- Shim layer to replace Control4-specific functions with native Lua equivalents
--- for debugging and testing outside the Control4 environment.
---
--- When luasocket is available, provides full networking and timer support.
--- Without luasocket, provides stubs sufficient for module loading and static analysis.

-- Try to load luasocket (optional dependency)
local has_socket, socket = pcall(require, "socket")

-- Lua 5.2+ compatibility: loadstring was removed in favor of load
if not loadstring then
  loadstring = load
end

-- Global C4 object shim
C4 = {}
Properties = {}
Variables = {}

-- Stub C4 functions that are called but not needed for testing
function C4:GetDriverConfigInfo()
  return nil
end
function C4:GetDeviceID()
  return 12345
end
function C4:GetDeviceData(deviceId, key)
  if key == "name" then
    return "Test Device"
  end
  return nil
end
function C4:AllowExecute() end
function C4:UpdateProperty() end
function C4:SetPropertyAttribs() end
function C4:GetVersionInfo()
  return { version = "test" }
end
function C4:FileSetDir() end
function C4:SendToDevice() end
function C4:SendToProxy() end
function C4:SendToNetwork() end
function C4:SendUIRequest()
  return ""
end
function C4:GetBindingsByDevice()
  return {}
end
function C4:FileExists()
  return false
end
function C4:FileOpen()
  return nil
end
function C4:FileGetSize()
  return 0
end
function C4:FileSetPos() end
function C4:FileRead()
  return ""
end
function C4:FileClose() end
function C4:FileDelete() end
function C4:FileWrite()
  return 0
end

--- Logging functions for C4 compatibility
function C4:ErrorLog(message)
  io.stderr:write(message .. "\n")
  io.stderr:flush()
end

function C4:DebugLog(message)
  print(message)
end

--- Base64 encoding/decoding
local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode_impl(data)
  if type(data) ~= "string" then
    return nil
  end
  return (
    (data:gsub(".", function(x)
      local r, b = "", x:byte()
      for i = 8, 1, -1 do
        r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0")
      end
      return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
      if #x < 6 then
        return ""
      end
      local c = 0
      for i = 1, 6 do
        c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0)
      end
      return base64_chars:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1]
  )
end

local function base64_decode_impl(data)
  if type(data) ~= "string" then
    error("Invalid base64 data type")
  end
  data = string.gsub(data, "[^" .. base64_chars .. "=]", "")
  return (
    data
      :gsub(".", function(x)
        if x == "=" then
          return ""
        end
        local r, f = "", (base64_chars:find(x) - 1)
        for i = 6, 1, -1 do
          r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0")
        end
        return r
      end)
      :gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then
          return ""
        end
        local c = 0
        for i = 1, 8 do
          c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0)
        end
        return string.char(c)
      end)
  )
end

-- Handle both C4:Base64Encode() and C4.Base64Encode(C4, ...) calling styles
function C4:Base64Encode(data, ...)
  if type(data) == "table" and data == C4 then
    local realData = select(1, ...)
    return base64_encode_impl(realData)
  else
    return base64_encode_impl(data)
  end
end

-- Handle both C4:Base64Decode() and C4.Base64Decode(C4, ...) calling styles
function C4:Base64Decode(data, ...)
  -- If called as C4.Base64Decode(C4, data), first arg is C4
  -- If called as C4:Base64Decode(data), first arg is data
  if type(data) == "table" and data == C4 then
    -- Called as C4.Base64Decode(C4, data) - get the real data argument
    local realData = select(1, ...)
    return base64_decode_impl(realData)
  else
    -- Called as C4:Base64Decode(data)
    return base64_decode_impl(data)
  end
end

--- Generate a UUID (simplified version)
local uuid_counter = 0
function C4:UUID(prefix)
  uuid_counter = uuid_counter + 1
  return string.format("%s-%d-%d", prefix or "UUID", os.time(), uuid_counter)
end

---------------------------------------------------------------------------
-- Variables
-- Mirrors the controller rather than accommodating callers: values are always
-- strings, updates are synchronous, and nothing is coerced or auto-created.
-- test/test_c4_shim.lua pins each behaviour, measured on a dev controller.
---------------------------------------------------------------------------

-- Accepted on hardware. The controller's error message names only four types.
-- Each maps to the code C4:GetDeviceVariables reports, measured one varType at
-- a time: NUMBER and INT share 2, and nothing observed reports 7.
local var_type_codes = {
  STRING = 1,
  INT = 2,
  NUMBER = 2,
  FLOAT = 3,
  BOOL = 4,
  LEVEL = 5,
  STATE = 6,
  TIME = 8,
  ROOM = 9,
  MEDIA = 10,
  LIST = 11,
  ULONG = 12,
  XML = 13,
  DEVICE = 14,
}

-- Director numbers each device's variables from 1001 and never reuses an id, so
-- a deleted name returns at the end of the range. lib/values.lua restores hidden
-- placeholders to keep that range stable, which is what makes ids worth modelling.
local next_variable_id = 1001

--- Id and attributes per variable name, behind C4:GetDeviceVariables. The value
--- is read from Variables at call time so a SetVariable needs no bookkeeping here.
--- @type table<string, { id: string, type: string, readonly: string, hidden: string }>
local variable_meta = {}

-- Strings and numbers only; nil means the controller would reject the value.
local function var_value(value)
  if type(value) == "string" then
    return value
  elseif type(value) == "number" then
    return tostring(value)
  end
end

-- Checks run in the controller's order: the value, then that varType is a
-- string, then the existing-name return, and only then whether varType names a
-- real type. An existing name returns false without ever validating varType.
function C4:AddVariable(name, value, varType, readOnly, hidden)
  local strValue = var_value(value)
  if strValue == nil then
    error("strValue should be a string", 2)
  end
  if type(varType) ~= "string" then
    error("strVarType should be a string", 2)
  end

  name = tostring(name)

  -- Already present: the controller keeps the existing value and type
  if Variables[name] ~= nil then
    return false
  end

  if not var_type_codes[varType] then
    error("Invalid variable type.  Valid types include: BOOL, LEVEL, NUMBER, STRING.", 2)
  end

  Variables[name] = strValue
  variable_meta[name] = {
    id = tostring(next_variable_id),
    type = tostring(var_type_codes[varType]),
    readonly = readOnly == true and "True" or "False",
    hidden = hidden == true and "True" or "False",
  }
  next_variable_id = next_variable_id + 1
  return true
end

-- The value is checked before the name is looked up, so a bad value raises even
-- on a name that was never added.
function C4:SetVariable(name, value)
  local strValue = var_value(value)
  if strValue == nil then
    error("strValue should be a string", 2)
  end
  name = tostring(name)

  -- Never added: silently does nothing, and does not create it
  if Variables[name] == nil then
    return
  end

  Variables[name] = strValue
end

function C4:DeleteVariable(name)
  name = tostring(name)
  Variables[name] = nil
  variable_meta[name] = nil
end

-- Keyed by id as a string, with every field a string: `type` is a numeric code,
-- `readonly` and `hidden` are "True"/"False", and `description` is always empty
-- because AddVariable cannot set one. A device with no variables and a device
-- that does not exist both give an empty table, and hidden variables are
-- returned rather than filtered out.
function C4:GetDeviceVariables(deviceId)
  local variables = {}
  if deviceId ~= C4:GetDeviceID() then
    return variables
  end
  for name, meta in pairs(variable_meta) do
    variables[meta.id] = {
      name = name,
      description = "",
      value = Variables[name],
      type = meta.type,
      readonly = meta.readonly,
      hidden = meta.hidden,
    }
  end
  return variables
end

-- Persistence stubs (in-memory storage for testing)
local persist_store = {}

function PersistGetValue(key, encrypted)
  return persist_store[key]
end

function PersistSetValue(key, value, encrypted)
  persist_store[key] = value
end

function PersistDeleteValue(key)
  persist_store[key] = nil
end

---------------------------------------------------------------------------
-- Timer handles
-- A controller returns userdata from C4:SetTimer, and global/timer.lua only
-- resolves a handle when `type(timerId) == "userdata"`, so a table handle
-- makes every CancelTimer a silent no-op under test. newproxy(true) is the
-- only way to mint userdata from Lua; LuaJIT keeps it.
---------------------------------------------------------------------------

local timer_handle_count = 0

--- @param cancel fun(): nil Invoked by handle:Cancel().
--- @return userdata handle A stand-in for the controller's C4LuaTimer.
local function new_timer_handle(cancel)
  timer_handle_count = timer_handle_count + 1
  local serial = timer_handle_count
  local handle = newproxy(true)
  local mt = getmetatable(handle)
  mt.__index = {
    Cancel = function()
      cancel()
      -- Returns nil, so global/timer.lua clears its slot on cancel
      return nil
    end,
  }
  -- Distinct per handle, like the controller's address-bearing rendering
  mt.__tostring = function()
    return string.format("C4LuaTimer (shim #%d)", serial)
  end
  return handle
end

---------------------------------------------------------------------------
-- Socket-dependent features (timers, TCP client, event loop)
-- Only available when luasocket is installed.
---------------------------------------------------------------------------

if has_socket then
  --- Timer implementation using socket.gettime
  local timers = {}
  local timer_id = 0

  function C4:SetTimer(delay_ms, callback, repeating)
    timer_id = timer_id + 1
    local id = timer_id

    local handle = new_timer_handle(function()
      if timers[id] then
        timers[id].cancelled = true
        timers[id] = nil
      end
    end)

    local timer = {
      id = id,
      delay = delay_ms / 1000,
      callback = callback,
      repeating = repeating or false,
      next_fire = socket.gettime() + (delay_ms / 1000),
      cancelled = false,
      handle = handle,
    }

    timers[id] = timer
    return handle
  end

  function C4:ProcessTimers()
    local now = socket.gettime()
    for id, timer in pairs(timers) do
      if not timer.cancelled and now >= timer.next_fire then
        timer.callback(timer.handle, 0)
        if timer.repeating then
          timer.next_fire = now + timer.delay
        else
          timers[id] = nil
        end
      end
    end
  end

  --- TCP Client implementation
  local TCPClient = {}
  TCPClient.__index = TCPClient

  local active_clients = {}
  local client_id_counter = 0

  function C4:CreateTCPClient()
    client_id_counter = client_id_counter + 1
    local client = {
      id = client_id_counter,
      socket = nil,
      on_connect = nil,
      on_disconnect = nil,
      on_error = nil,
      on_read = nil,
      connected = false,
    }
    setmetatable(client, TCPClient)
    active_clients[client.id] = client
    return client
  end

  function TCPClient:OnConnect(callback)
    self.on_connect = callback
    return self
  end

  function TCPClient:OnDisconnect(callback)
    self.on_disconnect = callback
    return self
  end

  function TCPClient:OnError(callback)
    self.on_error = callback
    return self
  end

  function TCPClient:OnRead(callback)
    self.on_read = callback
    return self
  end

  function TCPClient:Connect(host, port)
    self.socket = socket.tcp()
    if not self.socket then
      if self.on_error then
        self.on_error(self, -1, "Failed to create socket")
      end
      return nil
    end

    self.socket:settimeout(5)
    local success, err = self.socket:connect(host, port)

    if not success then
      if self.on_error then
        self.on_error(self, -1, err or "Connection failed")
      end
      return nil
    end

    self.socket:settimeout(0)
    self.connected = true

    if self.on_connect then
      C4:SetTimer(10, function()
        if self.on_connect then
          self.on_connect(self)
        end
      end, false)
    end

    return self
  end

  function TCPClient:Close()
    if self.socket then
      self.socket:close()
      self.socket = nil
    end
    self.connected = false
    if self.id then
      active_clients[self.id] = nil
    end
    if self.on_disconnect then
      self.on_disconnect(self)
    end
  end

  function TCPClient:Write(data)
    if not self.socket then
      return false
    end
    local sent, err = self.socket:send(data)
    if not sent then
      if self.on_error then
        self.on_error(self, -1, err or "Write failed")
      end
      return false
    end
    return true
  end

  function TCPClient:ReadUpTo(max_bytes)
    if not self.socket then
      return
    end
    self.want_read = true
    self.max_read_bytes = max_bytes
  end

  function TCPClient:DoRead()
    if not self.socket or not self.want_read then
      return
    end
    local data, err, partial = self.socket:receive(self.max_read_bytes or 4096)
    if data and #data > 0 then
      if self.on_read then
        self.on_read(self, data)
      end
    elseif partial and #partial > 0 then
      if self.on_read then
        self.on_read(self, partial)
      end
    elseif err and err ~= "timeout" and err ~= "wantread" then
      if self.on_error then
        self.on_error(self, -1, err)
      end
      self:Close()
    end
  end

  function sleep(seconds)
    socket.sleep(seconds)
  end

  function processEventLoop()
    C4:ProcessTimers()
    for _, client in pairs(active_clients) do
      if client.DoRead then
        client:DoRead()
      end
    end
  end

  --- Run the event loop until os.exit() or signal.
  function runEventLoop()
    while true do
      processEventLoop()
      socket.sleep(0.01)
    end
  end
else
  -- Stub timer that does nothing (sufficient for module loading). Still real
  -- userdata, so CancelTimer resolves the handle on this branch too.
  function C4:SetTimer(delay_ms, callback, repeating)
    return new_timer_handle(function() end)
  end

  function C4:ProcessTimers() end
  function C4:CreateTCPClient()
    return setmetatable({}, {
      __index = function()
        return function() end
      end,
    })
  end

  function sleep() end
  function processEventLoop() end
  function runEventLoop() end
end

-- Mirrors the controller rather than accommodating callers. Measured on a dev
-- controller: C4:SetTimer returns userdata carrying :Cancel(), C4:AddTimer
-- returns a number, and C4:KillTimer takes that number. Passing a SetTimer
-- handle raises "idTimer should be a number", so this does too: a shim that
-- accepted it would let a call that fails on hardware pass in tests.
function C4:KillTimer(idTimer)
  if type(idTimer) ~= "number" then
    error("idTimer should be a number", 2)
  end
end

print("C4 shim layer loaded" .. (has_socket and " (with luasocket)" or " (stubs only)"))

return C4
