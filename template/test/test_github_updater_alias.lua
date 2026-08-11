-- Tests that src/lib/utils.lua unlocks the C4Z_ROOT alias inside GetDriverVersion,
-- so the updater's version loop resolves every companion driver's directory.
--
-- Run from the template root:
--   LUA_PATH="$PWD/test/?.lua;$PWD/src/?.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" \
--     luajit -e "require('c4_shim')" test/test_github_updater_alias.lua

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

--- `src/constants.lua` is driver-specific, so it does not exist in the template itself.
--- utils.lua reads only HIDE_PROPERTY / SHOW_PROPERTY from it, in CheckMinimumVersion,
--- which this suite never calls.
package.preload["constants"] = function()
  return { SHOW_PROPERTY = 0, HIDE_PROPERTY = 1 }
end

-- utils.lua calls Select and FileRead, which drivers-common-public defines as globals.
require("drivers-common-public.global.lib")
require("lib.utils")

JSON = require("JSON")
local deferred = require("deferred")

--- Counts calls and drops the parsed version. utils.lua reads it out of driver.xml
--- through the shim's file API, which serves no such file, so the real return value
--- is nil and semver would reject it. The alias is what this test is about.
local realGetDriverVersion = GetDriverVersion
local getDriverVersionCalls = 0
local getDriverVersionError = nil
function GetDriverVersion(filename)
  getDriverVersionCalls = getDriverVersionCalls + 1
  local ok, err = pcall(realGetDriverVersion, filename)
  if not ok then
    getDriverVersionError = err
    error(err, 0)
  end
  return "1.0.0"
end

-- The module returns an already-constructed instance, not the class.
local updater = require("lib.github-updater")

-- Stub the release fetch to keep the test offline; an older release makes the
-- chain return right after the version loop.
local semver = require("version")
function updater:getLatestRelease()
  return deferred.new():resolve({ version = semver("0.0.1"), assets = {} })
end

-- Guards against passing on a no-op shim.
check("C4Z_ROOT is locked before the updater runs", not pcall(function()
  C4:FileSetDir("C4Z_ROOT")
end), "shim accepted C4Z_ROOT with no unlock, so this test cannot detect the defect")

local ok, err = pcall(function()
  updater:getOutdatedDriverAssets("finitelabs/example", { "example.c4z", "example_companion.c4z" }, false, false)
end)

check("getOutdatedDriverAssets does not fail on the alias", ok, err)
check("GetDriverVersion was actually reached", getDriverVersionCalls > 0, "the version loop never ran")
check("no Invalid alias error was raised", getDriverVersionError == nil, getDriverVersionError)

-- The loop must resolve every filename, not just the running driver's own.
check(
  "every driver filename was resolved",
  getDriverVersionCalls == 2,
  string.format("expected 2 GetDriverVersion calls, got %d", getDriverVersionCalls)
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
