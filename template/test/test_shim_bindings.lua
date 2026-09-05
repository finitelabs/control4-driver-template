-- Tests for the dynamic-binding half of test/c4_shim.lua.
--
-- lib/bindings.lua reads bindings back as much as it declares them: the rename
-- path snapshots connections out of GetBindingsByDevice and re-Binds them, and
-- Bind() asks GetBoundConsumerDevices whether a link already exists. The read
-- shapes pinned here were measured on a dev controller; where the DriverWorks
-- reference disagrees, the controller wins and the check names the divergence.
--
-- Run from the template root:
--   LUA_PATH="$PWD/test/?.lua;$PWD/src/?.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" \
--     luajit -e "require('c4_shim')" test/test_shim_bindings.lua

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

local function section(name)
  print("\n[" .. name .. "]")
end

--- Nil-safe nested lookup, so a shim regression FAILs the check rather than
--- crashing the run on the first missing field.
local function at(value, ...)
  for _, key in ipairs({ ... }) do
    if type(value) ~= "table" then
      return nil
    end
    value = value[key]
  end
  return value
end

local ME = C4:GetDeviceID()
local CONSUMER = 987

local function recordFor(deviceId, bindingId)
  for _, record in ipairs(C4:GetBindingsByDevice(deviceId).bindings or {}) do
    if record.bindingid == bindingId then
      return record
    end
  end
end

local function countBindings(deviceId)
  return #(C4:GetBindingsByDevice(deviceId).bindings or {})
end

--------------------------------------------------------------------------------
section("declaring a binding")
do
  ShimResetDynamicBindings()
  ShimSetStaticBindings({})
  local live = ShimDynamicBindings()

  C4:AddDynamicBinding(10, "CONTROL", true, "Valve", "RELAY", true, true)
  local b = live[10]
  check("add records every argument", b ~= nil and b.name == "Valve" and b.class == "RELAY" and b.provider == true)
  check("add records the trailing pair", b and b.hidden == true and b.autoBind == true)

  C4:AddDynamicBinding(11, "PROXY", false, "Light 1", "LIGHT_V2")
  check("hidden and autoBind default false", live[11].hidden == false and live[11].autoBind == false)

  local record = recordFor(ME, 10)
  check("a declared binding reads back through GetBindingsByDevice", record ~= nil)
  check(
    "the record carries the controller's field set",
    at(record, "deviceid") == ME
      and at(record, "name") == "Valve"
      and at(record, "provider") == true
      and at(record, "flags") == 0
      and at(record, "binding_info") == "",
    at(record, "name")
  )
  check("CONTROL is type 1, PROXY is type 2", at(record, "type") == 1 and at(recordFor(ME, 11), "type") == 2)
  check(
    "the class arrives under bindingclasses, with rank and autobind",
    at(record, "bindingclasses", 1, "class") == "RELAY"
      and at(record, "bindingclasses", 1, "rank") == 0
      and at(record, "bindingclasses", 1, "autobind") == true
      and type(at(record, "bindingclasses", 1, "excludeids")) == "table"
  )
  check(
    "an unbound binding is not bound and has no peers",
    at(record, "isbound") == false and at(record, "boundconsumers") == nil
  )

  C4:AddDynamicBinding(10, "CONTROL", true, "Valve renamed", "RELAY")
  check("a re-add under a live id replaces the record", at(recordFor(ME, 10), "name") == "Valve renamed")
end

--------------------------------------------------------------------------------
section("wiring a consumer to our provider binding")
do
  ShimResetDynamicBindings()
  ShimSetDevices({ [CONSUMER] = { deviceName = "Hallway Switch" } })
  C4:AddDynamicBinding(10, "CONTROL", true, "Valve", "RELAY")

  check("nothing is bound before Bind", C4:GetBoundConsumerDevices(ME, 10) == nil)
  check("GetBoundProviderDevice answers 0, not nil, when unbound", C4:GetBoundProviderDevice(ME, 10) == 0)

  C4:Bind(ME, 10, CONSUMER, 1, "RELAY")
  check("Bind records one connection", #ShimConnections() == 1)
  C4:Bind(ME, 10, CONSUMER, 1, "RELAY")
  check("Bind is idempotent", #ShimConnections() == 1)

  local bound = C4:GetBoundConsumerDevices(ME, 10)
  check(
    "GetBoundConsumerDevices answers { [deviceId] = name }",
    at(bound, CONSUMER) == "Hallway Switch",
    at(bound, CONSUMER)
  )
  check(
    "a device id of 0 means the current device",
    at(C4:GetBoundConsumerDevices(0, 10), CONSUMER) == "Hallway Switch"
  )
  check("our own provider binding reports us as the provider", C4:GetBoundProviderDevice(ME, 10) == ME)

  local record = recordFor(ME, 10)
  check("the record now reads bound", at(record, "isbound") == true)
  check(
    "boundconsumers carries the peer's id, binding and classes",
    #(at(record, "boundconsumers") or {}) == 1
      and at(record, "boundconsumers", 1, "deviceid") == CONSUMER
      and at(record, "boundconsumers", 1, "bindingid") == 1
      and at(record, "boundconsumers", 1, "name") == "Hallway Switch"
      and at(record, "boundconsumers", 1, "boundclasses", 1) == "RELAY"
  )

  C4:Unbind(CONSUMER, 1)
  check("Unbind drops the connection", #ShimConnections() == 0 and at(recordFor(ME, 10), "isbound") == false)
end

--------------------------------------------------------------------------------
section("our binding as the consumer side")
do
  ShimResetDynamicBindings()
  ShimSetDevices({ [CONSUMER] = { deviceName = "Zigbee Coordinator" } })
  C4:AddDynamicBinding(12, "PROXY", false, "Temperature", "TEMPERATURE")
  C4:Bind(CONSUMER, 7000, ME, 12, "TEMPERATURE")

  local record = recordFor(ME, 12)
  check("the consumer record reads bound", at(record, "isbound") == true and at(record, "boundconsumers") == nil)
  check(
    "boundprovider nests the peer under 'bound'",
    at(record, "boundprovider", "bound", "deviceid") == CONSUMER
      and at(record, "boundprovider", "bound", "bindingid") == 7000
      and at(record, "boundprovider", "bound", "name") == "Zigbee Coordinator"
  )
  check("GetBoundProviderDevice answers the providing device id", C4:GetBoundProviderDevice(ME, 12) == CONSUMER)
end

--------------------------------------------------------------------------------
section("removing a binding")
do
  ShimResetDynamicBindings()
  C4:AddDynamicBinding(10, "CONTROL", true, "Valve", "RELAY")
  C4:AddDynamicBinding(11, "CONTROL", true, "Pump", "RELAY")
  C4:Bind(ME, 10, CONSUMER, 1, "RELAY")
  C4:Bind(ME, 11, CONSUMER, 2, "RELAY")

  C4:RemoveDynamicBinding(10)
  check("remove drops the binding", recordFor(ME, 10) == nil)
  check("remove drops that binding's connections", C4:GetBoundConsumerDevices(ME, 10) == nil)
  check("remove leaves the other binding wired", #ShimConnections() == 1 and at(recordFor(ME, 11), "isbound") == true)
end

--------------------------------------------------------------------------------
section("static bindings and reset")
do
  ShimResetDynamicBindings()
  ShimSetStaticBindings({ { id = 1, type = "CONTROL", provider = false, name = "Serial", class = "SERIAL" } })
  C4:AddDynamicBinding(10, "CONTROL", true, "Valve", "RELAY")

  check("the get methods return statics alongside dynamics", countBindings(ME) == 2)
  check(
    "a static binding keeps its own shape",
    at(recordFor(ME, 1), "name") == "Serial" and at(recordFor(ME, 1), "type") == 1
  )

  ShimResetDynamicBindings()
  check("reset clears the dynamic bindings but not the statics", countBindings(ME) == 1 and recordFor(ME, 1) ~= nil)

  local live = ShimDynamicBindings()
  check("reset clears in place, so a held table stays live", next(live) == nil and live == ShimDynamicBindings())

  ShimSetStaticBindings({})
  check("seeding an empty set clears the statics", countBindings(ME) == 0)
end

--------------------------------------------------------------------------------
section("device ids the controller does not resolve")
do
  ShimResetDynamicBindings()
  C4:AddDynamicBinding(10, "CONTROL", true, "Valve", "RELAY")

  -- The reference says a device id of 0 is the current device here too; a
  -- controller answers with nothing.
  check("GetBindingsByDevice does not resolve device 0", countBindings(0) == 0)
  check("another device's bindings are not ours", countBindings(CONSUMER) == 0)
end

--------------------------------------------------------------------------------
ShimResetDynamicBindings()
ShimSetStaticBindings({})
ShimResetDevices()

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
