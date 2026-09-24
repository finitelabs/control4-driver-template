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

T.section("a read under the other encrypted flag returns ciphertext, not nil")
C4:PersistSetValue("Secret", "secret", true)
local plain = C4:PersistGetValue("Secret", false)
T.neq("an encrypted value read plain", plain, "secret")
T.eq("is base64 as long as the value's", #plain, #C4:Base64Encode("secret"))
T.eq("and the encrypted read still has it", C4:PersistGetValue("Secret", true), "secret")
C4:PersistSetValue("Plain", "plain", false)
local deciphered = C4:PersistGetValue("Plain", true)
T.neq("a plain value read encrypted", deciphered, "plain")
T.eq("is the value base64-decoded, then deciphered", #deciphered, #C4:Base64Decode("plain"))

T.finish()
