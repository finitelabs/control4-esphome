--- Generic property UI for selecting BLE devices.
--- Allows any module to register a device selection property for driver configuration.

local log = require("lib.logging")
local persist = require("lib.persist")
local constants = require("constants")
local bleScanner = require("esphome.ble.scanner")

--- @class PropertyRegistrationOptions
--- @field persistKey string Key for persisting selections in storage
--- @field onChanged? fun(selectedDevices: table<string, BLEDiscoveredDevice?>) Called on initial load and when selection changes
--- @field limit? number Maximum devices that can be selected (nil = unlimited)
--- @field filter? fun(device: BLEDiscoveredDevice): boolean Filter function; return true to include device
--- @field deferInitialCallback? boolean Skip the initial onChanged fire so the property can be
---   registered before the driver is ready to act on the selection. The caller is then
---   responsible for calling applySelection() once it is.

--- @class PropertyRegistration : PropertyRegistrationOptions
--- @field selectedDevices table<string, BLEDiscoveredDevice?> Currently selected devices keyed by MAC

--- @class BLEScannerProperties
--- @field _properties table<string, PropertyRegistration?> Registered properties by name
local BLEScannerProperties = {}
BLEScannerProperties.__index = BLEScannerProperties

--- Creates a new BLEScannerProperties instance.
--- @return BLEScannerProperties
function BLEScannerProperties:new()
  log:trace("BLEScannerProperties:new()")
  local instance = setmetatable({}, self)
  instance._properties = {}
  return instance
end

--- Register a property for device selection.
--- @param propertyName string The Control4 property name
--- @param options PropertyRegistrationOptions Registration options
function BLEScannerProperties:registerProperty(propertyName, options)
  log:trace("BLEScannerProperties:registerProperty(%s, <options>)", propertyName)

  if not options or IsEmpty(options.persistKey) then
    log:error("BLEScannerProperties:registerProperty requires persistKey option")
    return
  end

  -- Load selected devices from storage (full device info, keyed by MAC)
  --- @type table<string, BLEDiscoveredDevice?>
  local selectedDevices = persist:get(options.persistKey, {}) or {}

  self._properties[propertyName] = {
    persistKey = options.persistKey,
    onChanged = options.onChanged,
    selectedDevices = selectedDevices,
    limit = options.limit,
    filter = options.filter,
  }

  log:info(
    "Registered property '%s' with %d selected device(s)%s",
    propertyName,
    TableLength(selectedDevices),
    options.limit and string.format(" (limit: %d)", options.limit) or ""
  )

  -- Fire initial callback with current selection
  if not options.deferInitialCallback then
    self:applySelection(propertyName)
  end

  -- Initialize the property list with default options
  self:updateProperty(propertyName, false)
end

--- Fire a property's onChanged callback with its current selection.
--- Only needed after a registration that deferred the initial callback, to apply
--- the stored selection once the driver is ready to act on it.
--- @param propertyName string The property name
function BLEScannerProperties:applySelection(propertyName)
  log:trace("BLEScannerProperties:applySelection(%s)", propertyName)

  local registration = self._properties[propertyName]
  if not registration then
    log:warn("Property '%s' not registered", propertyName)
    return
  end

  local selectedDevices = registration.selectedDevices or {}
  if not registration.onChanged or TableLength(selectedDevices) == 0 then
    return
  end

  local success, err = pcall(registration.onChanged, selectedDevices)
  if not success then
    log:error("Property '%s' onChanged callback failed: %s", propertyName, err or "unknown error")
  end
end

--- Update the limit for a property.
--- Call this when BluetoothConnectionsFreeResponse provides the slot limit.
--- If limit is lower than current selection count, existing selections are kept
--- but no new devices can be added until some are removed.
--- @param propertyName string The property name
--- @param limit number|nil The new limit (nil = unlimited)
function BLEScannerProperties:setLimit(propertyName, limit)
  log:trace("BLEScannerProperties:setLimit(%s, %s)", propertyName, limit)

  local registration = self._properties[propertyName]
  if not registration then
    log:warn("Property '%s' not registered", propertyName)
    return
  end
  limit = tointeger(limit)
  if limit ~= nil then
    limit = math.max(0, limit)
  end
  if registration.limit == limit then
    log:trace("Limit for '%s' unchanged at %s", propertyName, limit or "unlimited")
    return
  end
  registration.limit = limit
  log:debug("Updated limit for '%s' to %s", propertyName, limit or "unlimited")

  -- Warn if current selection exceeds new limit
  if limit ~= nil then
    local currentCount = TableLength(registration.selectedDevices or {})
    if currentCount > limit then
      log:print(
        "Warning: %d device(s) selected but limit is %d. Remove %d device(s) to stay within limit.",
        currentCount,
        limit,
        currentCount - limit
      )
    end
  end
end

--- Count selected devices that require active connections (non-passive).
--- @param propertyName string The property name
--- @return number count Number of selected devices requiring active connections
function BLEScannerProperties:getSelectedActiveCount(propertyName)
  local registration = self._properties[propertyName]
  if not registration then
    return 0
  end

  local count = 0
  for _, device in pairs(registration.selectedDevices or {}) do
    if not device.passive then
      count = count + 1
    end
  end
  return count
end

--- Update a property's UI list.
--- @param propertyName string The property name
--- @param refresh boolean|nil If true, trigger a new scan first
function BLEScannerProperties:updateProperty(propertyName, refresh)
  log:trace("BLEScannerProperties:updateProperty(%s, %s)", propertyName, refresh)

  local registration = self._properties[propertyName]
  if not registration then
    log:warn("Property '%s' not registered", propertyName)
    return
  end

  local doUpdate = function()
    local discovered = bleScanner:getDiscoveredDevices()
    local selected = registration.selectedDevices or {}
    local filter = registration.filter

    -- Build sorted list of devices (apply filter: true = include)
    --- @type BLEDiscoveredDevice[]
    local devices = {}
    for _, device in pairs(discovered) do
      if not filter or filter(device) then
        table.insert(devices, device)
      end
    end

    -- Always show selected devices even if they don't pass filter
    for mac, device in pairs(selected) do
      if not discovered[mac] then
        table.insert(devices, device)
      end
    end

    -- Sort by name, then MAC
    table.sort(devices, function(a, b)
      local nameA = a.name or ""
      local nameB = b.name or ""
      if nameA ~= nameB then
        return nameA < nameB
      end
      return a.mac < b.mac
    end)

    -- Build option strings
    --- @type string[]
    local options = {}
    for _, device in ipairs(devices) do
      local displayName = device.displayName or device.mac
      if selected[device.mac] then
        table.insert(options, "[X] " .. displayName)
      else
        table.insert(options, "[  ] " .. displayName)
      end
    end

    -- Add special options at the beginning
    table.insert(options, 1, constants.REFRESH_LIST_OPTION)
    table.insert(options, 1, constants.SELECT_OPTION)

    -- Update the Control4 property
    C4:UpdatePropertyList(propertyName, table.concat(options, ","), constants.SELECT_OPTION)
  end

  if refresh then
    -- Show scanning indicator with stop/abort options
    local scanOptions = constants.SCANNING_OPTION
      .. ","
      .. constants.STOP_SCAN_OPTION
      .. ","
      .. constants.ABORT_SCAN_OPTION
    C4:UpdatePropertyList(propertyName, scanOptions, constants.SCANNING_OPTION)

    log:print("Scanning for Bluetooth devices...")
    bleScanner:scan():next(function()
      doUpdate()
    end, function(err)
      -- Don't log error for cancelled scans
      if err ~= "Scan cancelled" then
        log:error("Failed to scan for Bluetooth devices: %s", err or "unknown")
      end
      doUpdate()
    end)
  else
    doUpdate()
  end
end

--- Handle a selection change from the UI.
--- @param propertyName string The property name
--- @param propertyValue string The selected property value
--- @return boolean changed True if selection changed
function BLEScannerProperties:handleSelection(propertyName, propertyValue)
  log:trace("BLEScannerProperties:handleSelection(%s, %s)", propertyName, propertyValue)

  local registration = self._properties[propertyName]
  if not registration then
    log:warn("Property '%s' not registered", propertyName)
    return false
  end

  -- Handle special options
  if propertyValue == constants.REFRESH_LIST_OPTION then
    log:print("Refreshing device list for '%s'", propertyName)
    self:updateProperty(propertyName, true)
    return false
  end

  if propertyValue == constants.STOP_SCAN_OPTION then
    if bleScanner:stopScan() then
      log:print("Scan stopped")
    end
    return false
  end

  if propertyValue == constants.ABORT_SCAN_OPTION then
    if bleScanner:abortScan() then
      log:print("Scan aborted")
    end
    return false
  end

  if propertyValue == constants.SELECT_OPTION or propertyValue == constants.SCANNING_OPTION then
    return false
  end

  -- Extract MAC address from the option string
  -- Format: "[X] AA:BB:CC:DD:EE:FF - Name" or "[  ] AA:BB:CC:DD:EE:FF - Name"
  local mac = string.match(propertyValue or "", "([%x]+:[%x]+:[%x]+:[%x]+:[%x]+:[%x]+)")
  if not mac then
    log:warn("Could not extract MAC address from: %s", propertyValue)
    return false
  end

  local selected = registration.selectedDevices or {}
  local wasSelected = selected[mac] ~= nil
  local isUnselecting = string.match(propertyValue, "^%[X%]")

  -- Get device from discovered list, or from selected list for unselection
  local device = bleScanner:getDiscoveredDevices()[mac]
  if IsEmpty(device) and isUnselecting then
    -- For unselection, use the stored device info
    device = selected[mac]
  end

  if IsEmpty(device) then
    log:print("Cannot add device: unknown mac address. Refresh list and try again.")
    return false
  end
  --- @cast device -nil

  if isUnselecting then
    -- Currently selected, remove it
    selected[mac] = nil
    log:info("Removed device from '%s': %s", propertyName, mac)
  else
    selected[mac] = device
    log:info("Added device to '%s': %s (%s)", propertyName, mac, device.name or "unnamed")
  end

  registration.selectedDevices = selected

  -- Persist the full device info (keyed by MAC)
  persist:set(registration.persistKey, not IsEmpty(selected) and selected or nil)

  -- Update the property UI
  self:updateProperty(propertyName, false)

  -- Fire callback if selection actually changed
  local isSelected = selected[mac] ~= nil
  if wasSelected ~= isSelected and registration.onChanged then
    local success, err = pcall(registration.onChanged, selected)
    if not success then
      log:error("Property '%s' onChanged callback failed: %s", propertyName, err or "unknown error")
    end
  end

  return true
end

--- Resets all registered properties, clearing selections and persisted data.
--- Does NOT unregister properties - they remain registered but empty.
function BLEScannerProperties:reset()
  log:trace("BLEScannerProperties:reset()")
  for propertyName, registration in pairs(self._properties) do
    log:debug("Resetting property '%s'", propertyName)

    -- Clear the persisted selection
    persist:delete(registration.persistKey)

    -- Clear the in-memory selection
    registration.selectedDevices = {}

    -- Fire onChanged callback with empty selection
    if registration.onChanged then
      local success, err = pcall(registration.onChanged, {})
      if not success then
        log:error("Property '%s' onChanged callback failed: %s", propertyName, err or "unknown error")
      end
    end
  end
end

return BLEScannerProperties:new()
