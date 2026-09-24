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
local _, shortStored = zip.inflate("\1\5\0\250\255hell")
T.contains("a stored block a byte shorter than its length is rejected", shortStored, "ends early")

---------------------------------------------------------------------------
T.section("malformed Huffman blocks are rejected")
---------------------------------------------------------------------------

--- Packs { n, value } fields into bytes least significant bit first, except Huffman codes
--- ({ n, code, huffman = true }), which deflate packs most significant bit first.
local function pack(fields)
  local bytes, acc, count = {}, 0, 0
  for _, field in ipairs(fields) do
    local n, value = field[1], field[2]
    for i = 0, n - 1 do
      acc = acc + math.floor(value / 2 ^ (field.huffman and n - 1 - i or i)) % 2 * 2 ^ count
      count = count + 1
      if count == 8 then
        bytes[#bytes + 1], acc, count = string.char(acc), 0, 0
      end
    end
  end
  if count > 0 then
    bytes[#bytes + 1] = string.char(acc)
  end
  return table.concat(bytes)
end

local function huffman(n, code)
  return { n, code, huffman = true }
end

-- Every block's code-length code: 0, 1 and 2 are 00, 01 and 10; the repeats 16 and 18 are 110 and 111.
local CODE_LENGTH_SYMBOLS = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }
local CODE_LENGTH_CODES = {
  [0] = huffman(2, 0),
  [1] = huffman(2, 1),
  [2] = huffman(2, 2),
  [16] = huffman(3, 6),
  [18] = huffman(3, 7),
}

--- The code-length symbols that spell `lengths` (0-indexed), with runs of 11+ zeros as symbol 18.
local function spell(lengths, total, noRepeat)
  local program, i = {}, 0
  while i < total do
    local run = 0
    while not noRepeat and i + run < total and run < 138 and (lengths[i + run] or 0) == 0 do
      run = run + 1
    end
    if run >= 11 then
      table.insert(program, { 18, run - 11 })
      i = i + run
    else
      table.insert(program, { lengths[i] or 0 })
      i = i + 1
    end
  end
  return program
end

--- One final dynamic block: its code lengths spelled by `program`, then the `data` fields.
--- With noRepeat the code-length code leaves out 16 and 18, which makes it incomplete.
local function dynamicBlock(nlen, ndist, program, data, noRepeat)
  local fields = { { 1, 1 }, { 2, 2 }, { 5, nlen - 257 }, { 5, ndist - 1 }, { 4, 18 - 4 } }
  for i = 1, 18 do
    local symbol = CODE_LENGTH_SYMBOLS[i]
    local code = CODE_LENGTH_CODES[symbol]
    local omitted = code == nil or (noRepeat and symbol >= 16)
    table.insert(fields, { 3, omitted and 0 or code[1] })
  end
  for _, step in ipairs(program) do
    table.insert(fields, CODE_LENGTH_CODES[step[1]])
    if step[1] == 16 then
      table.insert(fields, { 2, step[2] })
    elseif step[1] == 18 then
      table.insert(fields, { 7, step[2] })
    end
  end
  for _, field in ipairs(data) do
    table.insert(fields, field)
  end
  return pack(fields)
end

-- 'a' is 0, end-of-block 10, length 3 is 11 and distance 1 is the lone one-bit code 0.
local LITERALS = { [97] = 1, [256] = 2, [257] = 2 }
local A, EOB, LENGTH_3, DISTANCE_1 = huffman(1, 0), huffman(2, 2), huffman(2, 3), huffman(1, 0)
local AAAA = { A, LENGTH_3, DISTANCE_1, EOB }

--- Literal/length code lengths `literals`, then distance 1 at one bit, spelled out.
local function lengthsProgram(literals, nlen, ndist, noRepeat)
  local lengths = { [nlen] = 1 }
  for symbol, n in pairs(literals) do
    lengths[symbol] = n
  end
  return spell(lengths, nlen + ndist, noRepeat)
end

local function block(literals, nlen, ndist, data)
  return dynamicBlock(nlen, ndist, lengthsProgram(literals, nlen, ndist), data)
end

local function inflateError(src)
  local ok, got, err = pcall(zip.inflate, src)
  if not ok then
    return "raised: " .. tostring(got)
  end
  return got == nil and err or "inflated " .. got
end

T.eq("the well-formed block the cases below vary", zip.inflate(block(LITERALS, 258, 1, AAAA)), "aaaa")

T.contains(
  "a copy from before the start",
  inflateError(block(LITERALS, 258, 1, { LENGTH_3, DISTANCE_1, EOB })),
  "distance reaches before the start"
)
T.contains(
  "no end-of-block code",
  inflateError(block({ [97] = 1, [257] = 2, [258] = 2 }, 259, 1, { A })),
  "no end-of-block code"
)
T.contains(
  "over-subscribed literal/length code lengths",
  inflateError(block({ [97] = 1, [256] = 1, [257] = 1 }, 258, 1, AAAA)),
  "invalid literal/length code lengths"
)
T.contains(
  "incomplete literal/length code lengths",
  inflateError(block({ [97] = 2, [256] = 2 }, 258, 1, { huffman(2, 0), huffman(2, 1) })),
  "invalid literal/length code lengths"
)
T.contains("287 literal/length codes", inflateError(block(LITERALS, 287, 1, AAAA)), "too many codes")
T.contains("31 distance codes", inflateError(block(LITERALS, 258, 31, AAAA)), "too many codes")

-- Eleven zeros end these distance lengths, spelled as one run of 11.
T.eq("a repeat that ends on the last code", zip.inflate(block(LITERALS, 258, 12, AAAA)), "aaaa")
-- Ten zeros end these; spelling them as a run of 11 overshoots by one.
local overrun = lengthsProgram(LITERALS, 258, 11)
for _ = 1, 10 do
  table.remove(overrun)
end
table.insert(overrun, { 18, 0 })
T.contains("a repeat past the last code", inflateError(dynamicBlock(258, 11, overrun, AAAA)), "too many code lengths")

local repeatFirst = lengthsProgram(LITERALS, 258, 1)
table.insert(repeatFirst, 1, { 16, 0 })
T.contains("a repeat before any length", inflateError(dynamicBlock(258, 1, repeatFirst, AAAA)), "no previous length")

T.contains(
  "an incomplete code-length code",
  inflateError(dynamicBlock(258, 1, lengthsProgram(LITERALS, 258, 1, true), AAAA, true)),
  "invalid code length code lengths"
)

-- Fixed codes 286 and 287 exist but name no length; 'a' is 10010001, 286 is 11000110.
local fixed286 = pack({ { 1, 1 }, { 2, 1 }, huffman(8, 0x91), huffman(8, 0xC6) })
T.contains("fixed length symbol 286", inflateError(fixed286), "invalid length symbol")

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
local longest = patch(stored, #stored - 1, "\255\255") .. string.rep("x", 65535)
T.eq("an archive with the longest comment", zip.read(longest, "driver.xml"), "<devicedata/>")

local entryComment = F.zip({ { "a.txt", "first", comment = "the first entry" }, { "driver.xml", "<devicedata/>" } })
T.eq("an entry after one with a comment", zip.read(entryComment, "driver.xml"), "<devicedata/>")

-- Info-ZIP's timestamp field holds two times in the local header and one in the central directory.
local LOCAL_UT, CENTRAL_UT = "UT\9\0\3" .. string.rep("\0", 8), "UT\5\0\3" .. string.rep("\0", 4)
local infoZip = F.zip({
  { "a.txt", "first", extra = LOCAL_UT, centralExtra = CENTRAL_UT },
  { "driver.xml", "<devicedata/>", extra = LOCAL_UT, centralExtra = CENTRAL_UT },
})
T.eq("entries whose local and central extra fields differ", zip.read(infoZip, "driver.xml"), "<devicedata/>")

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
T.contains("a compressed size past the end", readError(patch(stored, driverEntry + 20, "\255\255\0\0")), "ends early")
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
