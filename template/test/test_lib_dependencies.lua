-- Tests that src/lib modules pull in the modules defining the globals they call,
-- rather than relying on a driver's driver.lua to have required them first.
--
-- Run from the template root:
--   LUA_PATH="$PWD/test/?.lua;$PWD/src/?.lua;$PWD/vendor/?.lua;$PWD/vendor/?/init.lua;;" \
--     luajit -e "require('c4_shim')" test/test_lib_dependencies.lua
--
-- tools/gen-squishy.lua bundles from package.loaded, so a module nothing
-- requires is absent from the .c4z and fails as a nil-call in the field.

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

-- Deliberately no urlDo stub; requiring lib.http must be enough.
check("urlDo is not defined before lib.http is required", urlDo == nil, "a stub would void this test")

JSON = require("JSON")
require("lib.http")

check(
  "requiring lib.http loads drivers-common-public.global.url",
  package.loaded["drivers-common-public.global.url"] ~= nil,
  "url.lua is absent from package.loaded, so gen-squishy would omit it from the .c4z"
)
check(
  "urlDo is callable after requiring lib.http",
  type(urlDo) == "function",
  string.format("urlDo is %s; the first request would fail with a nil-call", type(urlDo))
)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  os.exit(1)
end
