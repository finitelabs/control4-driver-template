-- The shim's C4:Base64Decode and C4:Base64Encode against a 4.3.0 controller (4.2.1 decodes the
-- same). lib/persist.lua relies on the controller's exact decoder, not a lenient one.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_shim_base64.lua

local T = require("testlib")

require("c4_shim")

local function hex(s)
  return (s:gsub("..", function(x)
    return string.char(tonumber(x, 16))
  end))
end

-- The input, quoted, with every control or high byte as a decimal escape.
local function label(input)
  if #input > 40 then
    return #input .. " bytes"
  end
  return '"' .. input:gsub("[%z\1-\31\127-\255]", function(c)
    return "\\" .. c:byte()
  end) .. '"'
end

local function decodes(cases)
  for _, case in ipairs(cases) do
    T.eq(label(case[1]), C4:Base64Decode(case[1]), case[2])
  end
end

T.section("a group with a character outside the alphabet fails the whole decode")
decodes({
  { "abc!", "" },
  { "Living Room", "" },
  { "a-b_c", "" },
  { "12.5", "" },
  { "on off", "" },
  { "MT Iz", "" },
  { "TWFu\tTWFu", "" },
  { "MTIz!!!!", "" },
  { "- MTIz", "" },
  { "MTIz\rMTIz", "" },
  { "MTIz\vMTIz", "" },
  { "MTIz\fMTIz", "" },
  { " M T I z ", "" },
})

T.section("whole groups decode; a partial group and anything after it are dropped")
decodes({
  { "hello", hex("85e965") },
  { "true", hex("b6bb9e") },
  { "66568", hex("ebae7a") },
  { "65537:1", hex("eb9e77") },
  { "MTIz", "123" },
  { "MTI", "" },
  { "MT", "" },
  { "M", "" },
  { "N/A", "" },
  { "\255\254", "" },
  { "YQ", "" },
  { "YWI", "" },
  { "YWJj", "abc" },
  { "Zm9vYmFy", "foobar" },
  { "aGVsbG8gd29ybGQ", "hello wor" },
  { "MTIz!", "123" },
  { "MTIz-", "123" },
  { "MTIzMTIz!", "123123" },
  { "MTIz=", "123" },
  { "MTIz==", "123" },
  { "-_", "" },
  { "A==", "" },
  { "==", "" },
})

T.section("= is zero bits anywhere; only the last group's padding shortens the output")
decodes({
  { "MTI=", "12" },
  { "MT==", "1" },
  { "M===", "0" },
  { "YR==", "a" },
  { "aGVsbG8gd29ybGQ=", "hello world" },
  { "=MTIz", hex("00c4c8") },
  { "Zm9v=YmFy", hex("666f6f018985") },
  { "MTIzM===", "1230" },
  { "MTIzMTI=MTIz", hex("313233313200313233") },
  { "AAAA=", hex("000000") },
  { "A===", hex("00") },
  { "====", hex("00") },
  { "IkxpdmluZyBSb29tIg==", '"Living Room"' },
  { "dHJ1ZQ==", "true" },
})

T.section("the input is cut at its first NUL and trimmed of whitespace")
decodes({
  { "", "" },
  { " ", "" },
  { "\n", "" },
  { "abcd\0efg", hex("69b71d") },
  { "YWJj\0", "abc" },
  { " MTIz", "123" },
  { "  MTIz", "123" },
  { "\tMTIz", "123" },
  { "\nMTIz", "123" },
  { "\vMTIz", "123" },
  { "\fMTIz", "123" },
  { "\rMTIz", "123" },
  { "MTIz ", "123" },
  { "MTIz   ", "123" },
  { "MTIz\t", "123" },
  { "MTIz\v", "123" },
  { "MTIz\f", "123" },
  { "MTIz\n", "123" },
  { "MTIz\r\n", "123" },
  { "MTIzMT  ", "123" },
  { "MTIzMT\t\t", "123" },
  { " MTIzMTIz ", "123123" },
  { "MTIzMTIz\n", "123123" },
  { "\t \n MTIz \n\t", "123" },
  { "MTIzMw\n\n", "123" },
  { "MTIzM\n", "123" },
  { "Mw\n", "" },
  { "MTI=\n", "12" },
  { "M-TIz\n", "" },
})

T.section("a newline inside the input switches to line-by-line decoding")
decodes({
  { "MTIz\nMTIz", "123123" },
  { "MTIz\nMTIzMTIz", "123123123" },
  { "MTIz\n\n\nMTIz", "123123" },
  { "MTIz\r\nMTIz", "123123" },
  { "MTIz \nMTIz", "123123" },
  { "MTIz\n MTIz", "123123" },
  { "MT\nIz", "123" },
  { "M\nT\nI\nz", "123" },
  { "MTI\n=", "12" },
  { "MT\n==", "1" },
  { "MTIz\nMTI=", "12312" },
  { "MTIz\nMT==\n", "1231" },
  { "MTIz\n-", "123" },
  { "MTIz\nMTI", "" },
  { "MTIz\n!", "" },
  { "MTI=\nMTIz", "" },
  { "\nM T", "" },
  { "\n-MTIz", "" },
  { "-\nMTIz\n", "" },
  { "!!!!\nMTIz", "" },
  { "!!!!\nMTIz\n", "" },
  { "12.5\nMTIz", "" },
  { "Living Room\nMTIz", "" },
  { "MTIz\nLiving Room", "" },
  { "a\nb", "" },
})

T.section("long input is read 1024 bytes at a time")
local R = string.rep
decodes({
  { R("QUJD", 256) .. "!!!!", R("ABC", 256) },
  { R("QUJD", 300) .. "!", R("ABC", 300) },
  { "!!!!" .. R("QUJD", 256), "" },
  { R("QUJD", 255) .. "QUJ=QUJD", R("ABC", 255) .. "ABABC" },
  { R("QUJD", 10) .. "\n" .. R("QUJD", 300), R("ABC", 310) },
  { R("QUJD", 300) .. "\nQUJD", "" },
})

-- Compared by the output's length and a rolling hash of its bytes.
local function digest(s)
  local h = 0
  for k = 1, #s do
    h = (h * 31 + s:byte(k)) % 1000000007
  end
  return { #s, h }
end
for _, case in ipairs({
  { R("QUJD", 256) .. "!!!!" .. R("QUJD", 256), 768, 592210142 },
  { R("QUJD", 10) .. "\n" .. R("QUJD", 300) .. "!" .. R("QUJD", 300), 720, 257331668 },
  { R("QUJD", 300) .. "\n" .. R("QUJD", 10) .. "\n", 0, 0 },
  { R("QUJD", 200) .. "\n" .. R("QUJD", 300), 1500, 88550768 },
  { R("QUJD\n", 300), 900, 433549310 },
  { R("QUJD", 300) .. "-" .. R("QUJD", 300), 768, 592210142 },
  { R("QUJD", 10) .. "\n" .. R("QUJD", 300) .. "-" .. R("QUJD", 300), 930, 357729827 },
  { R("QUJD", 255) .. "QUJ" .. "\n" .. R("QUJD", 10), 768, 592210155 },
  { R("QU JD", 300), 0, 0 },
  { R("QUJD", 256) .. " " .. R("QUJD", 256), 768, 592210142 },
  { "!!!!\n" .. R("QUJD", 300) .. "\n" .. R("QUJD", 5), 0, 0 },
  { R("Q", 1023) .. "\n" .. R("QUJD", 5), 768, 103925729 },
  { R("QUJD", 400) .. "=" .. R("QUJD", 10), 1230, 172576963 },
}) do
  T.eq(label(case[1]), digest(C4:Base64Decode(case[1])), { case[2], case[3] })
end

T.section("a number decodes as its text; anything else raises")
T.eq("12345", C4:Base64Decode(12345), hex("d76df8"))
T.raises("nil", function()
  C4:Base64Decode(nil)
end, "strDecode should be a string")

T.section("C4:Base64Encode keeps every byte and adds no line breaks")
T.eq("empty", C4:Base64Encode(""), "")
T.eq("a NUL", C4:Base64Encode("a\0b"), "YQBi")
T.eq("high bytes", C4:Base64Encode("\255\128"), "/4A=")
local long = C4:Base64Encode(R("abc", 400))
T.eq("1200 bytes make 1600 characters", #long, 1600)
T.falsy("with no newline", long:find("\n", 1, true))

T.finish()
