-- Run in a template render, with the LUA_PATH `make test` sets: every src/lib module loads.
-- make test only loads the modules that call a drivers-common-public global.
require("c4_shim")
local failed = {}
local p = io.popen("ls src/lib")
for name in p:lines() do
  local mod = name:match("^(.*)%.lua$")
  if mod then
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
