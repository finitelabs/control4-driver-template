-- UpdateProperty drops a value driver.xml does not allow (upstream Handlers 37).
-- The fork reads the config once per load instead of on every call, and a
-- DYNAMIC_LIST update before any UpdatePropertyList call no longer throws.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_update_property.lua

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.handlers")

local CONFIG = table.concat({
  "<properties>",
  "<property><name>Mode</name><type>LIST</type><items><item>Auto</item><item>Off</item></items></property>",
  "<property><name>Level</name><type>RANGED_INTEGER</type><minimum>0</minimum><maximum>10</maximum></property>",
  "<property><name>Target</name><type>DYNAMIC_LIST</type><items></items></property>",
  "<property><name>Status</name><type>STRING</type></property>",
  "</properties>",
})

local configReads = 0
function C4:GetDriverConfigInfo(section)
  if section == "config" then
    configReads = configReads + 1
    return CONFIG
  end
end

local sent
function C4:UpdateProperty(name, value)
  sent = value
  Properties[name] = value
end

Properties.Mode, Properties.Level, Properties.Target, Properties.Status = "Off", "0", "", ""

--- Returns what reached C4:UpdateProperty, what was printed, and whether it threw.
local function update(name, value)
  sent = nil
  local ok, err, output = T.capture(function()
    UpdateProperty(name, value)
  end)
  return sent, output, ok and "" or err
end

T.section("A value is checked against driver.xml")
T.eq("a listed item is sent", update("Mode", "Auto"), "Auto")
local value, output = update("Mode", "On")
T.eq("an unlisted item is not", value, nil)
T.contains("and says why", output, "Value not in list")
T.eq("an integer in range is sent", update("Level", 7), "7")
T.eq("one out of range is not", update("Level", 11), nil)
T.eq("nor is a fraction", update("Level", 2.5), nil)
T.eq("an unchecked type is sent as is", update("Status", "anything"), "anything")
T.eq("the config was read once", configReads, 1)

T.section("A DYNAMIC_LIST is checked only once UpdatePropertyList has set it")
local _, _, err = update("Target", "Kitchen")
T.eq("an update before any UpdatePropertyList does not throw", err, "")
T.eq("and is sent", sent, "Kitchen")
UpdatePropertyList("Target", { "Kitchen", "Den" })
T.eq("a listed item is sent", update("Target", "Den"), "Den")
T.eq("an unlisted one is not", update("Target", "Garage"), nil)

T.finish()
