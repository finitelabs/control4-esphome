--- Homedics SereneScent BLE advertisement parser.
--- Detects SereneScent diffusers by their advertised local name. The diffuser also
--- advertises service 0xFFF0, but that is a generic vendor UUID many unrelated
--- devices share, and a false match would claim a GATT connection slot.
--- Sources:
---  - https://github.com/john-k-mcdowell/Homedics-SereneScent

--- @class SereneScent
local SereneScent = {}

--- Upstream names both: ARMH- in its constants (and on the tested ARMH-972),
--- ARPRP- in its Home Assistant discovery manifest.
SereneScent.NAME_PREFIXES = { "ARMH-", "ARPRP-" }

--- Device type names
SereneScent.DEVICE_NAMES = {
  DIFFUSER = "Homedics SereneScent",
}

--- @class SereneScentParsedData
--- @field deviceType string Device type name

--- Parse a SereneScent BLE advertisement.
--- @param name string|nil Advertised local name
--- @return SereneScentParsedData|nil parsed Parsed data or nil if not SereneScent
function SereneScent.parse(name)
  if type(name) ~= "string" then
    return nil
  end
  for _, prefix in ipairs(SereneScent.NAME_PREFIXES) do
    if name:sub(1, #prefix) == prefix then
      return { deviceType = SereneScent.DEVICE_NAMES.DIFFUSER }
    end
  end
  return nil
end

return SereneScent
