--- Diagnostics module for memory leak detection and error monitoring.
--- Periodically walks the _G table graph, detects growth, and ships metrics to InfluxDB 3.

local log = require("lib.logging")
-- #ifdef DRIVERCENTRAL
local http = require("lib.http")

require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
require("lib.utils")

-- Both are substituted at build time by tools/preprocess.py, from the env var of
-- the same name or a repo-root .env; an unsubstituted placeholder fails the build.
local INFLUXDB_URL = "%%SECRET:INFLUXDB_URL%%"
local INFLUXDB_TOKEN = "%%SECRET:INFLUXDB_TOKEN%%"
local INFLUXDB_BUCKET = "metrics"
local INFLUXDB_LOGS_BUCKET = "logs"

local DEFAULT_CENSUS_INTERVAL = ONE_HOUR
local CENSUS_MAX_DEPTH = 15
local CENSUS_TOP_N = 20
local CENSUS_THRESHOLD = 100
local CENSUS_NEW_TABLE_MIN_SIZE = 10
local INFLUXDB_TOP_N = 10

--- Paths that should always be recursed into, even if they exceed the CENSUS_THRESHOLD.
--- @type table<string, boolean?>
local CENSUS_ALWAYS_RECURSE = { ["_G"] = true }

local ERROR_RATE_LIMIT = 10
local ERROR_RATE_WINDOW = 60

--- @alias CensusEntry {path: string, size: number, bytes: number}

--- Reports whether the build-time secrets were substituted. `make test` and any other
--- raw-source context runs this file with the placeholders still in it, so without this
--- the module would POST to a placeholder URL bearing a placeholder token.
--- Spelling a whole placeholder here would itself trip the build's unresolved-secret scan.
--- @return boolean
local function secretsConfigured()
  for _, value in ipairs({ INFLUXDB_URL, INFLUXDB_TOKEN }) do
    if #value == 0 or value:find("%%SECRET:", 1, true) then
      return false
    end
  end
  return true
end

--- @class Diagnostics
--- @field _enabled boolean
--- @field _warnedUnconfigured boolean|nil Whether the unsubstituted-secret warning has been logged.
--- @field _previousCensus table<string, {count: number, bytes: number}?>|nil Map of path -> {count, bytes} from last census.
--- @field _gcAvailable boolean
--- @field _mac string|nil Cached MAC address.
--- @field _deviceId number|nil Cached device ID.
--- @field _driver string|nil Cached driver filename.
--- @field _version string|nil Cached driver version.
--- @field _osVersion string|nil Cached controller OS version.
--- @field _censusInterval number Census timer interval in milliseconds.
--- @field _errorWriteCount number Number of error writes in the current rate window.
--- @field _errorWindowStart number Start time of the current rate window.
--- @field _errorsDropped number Number of errors dropped due to rate limiting in the current window.
local Diagnostics = {}
Diagnostics.__index = Diagnostics

--- Creates a new Diagnostics instance.
--- @return Diagnostics
function Diagnostics:new()
  local instance = setmetatable({}, self)
  instance._enabled = false
  instance._warnedUnconfigured = false
  instance._previousCensus = nil
  instance._gcAvailable = false
  instance._mac = nil
  instance._deviceId = nil
  instance._driver = nil
  instance._version = nil
  instance._osVersion = nil
  instance._censusInterval = DEFAULT_CENSUS_INTERVAL
  instance._errorWriteCount = 0
  instance._errorWindowStart = 0
  instance._errorsDropped = 0
  return instance
end

--- Enables or disables diagnostics.
--- @param enabled boolean
function Diagnostics:setEnabled(enabled)
  self._enabled = toboolean(enabled)
  if self._enabled then
    if not secretsConfigured() then
      self._enabled = false
      if not self._warnedUnconfigured then
        self._warnedUnconfigured = true
        log:warn("[DIAG] Cloud monitoring unavailable: this build has no InfluxDB credentials")
      end
      return
    end
    self:_detectGcAvailability()
    self:_cacheTags()
    self:_installHooks()
    self:_startTimer()
    self:_startInitialReport()
    log:info(
      "[DIAG] Cloud monitoring enabled (interval=%dm, gc=%s)",
      self._censusInterval / ONE_MINUTE,
      self._gcAvailable and "available" or "unavailable"
    )
  else
    CancelTimer("Diagnostics")
    CancelTimer("InitialReport")
    self._previousCensus = nil
    self:_removeHooks()
    log:info("[DIAG] Cloud monitoring disabled")
  end
end

--- Returns whether diagnostics is enabled.
--- @return boolean
function Diagnostics:isEnabled()
  return self._enabled
end

--- Sets the census interval. Restarts the timer if monitoring is active.
--- @param interval number Interval in milliseconds (e.g. ONE_MINUTE, ONE_HOUR).
function Diagnostics:setCensusInterval(interval)
  self._censusInterval = interval
  if self._enabled then
    self:_startTimer()
  end
end

--- Takes an immediate snapshot: runs census, logs, and writes to InfluxDB.
function Diagnostics:dumpSnapshot()
  local wasEnabled = self._enabled
  if not wasEnabled then
    self:_detectGcAvailability()
    self:_cacheTags()
  end
  log:print("--- Diagnostics Snapshot ---")
  self:_tick(true)
  log:print("--- End Diagnostics Snapshot ---")
end

--- Captures an error and writes it directly to the InfluxDB logs bucket.
--- Rate-limited to ERROR_RATE_LIMIT writes per ERROR_RATE_WINDOW seconds.
--- @param message string
--- @param traceback string|nil
--- @param source string
function Diagnostics:captureError(message, traceback, source)
  if not self._enabled then
    return
  end

  message = tostring(message or "unknown error")
  traceback = tostring(traceback or "")
  source = tostring(source or "unknown")

  local now = os.time()

  -- Reset rate window if expired
  if now - self._errorWindowStart >= ERROR_RATE_WINDOW then
    if self._errorsDropped > 0 then
      log:warn("[DIAG] Rate limit: dropped %d errors in last window", self._errorsDropped)
    end
    self._errorWriteCount = 0
    self._errorWindowStart = now
    self._errorsDropped = 0
  end

  -- Rate limit
  if self._errorWriteCount >= ERROR_RATE_LIMIT then
    self._errorsDropped = self._errorsDropped + 1
    return
  end
  self._errorWriteCount = self._errorWriteCount + 1

  self:_writeErrorLog(message, traceback, source, now)
end

--- Wraps a function with xpcall, capturing errors into diagnostics.
--- @param fn function
--- @param source string
--- @return function
function Diagnostics:wrap(fn, source)
  return function(...)
    local args = { ... }
    local success, result = xpcall(function()
      return fn(unpack(args))
    end, function(err)
      local full = debug.traceback(err, 2)
      local traceback = full:match("\n(.+)$") or ""
      self:captureError(tostring(err), traceback, source)
      log:error("[DIAG] Error in %s: %s", source, full)
      return err
    end)
    if success then
      return result
    end
  end
end

-- Private methods ---------------------------------------------------------

--- Detects whether collectgarbage is available.
--- @private
function Diagnostics:_detectGcAvailability()
  local success, _ = pcall(function()
    return collectgarbage("count")
  end)
  self._gcAvailable = success
end

--- Caches the MAC address and device ID tags.
--- @private
function Diagnostics:_cacheTags()
  local success, mac = pcall(function()
    return C4:GetUniqueMAC()
  end)
  self._mac = success and mac or "unknown"

  local ok, id = pcall(function()
    return C4:GetDeviceID()
  end)
  self._deviceId = ok and tonumber(id) or 0

  local dOk, driver = pcall(function()
    return C4:GetDriverFileName()
  end)
  self._driver = dOk and driver or "unknown"

  local vOk, version = pcall(function()
    return C4:GetDeviceData(C4:GetDeviceID(), "version")
  end)
  self._version = vOk and version or "unknown"

  local osOk, osVersion = pcall(function()
    return Select(C4:GetVersionInfo(), "version")
  end)
  self._osVersion = osOk and osVersion or "unknown"
end

--- Installs global error hooks so handler, timer, and promise errors are captured.
--- @private
function Diagnostics:_installHooks()
  ON_HANDLER_ERROR = function(source, err)
    local errStr = tostring(err)
    local message = errStr:match("^([^\n]+)") or errStr
    local traceback = errStr:match("\n(.+)$") or ""
    self:captureError(message, traceback, source)
  end

  ON_TIMER_ERROR = function(timerId, err)
    local errStr = tostring(err)
    local message = errStr:match("^([^\n]+)") or errStr
    local traceback = errStr:match("\n(.+)$") or ""
    self:captureError(message, traceback, "Timer." .. tostring(timerId))
  end

  ON_UNHANDLED_REJECTION = function(err)
    local errStr = tostring(err)
    local message = errStr:match("^([^\n]+)") or errStr
    local traceback = errStr:match("\n(.+)$") or ""
    self:captureError(message, traceback, "UnhandledRejection")
  end
end

--- Removes global error hooks.
--- @private
--- @diagnostic disable-next-line: unused
function Diagnostics:_removeHooks()
  ON_HANDLER_ERROR = nil
  ON_TIMER_ERROR = nil
  ON_UNHANDLED_REJECTION = nil
end

--- Starts the repeating census timer.
--- @private
function Diagnostics:_startTimer()
  SetTimer("Diagnostics", self._censusInterval, function()
    if not self._enabled then
      return
    end
    self:_tick()
  end, true)
end

--- Schedules a one-shot initial report 30s after enable.
--- @private
function Diagnostics:_startInitialReport()
  SetTimer("InitialReport", 30 * ONE_SECOND, function()
    if not self._enabled then
      return
    end
    self:_tick()
  end)
end

--- Runs one full diagnostics tick: census + compare + log + influx.
--- @private
--- @param verbose boolean|nil When true, logs at print level (for snapshots). Otherwise uses trace/debug.
function Diagnostics:_tick(verbose)
  local out = verbose and log.LogLevel.PRINT or log.LogLevel.TRACE
  local outWarn = verbose and log.LogLevel.PRINT or log.LogLevel.DEBUG

  -- Memory
  local memoryKB = nil
  if self._gcAvailable then
    local success, count = pcall(collectgarbage, "count")
    if success then
      memoryKB = tonumber(count)
    end
  end

  -- Census
  local census = self:_tableCensus()

  -- Build sorted list by entry count
  local sorted = {} --- @type CensusEntry[]
  for path, info in pairs(census) do
    table.insert(sorted, { path = path, size = info.count, bytes = info.bytes })
  end
  table.sort(sorted, function(a, b)
    return a.size > b.size
  end)

  -- Build sorted list by string bytes
  local sortedByBytes = {} --- @type CensusEntry[]
  for i = 1, #sorted do
    sortedByBytes[i] = sorted[i]
  end
  table.sort(sortedByBytes, function(a, b)
    return a.bytes > b.bytes
  end)

  -- Log top 20 largest by entry count
  log:log(
    out,
    "[CENSUS] Total tables found: %d%s",
    #sorted,
    memoryKB and string.format(", Lua memory: %.1f KB", memoryKB) or ""
  )
  for i = 1, math.min(CENSUS_TOP_N, #sorted) do
    local entry = sorted[i]
    if entry then
      local level = entry.size > CENSUS_THRESHOLD and outWarn or out
      log:log(level, "[CENSUS] #%d %s = %d entries, %d str bytes", i, entry.path, entry.size, entry.bytes)
    end
  end

  -- Log top 10 by string bytes (surfaces large string buffers)
  for i = 1, math.min(INFLUXDB_TOP_N, #sortedByBytes) do
    local entry = sortedByBytes[i]
    if entry and entry.bytes > 0 then
      log:log(out, "[CENSUS:BYTES] #%d %s = %d str bytes (%d entries)", i, entry.path, entry.bytes, entry.size)
    end
  end

  -- Growth detection (compare to previous census)
  if self._previousCensus then
    local growers = {}
    for path, info in pairs(census) do
      local prev = self._previousCensus[path]
      if prev then
        local countDelta = info.count - prev.count
        local bytesDelta = info.bytes - prev.bytes
        if countDelta > 0 or bytesDelta > 0 then
          table.insert(growers, {
            path = path,
            prevCount = prev.count,
            count = info.count,
            countDelta = countDelta,
            prevBytes = prev.bytes,
            bytes = info.bytes,
            bytesDelta = bytesDelta,
          })
        end
      elseif not prev and info.count > CENSUS_NEW_TABLE_MIN_SIZE then
        log:log(out, "[CENSUS] New table: %s = %d entries, %d str bytes", path, info.count, info.bytes)
      end
    end
    if #growers > 0 then
      table.sort(growers, function(a, b)
        return a.bytesDelta > b.bytesDelta
      end)
      for _, g in ipairs(growers) do
        log:log(
          outWarn,
          "[CENSUS] GREW: %s entries %d->%d (+%d), bytes %d->%d (+%d)",
          g.path,
          g.prevCount,
          g.count,
          g.countDelta,
          g.prevBytes,
          g.bytes,
          g.bytesDelta
        )
      end
    end
  end

  -- Write to InfluxDB
  self:_writeMetrics(memoryKB, #sorted, sorted, sortedByBytes)

  -- Reset error counters so they act as per-interval counters
  self._errorWriteCount = 0
  self._errorsDropped = 0

  -- Store for next comparison
  self._previousCensus = census
end

--- Recursively walks _G and returns a map of path -> {count, bytes} for each table.
--- @private
--- @return table<string, {count: number, bytes: number}>
function Diagnostics:_tableCensus()
  local results = {}
  local seen = { [self] = true }

  local function walk(tbl, path, depth)
    if depth > CENSUS_MAX_DEPTH then
      return
    end
    if seen[tbl] then
      return
    end
    seen[tbl] = true

    local count = 0
    local bytes = 0
    for k, v in pairs(tbl) do
      count = count + 1
      if type(k) == "string" then
        bytes = bytes + #k
      end
      if type(v) == "string" then
        bytes = bytes + #v
      end
    end

    if count > 0 then
      results[path] = { count = count, bytes = bytes }
    end

    -- Don't recurse into large tables unless they're on the allow list
    if count > CENSUS_THRESHOLD and not CENSUS_ALWAYS_RECURSE[path] then
      return
    end

    for k, v in pairs(tbl) do
      if type(v) == "table" and not seen[v] then
        local childPath
        if type(k) == "string" then
          childPath = path .. "." .. k
        else
          childPath = path .. "[" .. tostring(k) .. "]"
        end
        walk(v, childPath, depth + 1)
      end
    end
  end

  walk(_G, "_G", 0)
  return results
end

--- Escapes a string value for InfluxDB line protocol.
--- @param s string
--- @return string
local function escapeInfluxString(s)
  return '"' .. tostring(s):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\t", "\\t"):gsub("\r", "\\r") .. '"'
end

--- Escapes a tag value for InfluxDB line protocol.
--- @param s string
--- @return string
local function escapeInfluxTag(s)
  return (tostring(s):gsub(",", "\\,"):gsub("=", "\\="):gsub(" ", "\\ "))
end

--- Computes the current license_state tag from global DC_X.
--- @return string
local function getLicenseState()
  ---@diagnostic disable-next-line: undefined-global
  local dcx = tonumber(DC_X)
  if dcx == nil then
    return "uninitialized"
  elseif dcx == 1 then
    return "activated"
  elseif dcx < 0 then
    return "trial"
  elseif dcx == 0 then
    return "unlicensed"
  else
    return "unknown"
  end
end

--- Normalizes the Cloud Status property to a tag value.
--- @return string
--- @return boolean
local function getCloudStatus()
  local ok, status = pcall(function()
    return Properties["Cloud Status"]
  end)
  if not ok or status == nil then
    return "unknown", false
  end

  -- "Update Available, " is prepended by the cloud driver's getAS() and only
  -- appears on license/activation states, never on error strings.
  local rest = status:match("^Update Available, (.+)$")
  local updateAvailable = rest ~= nil
  if updateAvailable then
    status = rest
  end

  -- License/activation states (from cloud driver STATES.AS)
  if status == "License Activated" then
    return "activated", updateAvailable
  elseif status:sub(1, 13) == "Trial Running" then
    return "trial_running", updateAvailable
  elseif status == "Showroom License Activated" then
    return "showroom", updateAvailable
  elseif status == "Connected to Cloud" then
    return "free", updateAvailable
  elseif status == "Trial Expired" then
    return "trial_expired", updateAvailable
  elseif status == "Invalid License" then
    return "invalid_license", updateAvailable

  -- Client initialization errors
  elseif status == "Error: missing PID" then
    return "missing_pid", false
  elseif status == "Error: missing DID" then
    return "missing_device_id", false
  elseif status == 'Missing property "Automatic Updates"' then
    return "missing_automatic_updates_property", false
  elseif status == "Error: Could not get OS_VERSION" then
    return "missing_os_version", false
  elseif status == "Error: 6" then
    return "missing_mac_address", false
  elseif status == "Error: 7" then
    return "missing_driver_version", false
  elseif status == "Error: 3" then
    return "encode_failed", false
  elseif status == "Error: 4" then
    return "decode_failed", false

  -- Cloud driver errors
  elseif
    status == "DriverCentral.io Cloud driver not found"
    or status == "Cloud driver removed, please install cloud driver."
  then
    return "cloud_driver_not_found", false
  elseif status == "Error: more than one cloud driver installed" then
    return "too_many_cloud_drivers", false
  elseif status == "Error: no cloud version" then
    return "no_cloud_version", false
  elseif status == "Outdated cloud version" then
    return "outdated_cloud_version", false
  elseif status == "Error: 1" then
    return "unknown_cloud_version", false
  elseif status == "Error: 2" then
    return "unknown_cloud_driver", false
  else
    return "unknown", false
  end
end

--- Writes metrics and census data to InfluxDB.
--- @private
--- @param memoryKB number|nil
--- @param totalTables number
--- @param sorted CensusEntry[] Sorted by entry count descending.
--- @param sortedByBytes CensusEntry[] Sorted by string bytes descending.
function Diagnostics:_writeMetrics(memoryKB, totalTables, sorted, sortedByBytes)
  local timestamp = os.time()
  local cloudStatus, updateAvailable = getCloudStatus()
  local tags = string.format(
    "mac=%s,device_id=%s,driver=%s,version=%s,os_version=%s,license_state=%s,cloud_status=%s,update_available=%s",
    escapeInfluxTag(self._mac or "unknown"),
    escapeInfluxTag(tostring(self._deviceId or 0)),
    escapeInfluxTag(self._driver or "unknown"),
    escapeInfluxTag(self._version or "unknown"),
    escapeInfluxTag(self._osVersion or "unknown"),
    escapeInfluxTag(getLicenseState()),
    escapeInfluxTag(cloudStatus),
    escapeInfluxTag(tostring(updateAvailable))
  )

  -- c4_diagnostics measurement
  local fields = {}
  if memoryKB then
    table.insert(fields, string.format("memory_kb=%.2f", memoryKB))
  end
  table.insert(fields, string.format("global_count=%di", TableLength(_G)))
  table.insert(fields, string.format("total_tables=%di", totalTables))
  table.insert(fields, string.format("errors_reported=%di", self._errorWriteCount))
  table.insert(fields, string.format("errors_dropped=%di", self._errorsDropped))

  local lines = {}
  if #fields > 0 then
    table.insert(lines, string.format("c4_diagnostics,%s %s %d", tags, table.concat(fields, ","), timestamp))
  end

  -- c4_census measurement: one point per table, path as tag
  -- Top N by entry count
  local reported = {}
  for i = 1, math.min(INFLUXDB_TOP_N, #sorted) do
    local entry = sorted[i]
    if entry then
      reported[entry.path] = true
      table.insert(
        lines,
        string.format(
          "c4_census,%s,path=%s size=%di,bytes=%di,rank=%di %d",
          tags,
          escapeInfluxTag(entry.path),
          entry.size,
          entry.bytes,
          i,
          timestamp
        )
      )
    end
  end

  -- Top N by string bytes (skip already reported)
  for i = 1, math.min(INFLUXDB_TOP_N, #sortedByBytes) do
    local entry = sortedByBytes[i]
    if entry and entry.bytes > 0 and not reported[entry.path] then
      reported[entry.path] = true
      table.insert(
        lines,
        string.format(
          "c4_census,%s,path=%s size=%di,bytes=%di,rank=%di %d",
          tags,
          escapeInfluxTag(entry.path),
          entry.size,
          entry.bytes,
          INFLUXDB_TOP_N + i,
          timestamp
        )
      )
    end
  end

  if #lines > 0 then
    self:_postToInflux(table.concat(lines, "\n"))
  end
end

--- Writes a single error log entry to the InfluxDB logs bucket.
--- @private
--- @param message string
--- @param traceback string
--- @param source string
--- @param timestamp number
function Diagnostics:_writeErrorLog(message, traceback, source, timestamp)
  local cloudStatus, updateAvailable = getCloudStatus()
  local tags = string.format(
    "mac=%s,device_id=%s,driver=%s,version=%s,os_version=%s,license_state=%s,cloud_status=%s,update_available=%s,source=%s",
    escapeInfluxTag(self._mac or "unknown"),
    escapeInfluxTag(tostring(self._deviceId or 0)),
    escapeInfluxTag(self._driver or "unknown"),
    escapeInfluxTag(self._version or "unknown"),
    escapeInfluxTag(self._osVersion or "unknown"),
    escapeInfluxTag(getLicenseState()),
    escapeInfluxTag(cloudStatus),
    escapeInfluxTag(tostring(updateAvailable)),
    escapeInfluxTag(source)
  )
  local fields = string.format("message=%s,traceback=%s", escapeInfluxString(message), escapeInfluxString(traceback))
  local line = string.format("c4_error_log,%s %s %d", tags, fields, timestamp)
  self:_postToInflux(line, INFLUXDB_LOGS_BUCKET)
end

--- Posts line protocol data to InfluxDB.
--- @private
--- @param body string
--- @param bucket string|nil Bucket to write to (defaults to INFLUXDB_BUCKET).
--- @diagnostic disable-next-line: unused
function Diagnostics:_postToInflux(body, bucket)
  -- dumpSnapshot() reaches here without going through setEnabled, so the check is
  -- repeated at the one point every upload passes through.
  if not secretsConfigured() then
    return
  end
  bucket = bucket or INFLUXDB_BUCKET
  local url = string.format("%s/api/v2/write?bucket=%s&precision=s", INFLUXDB_URL, bucket)

  local success, err = pcall(function()
    http
      :post(url, body, {
        ["Authorization"] = "Bearer " .. INFLUXDB_TOKEN,
        ["Content-Type"] = "text/plain; charset=utf-8",
      }, { timeout = 2 })
      :next(function(response)
        log:debug("[DIAG] InfluxDB write OK (%s)", response.code)
      end, function(httpErr)
        log:debug("[DIAG] InfluxDB write failed: %s", httpErr and httpErr.error or "unknown")
      end)
  end)
  if not success then
    log:debug("[DIAG] InfluxDB post error: %s", tostring(err))
  end
end

-- Lua allows only one top-level return, and the stub below needs its own. A return
-- inside a do block is legal mid-chunk, so a raw load of this file (make test, the
-- module-load CI step, stylua) runs the real module and never parses past here.
do
  return Diagnostics:new()
end
-- #else
--- Inert stand-in with the same public surface, so a driver can require and call
--- lib.diagnostics unconditionally regardless of which distribution it is built for.
local Stub = {}
Stub.__index = Stub

function Stub:setEnabled(enabled)
  if enabled then
    log:info("[DIAG] Cloud monitoring is not included in this build")
  end
end

function Stub:isEnabled()
  return false
end

function Stub:setCensusInterval(_interval) end

function Stub:dumpSnapshot()
  log:print("[DIAG] Diagnostics are not available in this build")
end

function Stub:captureError(_message, _traceback, _source) end

--- Keeps the real module's contract of swallowing the error and returning nil,
--- so a caller behaves the same in either build; only the upload is dropped.
function Stub:wrap(fn, source)
  return function(...)
    local args = { ... }
    local success, result = xpcall(function()
      return fn(unpack(args))
    end, function(err)
      log:error("[DIAG] Error in %s: %s", source, debug.traceback(err, 2))
      return err
    end)
    if success then
      return result
    end
  end
end

return setmetatable({}, Stub)
-- #endif
