-- Backwards-compatibility tests for the vendored websocket.lua changes:
--   1. Send(s, opcode)         additive; default must stay 0x81
--   2. per-endpoint binding reuse (must not merge distinct/concurrent sockets)
--   3. Host header omits the default port only

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

--------------------------------------------------------------------------------
-- C4 shim
--------------------------------------------------------------------------------
local bindingAddress = {} -- [binding] = host   (never cleared: mirrors the real leak)
local bindingPort = {}
local sentFrames = {}

C4 = {}
function C4:GetBindingAddress(i)
  return bindingAddress[i] or ""
end
function C4:CreateNetworkConnection(binding, host, _type)
  bindingAddress[binding] = host
end
function C4:NetPortOptions(binding, port, _t, _o)
  bindingPort[binding] = port
end
function C4:NetConnect() end
function C4:NetDisconnect() end
function C4:SendToNetwork(binding, port, data)
  sentFrames[#sentFrames + 1] = { binding = binding, port = port, data = data }
end
function C4:SetBindingAddress() end -- no-op on purpose: does not durably free
function C4:Base64Encode(s)
  return "b64:" .. tostring(s):sub(1, 8)
end
function C4:ErrorLog() end
function C4:DebugLog() end
function C4:GetDeviceID()
  return 1
end

-- C4 global: hex string -> packed bytes
function tohex(s)
  return (tostring(s):gsub("%x%x", function(cc)
    return string.char(tonumber(cc, 16))
  end))
end

function SetTimer()
  return "t"
end
function CancelTimer() end
ONE_SECOND = 1000
OCS, RFN = {}, {}

local WebSocket = require("drivers-common-public.module.websocket")

-- Mirror the module's own teardown bookkeeping (lines ~174-181): a closed socket
-- releases its registry entries, but the binding address stays populated.
local function simulateClose(ws)
  if WebSocket.Sockets then
    WebSocket.Sockets[ws.url] = nil
    WebSocket.Sockets[ws.netBinding] = nil
  end
  ws.connected = false
end

local function bindingsInUse()
  local n = 0
  for _ in pairs(bindingAddress) do
    n = n + 1
  end
  return n
end

--------------------------------------------------------------------------------
print("\n[1] Send() default opcode unchanged (0x81 text frame)")
--------------------------------------------------------------------------------
do
  local ws = WebSocket:new("wss://text.example.com/ws")
  ws.connected = true
  sentFrames = {}
  ws:Send("hello")
  local first = sentFrames[1] and sentFrames[1].data:byte(1)
  check("legacy Send(s) still emits 0x81", first == 0x81, string.format("got 0x%02X", first or 0))

  sentFrames = {}
  ws:Send("hello", 0x82)
  first = sentFrames[1] and sentFrames[1].data:byte(1)
  check("Send(s, 0x82) emits binary frame", first == 0x82, string.format("got 0x%02X", first or 0))

  sentFrames = {}
  ws:Send(string.rep("x", 300)) -- exercises the 126 extended-length branch
  first = sentFrames[1] and sentFrames[1].data:byte(1)
  check("extended-length frame keeps 0x81 default", first == 0x81, string.format("got 0x%02X", first or 0))
  simulateClose(ws)
end

--------------------------------------------------------------------------------
print("\n[2] Binding reuse across reconnects (the leak fix)")
--------------------------------------------------------------------------------
do
  bindingAddress, bindingPort = {}, {}
  local firstBinding, lastBinding
  for i = 1, 300 do
    local ws = WebSocket:new("wss://iot.example.com/mqtt?sig=" .. i) -- presigned: url differs each time
    firstBinding = firstBinding or ws.netBinding
    lastBinding = ws.netBinding
    simulateClose(ws) -- driver deletes the old socket BEFORE opening the next
  end
  check(
    "300 sequential reconnects reuse one binding",
    firstBinding == lastBinding,
    firstBinding .. " vs " .. lastBinding
  )
  check("pool holds exactly 1 slot for that host", bindingsInUse() == 1, bindingsInUse() .. " slots")
end

--------------------------------------------------------------------------------
print("\n[3] Same host, DIFFERENT ports, both live (home-connect multi-bridge)")
--------------------------------------------------------------------------------
do
  bindingAddress, bindingPort = {}, {}
  local a = WebSocket:new("ws://192.168.1.50:8581/socket.io/?a=1")
  local b = WebSocket:new("ws://192.168.1.50:8582/socket.io/?b=1")
  check("distinct ports get distinct bindings", a.netBinding ~= b.netBinding, a.netBinding .. " vs " .. b.netBinding)
  check("port 8581 bound correctly", bindingPort[a.netBinding] == nil or bindingPort[a.netBinding] == 8581)
  check(
    "each socket owns its own callbacks",
    WebSocket.Sockets[a.netBinding] == a and WebSocket.Sockets[b.netBinding] == b
  )
  simulateClose(a)
  simulateClose(b)
end

--------------------------------------------------------------------------------
print("\n[4] Same endpoint, two CONCURRENT live sockets")
--------------------------------------------------------------------------------
do
  bindingAddress, bindingPort = {}, {}
  local a = WebSocket:new("wss://same.example.com/ws?a=1")
  local b = WebSocket:new("wss://same.example.com/ws?b=2") -- opened before a closes
  check("concurrent sockets are not merged", a.netBinding ~= b.netBinding, a.netBinding .. " vs " .. b.netBinding)
  check("first socket keeps its callbacks", WebSocket.Sockets[a.netBinding] == a)
  check("second socket keeps its callbacks", WebSocket.Sockets[b.netBinding] == b)
  simulateClose(a)
  simulateClose(b)
end

--------------------------------------------------------------------------------
print("\n[5] Host header: default port omitted, others preserved")
--------------------------------------------------------------------------------
do
  local function hostHeaderOf(url)
    local ws = WebSocket:new(url)
    local h = ws:MakeHeaders()
    if type(h) == "table" then
      h = table.concat(h, "\r\n")
    end
    simulateClose(ws)
    return tostring(h):match("Host: ([^\r\n]+)")
  end
  check(
    "wss default 443 omits port",
    hostHeaderOf("wss://a.example.com/ws") == "a.example.com",
    hostHeaderOf("wss://a.example.com/ws")
  )
  check(
    "ws default 80 omits port",
    hostHeaderOf("ws://b.example.com/ws") == "b.example.com",
    hostHeaderOf("ws://b.example.com/ws")
  )
  check(
    "wss non-default keeps port",
    hostHeaderOf("wss://c.example.com:8443/ws") == "c.example.com:8443",
    hostHeaderOf("wss://c.example.com:8443/ws")
  )
  check(
    "ws non-default keeps port",
    hostHeaderOf("ws://d.example.com:8581/ws") == "d.example.com:8581",
    hostHeaderOf("ws://d.example.com:8581/ws")
  )
end

print(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
