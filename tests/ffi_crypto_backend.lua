-- The c4_shim of a template render resolves its FFI crypto backend. test_c4_shim.lua skips its
-- crypto assertions when no backend loads, so without one `make test` goes green having tested
-- nothing. The template is where that mock is developed, so its CI requires the backend; driver
-- repos keep the skip.
--
-- Run from the template repo:
--   make render-crypto NAME=<render>
-- or, in a render:
--   ./test/run_test.sh <template repo>/tests/ffi_crypto_backend.lua

require("c4_shim")

if not C4.SHIM_HAS_CRYPTO then
  io.stderr:write("no FFI crypto backend: the c4_shim crypto assertions would have skipped\n")
  os.exit(1)
end
print("FFI crypto backend resolved")
