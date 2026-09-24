-- Tests src/lib/zip.lua: reading one file out of an in-memory .c4z, which the GitHub
-- updater does to learn a release's minimum C4 OS before installing it. The deflate
-- streams below were produced by zlib (raw, wbits -15), the compressor behind the
-- driver packager's zipfile.ZIP_DEFLATED.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_zip.lua

local T = require("testlib")
local F = require("c4_fixtures")

local zip = require("lib.zip")

local function b64(s)
  return C4:Base64Decode(s)
end

--- Overwrite bytes of s starting at 1-based offset i.
local function patch(s, i, bytes)
  return s:sub(1, i - 1) .. bytes .. s:sub(i + #bytes)
end

---------------------------------------------------------------------------
T.section("inflate reproduces what zlib compressed")
---------------------------------------------------------------------------

local far = {}
for i = 32, 95 do
  far[#far + 1] = string.char(i)
end
local farEdge = table.concat(far)

local streams = {
  { "a fixed Huffman block", "y0jNyclXyECQOgopRZllqUV6Fbk5AA==", "hello hello hello, driver.xml" },
  {
    "a dynamic Huffman block",
    "dZFfa8MgFMXf8ymkHyCaUAYZzjLWPQxa2Nseg4u3rcw/xZjSfvuqMVnXsiflnN+9Ho50ddYKncD10pqXRVWSxYoVVMBJdiC456xAiHb2eHFyf/DsbbqhmtRP6P3M9VEB2vDvnuJfLA054N46dsdkNRKam2HHOz84uMf+WJE1XMPMrFM8ipOYNlkB6sEe1TkLCEYaXC9xik6aZ0LQ6zZHCmZeJHfyP3J2I5pLY5GpCKkonpSxMuOdVUwNvN2DieWMwo2pwR+sYB+fs5uVyAgnwz62TseXdT+hlayloNJIPejW9u307LJsmpKElI9WEWZvvvQK",
    F.PACKAGED_DRIVER_XML,
  },
  { "a stored block", "ARoA5f9zdG9yZWQgYmxvY2ssIGNvcGllZCBhcyBpcw==", "stored block, copied as is" },
  {
    "blocks split by a full flush",
    "srGvyM1RKEstKs7Mz7NVMtQzULK347JJSS3LTE5NSSxJtONSULBJzi+oLMpMzyixc4axFIwMjMwUXCsScwtyUhV8EpOKbfQRysCailITS/KL7NDUQEVBKnIT80rTEpNLSotS0ZWhSIHU5iXmpsLVuICdZ6MPFgSbBAAAAP//dZBBCsIwEEX3PUVO0ExLESIhINSFC8GdyxKaUYNNImlaPL5JaIsgrgLv/ckfxikcxPEtzWtA0uKse+TUuEQLQnjvUQZUAhitG1pDvSPA9gDkcOZ0lSkYR/RN/0tuNkVn9KN2VqRMBVBxupLc6GzwbhDDJLs72tiygC9pMDycEqfLZheSMsrr+J9o83N1/jlyurC8qLbaTKZzY7fWNiVjJcQtf1URZ/NRlAxSFB8=",
    F.PACKAGED_DRIVER_XML,
  },
  { "a copy that overlaps its own output", "S0wcBcQCAA==", string.rep("a", 300) },
  { "an empty stream", "AwA=", "" },
  {
    "a match 30 KiB back",
    "7d3FQQIAAABARqFBUgGlW2mQ7th/C4aA590iFwyFI9FYPJH8SKUz2Vz+86tQLH3/lCvVWr3RbLU73V7/928wHI0n09l88b9crTfb3f5wPJ0v19v9EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAeJPgi9/qEw==",
    farEdge .. string.rep("\0", 30000) .. farEdge,
  },
}

for _, case in ipairs(streams) do
  local got, err = zip.inflate(b64(case[2]))
  T.check(case[1], got == case[3], err or string.format("got %d bytes, want %d", got and #got or -1, #case[3]))
end

---------------------------------------------------------------------------
T.section("damaged deflate data is an error, never a raise or a hang")
---------------------------------------------------------------------------

local dynamicStream = b64(streams[2][2])
local raised, accepted = 0, 0
for cut = 0, #dynamicStream - 1 do
  local ok, got, err = pcall(zip.inflate, dynamicStream:sub(1, cut))
  if not ok then
    raised = raised + 1
  elseif got ~= nil or err == nil then
    accepted = accepted + 1
  end
end
T.eq("no truncation raises", raised, 0)
T.eq("every truncation is reported as an error", accepted, 0)

raised = 0
for i = 1, #dynamicStream do
  local ok = pcall(zip.inflate, patch(dynamicStream, i, string.char((dynamicStream:byte(i) + 97) % 256)))
  if not ok then
    raised = raised + 1
  end
end
T.eq("no corrupted byte raises", raised, 0)

local _, badType = zip.inflate("\7")
T.contains("block type 3 is rejected", badType, "invalid block type")
local _, badStored = zip.inflate("\1\5\0\0\0hello")
T.contains("a stored length that fails its complement is rejected", badStored, "complement")

---------------------------------------------------------------------------
T.section("reading from an archive the packager wrote")
---------------------------------------------------------------------------

local packaged = F.packagedC4z()
T.eq("driver.xml, the first entry, deflated", zip.read(packaged, "driver.xml"), F.PACKAGED_DRIVER_XML)
T.eq("driver.lua, a later entry", zip.read(packaged, "driver.lua"), string.rep("-- driver\n", 20))
T.eq("a file in a subdirectory", zip.read(packaged, "www/documentation/index.html"), "<html></html>")

local missing, missingErr = zip.read(packaged, "driver.json")
T.eq("a file the archive lacks is nil", missing, nil)
T.contains("and says so", missingErr, "driver.json is not in the archive")

---------------------------------------------------------------------------
T.section("reading stored entries")
---------------------------------------------------------------------------

local stored = F.zip({ { "a.txt", "first" }, { "driver.xml", "<devicedata/>" } })
T.eq("a stored entry is returned as is", zip.read(stored, "driver.xml"), "<devicedata/>")

-- A comment follows the end record; one that contains the record's signature must not be mistaken for it.
local comment = "PK\5\6 not the end record"
local commented = patch(stored, #stored - 1, string.char(#comment, 0)) .. comment
T.eq("an archive with a comment", zip.read(commented, "driver.xml"), "<devicedata/>")

---------------------------------------------------------------------------
T.section("archives that cannot be read")
---------------------------------------------------------------------------

local function readError(archive)
  local ok, got, err = pcall(zip.read, archive, "driver.xml")
  if not ok then
    return "raised: " .. tostring(got)
  end
  return got == nil and err or "read succeeded"
end

T.contains("not an archive", readError("<html>rate limited</html>"), "not a zip archive")
T.contains("not a string", readError(nil), "not a zip archive")
T.contains("an empty body", readError(""), "not a zip archive")
T.contains("a download cut short", readError(packaged:sub(1, #packaged - 40)), "not a zip archive")

-- stored = local header (30) + "a.txt" + "first", then the second; the central directory follows.
local centralStart = #stored - 22 - (46 + #"a.txt") - (46 + #"driver.xml") + 1
local driverEntry = centralStart + 46 + #"a.txt"
T.contains("an encrypted entry", readError(patch(stored, driverEntry + 8, "\1\0")), "encrypted")
T.contains("an unknown compression method", readError(patch(stored, driverEntry + 10, "\14\0")), "method 14")
T.contains("a size that does not match", readError(patch(stored, driverEntry + 24, "\99\0\0\0")), "expected 99")
T.contains("a local header offset that misses", readError(patch(stored, driverEntry + 42, "\1\0\0\0")), "local header")
T.contains("a corrupt central directory", readError(patch(stored, centralStart, "XXXX")), "central directory")

local allTruncations = 0
for cut = 0, #packaged - 1 do
  local ok = pcall(zip.read, packaged:sub(1, cut), "driver.xml")
  if not ok then
    allTruncations = allTruncations + 1
  end
end
T.eq("no truncation of the packaged archive raises", allTruncations, 0)

T.finish()
