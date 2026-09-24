-- lib/persist.lua stores every value as base64 of its JSON, so a plain string, a
-- number or a boolean reads back as itself after a driver update, and still reads
-- what earlier builds stored.
--
-- Every shipped build (template v0.1.0 to v0.9.29, and the esphome and mqtt copies
-- before the template) wrote PersistSetValue(key, Serialize(value), encrypted): a
-- table as base64 of its JSON, anything else raw. C4:Base64Decode returns "" for a raw
-- string with a space, comma, dot or dash, and JSON:decode("") returns nil, so their
-- Deserialize read such a string as nil and the caller got its default.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_persist_plain_values.lua

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.lib") -- Serialize, Deserialize, JSON
local log = require("lib.logging")

local errors = {}
function log:error(text, ...)
  table.insert(errors, string.format(text, ...))
end

-- A fresh instance stands in for a driver update: nothing cached, the same storage.
local function reload()
  return getmetatable(require("lib.persist")):new()
end

-- What every shipped build did on a set, and on a get.
local function legacySet(key, value, encrypted)
  PersistSetValue(key, Serialize(value), encrypted)
end
local function legacyGet(key, encrypted)
  return Deserialize(PersistGetValue(key, encrypted))
end

local function encoded(value)
  return C4:Base64Encode(JSON:encode(value))
end

-- A value for a test name: a string quoted with its control and high bytes escaped, a
-- number in full.
local function label(value)
  if type(value) == "number" then
    return string.format("%.17g", value)
  elseif type(value) ~= "string" then
    return T.show(value)
  end
  return '"' .. value:gsub("[%z\1-\31\127-\255]", function(c)
    return "\\" .. c:byte()
  end) .. '"'
end

-- The strings measured on a controller; `lost` is what a shipped build read back.
local STRINGS = {
  { "65542,67330,68356", lost = true },
  { "Living Room", lost = true },
  { "abc!", lost = true },
  { "a-b_c", lost = true },
  { "12.5", lost = true },
  { "", lost = true },
  { "N/A", lost = true },
  { "on off", lost = true },
  { "65537:1" },
  { "66568" },
  { "hello" },
  { "true" },
}

-- Each with the JSON it is stored as.
local SCALARS = {
  { 12.5, "12.5" },
  { 66568, "66568" },
  { 0, "0" },
  { -3, "-3" },
  { 100, "100" },
  { 1e300, "1e+300" },
  { math.huge, "1e+9999" },
  { -math.huge, "-1e+9999" },
  { true, "true" },
  { false, "false" },
  -- JSON:encode would keep 14 significant digits of these.
  { 187723572702975, "187723572702975" },
  { 2 ^ 53, "9007199254740992" },
  { 1727190000123456, "1727190000123456" },
  { 0.1 + 0.2, "0.30000000000000004" },
  { math.pi, "3.141592653589793" },
}

-- ── What this build writes ───────────────────────────────────────────────────

T.section("every example string survives a reload")
local p = reload()
for i, case in ipairs(STRINGS) do
  p:set("S" .. i, case[1])
end
local q = reload()
for i, case in ipairs(STRINGS) do
  T.eq(label(case[1]), q:get("S" .. i, "<default>"), case[1])
  T.eq("  stored as base64 of its JSON", C4:PersistGetValue("S" .. i, false), encoded(case[1]))
end

T.section("numbers and booleans keep their type and every digit")
for i, case in ipairs(SCALARS) do
  p:set("N" .. i, case[1])
end
q = reload()
for i, case in ipairs(SCALARS) do
  local got = q:get("N" .. i, "<default>")
  T.check(label(case[1]), got == case[1], "got " .. label(got))
  T.eq("  as a " .. type(case[1]), type(got), type(case[1]))
  T.eq("  stored as base64 of " .. case[2], C4:PersistGetValue("N" .. i, false), C4:Base64Encode(case[2]))
end

T.section("a number is written with a period where the locale writes a comma")
-- What a comma locale does to these, as global.lib's tonumber_expect_comma reads it.
local format, tonumberNative = string.format, tonumber
string.format = function(fmt, ...)
  local text = format(fmt, ...)
  return fmt:find("^%%%.%d+g$") and (text:gsub("%.", ",")) or text
end
tonumber = function(text, base)
  return tonumberNative(type(text) == "string" and (text:gsub(",", ".")) or text, base)
end
p:set("Comma1", 12.5)
p:set("Comma2", 0.1 + 0.2)
string.format, tonumber = format, tonumberNative
T.eq("12.5", C4:PersistGetValue("Comma1", false), C4:Base64Encode("12.5"))
T.eq("0.1 + 0.2", C4:PersistGetValue("Comma2", false), C4:Base64Encode("0.30000000000000004"))
T.check("  which reads back", reload():get("Comma2") == 0.1 + 0.2)

T.section("a table is stored exactly as Serialize writes it")
local tbl = { name = "Living Room", ids = { 65542, 67330 }, on = true }
p:set("Tbl", tbl)
T.eq("the same bytes", C4:PersistGetValue("Tbl", false), Serialize(tbl))
T.eq("and it reads back", reload():get("Tbl"), tbl)

T.section("an encrypted value reads back under its flag")
local SECRETS = { "Living Room", "", 42, false, { code = "1 2 3" } }
for i, value in ipairs(SECRETS) do
  p:set("E" .. i, value, true)
end
q = reload()
for i, value in ipairs(SECRETS) do
  T.eq(label(value), q:get("E" .. i, "<default>", true), value)
  T.eq("  stored encrypted", Deserialize(C4:PersistGetValue("E" .. i, true)), value)
end

T.section("text that JSON escapes reads back byte for byte")
for i, value in ipairs({ "a\0b", "tab\there\nnewline", 'quote " and \\ slash /', "Zürich ☕", "\127" }) do
  p:set("U" .. i, value)
  T.eq(label(value), reload():get("U" .. i), value)
end

T.section("a shipped build reads every value this build writes")
for i, case in ipairs(STRINGS) do
  T.eq(label(case[1]), legacyGet("S" .. i, false), case[1])
end
for i, case in ipairs(SCALARS) do
  local got = legacyGet("N" .. i, false)
  T.check(label(case[1]), got == case[1], "got " .. label(got))
end
T.eq("the table", legacyGet("Tbl", false), tbl)
T.eq("an encrypted string", legacyGet("E1", true), "Living Room")

-- ── What shipped builds wrote ────────────────────────────────────────────────

T.section("an older build's raw strings read back, where it lost most of them")
for i, case in ipairs(STRINGS) do
  legacySet("L" .. i, case[1], false)
end
q = reload()
for i, case in ipairs(STRINGS) do
  if case[1] == "" then
    -- The controller stores nothing for an empty string, so there is nothing to read.
    T.eq('""', q:get("L" .. i, "<default>"), "<default>")
  else
    T.eq(label(case[1]), q:get("L" .. i, "<default>"), case[1])
  end
  T.eq("  where a shipped build read", legacyGet("L" .. i, false), (not case.lost) and case[1] or nil)
end

T.section("an older build's numbers, booleans, tables and encrypted strings read back")
for i, case in ipairs(SCALARS) do
  legacySet("LN" .. i, case[1], false)
end
legacySet("LTbl", tbl, false)
legacySet("LEnc", "Living Room", true)
q = reload()
for i, case in ipairs(SCALARS) do
  local got = q:get("LN" .. i, "<default>")
  T.check(label(case[1]), got == case[1], "got " .. label(got))
end
T.eq("a table", q:get("LTbl"), tbl)
T.eq("an encrypted string", q:get("LEnc", nil, true), "Living Room")

T.section("an older build's NaN reads as the default, as it did")
-- Measured on 4.3.0: Director hands back a NaN stored raw as this text.
PersistSetValue("LNan", '{":number:":null}', false)
T.eq("the default", reload():get("LNan", "<default>"), "<default>")
T.eq("  where a shipped build read nothing", legacyGet("LNan", false), nil)

T.section("an older build's raw string in which Deserialize finds base64 of JSON reads as that JSON, as it always did")
for _, case in ipairs({
  { "MTIz", 123 },
  { "dHJ1ZQ==", true },
  { "ZmFsc2U=", false },
  { "e30=", {} },
  { "IkxpdmluZyBSb29tIg==", "Living Room" },
  -- C4:Base64Decode drops a trailing partial group, whatever it holds.
  { "MTIz!", 123 },
  { "MTIzYQ", 123 },
}) do
  PersistSetValue("LJ", case[1], false)
  T.eq(case[1], reload():get("LJ", "<default>"), case[2])
  T.eq("  the same as a shipped build", reload():get("LJ", "<default>"), legacyGet("LJ", false))
end
PersistSetValue("LJ", "bnVsbA==", false) -- base64 of JSON null
T.eq('"bnVsbA==" is the raw string, not the default a shipped build gave', reload():get("LJ", "<default>"), "bnVsbA==")

T.section("a read leaves an older build's value alone; the next set rewrites it")
legacySet("Old", "Living Room", false)
q = reload()
T.eq("it reads back", q:get("Old"), "Living Room")
T.eq("and storage still holds the raw string", C4:PersistGetValue("Old", false), "Living Room")
q:set("Old", "Kitchen")
T.eq("a set stores the new form", C4:PersistGetValue("Old", false), encoded("Kitchen"))

T.section("a read under the other encrypted flag does not overwrite the value")
p:set("Code", "1 2 3 4", true)
q = reload()
T.neq("read plain, it is the ciphertext", q:get("Code", "<default>", false), "1 2 3 4")
T.eq("which leaves storage alone", Deserialize(C4:PersistGetValue("Code", true)), "1 2 3 4")
T.eq("so an encrypted read still has it", reload():get("Code", nil, true), "1 2 3 4")

-- ── Values JSON cannot carry ─────────────────────────────────────────────────

T.section("a NaN or a string that is not UTF-8 is logged and not stored")
local NAN = 0 / 0
for _, case in ipairs({ { "Nan", NAN }, { "Bytes", "\255\254\1" }, { "Lone", "a\128b" }, { "Cut", "caf\195" } }) do
  errors = {}
  p:set(case[1], "earlier")
  p:set(case[1], case[2])
  T.eq(case[1] .. ": one error", #errors, 1)
  T.contains("  naming the key", errors[1], case[1])
  local here = p:get(case[1])
  T.check("  this load keeps the value", here == case[2] or (here ~= here and case[2] ~= case[2]))
  T.eq("  a reload reads the default, not the earlier value", reload():get(case[1], "<default>"), "<default>")
end

-- ── Write-behind ─────────────────────────────────────────────────────────────

T.section("a write-behind flush stores the same form")
p = reload()
p:setWriteBehind("Hot", 60000)
p:defer(p.set, p, "Hot", "Living Room")
p:flush()
T.eq("the flushed string reads back", reload():get("Hot"), "Living Room")
T.eq("stored as base64 of its JSON", C4:PersistGetValue("Hot", false), encoded("Living Room"))
p:defer(p.set, p, "Hot", 0 / 0)
errors = {}
p:flush()
T.eq("a NaN at the flush is logged", #errors, 1)
T.eq("and not stored", reload():get("Hot", "<default>"), "<default>")
ShimFireTimers()

T.finish()
