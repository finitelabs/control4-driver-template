-- A built driver's squished Lua, loaded and taken through its init, holds no package.preload copy of a module it
-- loaded once its late init returns (src/squish-tail.lua), and held some before.
--
-- Run from the template repo:
--   make build-squish-tail NAME=<render>
-- or, in a render, after make build:
--   SQUISHED=dist/oss/source/example.lua ./test/run_test.sh <template repo>/tests/squish_tail.lua

require("c4_shim")

local source = assert(os.getenv("SQUISHED"), "set SQUISHED to a squished driver's .lua")

-- The shim models no minimum_os_version; the driver's own check passes against the shim's version.
local configInfo = C4.GetDriverConfigInfo
function C4:GetDriverConfigInfo(section)
  if section == "minimum_os_version" then
    return C4:GetVersionInfo().version:match("^[%d.]+")
  end
  return configInfo(self, section)
end

local function copies()
  local n = 0
  for name, loader in pairs(package.preload) do
    if package.loaded[name] ~= nil and type(loader) == "function" and debug.getinfo(loader, "S").what == "Lua" then
      n = n + 1
    end
  end
  return n
end

dofile(source)
if OnDriverInit then
  OnDriverInit("DIT_STARTUP")
end
local before = copies()
OnDriverLateInit("DIT_STARTUP")
local after = copies()
print(string.format("%s: %d preload copies of loaded modules before late init, %d after", source, before, after))
if before == 0 or after ~= 0 then
  os.exit(1)
end
