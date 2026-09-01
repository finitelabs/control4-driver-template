-- Rename path in lib/bindings.lua: getOrAddDynamicBinding re-adds a binding under the
-- same id when its name/provider/class changes, and must preserve the installer's wiring
-- across the remove/add. Covers both orientations, the provider-flip skip, and that the
-- re-add keeps the record's original type (not the freshly passed one).
require("c4_shim")

local persist = require("lib.persist")
local store = {}
persist.get = function(_, k, d)
  local v = store[k]
  if v == nil then
    return d
  end
  return v
end
persist.set = function(_, k, v)
  store[k] = v
end
persist.delete = function(_, k)
  store[k] = nil
end

local log = require("lib.logging")
for _, m in ipairs({ "trace", "debug", "info", "warn", "error" }) do
  if type(log[m]) == "function" then
    log[m] = function() end
  end
end

local bindings = require("lib.bindings")

_G.RFP = _G.RFP or {}
_G.OBC = _G.OBC or {}

local addCalls, removeCalls, bindCalls = {}, {}, {}
local deviceBindings = {}
_G.GetDeviceBindings = function()
  return deviceBindings
end
function C4:GetDeviceID()
  return 100
end
function C4:AddDynamicBinding(id, typ, prov, name, class)
  addCalls[#addCalls + 1] = { id = id, type = typ, provider = prov, name = name, class = class }
end
function C4:RemoveDynamicBinding(id)
  removeCalls[#removeCalls + 1] = id
end
function C4:GetBoundConsumerDevices() -- empty so Bind() always issues a C4:Bind we can capture
  return {}
end
function C4:Bind(dp, bp, dc, bc, class)
  bindCalls[#bindCalls + 1] = { dp = dp, bp = bp, dc = dc, bc = bc, class = class }
end

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (detail ~= nil and ("  [" .. tostring(detail) .. "]") or ""))
  end
end
local function clearCalls()
  for _, t in ipairs({ addCalls, removeCalls, bindCalls }) do
    for i = #t, 1, -1 do
      t[i] = nil
    end
  end
end

-- 1. rename while WE PROVIDE: the consumer link is re-bound with us as provider.
store, deviceBindings = {}, {}
clearCalls()
bindings:getOrAddDynamicBinding("ns", "k1", "CONTROL", true, "Old", "RELAY")
local id1 = addCalls[#addCalls].id
deviceBindings = { [id1] = { isbound = true, provider = true, boundconsumers = { { deviceid = 777, bindingid = 5 } } } }
clearCalls()
bindings:getOrAddDynamicBinding("ns", "k1", "CONTROL", true, "New", "RELAY")
check("provider rename: removed the old id", removeCalls[1] == id1, removeCalls[1])
check("provider rename: re-added with the new name", addCalls[1] and addCalls[1].name == "New")
check("provider rename: exactly one reconnect", #bindCalls == 1, #bindCalls)
do
  local b = bindCalls[1]
  check(
    "provider rename: re-bound in the original direction (me -> peer)",
    b and b.dp == 100 and b.bp == id1 and b.dc == 777 and b.bc == 5,
    b and (b.dp .. "/" .. b.bp .. " -> " .. b.dc .. "/" .. b.bc)
  )
end

-- 2. rename while WE CONSUME: the provider link is re-bound with us as consumer.
store, deviceBindings = {}, {}
clearCalls()
bindings:getOrAddDynamicBinding("ns", "k2", "CONTROL", false, "Old", "RELAY")
local id2 = addCalls[#addCalls].id
deviceBindings = { [id2] = { isbound = true, provider = false, boundprovider = { bound = { deviceid = 888, bindingid = 3 } } } }
clearCalls()
bindings:getOrAddDynamicBinding("ns", "k2", "CONTROL", false, "New", "RELAY")
check("consumer rename: exactly one reconnect", #bindCalls == 1, #bindCalls)
do
  local c = bindCalls[1]
  check(
    "consumer rename: re-bound in the original direction (peer -> me)",
    c and c.dp == 888 and c.bp == 3 and c.dc == 100 and c.bc == id2,
    c and (c.dp .. "/" .. c.bp .. " -> " .. c.dc .. "/" .. c.bc)
  )
end

-- 3. provider flip: the old links are not restorable in the new orientation, so skip
--    rather than re-bind them inverted.
store, deviceBindings = {}, {}
clearCalls()
bindings:getOrAddDynamicBinding("ns", "k3", "CONTROL", true, "Old", "RELAY")
local id3 = addCalls[#addCalls].id
deviceBindings = { [id3] = { isbound = true, provider = true, boundconsumers = { { deviceid = 777, bindingid = 5 } } } }
clearCalls()
bindings:getOrAddDynamicBinding("ns", "k3", "CONTROL", false, "Old", "RELAY")
check("provider flip: still re-added the binding", #addCalls == 1)
check("provider flip: no reconnect (would invert the link)", #bindCalls == 0, #bindCalls)

-- 4. type is committed to the id's range: a rename re-adds with the record's own type,
--    not a freshly passed one, so live and persisted types can't diverge.
store, deviceBindings = {}, {}
clearCalls()
bindings:getOrAddDynamicBinding("ns", "k4", "PROXY", true, "Old", "RELAY")
clearCalls()
bindings:getOrAddDynamicBinding("ns", "k4", "CONTROL", true, "New", "RELAY")
check("type on rename: re-added with the original type", addCalls[1] and addCalls[1].type == "PROXY", addCalls[1] and addCalls[1].type)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
