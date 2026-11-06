-- Tests that the updater skips a release whose declared minimum OS is above the controller's
-- and takes the newest one it can run, so raising a driver's minimum OS does not disable it
-- on an older controller.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_github_updater_minimum_os.lua

local T = require("testlib")

local updater = require("lib.github-updater")
require("drivers-common-public.global.lib")
JSON = require("JSON")
local deferred = require("deferred")
local http = require("lib.http")

local FILENAME = "example.c4z"

--- A release as GitHub lists it, with the notes tools/package.py release-body starts.
local function release(tag, minimumOS, fields)
  local out = {
    tag_name = tag,
    name = tag,
    draft = false,
    prerelease = false,
    body = "## What's Changed\n* a change",
    assets = { { name = FILENAME, browser_download_url = "https://example.invalid/" .. tag } },
  }
  if minimumOS ~= nil then
    out.body = "<!-- minimum_os_version: " .. minimumOS .. " -->\n\n" .. out.body
  end
  for key, value in pairs(fields or {}) do
    out[key] = value
  end
  return out
end

--- Runs on a controller at `controllerOS`, with GitHub listing `releases` newest first.
local function on(controllerOS, releases)
  C4.GetVersionInfo = function()
    return { version = controllerOS }
  end
  http.get = function()
    return deferred.new():resolve({ body = releases })
  end
end

local function latest(includePrereleases)
  local tag, failure
  updater:getLatestRelease("finitelabs/example", includePrereleases):next(function(found)
    tag = found.tag_name
  end, function(err)
    failure = err
  end)
  return tag, failure
end

T.section("A release the controller can run")

on("4.3.0.757028-res", { release("v20261102", "4.3.0") })
T.eq("at its minimum", latest(), "v20261102")

on("4.4.1.800000-res", { release("v20261102", "4.3.0") })
T.eq("above its minimum", latest(), "v20261102")

on("4.2.1.757028-res", { release("v20261102") })
T.eq("with no declared minimum", latest(), "v20261102")

on("4.2.1.757028-res", { release("v20261102", nil, { body = nil }) })
T.eq("with no notes at all", latest(), "v20261102")

on("4.10.0.1-res", { release("v20261102", "4.9.0") })
T.eq("versions compare as numbers", latest(), "v20261102")

T.section("A release above the controller's OS")

on("4.2.1.757028-res", { release("v20261102", "4.3.0"), release("v20261101", "3.3.0") })
T.eq("the newest one it can run is taken instead", latest(), "v20261101")

on("4.2.1.757028-res", { release("v20261103", "4.4.0"), release("v20261102", "4.3.0"), release("v20261101", "3.3.0") })
T.eq("every one above it is passed over", latest(), "v20261101")

on("4.2.1.757028-res", { release("v20261102", "4.3.0") })
local tag, failure = latest()
T.eq("with nothing it can run, no release is returned", tag, nil)
T.eq("and the failure says why", failure, "repo finitelabs/example has no release this controller's OS can run")

T.section("The Prerelease channel")

on("4.2.1.757028-res", {
  release("v20261103-rc1", "4.3.0", { prerelease = true }),
  release("v20261102-rc1", "3.3.0", { prerelease = true }),
  release("v20261101", "3.3.0"),
})
T.eq("a pre-release above the controller's OS is passed over", latest(true), "v20261102-rc1")
T.eq("off the channel, pre-releases stay out", latest(false), "v20261101")

T.section("What the update does")

GetDriverVersion = function()
  return "20261101"
end

local function assets(forceUpdate)
  local urls
  updater:getOutdatedDriverAssets("finitelabs/example", { FILENAME }, false, forceUpdate):next(function(found)
    urls = {}
    for _, asset in ipairs(found) do
      urls[#urls + 1] = asset.browser_download_url
    end
  end)
  return urls
end

on("4.2.1.757028-res", { release("v20261102", "4.3.0"), release("v20261101", "3.3.0") })
T.eq("the driver on the newest release it can run downloads nothing", assets(false), {})
T.eq("a forced update stays on a release it can run", assets(true), { "https://example.invalid/v20261101" })

on("4.3.0.757028-res", { release("v20261102", "4.3.0"), release("v20261101", "3.3.0") })
T.eq("once the OS reaches the minimum, the release downloads", assets(false), { "https://example.invalid/v20261102" })

T.finish()
