--- Yale/August BLE advertisement parser.
--- Detects Yale/August smart locks by manufacturer ID 0x01D1.
--- Sources:
---  - https://github.com/bdraco/yalexs-ble

--- @class Yale
local Yale = {}

--- August Home / Yale manufacturer company ID
Yale.MANUFACTURER_ID = 0x01D1

--- Device type names
Yale.DEVICE_NAMES = {
  LOCK = "Yale Lock",
}

--- @class YaleParsedData
--- @field deviceType string Device type name

--- Find Yale manufacturer data from advertisement
--- @param manufacturerData BLEManufacturerData[]|nil Manufacturer data entries
--- @return boolean found True if Yale manufacturer data is present
local function hasManufacturerData(manufacturerData)
  if not manufacturerData then
    return false
  end
  for _, mfg in ipairs(manufacturerData) do
    if mfg.company == Yale.MANUFACTURER_ID then
      return true
    end
  end
  return false
end

--- Parse Yale BLE advertisement data.
--- @param _serviceData BLEServiceData[]|nil Service data array (unused, Yale uses manufacturer data)
--- @param manufacturerData BLEManufacturerData[]|nil Manufacturer data array
--- @return YaleParsedData|nil parsed Parsed data or nil if not Yale
function Yale.parse(_serviceData, manufacturerData)
  if not hasManufacturerData(manufacturerData) then
    return nil
  end

  return {
    deviceType = Yale.DEVICE_NAMES.LOCK,
  }
end

return Yale
