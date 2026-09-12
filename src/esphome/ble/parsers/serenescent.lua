--- Homedics SereneScent BLE advertisement parser.
--- Detects SereneScent diffusers by advertised service UUID 0xFFF0
--- and device name prefix "ARMH-".
--- Sources:
---   - https://github.com/john-k-mcdowell/Homedics-SereneScent

--- @class SereneScent
local SereneScent = {}

--- Advertised 16-bit service UUID (0xFFF0) used for discovery.
--- This is the short-form UUID that appears in BLE advertisements.
SereneScent.ADVERTISED_SERVICE_UUID = "FFF0"

--- Device name prefix used as a secondary fingerprint.
SereneScent.NAME_PREFIX = "ARMH-"

--- Device type name (used as key into scanner DEVICE_TYPE_TO_BINDING_CLASS).
SereneScent.DEVICE_NAMES = {
  DIFFUSER = "Homedics SereneScent",
}

--- @class SerenescentParsedData
--- @field deviceType string Device type name

--- Check if the advertisement has the SereneScent service UUID.
--- @param serviceUuids BLEServiceUUID[]|nil List of service UUIDs from advertisement
--- @return boolean found True if the SereneScent service UUID is present
local function hasServiceUuid(serviceUuids)
  if not serviceUuids then
    return false
  end
  for _, svc in ipairs(serviceUuids) do
    if svc.uuid and svc.uuid:upper() == SereneScent.ADVERTISED_SERVICE_UUID then
      return true
    end
  end
  return false
end

--- Check if the device name starts with the ARMH- prefix.
--- @param name string|nil Device name from advertisement
--- @return boolean matches True if name starts with "ARMH-"
local function hasNamePrefix(name)
  if not name then
    return false
  end
  return name:sub(1, #SereneScent.NAME_PREFIX) == SereneScent.NAME_PREFIX
end

--- Parse a SereneScent BLE advertisement.
--- Matches on advertised service UUID 0xFFF0, with name prefix as secondary check.
--- @param serviceUuids BLEServiceUUID[]|nil Service UUIDs from advertisement
--- @param name string|nil Device name from advertisement
--- @return SerenescentParsedData|nil parsed Parsed data or nil if not SereneScent
function SereneScent.parse(serviceUuids, name)
  -- Primary: match on advertised service UUID 0xFFF0
  if hasServiceUuid(serviceUuids) then
    return { deviceType = SereneScent.DEVICE_NAMES.DIFFUSER }
  end

  -- Secondary fallback: match on device name prefix (in case UUID is absent)
  if hasNamePrefix(name) then
    return { deviceType = SereneScent.DEVICE_NAMES.DIFFUSER }
  end

  return nil
end

return SereneScent
