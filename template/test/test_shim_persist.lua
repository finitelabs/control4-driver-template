-- The shim's C4:PersistSetValue and C4:PersistGetValue against what a 4.3.0
-- controller kept for the same writes.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_shim_persist.lua

local T = require("testlib")

require("c4_shim")

T.section("a number or boolean keeps its type")
C4:PersistSetValue("Num", 12.5, false)
C4:PersistSetValue("Big", 187723572702975, false)
C4:PersistSetValue("Bool", false, false)
T.eq("a number", C4:PersistGetValue("Num", false), 12.5)
T.eq("with every digit", C4:PersistGetValue("Big", false), 187723572702975)
T.eq("a boolean", C4:PersistGetValue("Bool", false), false)

T.section("a NaN comes back as text, and a number past the 64-bit range is clamped")
C4:PersistSetValue("Nan", 0 / 0, false)
C4:PersistSetValue("Huge", 1e300, false)
C4:PersistSetValue("Inf", math.huge, false)
C4:PersistSetValue("NegInf", -math.huge, false)
T.eq("a NaN", C4:PersistGetValue("Nan", false), '{":number:":null}')
T.eq("1e300", C4:PersistGetValue("Huge", false), 2 ^ 64)
T.eq("inf", C4:PersistGetValue("Inf", false), 2 ^ 64)
T.eq("-inf", C4:PersistGetValue("NegInf", false), -2 ^ 63)

T.section("a string is cut at its first NUL")
C4:PersistSetValue("Nul", "a\0b", false)
C4:PersistSetValue("LeadingNul", "\0abc", false)
T.eq('"a\\0b"', C4:PersistGetValue("Nul", false), "a")
T.eq('"\\0abc"', C4:PersistGetValue("LeadingNul", false), nil)

T.section("an empty string deletes a plain value and leaves an encrypted one")
C4:PersistSetValue("Empty", "", false)
T.eq("plain, on a new key", C4:PersistGetValue("Empty", false), nil)
C4:PersistSetValue("Over", "x", false)
C4:PersistSetValue("Over", "", false)
T.eq("plain, over a value", C4:PersistGetValue("Over", false), nil)
C4:PersistSetValue("EncEmpty", "", true)
T.eq("encrypted, on a new key", C4:PersistGetValue("EncEmpty", true), nil)
C4:PersistSetValue("EncOver", "y", true)
C4:PersistSetValue("EncOver", "", true)
T.eq("encrypted, over a value", C4:PersistGetValue("EncOver", true), "y")

T.section("a read under the other encrypted flag returns the value run through the cipher, or nothing")
local function hex(s)
  return (s:gsub("..", function(x)
    return string.char(tonumber(x, 16))
  end))
end
local A20 = string.rep("A", 20)
local A20_CIPHER = hex("016bbbc10d876bb33e1ffa6f91d167f390c21f70")
C4:PersistSetValue("Secret", A20, true)
C4:PersistSetValue("Zero", "0", true)
T.eq(
  "an encrypted value read plain is base64 of its ciphertext",
  C4:PersistGetValue("Secret", false),
  C4:Base64Encode(A20_CIPHER)
)
T.eq('  "0"', C4:PersistGetValue("Zero", false), "cA==")
T.eq("  and the encrypted read still has it", C4:PersistGetValue("Secret", true), A20)
for _, case in ipairs({
  { C4:Base64Encode(A20), A20_CIPHER },
  { C4:Base64Encode(string.rep("A", 40)), A20_CIPHER .. hex("5bae7d7fbf93c1c9206e6acfbc7c2e004f40d510") },
  { C4:Base64Encode("0"), "p" },
  { C4:Base64Encode("7"), "w" },
  { C4:Base64Encode('"123456"'), hex("621bc8b378f31cd0") },
  { C4:Base64Encode("@abc"), hex("004b98e3") },
  { "hello", hex("c5c39f") },
  { "123456", hex("974702") },
}) do
  C4:PersistSetValue("Plain", case[1], false)
  T.eq("a plain " .. case[1] .. " read encrypted", C4:PersistGetValue("Plain", true), case[2])
end
for _, value in ipairs({ "Living Room", "Den", "101", 42, true }) do
  C4:PersistSetValue("Plain", value, false)
  T.eq("a plain " .. tostring(value) .. " read encrypted is nothing", select("#", C4:PersistGetValue("Plain", true)), 0)
end

T.finish()
