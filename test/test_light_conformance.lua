-- The light conformance run over every light_v2 driver in this repo. The template owns this file: a new
-- case reaches every light repo at its next copier update.
--
-- For each driver whose driver.xml names the light_v2 proxy, its chunk makes one light at its top level,
-- and sets no command-keyed RFP for a command the library handles. Then every rig test/light_rigs.lua
-- gives for it runs the cases in test/light_conformance.lua.
--
-- test/light_rigs.lua is the repo's own: { version = C.RIG_VERSION, rigs = { [folder] = { LightRig, ... } } },
-- each rig loading its driver as it ships and faking only its transport.

local T = require("testlib")

require("c4_shim")

local C = require("light_conformance")
local D = require("light_drivers")
local Light = require("lib.light")

-- The commands lib.light handles on the proxy and link bindings, as its handlers list them.
local LIBRARY_COMMANDS = require("lib.light.handlers").COMMANDS

local root = D.root()
local lights = D.lights(root)
local rigsFile = io.open(root .. "/test/light_rigs.lua")
local hasRigs = rigsFile ~= nil
if rigsFile then
  rigsFile:close()
end

-- A repo with no light driver yet has nothing to prove, unless it gives rigs.
if #lights == 0 and not hasRigs then
  print("No light_v2 driver under drivers/ and no test/light_rigs.lua: nothing to prove.")
  T.finish()
  return
end

for _, folder in ipairs(lights) do
  T.section(folder .. ": its chunk makes one light at its top level, and takes no library command itself")
  for _, cmd in ipairs(LIBRARY_COMMANDS) do
    RFP[cmd] = nil
  end
  D.seedProperties(D.xml(root, folder) or "")
  local light, err = D.load(root, folder)
  T.check(folder .. ": driver.lua loads and makes its light", light ~= nil, err)
  if light then
    T.eq(folder .. ": at the API this library is", light.profile.api, Light.API)
  end
  local taken = {}
  for _, cmd in ipairs(LIBRARY_COMMANDS) do
    if RFP[cmd] ~= nil then
      taken[#taken + 1] = cmd
    end
  end
  T.eq(folder .. ": no command-keyed RFP names a command the library handles", taken, {})
end

local ok, rigsOrErr = pcall(require, "light_rigs")
T.section("test/light_rigs.lua")
T.check("test/light_rigs.lua loads", ok, not ok and tostring(rigsOrErr) or nil)
if not ok then
  T.finish()
  return
end
local file = rigsOrErr
T.eq(
  "it is written for the rig interface these cases take",
  type(file) == "table" and file.version or nil,
  C.RIG_VERSION
)
local rigs = type(file) == "table" and type(file.rigs) == "table" and file.rigs or {}

local isLight = {}
for _, folder in ipairs(lights) do
  isLight[folder] = true
  local list = rigs[folder]
  T.check(folder .. ": has at least one rig", type(list) == "table" and #list > 0, "test/light_rigs.lua gives none")
end
for folder in pairs(rigs) do
  T.check(folder .. ": a rig is for a light_v2 driver", isLight[folder] == true, "drivers/" .. folder .. " is not one")
end

if file.version == C.RIG_VERSION then
  for _, folder in ipairs(lights) do
    for index, rig in ipairs(rigs[folder] or {}) do
      rig.folder = folder
      rig.name = rig.name or string.format("%s rig %d", folder, index)
      C.run(T, rig)
    end
  end
end

T.finish()
