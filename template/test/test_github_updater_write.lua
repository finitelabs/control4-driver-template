-- Tests that the GitHub updater notices a .c4z it failed to write and puts every driver
-- file of the update back. Director installs from the written file, so an unnoticed
-- failure would send it a truncated or missing driver, or half of a suite.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_github_updater_write.lua

local T = require("testlib")
local F = require("c4_fixtures")

local updater = require("lib.github-updater")
require("drivers-common-public.global.lib")
JSON = require("JSON")
local deferred = require("deferred")
local semver = require("version")
local http = require("lib.http")

local RUNNING = C4:GetDriverFileName()
local COMPANION = "example_companion.c4z"
local OLD = { [RUNNING] = "installed " .. RUNNING, [COMPANION] = "installed " .. COMPANION }

C4.GetDevicesByC4iName = function()
  return { 1 }
end
GetDriverVersion = function()
  return "1.0.0"
end

local root = ShimFiles("C4Z_ROOT")
local real = { FileOpen = C4.FileOpen, FileRead = C4.FileRead, FileWrite = C4.FileWrite, FileDelete = C4.FileDelete }

--- Faults for the next update, by C4 file method. A fault gets the method's arguments and
--- returns true and a value to answer with instead, or nothing to call through.
local faults = {}
for method, realMethod in pairs(real) do
  C4[method] = function(self, ...)
    local fault = faults[method]
    if fault then
      local ok, value = fault(...)
      if ok then
        return value
      end
    end
    return realMethod(self, ...)
  end
end

--- Publish a release of the running driver then the companion, with the installed files as
--- `installed` lists them, run updateAll and report the outcome and what C4Z_ROOT holds.
local function update(tag, installed, methodFaults)
  local assets = {}
  for _, name in ipairs({ RUNNING, COMPANION }) do
    local url = "https://example.invalid/" .. tag .. "/" .. name
    table.insert(assets, { name = name, browser_download_url = url, updated_at = "2026-10-01T00:00:00Z" })
  end
  updater.getLatestRelease = function()
    return deferred.new():resolve({ version = semver(tag), assets = assets })
  end
  http.get = function()
    return deferred.new():resolve({ body = F.c4z(tag) })
  end

  for name in pairs(root) do
    root[name] = nil
  end
  for name, contents in pairs(installed) do
    root[name] = contents
  end
  faults = methodFaults or {}

  local tcp = F.captureTcpClient()
  local result = {}
  updater:updateAll("finitelabs/example", { RUNNING, COMPANION }, false, false):next(function(updated)
    result.updated = updated
  end, function(err)
    result.err = err
  end)
  tcp.restore()
  faults = {}

  result.sent = #tcp.writes
  result.open = C4:FileGetOpenedHandles()
  result.files = {}
  for name, contents in pairs(root) do
    result.files[name] = contents
  end
  return result
end

--- A fault that fires for one file, by the name its handle was opened with.
local function forFile(name, value)
  return function(fh)
    if C4:FileGetName(fh) == name then
      return true, value
    end
  end
end

--- Fire a fault on its first match only, so the restore that follows can succeed.
local function once(fault)
  local fired = false
  return function(...)
    if not fired then
      local ok, value = fault(...)
      fired = ok == true
      return ok, value
    end
  end
end

local function restores(label, result, needle, installed)
  T.eq(label .. ": resolves nothing", result.updated, nil)
  T.contains(label .. ": says which write failed", tostring(result.err), "failed to write " .. needle)
  T.contains(label .. ": says the files are unchanged", tostring(result.err), "unchanged")
  T.eq(label .. ": sends nothing to Director", result.sent, 0)
  T.eq(label .. ": leaves the installed files as they were", result.files, installed or OLD)
  T.eq(label .. ": leaves no file open", result.open, nil)
end

--- A FileDelete fault that leaves the companion in place, as the controller answers.
local function keepsCompanion(name)
  return name == COMPANION, false
end

---------------------------------------------------------------------------
T.section("a release that writes cleanly installs")
---------------------------------------------------------------------------

local clean = update("2.0.0", OLD)
T.eq("resolves with both drivers", clean.updated, { RUNNING, COMPANION })
T.eq("sends both to Director", clean.sent, 2)
T.eq("C4Z_ROOT holds the release", clean.files, { [RUNNING] = F.c4z("2.0.0"), [COMPANION] = F.c4z("2.0.0") })
T.eq("leaves no file open", clean.open, nil)

---------------------------------------------------------------------------
T.section("a failed write puts every file of the update back")
---------------------------------------------------------------------------

-- The companion is written second, so the running driver's new file is already in place.
local cannotCreate = once(function(name)
  if name == COMPANION and not C4:FileExists(name) then
    return true, -1
  end
end)
restores("the companion cannot be created", update("2.1.0", OLD, { FileOpen = cannotCreate }), COMPANION)

local invalid = once(forFile(COMPANION, -1))
restores("the companion's handle is not valid", update("2.2.0", OLD, { FileWrite = invalid }), COMPANION)

local short = once(function(fh, _, data)
  if C4:FileGetName(fh) == COMPANION then
    return true, real.FileWrite(C4, fh, 10, data:sub(1, 10))
  end
end)
restores("the companion is written short", update("2.3.0", OLD, { FileWrite = short }), COMPANION)

-- Longer than the release, so the write leaves its tail and only reading it back shows it.
local LONG = { [RUNNING] = OLD[RUNNING], [COMPANION] = OLD[COMPANION] .. string.rep(".", 1000) }
local notDeleted = update("2.4.0", LONG, { FileDelete = once(keepsCompanion) })
restores("the old companion is not deleted", notDeleted, COMPANION, LONG)

-- The restore cannot delete it either and writes the old bytes back over the release.
local neverDeleted = update("2.4.1", LONG, { FileDelete = keepsCompanion })
restores("the old companion is never deleted", neverDeleted, COMPANION, LONG)

local fresh = update("2.5.0", { [RUNNING] = OLD[RUNNING] }, { FileWrite = once(forFile(COMPANION, -1)) })
T.contains("a driver with no file before", tostring(fresh.err), "unchanged")
T.eq("has none after", fresh.files, { [RUNNING] = OLD[RUNNING] })

-- FileWrite answers -1 for 0 bytes, so only reading back shows an empty file restored.
local empty = { [RUNNING] = OLD[RUNNING], [COMPANION] = "" }
local emptied = update("2.6.0", empty, { FileWrite = once(forFile(COMPANION, -1)) })
T.contains("an empty installed file", tostring(emptied.err), "unchanged")
T.eq("is restored empty", emptied.files, empty)

---------------------------------------------------------------------------
T.section("a restore that fails is reported")
---------------------------------------------------------------------------

local companionFails = once(forFile(COMPANION, -1))
local stuck = update("3.0.0", OLD, {
  FileWrite = function(fh, _, data)
    if data == OLD[RUNNING] then
      return true, -1
    end
    return companionFails(fh)
  end,
})
T.eq("resolves nothing", stuck.updated, nil)
T.contains(
  "names both files",
  tostring(stuck.err),
  "failed to write " .. COMPANION .. " and could not restore " .. RUNNING
)
T.eq("sends nothing to Director", stuck.sent, 0)

local stray = update("3.1.0", { [RUNNING] = OLD[RUNNING] }, {
  FileWrite = once(forFile(COMPANION, -1)),
  FileDelete = keepsCompanion,
})
T.contains(
  "a new file it cannot remove is named",
  tostring(stray.err),
  "failed to write " .. COMPANION .. " and could not restore " .. COMPANION
)
T.eq("and nothing is sent to Director", stray.sent, 0)

---------------------------------------------------------------------------
T.section("an old file the delete leaves is written over from the start")
---------------------------------------------------------------------------

-- The installed companion is shorter than the release, so the release covers all of it.
local over = update("3.2.0", OLD, { FileDelete = keepsCompanion })
T.eq("resolves with both drivers", over.updated, { RUNNING, COMPANION })
T.eq("sends both to Director", over.sent, 2)
T.eq("C4Z_ROOT holds the release", over.files, { [RUNNING] = F.c4z("3.2.0"), [COMPANION] = F.c4z("3.2.0") })

---------------------------------------------------------------------------
T.section("an installed file that cannot be read is not overwritten")
---------------------------------------------------------------------------

local unreadable = update("4.0.0", OLD, {
  FileOpen = function(name)
    if name == COMPANION then
      return true, -1
    end
  end,
})
T.eq("resolves nothing", unreadable.updated, nil)
T.contains("says which file it could not read", tostring(unreadable.err), "cannot read the current " .. COMPANION)
T.eq("sends nothing to Director", unreadable.sent, 0)
T.eq("writes none of the drivers", unreadable.files, OLD)

-- A partial copy would be what a later failure restores.
local readsShort = update("4.1.0", OLD, {
  FileRead = once(function(fh, count)
    if C4:FileGetName(fh) == COMPANION then
      return true, real.FileRead(C4, fh, count - 1)
    end
  end),
})
T.contains("a file that reads back short", tostring(readsShort.err), "cannot read the current " .. COMPANION)
T.eq("is not overwritten either", readsShort.files, OLD)

T.finish()
