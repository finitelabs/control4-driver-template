-- SendToDevice in lib/utils.lua with logCommand false, which C4 documents as
-- keeping sensitive content out of its log. Every shipped build traced the
-- parameters anyway, so a user code sent that way was printed in plain text.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_send_to_device_log_command.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")

local log = require("lib.logging")

-- Obviously fake: a trace that shows it has leaked it.
local CODE = "FAKE-CODE-0000"

local sent = {}
function C4:SendToDevice(...)
  sent[#sent + 1] = { n = select("#", ...), ... }
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

T.section("logCommand false keeps the parameters out of the trace")
local output = traced(function()
  SendToDevice(12, "PARTITION_DISARM", { UserCode = CODE }, nil, false)
end)
T.contains("the device and the command", output, "C4:SendToDevice(12, PARTITION_DISARM, <not logged>)")
T.excludes("and never the parameters", output, CODE)
T.eq(
  "C4 gets every argument, logCommand included",
  sent,
  { { n = 5, 12, "PARTITION_DISARM", { UserCode = CODE }, nil, false } }
)

T.section("without it the parameters are traced as before")
output = traced(function()
  SendToDevice(12, "PARTITION_ARM", { ArmType = "Away" })
end)
T.contains("the whole call", output, 'C4:SendToDevice(12, PARTITION_ARM, {"ArmType":"Away"}, nil, nil)')
T.eq("C4 gets the arguments up to the last one given", sent, { { n = 3, 12, "PARTITION_ARM", { ArmType = "Away" } } })

T.finish()
