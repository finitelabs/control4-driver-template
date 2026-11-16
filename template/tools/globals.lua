--- Print each global each Lua file reads or sets, as LuaJIT compiles it: one `<file>\t<GGET|GSET>\t<name>`
--- line per distinct pair, and `<file>\tERROR\t<message>` for a file that does not compile.
--- tools/globals.py compares a build's files with their source this way.

local util = require("jit.util")
local vmdef = require("jit.vmdef")
local bit = require("bit")

--- The bytecode op names, indexed by opcode.
local OPS = {}
for i = 0, #vmdef.bcnames / 6 - 1 do
  OPS[i] = vmdef.bcnames:sub(i * 6 + 1, i * 6 + 6):gsub(" +$", "")
end

--- @param fn function A compiled chunk or one of its child prototypes.
--- @param found table<string, true> Each `<op>\t<name>` seen so far.
local function walk(fn, found)
  local pc = 1
  while true do
    local ins = util.funcbc(fn, pc)
    if not ins then
      break
    end
    local op = OPS[bit.band(ins, 0xff)]
    local d = bit.rshift(ins, 16)
    if op == "GGET" or op == "GSET" then
      found[op .. "\t" .. util.funck(fn, -d - 1)] = true
    elseif op == "FNEW" then
      walk(util.funck(fn, -d - 1), found)
    end
    pc = pc + 1
  end
end

if #arg == 0 then
  io.stderr:write("usage: luajit tools/globals.lua <file.lua>...\n")
  os.exit(1)
end
for _, path in ipairs(arg) do
  local chunk, err = loadfile(path)
  if chunk then
    local found = {}
    walk(chunk, found)
    for line in pairs(found) do
      print(path .. "\t" .. line)
    end
  else
    print(path .. "\tERROR\t" .. err:gsub("\n", " "))
  end
end
