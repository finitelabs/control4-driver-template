-- make light-caps: write each light_v2 driver's <capabilities> block from the profile its lib.light
-- adapter gives Light.new. The block is the library's: nothing in it is written by hand, and the
-- contract run (test/test_light_contract.lua) fails a driver.xml that differs from it.
--
-- Run from the repo root under the shim, as make light-caps does.

local D = require("light_drivers")

local root = D.root()
local lights = D.lights(root)
if #lights == 0 then
  print("No light_v2 driver under drivers/.")
  return
end

local failed = false
for _, folder in ipairs(lights) do
  local light, err = D.load(root, folder)
  local xml = D.xml(root, folder)
  local written
  if light and not xml then
    err = "no driver.xml"
  elseif light then
    written, err = D.written(xml, light)
  end
  if not written then
    io.stderr:write(string.format("drivers/%s: %s\n", folder, err))
    failed = true
  elseif written == xml then
    print(string.format("drivers/%s/driver.xml: up to date", folder))
  else
    local path = string.format("%s/drivers/%s/driver.xml", root, folder)
    local f = assert(io.open(path, "wb"))
    f:write(written)
    f:close()
    print(string.format("drivers/%s/driver.xml: capabilities written", folder))
  end
end
if failed then
  os.exit(1)
end
