-- Tests that src/lib/github-updater.lua unlocks the C4Z_ROOT alias before
-- anything that depends on it runs.
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

-- Globals src/lib/utils.lua defines in a driver; it is not loadable here.
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
function InRange(n, min, max)
  return math.max(min, math.min(n, max))
end

JSON = require("JSON")
local deferred = require("deferred")
function reject(err)
  return deferred.new():reject(err)
end

-- Stand-in for utils.GetDriverVersion, which resolves a companion driver's
-- directory through the C4Z_ROOT alias.
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
