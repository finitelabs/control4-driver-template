-- Every src/lib module of a template render loads. make test only loads the modules that call
-- a drivers-common-public global.
--
-- Run from the template repo:
--   make render-lib-loads NAME=<render>
-- or, in a render:
--   ./test/run_test.sh <template repo>/tests/lib_modules_load.lua

require("c4_shim")

-- The render's root, from the LUA_PATH test/run_test.sh sets.
local root = package.path:match("([^;]+)/src/%?%.lua")
assert(root, "LUA_PATH has no src/?.lua: run this with test/run_test.sh")

local failed = {}
local p = io.popen('cd "' .. root .. '/src/lib" && find . -name "*.lua" | sort')
for name in p:lines() do
  local mod = name:match("^%./(.*)%.lua$")
  if mod then
    mod = mod:gsub("/", ".")
    local ok, err = pcall(require, "lib." .. mod)
    if not ok then
      failed[#failed + 1] = mod .. ": " .. tostring(err)
    end
  end
end
p:close()
if #failed > 0 then
  io.stderr:write("modules that do not load:\n  " .. table.concat(failed, "\n  ") .. "\n")
  os.exit(1)
end
print("every src/lib module loads")
