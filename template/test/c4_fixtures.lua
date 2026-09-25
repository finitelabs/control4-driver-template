-- Reusable Control4 test seams built on c4_shim.
--
-- Separate from c4_shim so the environment mock stays one clean layer and the
-- fixtures a test composes stay another. Generic assertions live in testlib.
--
-- Usage:
--   local F = require("c4_fixtures")

require("c4_shim")

local F = {}

--- Reload c4_shim with luasocket forced present or absent, run body, then put
--- every global the reload touched back.
---
--- The two branches of the shim define C4:SetTimer separately and CI has no
--- luasocket while a developer machine may, so behaviour that must hold on both
--- has to be driven on both. When luasocket is faked present, body receives a
--- clock whose advance() moves time forward and fires whatever came due.
---
--- Returns pcall's ok and error.
function F.withShim(opts, body)
  local hasSocket = opts.luasocket and true or false
  local saved = {
    C4 = C4,
    Variables = Variables,
    Properties = Properties,
    socketLoaded = package.loaded["socket"],
    socketPreload = package.preload["socket"],
    shim = package.loaded["c4_shim"],
    Timer = Timer,
    TimerFunctions = TimerFunctions,
    shimAccessors = {},
  }
  for name, value in pairs(_G) do
    if type(name) == "string" and name:find("^Shim") then
      saved.shimAccessors[name] = value
    end
  end

  local now = opts.startTime or 1000
  package.loaded["socket"] = nil
  if hasSocket then
    package.preload["socket"] = function()
      return {
        gettime = function()
          return now
        end,
        sleep = function() end,
        tcp = function()
          return nil
        end,
      }
    end
  else
    package.preload["socket"] = function()
      error("luasocket not installed")
    end
  end

  package.loaded["c4_shim"] = nil
  require("c4_shim")

  -- drivers-common-public/global/timer.lua keeps its registries in globals, so a
  -- fresh shim alone does not give the body a clean timer table.
  Timer, TimerFunctions = {}, {}

  local clock = {
    now = function()
      return now
    end,
    advance = function(seconds)
      now = now + (seconds or 1)
      C4:ProcessTimers()
    end,
  }

  local ok, err = pcall(body, clock)

  package.loaded["socket"] = saved.socketLoaded
  package.preload["socket"] = saved.socketPreload
  package.loaded["c4_shim"] = saved.shim
  -- The id counter and the attribute tables are locals in the shim, so the
  -- reload got its own and restoring C4 restores the originals with it.
  C4, Variables, Properties = saved.C4, saved.Variables, saved.Properties
  Timer, TimerFunctions = saved.Timer, saved.TimerFunctions
  -- The Shim* accessors are free globals, not C4 methods, so restoring C4 leaves
  -- the reload's copies in place, closed over the reload's tables.
  for name, value in pairs(saved.shimAccessors) do
    _G[name] = value
  end

  return ok, err
end

--- Replace C4:CreateTCPClient with one that records what is written and
--- completes the connect synchronously.
---
--- Returns a handle whose `writes` holds every Write payload in order, and whose
--- `restore()` puts the real constructor back.
function F.captureTcpClient()
  local capture = { writes = {} }
  local real = C4.CreateTCPClient

  C4.CreateTCPClient = function()
    local client = {}
    function client:OnConnect(callback)
      self._onConnect = callback
      return self
    end
    function client:OnError()
      return self
    end
    function client:Write(data)
      table.insert(capture.writes, data)
      return self
    end
    function client:Close() end
    function client:Connect()
      if self._onConnect then
        self._onConnect(self)
      end
      return self
    end
    return client
  end

  function capture.restore()
    C4.CreateTCPClient = real
  end

  return capture
end

--- @param n integer
--- @param bytes integer
--- @return string
local function littleEndian(n, bytes)
  local out = {}
  for i = 1, bytes do
    out[i] = string.char(n % 256)
    n = math.floor(n / 256)
  end
  return table.concat(out)
end

--- A zip archive laid out as the driver packager writes one, with every file stored
--- uncompressed. CRCs are left zero: lib.zip does not read them.
--- @param files { [1]: string, [2]: string, extra?: string, centralExtra?: string, comment?: string }[]
--- Ordered { name, contents } pairs, each with optional extra fields for its local header and its
--- central directory entry, and a comment for the latter.
--- @return string
function F.zip(files)
  local body, central = {}, {}
  local offset = 0
  for _, file in ipairs(files) do
    local name, contents = file[1], file[2]
    local extra, centralExtra, comment = file.extra or "", file.centralExtra or "", file.comment or ""
    local sizes = littleEndian(0, 4) .. littleEndian(#contents, 4) .. littleEndian(#contents, 4)
    local header = "PK\3\4" .. littleEndian(20, 2) .. littleEndian(0, 8) .. sizes .. littleEndian(#name, 2)
    header = header .. littleEndian(#extra, 2) .. name .. extra
    table.insert(body, header .. contents)
    table.insert(
      central,
      "PK\1\2"
        .. littleEndian(20, 2)
        .. littleEndian(20, 2)
        .. littleEndian(0, 8)
        .. sizes
        .. littleEndian(#name, 2)
        .. littleEndian(#centralExtra, 2)
        .. littleEndian(#comment, 2)
        .. littleEndian(0, 8)
        .. littleEndian(offset, 4)
        .. name
        .. centralExtra
        .. comment
    )
    offset = offset + #header + #contents
  end
  local directory = table.concat(central)
  local count = littleEndian(#files, 2)
  local tail = "PK\5\6" .. littleEndian(0, 4) .. count .. count .. littleEndian(#directory, 4)
  return table.concat(body) .. directory .. tail .. littleEndian(offset, 4) .. littleEndian(0, 2)
end

--- A .c4z whose driver.xml declares `version` and, unless nil, `minimumOs`.
--- @param version string
--- @param minimumOs? string
--- @return string
function F.c4z(version, minimumOs)
  local xml = '<?xml version="1.0"?>\n<devicedata>\n  <version>' .. version .. "</version>\n"
  if minimumOs ~= nil then
    xml = xml .. "  <minimum_os_version>" .. minimumOs .. "</minimum_os_version>\n"
  end
  xml = xml .. "  <name>Example</name>\n</devicedata>\n"
  return F.zip({ { "driver.lua", "-- driver" }, { "driver.xml", xml } })
end

--- The driver.xml inside F.packagedC4z().
F.PACKAGED_DRIVER_XML = [[
<?xml version="1.0"?>
<devicedata>
  <copyright>Copyright 2026 Example Labs</copyright>
  <creator>Example Labs</creator>
  <manufacturer>Example Labs</manufacturer>
  <name>Example Device</name>
  <model>Example Device</model>
  <created>09/24/2026 09:00 AM</created>
  <modified>09/24/2026 09:00 AM</modified>
  <version>20261001</version>
  <control>lua_gen</control>
  <controlmethod>IP</controlmethod>
  <driver>DriverWorks</driver>
  <minimum_os_version>4.99.0</minimum_os_version>
</devicedata>
]]

--- A .c4z written by Python's zipfile with ZIP_DEFLATED, as the driver packager writes
--- one: driver.xml (F.PACKAGED_DRIVER_XML), driver.lua ("-- driver\n" x 20) and
--- www/documentation/index.html ("<html></html>"), all deflated.
--- @return string
function F.packagedC4z()
  return C4:Base64Decode(table.concat({
    "UEsDBBQAAAAIADRKOF2AgU4W8wAAAPYBAAAKAAAAZHJpdmVyLnhtbHWRX2vDIBTF3/MppB8gmlAGGc4y1j0MWtjbHoOLt63MP8WY",
    "0n77qjFZ17In5ZzfvR6OdHXWCp3A9dKal0VVksWKFVTASXYguOesQIh29nhxcn/w7G26oZrUT+j9zPVRAdrw757iXywNOeDeOnbH",
    "ZDUSmpthxzs/OLjH/liRNVzDzKxTPIqTmDZZAerBHtU5CwhGGlwvcYpOmmdC0Os2RwpmXiR38j9ydiOaS2ORqQipKJ6UsTLjnVVM",
    "Dbzdg4nljMKNqcEfrGAfn7OblcgIJ8M+tk7Hl3U/oZWspaDSSD3o1vbt9OyybJqShJSPVhFmb770ClBLAwQUAAAACAA0SjhdzZX6",
    "1g8AAADIAAAACgAAAGRyaXZlci5sdWHT1VVIKcosSy3i0h3SLABQSwMEFAAAAAgANEo4XR+HG2ALAAAADQAAABwAAAB3d3cvZG9j",
    "dW1lbnRhdGlvbi9pbmRleC5odG1ss8koyc2xs9EHUwBQSwECFAMUAAAACAA0SjhdgIFOFvMAAAD2AQAACgAAAAAAAAAAAAAAgAEA",
    "AAAAZHJpdmVyLnhtbFBLAQIUAxQAAAAIADRKOF3NlfrWDwAAAMgAAAAKAAAAAAAAAAAAAACAARsBAABkcml2ZXIubHVhUEsBAhQD",
    "FAAAAAgANEo4XR+HG2ALAAAADQAAABwAAAAAAAAAAAAAAIABUgEAAHd3dy9kb2N1bWVudGF0aW9uL2luZGV4Lmh0bWxQSwUGAAAA",
    "AAMAAwC6AAAAlwEAAAAA",
  }))
end

return F
