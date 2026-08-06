-- Tests for the credential redaction in src/lib/http.lua.
--
-- Run from the template root:
--   LUA_PATH="$PWD/src/?.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" luajit test/test_http_redact.lua

local pass, fail = 0, 0
local function check(name, ok, detail)
  if ok then
    pass = pass + 1
    print(string.format("  ok   %s", name))
  else
    fail = fail + 1
    print(string.format("  FAIL %s%s", name, detail and ("  -> " .. tostring(detail)) or ""))
  end
end

-- Minimal C4 surface required to load lib.logging / lib.http.
C4 = {}
function C4:ErrorLog() end
function C4:DebugLog() end
function C4:GetDeviceID()
  return 1
end
function C4:GetDeviceData()
  return ""
end
function C4:AllowExecute() end
function InRange(v)
  return v
end
function IsEmpty(v)
  return v == nil or v == ""
end
function urlDo() end

local JSON = require("JSON")
local Http = require("lib.http")

local redact = Http._redact
local isSensitiveKey = Http._isSensitiveKey

local REDACTED = "***REDACTED***"

--- Encode the way lib.logging does, so assertions look at real log output.
local function encoded(value)
  local ok, out = pcall(function()
    return JSON:encode(value)
  end)
  return ok and out or ("<encode error: " .. tostring(out) .. ">")
end

local function contains(haystack, needle)
  return tostring(haystack):find(needle, 1, true) ~= nil
end

--------------------------------------------------------------------------------
print("\n[1] Credential keys are masked")
--------------------------------------------------------------------------------
do
  local out = encoded(redact({
    email = "user@example.com",
    password = "hunter2",
    client_secret = "sh-abc",
    ["X-Api-Key"] = "key-123",
    ["Authorization"] = "Bearer abc.def.ghi",
    ["Set-Cookie"] = "session=xyz",
    access_token = "tok_live_1",
    ["X-HatchBaby-Auth"] = "member-token",
    ["X-Amz-Signature"] = "deadbeef",
  }))
  check("password masked", not contains(out, "hunter2"), out)
  check("client_secret masked", not contains(out, "sh-abc"), out)
  check("X-Api-Key masked", not contains(out, "key-123"), out)
  check("Authorization masked", not contains(out, "Bearer abc"), out)
  check("Set-Cookie masked", not contains(out, "session=xyz"), out)
  check("access_token masked", not contains(out, "tok_live_1"), out)
  check("X-HatchBaby-Auth masked", not contains(out, "member-token"), out)
  check("X-Amz-Signature masked", not contains(out, "deadbeef"), out)
  check("non-secret email preserved", contains(out, "user@example.com"), out)
end

--------------------------------------------------------------------------------
print("\n[2] Generic fragments do not over-match (review item 4)")
--------------------------------------------------------------------------------
do
  check("AuthFlow is not sensitive", not isSensitiveKey("AuthFlow"))
  check("AuthParameters is not sensitive", not isSensitiveKey("AuthParameters"))
  check("author is not sensitive", not isSensitiveKey("author"))
  check("tokenizer is not sensitive", not isSensitiveKey("tokenizer"))
  check("Authorization IS sensitive", isSensitiveKey("Authorization"))
  check("X-HatchBaby-Auth IS sensitive", isSensitiveKey("X-HatchBaby-Auth"))
  check("access_token IS sensitive", isSensitiveKey("access_token"))

  -- The real Cognito shape: the diagnostic values stay readable, the secret does not.
  local out = encoded(redact({
    AuthFlow = "USER_PASSWORD_AUTH",
    AuthParameters = { USERNAME = "user@example.com", PASSWORD = "hunter2" },
    ClientId = "abc123",
  }))
  check("AuthFlow value readable", contains(out, "USER_PASSWORD_AUTH"), out)
  check("USERNAME under sensitive parent preserved", contains(out, "user@example.com"), out)
  check("PASSWORD under sensitive parent masked", not contains(out, "hunter2"), out)
  check("ClientId preserved", contains(out, "abc123"), out)
end

--------------------------------------------------------------------------------
print("\n[3] Bare JWTs are caught regardless of key (Cognito Logins map)")
--------------------------------------------------------------------------------
do
  local jwt = "eyJhbGciOiJIUzI1NiJ9." .. string.rep("a", 48) .. ".sig_value_here"
  local out = encoded(redact({ Logins = { ["cognito-identity.amazonaws.com"] = jwt } }))
  check("JWT under an innocuous key masked", not contains(out, jwt), out)

  local short = "abc.def.ghi"
  check("short dotted value left alone", redact(short) == short, redact(short))
end

--------------------------------------------------------------------------------
print("\n[4] Serialized bodies, query strings and URLs")
--------------------------------------------------------------------------------
do
  local body = '{"email":"user@example.com","password":"hunter2"}'
  local out = redact(body)
  check("JSON body password masked", not contains(out, "hunter2"), out)
  check("JSON body email preserved", contains(out, "user@example.com"), out)

  local form = "username=alice&password=hunter2&remember=1"
  out = redact(form)
  check("form password masked", not contains(out, "hunter2"), out)
  check("form username preserved", contains(out, "alice"), out)

  local url = "https://example.com/api?user=alice&access_token=tok_live_1"
  out = redact(url)
  check("URL query token masked", not contains(out, "tok_live_1"), out)
  check("URL path preserved", contains(out, "example.com/api"), out)
end

--------------------------------------------------------------------------------
print("\n[5] Guards fail closed (review items 2 and 3)")
--------------------------------------------------------------------------------
do
  -- Secret buried below the depth cap must not print.
  local deep = { access_token = "tok_live_DEEP", password = "hunter2" }
  for _ = 1, 12 do
    deep = { lvl = deep }
  end
  local out = encoded(redact(deep))
  check("secret past depth cap not leaked", not contains(out, "tok_live_DEEP"), out)
  check("password past depth cap not leaked", not contains(out, "hunter2"), out)
  check("depth cap emits marker", contains(out, REDACTED), out)

  -- A cyclic table must neither leak nor throw in the encoder.
  local cyclic = { name = "root", password = "hunter2" }
  cyclic.self = cyclic
  local encodedCyclic = encoded(redact(cyclic))
  check("cyclic table does not throw", not contains(encodedCyclic, "encode error"), encodedCyclic)
  check("cyclic table password masked", not contains(encodedCyclic, "hunter2"), encodedCyclic)
end

--------------------------------------------------------------------------------
print("\n[6] Caller's tables are never mutated")
--------------------------------------------------------------------------------
do
  local original = { password = "hunter2", nested = { token = "t1" } }
  redact(original)
  check("top-level value untouched", original.password == "hunter2", original.password)
  check("nested value untouched", original.nested.token == "t1", original.nested.token)
end

--------------------------------------------------------------------------------
print("\n[7] Non-table, non-string values pass through")
--------------------------------------------------------------------------------
do
  check("nil passes through", redact(nil) == nil)
  check("number passes through", redact(42) == 42)
  check("boolean passes through", redact(true) == true)
end

print(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
