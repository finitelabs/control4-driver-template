--- A utility module for updating drivers from GitHub releases.
--- This module provides functionality to check for, download, and install driver updates from GitHub repositories.

local http = require("lib.http")
local log = require("lib.logging")
local zip = require("lib.zip")
local deferred = require("deferred")
local version = require("version")

require("lib.utils")
require("drivers-common-public.global.lib")

--- Utility class for updating drivers from GitHub releases.
--- @class GitHubUpdater
local GitHubUpdater = {}
GitHubUpdater.__index = GitHubUpdater

--- Default headers for all HTTP requests to GitHub.
--- @type table<string, string>
local DEFAULT_HEADERS = {
  ["User-Agent"] = "curl/8.1.2",
  Accept = "*/*",
}

--- What a downloaded .c4z's driver.xml declares, by download URL and upload time, so a
--- release this controller cannot run is not downloaded again on every check.
--- @type table<string, { version: string|nil, minimumOs: string|nil }>
local assetRequirements = {}

--- @param asset table A GitHub release asset.
--- @return string
local function assetKey(asset)
  return tostring(asset.browser_download_url) .. "|" .. tostring(asset.updated_at)
end

--- Read the driver version and minimum C4 OS a .c4z declares in its driver.xml.
--- @param asset table A GitHub release asset.
--- @param body string The downloaded .c4z.
--- @return { version: string|nil, minimumOs: string|nil }|nil requirement
--- @return string|nil err
local function readRequirement(asset, body)
  local xml, err = zip.read(body, "driver.xml")
  if xml == nil then
    return nil, string.format("asset %s is not a readable driver package: %s", asset.name, err)
  end
  local ok, parsed = pcall(ParseXml, xml)
  local devicedata = ok and Select(parsed, "devicedata") or nil
  if type(devicedata) ~= "table" then
    return nil, string.format("asset %s has no devicedata in its driver.xml", asset.name)
  end
  return {
    version = type(devicedata.version) == "string" and devicedata.version or nil,
    minimumOs = type(devicedata.minimum_os_version) == "string" and devicedata.minimum_os_version or nil,
  }
end

--- Why an asset cannot be installed on this controller's OS, or nil when it can.
--- @param asset table A GitHub release asset.
--- @param requirement { version: string|nil, minimumOs: string|nil }
--- @return string|nil reason
local function unsupportedReason(asset, requirement)
  -- VersionCheck is what CheckMinimumVersion disables a driver with, so the two agree.
  if IsEmpty(requirement.minimumOs) or VersionCheck(requirement.minimumOs) then
    return nil
  end
  return string.format(
    "%s version %s requires C4 OS %s or later and this controller runs %s; keeping the installed driver(s)",
    asset.name,
    requirement.version or "(unknown)",
    requirement.minimumOs,
    C4:GetVersionInfo().version
  )
end

--- Create a new instance of GitHubUpdater.
--- @return GitHubUpdater updater A new GitHubUpdater instance.
function GitHubUpdater:new()
  local instance = setmetatable({}, self)
  return instance
end

--- Retrieve the latest release from a GitHub repository.
--- @param repo string The GitHub repository, in the format "owner/repo".
--- @param includePrereleases? boolean If true, includes pre-releases (optional).
--- @return Deferred<table|nil, string> latestRelease Deferred resolving to the latest release table, or rejected with an error message.
--- @diagnostic disable-next-line: unused
function GitHubUpdater:getLatestRelease(repo, includePrereleases)
  log:trace("GitHubUpdater:getLatestRelease(%s, %s)", repo, includePrereleases)
  if IsEmpty(repo) then
    return reject("repo name is required")
  end
  return http:get("https://api.github.com/repos/" .. repo .. "/releases", DEFAULT_HEADERS):next(function(response)
    for _, release in pairs(response.body or {}) do
      local releaseVersion, err = version(release.tag_name)
      if IsEmpty(err) then
        if not release.draft and (toboolean(includePrereleases) or not release.prerelease) then
          release.version = releaseVersion
          return release
        end
      else
        log:warn("repo %s release '%s' has an invalid tag version '%s'", repo, release.name, release.tag_name)
      end
    end
    return reject(string.format("repo %s does not have any valid releases", repo))
  end, function(response)
    return reject(response.error)
  end)
end

--- Identify assets for driver files that are outdated compared to the latest GitHub release.
--- @param repo string The GitHub repository, in the format "owner/repo".
--- @param driverFilenames string[] List of driver filenames to check.
--- @param includePrereleases? boolean If true, includes pre-releases (optional).
--- @param forceUpdate? boolean If true, all assets will be treated as outdated regardless of version (optional).
--- @return Deferred<table[], string> outdatedAssets Deferred resolving to a list of assets to be updated, or rejected with an error message.
function GitHubUpdater:getOutdatedDriverAssets(repo, driverFilenames, includePrereleases, forceUpdate)
  log:trace(
    "GitHubUpdater:getOutdatedDriverAssets(%s, %s, %s, %s)",
    repo,
    driverFilenames,
    includePrereleases,
    forceUpdate
  )
  if IsEmpty(driverFilenames) then
    return reject(string.format("at least one driver filename is required to check for updates"))
  end
  -- Determine the minimum driver version from the provided filenames; this determines if an update is needed.
  local minDriverVersion
  for _, driverFilename in pairs(driverFilenames) do
    local driverVersion, err = version(GetDriverVersion(driverFilename))
    if not IsEmpty(err) then
      return reject(string.format("failed to determine the current %s driver version", driverFilename))
    elseif minDriverVersion == nil or minDriverVersion > driverVersion then
      minDriverVersion = driverVersion
    end
  end

  return self:getLatestRelease(repo, includePrereleases):next(function(latestRelease)
    if not forceUpdate and latestRelease.version <= minDriverVersion then
      return {}
    end
    --- @type table[]
    local assets = {}
    local driverFilenamesMap = TableReverse(driverFilenames)
    for _, asset in pairs(Select(latestRelease, "assets") or {}) do
      local assetName = Select(asset, "name")
      if driverFilenamesMap[assetName] ~= nil then
        driverFilenamesMap[assetName] = nil
        table.insert(assets, asset)
      end
    end
    if not IsEmpty(driverFilenamesMap) then
      return reject(
        string.format(
          "repo %s latest release does not have the following asset(s): %s",
          repo,
          table.concat(TableKeys(driverFilenamesMap), ", ")
        )
      )
    end
    return assets
  end)
end

--- Download outdated driver assets from GitHub and write them to the specified directory.
--- Writes nothing when any asset requires a newer C4 OS than this controller runs.
--- @param dir string Target directory to save downloaded driver assets.
--- @param repo string The GitHub repository, in the format "owner/repo".
--- @param driverFilenames string[] List of driver filenames to update.
--- @param includePrereleases? boolean If true, includes pre-releases (optional).
--- @param forceUpdate? boolean Optional. If true, downloads all drivers regardless of version (optional).
--- @return Deferred<string[], string|table<number, string>> outdatedDrivers Deferred resolving to a list of successfully downloaded driver filenames, or rejected with an error message or a table of error messages indexed by number.
function GitHubUpdater:downloadOutdatedDrivers(dir, repo, driverFilenames, includePrereleases, forceUpdate)
  log:trace(
    "GitHubUpdater:downloadOutdatedDrivers(%s, %s, %s, %s, %s)",
    dir,
    repo,
    driverFilenames,
    includePrereleases,
    forceUpdate
  )
  return self:getOutdatedDriverAssets(repo, driverFilenames, includePrereleases, forceUpdate):next(function(assets)
    for _, asset in ipairs(assets) do
      local known = assetRequirements[assetKey(asset)]
      local reason = known and unsupportedReason(asset, known)
      if reason then
        log:warn("Skipping driver update: %s", reason)
        return reject(reason)
      end
    end

    --- @type Deferred<table, string>[]
    local downloads = {}
    for _, asset in ipairs(assets) do
      if IsEmpty(asset.browser_download_url) then
        return reject(string.format("repo %s latest release asset %s download is unavailable", repo, asset.name))
      end

      --- @type Deferred<table, string>
      local download = http:get(asset.browser_download_url, DEFAULT_HEADERS):next(function(response)
        if string.len(response.body) < 1 then
          return reject(string.format("asset %s download is empty", asset.name))
        end
        local requirement, err = readRequirement(asset, response.body)
        if requirement == nil then
          return reject(err)
        end
        assetRequirements[assetKey(asset)] = requirement
        return { asset = asset, body = response.body, requirement = requirement }
      end, function(response)
        return reject(response.error)
      end)

      table.insert(downloads, download)
    end

    return deferred.all(downloads):next(function(downloaded)
      -- Checked before any write: a written .c4z is what Director installs from, and a
      -- partial suite would leave the drivers on mismatched versions.
      for _, download in ipairs(downloaded) do
        local reason = unsupportedReason(download.asset, download.requirement)
        if reason then
          log:warn("Skipping driver update: %s", reason)
          return reject(reason)
        end
      end

      local written, errors = {}, {}
      for i, download in ipairs(downloaded) do
        local name = download.asset.name
        -- GetDriverVersion only unlocks C4Z_ROOT for companion drivers, so a project running
        -- one driver from this repo reaches the write with the alias still locked.
        UnlockC4ZRoot()
        C4:FileSetDir(dir)
        local currentContents = C4:FileExists(name) and FileRead(name) or nil
        if FileWrite(name, download.body, true) == -1 then
          -- Restore the previous contents if the write failed
          if currentContents ~= nil then
            FileWrite(name, currentContents, true)
          end
          errors[i] = string.format("failed to download asset %s", name)
        else
          log:info("Downloaded asset %s (%d bytes)", name, string.len(download.body))
          table.insert(written, name)
        end
      end
      if not IsEmpty(errors) then
        return reject(errors)
      end
      return written
    end)
  end)
end

--- Update all given drivers to the latest release from GitHub.
--- Downloads new drivers, writes them, and sends them for update over TCP to the local system.
--- @param repo string The GitHub repository, in the format "owner/repo".
--- @param driverFilenames string[] List of driver filenames to update.
--- @param includePrereleases? boolean If true, includes pre-releases (optional).
--- @param forceUpdate? boolean If true, runs update even if drivers are up to date (optional).
--- @return Deferred<string[], table<number, string>> updatedDrivers Deferred resolving to a list of updated driver filenames, or rejected with an error table.
function GitHubUpdater:updateAll(repo, driverFilenames, includePrereleases, forceUpdate)
  log:trace("GitHubUpdater:updateAll(%s, %s, %s, %s)", repo, driverFilenames, includePrereleases, forceUpdate)
  -- Only update drivers that are already installed.
  local installedDriverFilenames = {}
  for _, driverFilename in pairs(driverFilenames) do
    if not IsEmpty(C4:GetDevicesByC4iName(driverFilename) or {}) then
      table.insert(installedDriverFilenames, driverFilename)
    end
  end

  return self
    :downloadOutdatedDrivers("C4Z_ROOT", repo, installedDriverFilenames, includePrereleases, forceUpdate)
    :next(function(downloadedDriverFilenames)
      --- @type Deferred<string[], table<number, string>>
      local d = deferred.new()
      if IsEmpty(downloadedDriverFilenames) then
        return d:resolve(downloadedDriverFilenames)
      end

      -- Update the running driver's own c4z LAST: reloading it tears down this
      -- loop (and its socket) before the remaining companions are sent, which
      -- strands them a version behind.
      local ownFilename = C4.GetDriverFileName and C4:GetDriverFileName()
      local updateOrder = {}
      local ownFilenameToUpdate
      for _, driverFilename in pairs(downloadedDriverFilenames) do
        if driverFilename == ownFilename then
          ownFilenameToUpdate = driverFilename
        else
          table.insert(updateOrder, driverFilename)
        end
      end
      if ownFilenameToUpdate ~= nil then
        table.insert(updateOrder, ownFilenameToUpdate)
      end

      C4:CreateTCPClient()
        :OnConnect(function(client)
          for _, driverFilename in ipairs(updateOrder) do
            local c4soap = XMLTag(
              "c4soap",
              XMLTag("param", driverFilename, nil, nil, {
                name = "name",
                type = "string",
              }),
              false,
              false,
              {
                name = "UpdateProjectC4i",
                session = "0",
                operation = "RWX",
                category = "composer",
                async = "0",
              }
            ) .. "\0"
            client:Write(c4soap)
          end
          client:Close()
          d:resolve(downloadedDriverFilenames)
        end)
        :OnError(function(client, errCode, errMsg)
          client:Close()
          d:reject("Error " .. errCode .. ": " .. errMsg)
        end)
        :Connect("127.0.0.1", 5020)
      return d
    end)
end

return GitHubUpdater:new()
