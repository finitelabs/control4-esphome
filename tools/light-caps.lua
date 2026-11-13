--- Write a Light V2 driver's light capabilities into its build's driver.xml, from the profile its chunk
--- gave Light.new. gen-squishy.lua runs it in the build's driver folder, with the driver loaded, so
--- the source driver.xml carries none of these keys.

local Caps = require("lib.light.caps")

--- So a reader of a light driver's source driver.xml knows the build writes its capabilities.
local COMMENT =
  "<!-- The light's capabilities are the build's, written from the profile the driver gives Light.new. -->"

--- The element for key between from and to, where the capabilities element opens and closes.
--- @param xml string
--- @param key string
--- @param from integer
--- @param to integer
--- @return integer|nil start, integer|nil stop
local function findKey(xml, key, from, to)
  local s, e = xml:find("<" .. key .. ">[^<]*</" .. key .. ">", from)
  if s and e <= to then
    return s, e
  end
  return nil, nil
end

--- @param light Light The light the driver's chunk made.
--- @param path string The build's driver.xml.
return function(light, path)
  local f = assert(io.open(path, "rb"))
  local xml = f:read("*a")
  f:close()
  local at = xml:find("<capabilities[%s/>]")
  if at and (xml:sub(1, at - 1):gsub("%s+$", "")):sub(-#COMMENT) ~= COMMENT then
    error(path .. " needs this line just above its <capabilities> element:\n  " .. COMMENT, 0)
  end
  -- An empty <capabilities/>, as the template's driver.xml starts, opens to take the keys.
  local emptyStart, emptyEnd = xml:find("<capabilities%s*/>")
  if emptyStart then
    local lineIndent = xml:sub(1, emptyStart - 1):match("([ \t]*)$") or ""
    xml = xml:sub(1, emptyStart - 1) .. "<capabilities>\n" .. lineIndent .. "</capabilities>" .. xml:sub(emptyEnd + 1)
  end
  local open = select(2, xml:find("<capabilities>", 1, true))
  local close = xml:find("</capabilities>", 1, true)
  if not open or not close then
    error(path .. " has no <capabilities> element for the light's capabilities")
  end
  local indent = xml:sub(1, close - 1):match("\n([ \t]*)[^\n]*$") or ""
  local childIndent = indent .. "  "
  for _, cap in ipairs(Caps.static(light.profile)) do
    local element = string.format("<%s>%s</%s>", cap.key, cap.value, cap.key)
    local s, e = findKey(xml, cap.key, open, close)
    if s then
      xml = xml:sub(1, s - 1) .. element .. xml:sub(e + 1)
    else
      xml = xml:sub(1, close - 1):gsub("[ \t]*$", "") .. childIndent .. element .. "\n" .. indent .. xml:sub(close)
    end
    close = xml:find("</capabilities>", 1, true)
  end
  f = assert(io.open(path, "wb"))
  f:write(xml)
  f:close()
end
