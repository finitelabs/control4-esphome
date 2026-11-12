--- The light_v2 drivers of a repo, each loaded as its OSS build compiles it, for the conformance run:
--- which drivers are lights, and the one light each one's chunk makes.

local F = require("c4_fixtures")
local Light = require("lib.light")

local D = {}

--- @param path string
--- @return string|nil
local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

--- The repo's root: the folder above test/.
--- @return string
function D.root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  local dir = source:match("^(.*)/[^/]*$") or "."
  local pipe = assert(io.popen(string.format("cd %q/.. && pwd", dir)))
  local root = pipe:read("*l")
  pipe:close()
  return root
end

--- Every driver folder under drivers/ whose driver.xml names the light_v2 proxy, sorted.
--- @param root string
--- @return string[] folders
function D.lights(root)
  local folders = {}
  local pipe = assert(io.popen(string.format("cd %q && ls -d drivers/*/ 2>/dev/null", root)))
  for line in pipe:lines() do
    local folder = line:match("^drivers/([^/]+)/$")
    local xml = folder and read(string.format("%s/drivers/%s/driver.xml", root, folder))
    if xml and xml:match("<proxy[^>]*>%s*light_v2%s*</proxy>") then
      folders[#folders + 1] = folder
    end
  end
  pipe:close()
  table.sort(folders)
  return folders
end

--- The driver's driver.xml.
--- @param root string
--- @param folder string
--- @return string|nil
function D.xml(root, folder)
  return read(string.format("%s/drivers/%s/driver.xml", root, folder))
end

--- The driver's driver.lua path.
--- @param root string
--- @param folder string
--- @return string
function D.path(root, folder)
  return string.format("%s/drivers/%s/driver.lua", root, folder)
end

--- Load a driver's chunk as its OSS build compiles it, and the one light it made there.
--- @param root string
--- @param folder string
--- @return Light|nil light
--- @return string|nil err Why there is none: the chunk raised, made no light, or made more than one.
function D.load(root, folder)
  local before = #Light.made
  local ok, err = pcall(F.dofileBuild, D.path(root, folder), "oss")
  if not ok then
    return nil, tostring(err)
  end
  local made = #Light.made - before
  if made == 0 then
    return nil, "driver.lua makes no light in its main chunk: call Light.new at the top level"
  elseif made > 1 then
    return nil, string.format("driver.lua makes %d lights: one light per driver", made)
  end
  return Light.made[#Light.made], nil
end

--- Answer the driver config reads the shim leaves out, minimum_os_version and version, from a
--- driver.xml, as Director answers them from the driver's own, and run the driver on the OS it asks for.
--- @param xml string
--- @return fun() restore Puts the shim's answer back.
function D.answerConfig(xml)
  local prior = C4.GetDriverConfigInfo
  function C4:GetDriverConfigInfo(section)
    if section == "minimum_os_version" or section == "version" then
      return xml:match("<" .. section .. ">([^<]*)</" .. section .. ">") or ""
    end
    return prior(self, section)
  end
  local priorVersion = C4.GetVersionInfo
  local minimum = xml:match("<minimum_os_version>([^<]*)</minimum_os_version>")
  if minimum and minimum ~= "" then
    function C4:GetVersionInfo()
      local info = {}
      for k, v in pairs(priorVersion(self)) do
        info[k] = v
      end
      info.version = minimum
      return info
    end
  end
  return function()
    C4.GetDriverConfigInfo = prior
    C4.GetVersionInfo = priorVersion
  end
end

--- Give Properties each property driver.xml declares, at its default, as Director does before a driver loads,
--- so the driver can UpdateProperty its own properties.
--- @param xml string
function D.seedProperties(xml)
  for block in xml:gmatch("<property>(.-)</property>") do
    local name = block:match("<name>(.-)</name>")
    if name then
      Properties[name] = block:match("<default>(.-)</default>") or ""
    end
  end
end

return D
