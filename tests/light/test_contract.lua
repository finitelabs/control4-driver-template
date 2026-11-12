local T = require("testlib")
local Types = require("lib.light.types")

local CONTRACT = { api = 1, hash = 795440677 }

--- @return string
local function source()
  local path = assert(package.searchpath("lib.light.types", package.path))
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

--- A 31-bit polynomial hash, which every Lua the template tests on computes alike.
--- @param text string
--- @return integer
local function hash(text)
  local h = 0
  for i = 1, #text do
    h = (h * 31 + text:byte(i)) % 2147483647
  end
  return h
end

local text = source()
local cut = text:find("\n%-+\n%-%- The library's own shapes")
T.check("types.lua marks where the library's own shapes begin", cut ~= nil)
T.eq("the contract's version", Types.API, CONTRACT.api)
T.eq("the contract's text, as pinned", hash(text:sub(1, cut or #text)), CONTRACT.hash)
T.finish()
