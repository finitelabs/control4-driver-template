-- Tests that src/lib/github-updater.lua unlocks the C4Z_ROOT alias before
-- anything that depends on it runs.
--
-- Run from the template root:
--   LUA_PATH="$PWD/test/?.lua;$PWD/src/?.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" \
--     luajit -e "require('c4_shim')" test/test_github_updater_alias.lua
--
-- Without the unlock this fails the way it does in the field: the updater walks
-- DRIVER_FILENAMES calling GetDriverVersion, which does
-- C4:FileSetDir("C4Z_ROOT", basename), and that errors before any network call.

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

-- Globals src/lib/utils.lua would define in a driver. utils is not loaded here:
-- it requires the driver-owned src/constants.lua that the template does not ship.
function IsEmpty(value)
  return value == nil or value == "" or (type(value) == "table" and next(value) == nil)
end
function Select(t, ...)
  for _, k in ipairs({ ... }) do
    if type(t) ~= "table" then
      return nil
    end
    t = t[k]
  end
  return t
end
function TableReverse(t)
  local r = {}
  for k, v in pairs(t) do
    r[v] = k
  end
  return r
end
function TableKeys(t)
  local r = {}
  for k in pairs(t) do
    table.insert(r, k)
  end
  return r
end
-- src/lib/http.lua calls this on the request path without requiring lib.utils.
function InRange(n, min, max)
  return math.max(min, math.min(n, max))
end

JSON = require("JSON")
local deferred = require("deferred")
function reject(err)
  return deferred.new():reject(err)
end

-- Stand-in for utils.GetDriverVersion, reproducing the one thing that matters
-- here: it resolves a *companion* driver's directory through the C4Z_ROOT alias.
local getDriverVersionCalls = 0
local getDriverVersionError = nil
function GetDriverVersion(filename)
  getDriverVersionCalls = getDriverVersionCalls + 1
  local basename = filename:match("(.*)%.(.*)")
  local ok, err = pcall(function()
    C4:FileSetDir("C4Z_ROOT", basename)
  end)
  if not ok then
    getDriverVersionError = err
    error(err, 0)
  end
  return "1.0.0"
end

-- The module returns an already-constructed instance, not the class.
local updater = require("lib.github-updater")

-- Everything this test cares about happens in the version loop, which runs
-- before the first network call. Stub the release fetch so the test stays
-- offline and deterministic: an older release makes the chain return early.
local semver = require("version")
function updater:getLatestRelease()
  return deferred.new():resolve({ version = semver("0.0.1"), assets = {} })
end

-- The alias must not already be armed, or this test would pass on a no-op shim.
check("C4Z_ROOT is locked before the updater runs", not pcall(function()
  C4:FileSetDir("C4Z_ROOT")
end), "shim accepted C4Z_ROOT with no unlock, so this test cannot detect the defect")

-- Drive the real entry point. Network calls happen strictly after the version
-- loop, so this reaches the alias use without needing an HTTP stub.
local ok, err = pcall(function()
  updater:getOutdatedDriverAssets("finitelabs/example", { "example.c4z", "example_companion.c4z" }, false, false)
end)

check("getOutdatedDriverAssets does not fail on the alias", ok, err)
check("GetDriverVersion was actually reached", getDriverVersionCalls > 0, "the version loop never ran")
check("no Invalid alias error was raised", getDriverVersionError == nil, getDriverVersionError)

-- Guard the companion-read shape: the loop must resolve every filename, not just
-- the running driver's own. A single call would mean the loop collapsed.
check(
  "every driver filename was resolved",
  getDriverVersionCalls == 2,
  string.format("expected 2 GetDriverVersion calls, got %d", getDriverVersionCalls)
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
