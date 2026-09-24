-- Tests that the GitHub updater installs nothing from a release whose .c4z declares a
-- minimum_os_version above the controller's OS. Such a driver disables itself on load
-- (CheckMinimumVersion), so installing it would take a working driver offline.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_github_updater_min_os.lua

local T = require("testlib")
local F = require("c4_fixtures")

local updater = require("lib.github-updater")
require("drivers-common-public.global.lib")
JSON = require("JSON")
local deferred = require("deferred")
local semver = require("version")
local http = require("lib.http")
local log = require("lib.logging")

local RUNNING = C4:GetDriverFileName()
local COMPANION = "example_companion.c4z"

C4.GetDevicesByC4iName = function()
  return { 1 }
end
local installedVersion = "1.0.0"
GetDriverVersion = function()
  return installedVersion
end
local osVersion
C4.GetVersionInfo = function()
  return { version = osVersion }
end

local bodies, gets, writes, warnings = {}, {}, {}, {}
http.get = function(_, url)
  table.insert(gets, url)
  if bodies[url] == nil then
    return deferred.new():reject({ error = "404 " .. url })
  end
  return deferred.new():resolve({ body = bodies[url] })
end
local realFileWrite = FileWrite
FileWrite = function(name, ...)
  table.insert(writes, name)
  return realFileWrite(name, ...)
end
log.warn = function(_, format, ...)
  table.insert(warnings, string.format(format, ...))
end

--- Publish a release of `tag` with one asset per { name, minimumOs | body | missing }, run
--- updateAll against it and report what it downloaded, wrote and sent to Director.
local function update(tag, assetSpecs, forceUpdate)
  local assets = {}
  for _, spec in ipairs(assetSpecs) do
    local url = "https://example.invalid/" .. tag .. "/" .. spec.name
    bodies[url] = not spec.missing and (spec.body or F.c4z(tag, spec.minimumOs)) or nil
    table.insert(assets, { name = spec.name, browser_download_url = url, updated_at = "2026-10-01T00:00:00Z" })
  end
  updater.getLatestRelease = function()
    return deferred.new():resolve({ version = semver(tag), assets = assets })
  end

  gets, writes, warnings = {}, {}, {}
  local filenames = {}
  for _, asset in ipairs(assets) do
    table.insert(filenames, asset.name)
  end
  local tcp = F.captureTcpClient()
  local result = { settled = false }
  updater:updateAll("finitelabs/example", filenames, false, forceUpdate):next(function(updated)
    result.settled, result.updated = true, updated
  end, function(err)
    result.settled, result.err = true, err
  end)
  tcp.restore()

  result.sent = {}
  for _, data in ipairs(tcp.writes) do
    table.insert(result.sent, data:match("([%w_]+%.c4z)"))
  end
  result.gets, result.writes, result.warnings = gets, writes, warnings
  return result
end

local function describe(value)
  if type(value) == "table" then
    local parts = {}
    for _, v in pairs(value) do
      table.insert(parts, tostring(v))
    end
    return table.concat(parts, "; ")
  end
  return tostring(value)
end

local function installs(name, result, want)
  T.eq(name .. ": resolves with the updated drivers", result.updated, want)
  T.eq(name .. ": writes them", result.writes, want)
  T.eq(name .. ": sends them to Director", result.sent, want)
  T.eq(name .. ": warns about nothing", result.warnings, {})
end

local function skips(name, result, needles)
  T.check(name .. ": rejects", result.settled and result.updated == nil, "resolved " .. describe(result.updated))
  T.eq(name .. ": writes nothing", result.writes, {})
  T.eq(name .. ": sends nothing to Director", result.sent, {})
  T.eq(name .. ": warns once", #result.warnings, 1)
  for _, needle in ipairs(needles) do
    T.contains(name .. ": says " .. needle, describe(result.err), needle)
  end
  T.contains(name .. ": the warning says why", result.warnings[1], needles[1])
end

---------------------------------------------------------------------------
T.section("a release above the controller's OS is skipped")
---------------------------------------------------------------------------

osVersion = "4.2.1.757028"
local above = update("2.0.0", { { name = RUNNING, minimumOs = "4.99.0" } })
skips("minimum 4.99.0 on 4.2.1", above, { "requires C4 OS 4.99.0", RUNNING, "2.0.0", "runs 4.2.1.757028" })
T.eq("the reason reaches the caller as a message", type(above.err), "string")

---------------------------------------------------------------------------
T.section("a release the controller's OS meets installs as before")
---------------------------------------------------------------------------

installs("minimum 4.2.0 on 4.2.1", update("2.1.0", { { name = RUNNING, minimumOs = "4.2.0" } }), { RUNNING })
installs("minimum equal to the OS", update("2.2.0", { { name = RUNNING, minimumOs = "4.2.1" } }), { RUNNING })
installs("no minimum_os_version", update("2.3.0", { { name = RUNNING } }), { RUNNING })

---------------------------------------------------------------------------
T.section("versions compare numerically per component")
---------------------------------------------------------------------------

osVersion = "4.10.0.100"
installs("minimum 4.9.0 on 4.10.0", update("3.0.0", { { name = RUNNING, minimumOs = "4.9.0" } }), { RUNNING })
osVersion = "4.9.5.100"
skips("minimum 4.10.0 on 4.9.5", update("3.1.0", { { name = RUNNING, minimumOs = "4.10.0" } }), { "4.10.0" })
osVersion = "4.2.1.757028"

---------------------------------------------------------------------------
T.section("one driver of a suite above the OS holds back the whole suite")
---------------------------------------------------------------------------

-- The blocking companion is last, so writing each asset as it downloads would already
-- have replaced the running driver's .c4z.
local suite = update("4.0.0", {
  { name = RUNNING, minimumOs = "4.2.0" },
  { name = COMPANION, minimumOs = "4.99.0" },
})
skips("a companion needing 4.99.0", suite, { COMPANION, "4.99.0" })
T.excludes("the running driver is not blamed", describe(suite.err), RUNNING)

installs(
  "every driver meets the OS",
  update("4.1.0", { { name = COMPANION, minimumOs = "4.2.0" }, { name = RUNNING, minimumOs = "3.3.0" } }),
  { COMPANION, RUNNING }
)

---------------------------------------------------------------------------
T.section("the Update Drivers action goes through the same check")
---------------------------------------------------------------------------

-- The action forces a reinstall, which the release's version would not otherwise trigger.
installedVersion = "5.0.0"
skips("forced, above the OS", update("5.0.0", { { name = RUNNING, minimumOs = "4.99.0" } }, true), { "4.99.0" })
installedVersion = "5.1.0"
installs("forced, within the OS", update("5.1.0", { { name = RUNNING, minimumOs = "4.2.0" } }, true), { RUNNING })
installedVersion = "1.0.0"

---------------------------------------------------------------------------
T.section("a package the updater cannot read is not installed")
---------------------------------------------------------------------------

local unreadable = update("6.0.0", { { name = RUNNING, body = "<html>rate limited</html>" } })
T.contains("rejects", describe(unreadable.err), "not a readable driver package")
T.eq("writes nothing", unreadable.writes, {})
T.eq("sends nothing to Director", unreadable.sent, {})

local noDevicedata = update("6.1.0", { { name = RUNNING, body = F.zip({ { "driver.xml", "<other/>" } }) } })
T.contains("a driver.xml with no devicedata is rejected", describe(noDevicedata.err), "no devicedata")
T.eq("and writes nothing", noDevicedata.writes, {})

-- A failed download used to leave the drivers that had already arrived written but not installed.
local failed = update("6.2.0", { { name = COMPANION, minimumOs = "4.2.0" }, { name = RUNNING, missing = true } })
T.contains("a failed download rejects", describe(failed.err), "404")
T.eq("and writes none of the drivers that did download", failed.writes, {})

---------------------------------------------------------------------------
T.section("the packager's deflated driver.xml is read")
---------------------------------------------------------------------------

local packaged = update("20261001", { { name = RUNNING, body = F.packagedC4z() } })
skips("a packaged .c4z needing 4.99.0", packaged, { "requires C4 OS 4.99.0", "version 20261001" })

---------------------------------------------------------------------------
T.section("a skipped release is not downloaded again")
---------------------------------------------------------------------------

local again = update("2.0.0", { { name = RUNNING, minimumOs = "4.99.0" } })
skips("the same release on the next check", again, { "requires C4 OS 4.99.0" })
T.eq("without downloading it", again.gets, {})

-- What is remembered is the minimum, not the verdict: an OS that meets it installs.
osVersion = "4.99.0.1"
local upgraded = update("2.0.0", { { name = RUNNING, minimumOs = "4.99.0" } })
installs("after the OS reaches it", upgraded, { RUNNING })
osVersion = "4.2.1.757028"

T.finish()
