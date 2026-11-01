-- Run in a template render, with the LUA_PATH `make test` sets: the shim's FFI crypto backend loads.
-- test_c4_shim.lua skips its crypto assertions when no FFI backend loads, so on a machine without one
-- `make test` would go green having tested nothing. The template is where that mock is developed, so
-- its CI requires the backend; driver repos keep the skip.
require("c4_shim")
if not C4.SHIM_HAS_CRYPTO then
  io.stderr:write("no FFI crypto backend: the c4_shim crypto assertions would have skipped\n")
  os.exit(1)
end
print("FFI crypto backend resolved")
