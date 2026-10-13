-- Tests for src/lib/diagnostics.lua: raw source never reaches the network.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_diagnostics.lua

local T = require("testlib")

require("c4_shim")

local http = require("lib.http")
local posts = {}
http.post = function(_self, url, body, headers)
  table.insert(posts, { url = url, body = body, headers = headers })
  return {
    next = function() end,
  }
end

--------------------------------------------------------------------------------
T.section("Raw source, placeholders unsubstituted")
--------------------------------------------------------------------------------
do
  local diagnostics = require("lib.diagnostics")
  T.check("raw source loads the real module, not the stub", rawget(diagnostics, "_censusInterval") ~= nil)

  diagnostics:setEnabled(true)
  T.eq("setEnabled(true) leaves it disabled", diagnostics:isEnabled(), false)

  local ok, err = T.capture(function()
    diagnostics:dumpSnapshot()
  end)
  T.check("dumpSnapshot() runs", ok, err)
  T.eq("dumpSnapshot() makes no request", #posts, 0)
end

--------------------------------------------------------------------------------
T.section("Substituted copy: the same calls do post")
--------------------------------------------------------------------------------
local diagnostics
do
  local path = assert(package.searchpath("lib.diagnostics", package.path))
  local file = assert(io.open(path, "r"))
  local source = file:read("*a")
  file:close()
  source = source:gsub("%%%%SECRET:INFLUXDB_URL%%%%", "https://example.invalid")
  source = source:gsub("%%%%SECRET:INFLUXDB_TOKEN%%%%", "test-token")
  diagnostics = assert(loadstring(source, "=diagnostics (substituted)"))()

  local ok, err = T.capture(function()
    diagnostics:dumpSnapshot()
  end)
  T.check("dumpSnapshot() runs", ok, err)
  T.check("dumpSnapshot() posts", #posts > 0, #posts)
  T.eq("bearer token is the substituted one", posts[1] and posts[1].headers.Authorization, "Bearer test-token")

  posts = {}
  diagnostics._enabled = true
  diagnostics:captureError('decode failed at "\\u12"', "trace", "a b,c=d\ne\\f")
  local body = posts[1] and posts[1].body or ""
  T.contains("backslash and quote escaped in a field", body, 'message="decode failed at \\"\\\\u12\\""')
  T.contains("tag escapes backslash first, then space, comma, equals, newline", body, "source=a\\ b\\,c\\=d\\ne\\\\f ")
end

--------------------------------------------------------------------------------
T.section("wrap keeps every argument and result, and reports any error")
--------------------------------------------------------------------------------
do
  local wrapped = diagnostics:wrap(function(...)
    return select("#", ...), ...
  end, "args")
  local count, a, b, c = wrapped(1, nil, 3)
  T.eq("an argument after a nil reaches the function", count, 3)
  T.eq("every result comes back", c, 3)
  T.eq("a nil result keeps its place", b, nil)
  T.eq("the first result is unchanged", a, 1)

  posts = {}
  local ok, err = T.capture(function()
    return diagnostics:wrap(function()
      error({ code = 1 })
    end, "table-error")()
  end)
  T.check("an error that is not a string does not escape", ok, err)
  T.contains("an error that is not a string is reported", posts[1] and posts[1].body or "", "source=table-error")
end

--------------------------------------------------------------------------------
T.section("A failed write does not log the server URL")
--------------------------------------------------------------------------------
do
  http.post = function(_self, url)
    return {
      next = function(_, _, onError)
        onError({ error = "HTTP POST request to " .. url .. " failed with status code 401" })
      end,
    }
  end
  local log = require("lib.logging")
  log:setLogMode("Print")
  log:setLogLevel(log.LogLevel.ULTRA)
  local printed = {}
  local realPrint = print
  print = function(...)
    table.insert(printed, table.concat({ ... }, " "))
  end
  local ok, err = pcall(function()
    diagnostics:captureError("message", "trace", "url-check")
  end)
  print = realPrint
  local output = table.concat(printed, "\n")
  T.check("captureError runs", ok, err)
  T.contains("the failure is logged with its status", output, "InfluxDB write failed with status code 401")
  T.excludes("the URL is not logged", output, "example.invalid")
end

T.finish()
