--- Print each global each Lua file reads or sets, as LuaJIT compiles it: one `<file>\t<GGET|GSET>\t<name>`
--- line per distinct pair, and `<file>\tERROR\t<message>` for a file that does not compile.
--- tools/globals.py compares a build's files with their source this way.

local util = require("jit.util")
local bit = require("bit")

--- The opcode of the first instruction LuaJIT compiles fn to. Opcodes differ between LuaJIT versions, and
--- jit.vmdef, which names them, is not in every install, so each one is read from a function that uses it.
--- @param fn function
--- @return integer
local function firstOp(fn)
  return bit.band(util.funcbc(fn, 1), 0xff)
end

local OPS = {
  [firstOp(function()
    return Probe
  end)] = "GGET",
  [firstOp(function(value)
    Probe = value
  end)] = "GSET",
  [firstOp(function()
    return function() end
  end)] = "FNEW",
}

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
