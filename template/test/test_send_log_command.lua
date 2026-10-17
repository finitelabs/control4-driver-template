-- The send wrappers in lib/utils.lua with logCommand false, which C4 documents
-- for SendToDevice as keeping sensitive content out of its log. Every shipped
-- build traced the parameters anyway, so a user code sent that way was printed
-- in plain text.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_send_log_command.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local log = require("lib.logging")

-- Obviously fake: a trace that shows it has leaked it.
local CODE = "FAKE-CODE-0000"

local sent = {}
for _, method in ipairs({ "SendToDevice", "SendToProxy", "SendToNetwork" }) do
  C4[method] = function(_, ...)
    sent[#sent + 1] = { n = select("#", ...), ... }
  end
end

--- Everything lib.logging prints at trace level while fn runs.
local function traced(fn)
  sent = {}
  log:setLogLevel("5 - Trace")
  log:setLogMode("Print")
  local ok, err, output = T.capture(fn)
  log:setLogMode("")
  T.truthy("runs without error", ok, err)
  return output
end

T.section("SendToDevice with logCommand false keeps the parameters out of the trace")
local output = traced(function()
  SendToDevice(12, "PARTITION_DISARM", { UserCode = CODE }, nil, false)
end)
T.contains("the rest of the call", output, "C4:SendToDevice(12, PARTITION_DISARM, <not logged>, nil, false)")
T.excludes("and never the parameters", output, CODE)
T.eq(
  "C4 gets every argument, logCommand included",
  sent,
  { { n = 5, 12, "PARTITION_DISARM", { UserCode = CODE }, nil, false } }
)

T.section("SendToProxy with logCommand false keeps the parameters out of the trace")
output = traced(function()
  SendToProxy(5001, "USERS", { PASSCODE = CODE }, "NOTIFY", nil, false)
end)
T.contains("the rest of the call", output, "C4:SendToProxy(5001, USERS, <not logged>, NOTIFY, nil)")
T.excludes("and never the parameters", output, CODE)
T.eq("C4 gets its own arguments, not logCommand", sent, { { n = 4, 5001, "USERS", { PASSCODE = CODE }, "NOTIFY" } })

T.section("SendToNetwork with logCommand false keeps the data out of the trace")
output = traced(function()
  SendToNetwork(6001, 6053, "login " .. CODE, false)
end)
T.contains("the rest of the call", output, "C4:SendToNetwork(6001, 6053, <not logged>)")
T.excludes("and never the data", output, CODE)
T.eq("C4 gets its own arguments, not logCommand", sent, { { n = 3, 6001, 6053, "login " .. CODE } })

T.section("without it every wrapper traces the parameters as before")
output = traced(function()
  SendToDevice(12, "PARTITION_ARM", { ArmType = "Away" })
  SendToProxy(5001, "LOCK_STATUS", { STATUS = "locked" }, "NOTIFY")
  SendToNetwork(6001, 6053, "ping")
end)
T.contains("SendToDevice", output, 'C4:SendToDevice(12, PARTITION_ARM, {"ArmType":"Away"}, nil, nil)')
T.contains("SendToProxy", output, 'C4:SendToProxy(5001, LOCK_STATUS, {"STATUS":"locked"}, NOTIFY, nil)')
T.contains("SendToNetwork", output, "C4:SendToNetwork(6001, 6053, ping)")
T.eq("C4 gets the arguments up to the last one given", sent, {
  { n = 3, 12, "PARTITION_ARM", { ArmType = "Away" } },
  { n = 4, 5001, "LOCK_STATUS", { STATUS = "locked" }, "NOTIFY" },
  { n = 3, 6001, 6053, "ping" },
})

T.finish()
