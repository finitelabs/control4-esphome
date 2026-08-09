do
  local _ENV = _ENV
  package.preload["bthome.const"] = function(...)
    local arg = _G.arg
    --- @module "bthome.const"
    --- BTHome object ID definitions and data format constants.
    --- Contains all 78+ sensor object IDs from the BTHome specification.
    --- @see https://bthome.io/format
    ---
    --- @class bthome.const
    local const = {}

    --- @class BTHomeObjectDefinition
    --- @field name string Sensor name (e.g., "temperature", "humidity")
    --- @field display_name string Human-readable display name (e.g., "Temperature", "Humidity")
    --- @field format BTHomeFormat Data format type (e.g., "uint8", "sint16", "string")
    --- @field factor number Scaling factor to apply to raw value
    --- @field unit string|nil Unit of measurement (e.g., "°C", "%", nil)
    --- @field length integer Byte length of the value (0 for variable-length)
    --- @field is_event boolean|nil True if this is an event type (button, dimmer)

    --- Data format types for encoding values.
    --- @enum BTHomeFormat
    const.FORMAT = {
      UINT8 = "uint8",
      SINT8 = "sint8",
      UINT16 = "uint16",
      SINT16 = "sint16",
      UINT24 = "uint24",
      SINT24 = "sint24",
      UINT32 = "uint32",
      SINT32 = "sint32",
      UINT48 = "uint48",
      STRING = "string",
      MAC = "mac",
    }

    --- Object ID definitions.
    --- @type table<integer, BTHomeObjectDefinition?>
    const.OBJECT_IDS = {
      -- Sensors
      [0x01] = {
        name = "battery",
        display_name = "Battery",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = "%",
        length = 1,
      },
      [0x02] = {
        name = "temperature",
        display_name = "Temperature",
        format = const.FORMAT.SINT16,
        factor = 0.01,
        unit = "°C",
        length = 2,
      },
      [0x03] = {
        name = "humidity",
        display_name = "Humidity",
        format = const.FORMAT.UINT16,
        factor = 0.01,
        unit = "%",
        length = 2,
      },
      [0x04] = {
        name = "pressure",
        display_name = "Pressure",
        format = const.FORMAT.UINT24,
        factor = 0.01,
        unit = "hPa",
        length = 3,
      },
      [0x05] = {
        name = "illuminance",
        display_name = "Illuminance",
        format = const.FORMAT.UINT24,
        factor = 0.01,
        unit = "lx",
        length = 3,
      },
      [0x06] = {
        name = "mass_kg",
        display_name = "Mass",
        format = const.FORMAT.UINT16,
        factor = 0.01,
        unit = "kg",
        length = 2,
      },
      [0x07] = {
        name = "mass_lb",
        display_name = "Mass",
        format = const.FORMAT.UINT16,
        factor = 0.01,
        unit = "lb",
        length = 2,
      },
      [0x08] = {
        name = "dewpoint",
        display_name = "Dew Point",
        format = const.FORMAT.SINT16,
        factor = 0.01,
        unit = "°C",
        length = 2,
      },
      [0x09] = {
        name = "count",
        display_name = "Count",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x0A] = {
        name = "energy",
        display_name = "Energy",
        format = const.FORMAT.UINT24,
        factor = 0.001,
        unit = "kWh",
        length = 3,
      },
      [0x0B] = {
        name = "power",
        display_name = "Power",
        format = const.FORMAT.UINT24,
        factor = 0.01,
        unit = "W",
        length = 3,
      },
      [0x0C] = {
        name = "voltage",
        display_name = "Voltage",
        format = const.FORMAT.UINT16,
        factor = 0.001,
        unit = "V",
        length = 2,
      },
      [0x0D] = {
        name = "pm2_5",
        display_name = "PM2.5",
        format = const.FORMAT.UINT16,
        factor = 1,
        unit = "µg/m³",
        length = 2,
      },
      [0x0E] = {
        name = "pm10",
        display_name = "PM10",
        format = const.FORMAT.UINT16,
        factor = 1,
        unit = "µg/m³",
        length = 2,
      },
      [0x12] = {
        name = "co2",
        display_name = "CO₂",
        format = const.FORMAT.UINT16,
        factor = 1,
        unit = "ppm",
        length = 2,
      },
      [0x13] = {
        name = "tvoc",
        display_name = "TVOC",
        format = const.FORMAT.UINT16,
        factor = 1,
        unit = "µg/m³",
        length = 2,
      },
      [0x14] = {
        name = "moisture",
        display_name = "Moisture",
        format = const.FORMAT.UINT16,
        factor = 0.01,
        unit = "%",
        length = 2,
      },
      [0x2E] = {
        name = "humidity",
        display_name = "Humidity",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = "%",
        length = 1,
      },
      [0x2F] = {
        name = "moisture",
        display_name = "Moisture",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = "%",
        length = 1,
      },
      [0x3D] = {
        name = "count",
        display_name = "Count",
        format = const.FORMAT.UINT16,
        factor = 1,
        unit = nil,
        length = 2,
      },
      [0x3E] = {
        name = "count",
        display_name = "Count",
        format = const.FORMAT.UINT32,
        factor = 1,
        unit = nil,
        length = 4,
      },
      [0x3F] = {
        name = "rotation",
        display_name = "Rotation",
        format = const.FORMAT.SINT16,
        factor = 0.1,
        unit = "°",
        length = 2,
      },
      [0x40] = {
        name = "distance_mm",
        display_name = "Distance",
        format = const.FORMAT.UINT16,
        factor = 1,
        unit = "mm",
        length = 2,
      },
      [0x41] = {
        name = "distance_m",
        display_name = "Distance",
        format = const.FORMAT.UINT16,
        factor = 0.1,
        unit = "m",
        length = 2,
      },
      [0x42] = {
        name = "duration",
        display_name = "Duration",
        format = const.FORMAT.UINT24,
        factor = 0.001,
        unit = "s",
        length = 3,
      },
      [0x43] = {
        name = "current",
        display_name = "Current",
        format = const.FORMAT.UINT16,
        factor = 0.001,
        unit = "A",
        length = 2,
      },
      [0x44] = {
        name = "speed",
        display_name = "Speed",
        format = const.FORMAT.UINT16,
        factor = 0.01,
        unit = "m/s",
        length = 2,
      },
      [0x45] = {
        name = "temperature",
        display_name = "Temperature",
        format = const.FORMAT.SINT16,
        factor = 0.1,
        unit = "°C",
        length = 2,
      },
      [0x46] = {
        name = "uv_index",
        display_name = "UV Index",
        format = const.FORMAT.UINT8,
        factor = 0.1,
        unit = nil,
        length = 1,
      },
      [0x47] = {
        name = "volume",
        display_name = "Volume",
        format = const.FORMAT.UINT16,
        factor = 0.1,
        unit = "L",
        length = 2,
      },
      [0x48] = {
        name = "volume_ml",
        display_name = "Volume",
        format = const.FORMAT.UINT16,
        factor = 1,
        unit = "mL",
        length = 2,
      },
      [0x49] = {
        name = "volume_flow_rate",
        display_name = "Volume Flow Rate",
        format = const.FORMAT.UINT16,
        factor = 0.001,
        unit = "m³/h",
        length = 2,
      },
      [0x4A] = {
        name = "voltage",
        display_name = "Voltage",
        format = const.FORMAT.UINT16,
        factor = 0.1,
        unit = "V",
        length = 2,
      },
      [0x4B] = {
        name = "gas",
        display_name = "Gas",
        format = const.FORMAT.UINT24,
        factor = 0.001,
        unit = "m³",
        length = 3,
      },
      [0x4C] = {
        name = "gas",
        display_name = "Gas",
        format = const.FORMAT.UINT32,
        factor = 0.001,
        unit = "m³",
        length = 4,
      },
      [0x4D] = {
        name = "energy",
        display_name = "Energy",
        format = const.FORMAT.UINT32,
        factor = 0.001,
        unit = "kWh",
        length = 4,
      },
      [0x4E] = {
        name = "volume",
        display_name = "Volume",
        format = const.FORMAT.UINT32,
        factor = 0.001,
        unit = "L",
        length = 4,
      },
      [0x4F] = {
        name = "water",
        display_name = "Water",
        format = const.FORMAT.UINT32,
        factor = 0.001,
        unit = "L",
        length = 4,
      },
      [0x50] = {
        name = "timestamp",
        display_name = "Timestamp",
        format = const.FORMAT.UINT32,
        factor = 1,
        unit = nil,
        length = 4,
      },
      [0x51] = {
        name = "acceleration",
        display_name = "Acceleration",
        format = const.FORMAT.UINT16,
        factor = 0.001,
        unit = "m/s²",
        length = 2,
      },
      [0x52] = {
        name = "gyroscope",
        display_name = "Gyroscope",
        format = const.FORMAT.UINT16,
        factor = 0.001,
        unit = "°/s",
        length = 2,
      },
      [0x53] = {
        name = "text",
        display_name = "Text",
        format = const.FORMAT.STRING,
        factor = 1,
        unit = nil,
        length = 0,
      }, -- Variable length
      [0x54] = { name = "raw", display_name = "Raw", format = const.FORMAT.STRING, factor = 1, unit = nil, length = 0 }, -- Variable length
      [0x55] = {
        name = "volume_storage",
        display_name = "Volume Storage",
        format = const.FORMAT.UINT32,
        factor = 0.001,
        unit = "L",
        length = 4,
      },
      [0x56] = {
        name = "conductivity",
        display_name = "Conductivity",
        format = const.FORMAT.UINT16,
        factor = 1,
        unit = "µS/cm",
        length = 2,
      },
      [0x57] = {
        name = "temperature",
        display_name = "Temperature",
        format = const.FORMAT.SINT8,
        factor = 1,
        unit = "°C",
        length = 1,
      },
      [0x58] = {
        name = "temperature",
        display_name = "Temperature",
        format = const.FORMAT.SINT8,
        factor = 0.35,
        unit = "°C",
        length = 1,
      },
      [0x59] = {
        name = "count",
        display_name = "Count",
        format = const.FORMAT.SINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x5A] = {
        name = "count",
        display_name = "Count",
        format = const.FORMAT.SINT16,
        factor = 1,
        unit = nil,
        length = 2,
      },
      [0x5B] = {
        name = "count",
        display_name = "Count",
        format = const.FORMAT.SINT32,
        factor = 1,
        unit = nil,
        length = 4,
      },
      [0x5C] = {
        name = "power",
        display_name = "Power",
        format = const.FORMAT.SINT32,
        factor = 0.01,
        unit = "W",
        length = 4,
      },
      [0x5D] = {
        name = "current",
        display_name = "Current",
        format = const.FORMAT.SINT16,
        factor = 0.001,
        unit = "A",
        length = 2,
      },
      [0x5E] = {
        name = "direction",
        display_name = "Direction",
        format = const.FORMAT.UINT16,
        factor = 0.01,
        unit = "°",
        length = 2,
      },
      [0x5F] = {
        name = "precipitation",
        display_name = "Precipitation",
        format = const.FORMAT.UINT16,
        factor = 0.1,
        unit = "mm",
        length = 2,
      },
      [0x60] = {
        name = "channel",
        display_name = "Channel",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x61] = {
        name = "rotational_speed",
        display_name = "Rotational Speed",
        format = const.FORMAT.UINT16,
        factor = 1,
        unit = "rpm",
        length = 2,
      },
      [0x62] = {
        name = "speed_signed",
        display_name = "Speed",
        format = const.FORMAT.SINT32,
        factor = 0.000001,
        unit = "m/s",
        length = 4,
      },
      [0x63] = {
        name = "acceleration_signed",
        display_name = "Acceleration",
        format = const.FORMAT.SINT32,
        factor = 0.000001,
        unit = "m/s²",
        length = 4,
      },

      -- Binary sensors
      [0x0F] = {
        name = "generic_boolean",
        display_name = "Generic Boolean",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x10] = {
        name = "power_on",
        display_name = "Power",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x11] = {
        name = "opening",
        display_name = "Opening",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x15] = {
        name = "battery_low",
        display_name = "Battery Low",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x16] = {
        name = "battery_charging",
        display_name = "Battery Charging",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x17] = {
        name = "carbon_monoxide_detected",
        display_name = "Carbon Monoxide",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x18] = { name = "cold", display_name = "Cold", format = const.FORMAT.UINT8, factor = 1, unit = nil, length = 1 },
      [0x19] = {
        name = "connectivity",
        display_name = "Connectivity",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x1A] = { name = "door", display_name = "Door", format = const.FORMAT.UINT8, factor = 1, unit = nil, length = 1 },
      [0x1B] = {
        name = "garage_door",
        display_name = "Garage Door",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x1C] = {
        name = "gas_detected",
        display_name = "Gas",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x1D] = { name = "heat", display_name = "Heat", format = const.FORMAT.UINT8, factor = 1, unit = nil, length = 1 },
      [0x1E] = {
        name = "light_detected",
        display_name = "Light",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x1F] = {
        name = "lock_unlocked",
        display_name = "Lock",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x20] = {
        name = "moisture_detected",
        display_name = "Moisture",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x21] = {
        name = "motion",
        display_name = "Motion",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x22] = {
        name = "moving",
        display_name = "Moving",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x23] = {
        name = "occupancy",
        display_name = "Occupancy",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x24] = { name = "plug", display_name = "Plug", format = const.FORMAT.UINT8, factor = 1, unit = nil, length = 1 },
      [0x25] = {
        name = "presence",
        display_name = "Presence",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x26] = {
        name = "problem",
        display_name = "Problem",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x27] = {
        name = "running",
        display_name = "Running",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x28] = {
        name = "safety",
        display_name = "Safety",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x29] = {
        name = "smoke_detected",
        display_name = "Smoke",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x2A] = {
        name = "sound_detected",
        display_name = "Sound",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x2B] = {
        name = "tamper",
        display_name = "Tamper",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x2C] = {
        name = "vibration_detected",
        display_name = "Vibration",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
      [0x2D] = {
        name = "window",
        display_name = "Window",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },

      -- Events
      [0x3A] = {
        name = "button",
        display_name = "Button",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
        is_event = true,
      },
      [0x3C] = {
        name = "dimmer",
        display_name = "Dimmer",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 2,
        is_event = true,
      },

      -- Device Info
      [0xF0] = {
        name = "device_type_id",
        display_name = "Device Type ID",
        format = const.FORMAT.UINT16,
        factor = 1,
        unit = nil,
        length = 2,
      },
      [0xF1] = {
        name = "firmware_version",
        display_name = "Firmware Version",
        format = const.FORMAT.UINT32,
        factor = 1,
        unit = nil,
        length = 4,
      },
      [0xF2] = {
        name = "firmware_version",
        display_name = "Firmware Version",
        format = const.FORMAT.UINT24,
        factor = 1,
        unit = nil,
        length = 3,
      },

      -- Misc
      [0x00] = {
        name = "packet_id",
        display_name = "Packet ID",
        format = const.FORMAT.UINT8,
        factor = 1,
        unit = nil,
        length = 1,
      },
    }

    --- @class BTHomeV1FormatDefinition
    --- @field format BTHomeFormat Format name (e.g., "uint8", "sint16")
    --- @field length integer Byte length

    --- BTHome V1 data format types (for legacy support).
    --- In V1, bits 5-7 of the object byte encode the data format.
    --- @type table<integer, BTHomeV1FormatDefinition?>
    const.V1_FORMATS = {
      [0x00] = { format = const.FORMAT.UINT8, length = 1 },
      [0x01] = { format = const.FORMAT.SINT8, length = 1 },
      [0x02] = { format = const.FORMAT.UINT16, length = 2 },
      [0x03] = { format = const.FORMAT.SINT16, length = 2 },
      [0x04] = { format = const.FORMAT.UINT24, length = 3 },
      [0x05] = { format = const.FORMAT.SINT24, length = 3 },
      [0x06] = { format = const.FORMAT.UINT32, length = 4 },
      [0x07] = { format = const.FORMAT.SINT32, length = 4 },
    }

    --- Device info byte bit positions.
    --- @enum BTHomeDeviceInfoBit
    const.DEVICE_INFO = {
      ENCRYPTED_BIT = 0, -- Bit 0: encryption flag
      TRIGGER_BIT = 2, -- Bit 2: trigger-based device flag
      VERSION_SHIFT = 5, -- Bits 5-7: BTHome version
      VERSION_MASK = 0x07, -- Mask for version bits (3 bits)
    }

    --- BTHome versions.
    --- @enum BTHomeVersionEnum
    const.VERSION = {
      V1 = 1,
      V2 = 2,
    }

    --- Get object definition by ID.
    --- @param object_id integer The object ID (0x00-0xFF)
    --- @return BTHomeObjectDefinition|nil definition Object definition or nil if unknown
    function const.get_object(object_id)
      return const.OBJECT_IDS[object_id]
    end

    --- Get the length of a variable-length field.
    --- For text and raw fields, the first byte is the length.
    --- @param format BTHomeFormat The format type
    --- @param data string The data starting at the length byte
    --- @return integer length The total length including the length byte
    function const.get_variable_length(format, data)
      if format == const.FORMAT.STRING and #data >= 1 then
        return 1 + string.byte(data, 1)
      end
      return 0
    end

    --- Run self-tests.
    --- @return boolean success True if all tests passed
    function const.selftest()
      print("Testing const module...")
      local passed = 0
      local total = 0

      -- ===========================================================================
      -- Object ID Lookup Tests
      -- ===========================================================================

      local test_ids = {
        { id = 0x00, name = "packet_id" },
        { id = 0x01, name = "battery" },
        { id = 0x02, name = "temperature" },
        { id = 0x03, name = "humidity" },
        { id = 0x3A, name = "button" },
        { id = 0x53, name = "text" },
      }

      for _, test in ipairs(test_ids) do
        total = total + 1
        local obj = const.get_object(test.id)
        if obj and obj.name == test.name then
          print(string.format("  PASS: Object ID 0x%02X = %s", test.id, test.name))
          passed = passed + 1
        else
          print(string.format("  FAIL: Object ID 0x%02X", test.id))
          print(string.format("    Expected: %s", test.name))
          print(string.format("    Got: %s", obj and obj.name or "nil"))
        end
      end

      -- ===========================================================================
      -- Object Attribute Tests
      -- ===========================================================================

      total = total + 1
      local temp = const.get_object(0x02)
      if temp and temp.factor == 0.01 and temp.length == 2 then
        print("  PASS: Temperature has correct factor and length")
        passed = passed + 1
      else
        print("  FAIL: Temperature attributes")
        print(string.format("    Expected: factor=0.01, length=2"))
        print(string.format("    Got: factor=%s, length=%s", temp and temp.factor, temp and temp.length))
      end

      -- ===========================================================================
      -- Unknown Object ID Tests
      -- ===========================================================================

      total = total + 1
      local unknown = const.get_object(0xFF)
      if unknown == nil then
        print("  PASS: Unknown object ID returns nil")
        passed = passed + 1
      else
        print("  FAIL: Unknown object ID should return nil")
        print(string.format("    Got: %s", tostring(unknown)))
      end

      print(string.format("\nconst module: %d/%d tests passed\n", passed, total))
      return passed == total
    end

    return const
  end
end

do
  local _ENV = _ENV
  package.preload["bthome.crypto"] = function(...)
    local arg = _G.arg
    --- @module "bthome.crypto"
    --- BTHome cryptographic operations module.
    --- Provides AES-CCM authenticated encryption for encrypted BTHome advertisements.
    ---
    --- @class bthome.crypto
    local crypto = {
      --- @type bthome.crypto.aes_ccm
      aes_ccm = require("bthome.crypto.aes_ccm"),
    }

    --- Run self-tests for crypto module.
    --- @return boolean success True if all tests passed
    function crypto.selftest()
      return crypto.aes_ccm.selftest()
    end

    return crypto
  end
end

do
  local _ENV = _ENV
  package.preload["bthome.crypto.aes_ccm"] = function(...)
    local arg = _G.arg
    --- @module "bthome.crypto.aes_ccm"
    --- AES-CCM Authenticated Encryption for BTHome BLE advertisements.
    --- CCM combines CTR mode encryption with CBC-MAC authentication.
    --- @see RFC 3610 for CCM specification
    --- @see https://bthome.io/encryption for BTHome encryption details
    ---
    --- @class bthome.crypto.aes_ccm
    local aes_ccm = {}

    local bit32 = require("bitn").bit32

    -- Local references for performance
    local bit32_raw_band = bit32.raw_band
    local bit32_raw_bxor = bit32.raw_bxor
    local bit32_raw_lshift = bit32.raw_lshift
    local math_floor = math.floor
    local math_min = math.min
    local string_byte = string.byte
    local string_char = string.char
    local string_format = string.format
    local string_rep = string.rep
    local string_sub = string.sub
    local table_concat = table.concat

    -- ============================================================================
    -- AES CORE IMPLEMENTATION
    -- ============================================================================

    -- AES S-box (substitution box)
    --- @type integer[]
    local SBOX = {
      0x63,
      0x7c,
      0x77,
      0x7b,
      0xf2,
      0x6b,
      0x6f,
      0xc5,
      0x30,
      0x01,
      0x67,
      0x2b,
      0xfe,
      0xd7,
      0xab,
      0x76,
      0xca,
      0x82,
      0xc9,
      0x7d,
      0xfa,
      0x59,
      0x47,
      0xf0,
      0xad,
      0xd4,
      0xa2,
      0xaf,
      0x9c,
      0xa4,
      0x72,
      0xc0,
      0xb7,
      0xfd,
      0x93,
      0x26,
      0x36,
      0x3f,
      0xf7,
      0xcc,
      0x34,
      0xa5,
      0xe5,
      0xf1,
      0x71,
      0xd8,
      0x31,
      0x15,
      0x04,
      0xc7,
      0x23,
      0xc3,
      0x18,
      0x96,
      0x05,
      0x9a,
      0x07,
      0x12,
      0x80,
      0xe2,
      0xeb,
      0x27,
      0xb2,
      0x75,
      0x09,
      0x83,
      0x2c,
      0x1a,
      0x1b,
      0x6e,
      0x5a,
      0xa0,
      0x52,
      0x3b,
      0xd6,
      0xb3,
      0x29,
      0xe3,
      0x2f,
      0x84,
      0x53,
      0xd1,
      0x00,
      0xed,
      0x20,
      0xfc,
      0xb1,
      0x5b,
      0x6a,
      0xcb,
      0xbe,
      0x39,
      0x4a,
      0x4c,
      0x58,
      0xcf,
      0xd0,
      0xef,
      0xaa,
      0xfb,
      0x43,
      0x4d,
      0x33,
      0x85,
      0x45,
      0xf9,
      0x02,
      0x7f,
      0x50,
      0x3c,
      0x9f,
      0xa8,
      0x51,
      0xa3,
      0x40,
      0x8f,
      0x92,
      0x9d,
      0x38,
      0xf5,
      0xbc,
      0xb6,
      0xda,
      0x21,
      0x10,
      0xff,
      0xf3,
      0xd2,
      0xcd,
      0x0c,
      0x13,
      0xec,
      0x5f,
      0x97,
      0x44,
      0x17,
      0xc4,
      0xa7,
      0x7e,
      0x3d,
      0x64,
      0x5d,
      0x19,
      0x73,
      0x60,
      0x81,
      0x4f,
      0xdc,
      0x22,
      0x2a,
      0x90,
      0x88,
      0x46,
      0xee,
      0xb8,
      0x14,
      0xde,
      0x5e,
      0x0b,
      0xdb,
      0xe0,
      0x32,
      0x3a,
      0x0a,
      0x49,
      0x06,
      0x24,
      0x5c,
      0xc2,
      0xd3,
      0xac,
      0x62,
      0x91,
      0x95,
      0xe4,
      0x79,
      0xe7,
      0xc8,
      0x37,
      0x6d,
      0x8d,
      0xd5,
      0x4e,
      0xa9,
      0x6c,
      0x56,
      0xf4,
      0xea,
      0x65,
      0x7a,
      0xae,
      0x08,
      0xba,
      0x78,
      0x25,
      0x2e,
      0x1c,
      0xa6,
      0xb4,
      0xc6,
      0xe8,
      0xdd,
      0x74,
      0x1f,
      0x4b,
      0xbd,
      0x8b,
      0x8a,
      0x70,
      0x3e,
      0xb5,
      0x66,
      0x48,
      0x03,
      0xf6,
      0x0e,
      0x61,
      0x35,
      0x57,
      0xb9,
      0x86,
      0xc1,
      0x1d,
      0x9e,
      0xe1,
      0xf8,
      0x98,
      0x11,
      0x69,
      0xd9,
      0x8e,
      0x94,
      0x9b,
      0x1e,
      0x87,
      0xe9,
      0xce,
      0x55,
      0x28,
      0xdf,
      0x8c,
      0xa1,
      0x89,
      0x0d,
      0xbf,
      0xe6,
      0x42,
      0x68,
      0x41,
      0x99,
      0x2d,
      0x0f,
      0xb0,
      0x54,
      0xbb,
      0x16,
    }

    -- Round constants (Rcon) for key expansion
    --- @type integer[]
    local RCON = {
      0x01,
      0x02,
      0x04,
      0x08,
      0x10,
      0x20,
      0x40,
      0x80,
      0x1b,
      0x36,
    }

    --- @alias AESWord [integer, integer, integer, integer]
    --- @alias AESBlock [integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer]
    --- @alias AESState [AESWord, AESWord, AESWord, AESWord]

    --- Initialize a 4-element AES word with zeros
    --- @return AESWord word Initialized word
    local function create_aes_word()
      --- @type AESWord
      return { 0, 0, 0, 0 }
    end

    --- Initialize a 4x4 AES state array with zeros
    --- @return AESState state Initialized state
    local function create_aes_state()
      --- @type AESState
      return {
        create_aes_word(),
        create_aes_word(),
        create_aes_word(),
        create_aes_word(),
      }
    end

    -- Pre-allocated state array for aes_encrypt_block()
    local aes_state = create_aes_state()

    -- Pre-allocated arrays for mix_columns()
    local mix_a = create_aes_word()
    local mix_b = create_aes_word()

    --- XOR two 4-byte words
    --- @param a AESWord 4-byte array
    --- @param b AESWord 4-byte array
    --- @return AESWord result 4-byte array
    local function xor_words(a, b)
      return {
        bit32_raw_bxor(a[1], b[1]),
        bit32_raw_bxor(a[2], b[2]),
        bit32_raw_bxor(a[3], b[3]),
        bit32_raw_bxor(a[4], b[4]),
      }
    end

    --- Rotate word (circular left shift by 1 byte)
    --- @param word AESWord 4-byte array
    --- @return AESWord result Rotated 4-byte array
    local function rot_word(word)
      return { word[2], word[3], word[4], word[1] }
    end

    --- Apply S-box substitution to a word
    --- @param word AESWord 4-byte array
    --- @return AESWord result Substituted 4-byte array
    local function sub_word(word)
      local s_1 = assert(SBOX[word[1] + 1], "Invalid SBOX index " .. (word[1] + 1))
      local s_2 = assert(SBOX[word[2] + 1], "Invalid SBOX index " .. (word[2] + 1))
      local s_3 = assert(SBOX[word[3] + 1], "Invalid SBOX index " .. (word[3] + 1))
      local s_4 = assert(SBOX[word[4] + 1], "Invalid SBOX index " .. (word[4] + 1))
      return { s_1, s_2, s_3, s_4 }
    end

    --- AES key expansion
    --- @param key string Encryption key (16, 24, or 32 bytes)
    --- @return table expanded_key Array of round keys
    --- @return integer nr Number of rounds
    local function key_expansion(key)
      local key_len = #key
      local nr -- Number of rounds
      local nk -- Number of 32-bit words in key

      if key_len == 16 then
        nr = 10
        nk = 4
      elseif key_len == 24 then
        nr = 12
        nk = 6
      elseif key_len == 32 then
        nr = 14
        nk = 8
      else
        error("Invalid key length. Must be 16, 24, or 32 bytes")
      end

      -- Convert key to words
      --- @type AESState
      local w = {}
      for i = 1, nk do
        w[i] = {
          string_byte(key, (i - 1) * 4 + 1),
          string_byte(key, (i - 1) * 4 + 2),
          string_byte(key, (i - 1) * 4 + 3),
          string_byte(key, (i - 1) * 4 + 4),
        }
      end

      -- Expand key
      for i = nk + 1, 4 * (nr + 1) do
        local temp = w[i - 1]
        local idx = i - 1 -- 0-based index for modulo arithmetic
        if idx % nk == 0 then
          local t = assert(RCON[idx / nk], "Invalid RCON index " .. (idx / nk))
          temp = xor_words(sub_word(rot_word(temp)), { t, 0, 0, 0 })
        elseif nk > 6 and idx % nk == 4 then
          temp = sub_word(temp)
        end
        w[i] = xor_words(w[i - nk], temp)
      end

      return w, nr
    end

    --- MixColumns transformation
    --- @param state AESState 4x4 state matrix
    local function mix_columns(state)
      -- Reuse pre-allocated arrays
      local a = mix_a
      local b = mix_b
      for c = 1, 4 do
        for i = 1, 4 do
          a[i] = state[i][c]
          b[i] = bit32_raw_band(state[i][c], 0x80) ~= 0
              and bit32_raw_bxor(bit32_raw_band(bit32_raw_lshift(state[i][c], 1), 0xFF), 0x1B)
            or bit32_raw_band(bit32_raw_lshift(state[i][c], 1), 0xFF)
        end

        state[1][c] = bit32_raw_bxor(bit32_raw_bxor(bit32_raw_bxor(b[1], a[2]), bit32_raw_bxor(b[2], a[3])), a[4])
        state[2][c] = bit32_raw_bxor(bit32_raw_bxor(bit32_raw_bxor(a[1], b[2]), bit32_raw_bxor(a[3], b[3])), a[4])
        state[3][c] = bit32_raw_bxor(bit32_raw_bxor(bit32_raw_bxor(a[1], a[2]), bit32_raw_bxor(b[3], a[4])), b[4])
        state[4][c] = bit32_raw_bxor(bit32_raw_bxor(bit32_raw_bxor(a[1], b[1]), bit32_raw_bxor(a[2], a[3])), b[4])
      end
    end

    --- SubBytes transformation
    --- @param state AESState 4x4 state matrix
    local function sub_bytes(state)
      for i = 1, 4 do
        for j = 1, 4 do
          local s_index = state[i][j] + 1
          state[i][j] = assert(SBOX[s_index], "Invalid SBOX index " .. s_index)
        end
      end
    end

    --- ShiftRows transformation
    --- @param state AESState 4x4 state matrix
    local function shift_rows(state)
      -- Row 1: no shift
      -- Row 2: shift left by 1
      local temp = state[2][1]
      state[2][1] = state[2][2]
      state[2][2] = state[2][3]
      state[2][3] = state[2][4]
      state[2][4] = temp

      -- Row 3: shift left by 2
      temp = state[3][1]
      state[3][1] = state[3][3]
      state[3][3] = temp
      temp = state[3][2]
      state[3][2] = state[3][4]
      state[3][4] = temp

      -- Row 4: shift left by 3 (or right by 1)
      temp = state[4][4]
      state[4][4] = state[4][3]
      state[4][3] = state[4][2]
      state[4][2] = state[4][1]
      state[4][1] = temp
    end

    --- AddRoundKey transformation
    --- @param state AESState 4x4 state matrix
    --- @param round_key table Round key words
    --- @param round integer Round number
    local function add_round_key(state, round_key, round)
      for c = 1, 4 do
        local key_word = round_key[round * 4 + c]
        for r = 1, 4 do
          state[r][c] = bit32_raw_bxor(state[r][c], key_word[r])
        end
      end
    end

    --- AES block encryption
    --- @param input string 16-byte plaintext block
    --- @param expanded_key table Expanded key
    --- @param nr integer Number of rounds
    --- @return string ciphertext 16-byte encrypted block
    local function aes_encrypt_block(input, expanded_key, nr)
      -- Reuse pre-allocated state array
      local state = aes_state
      for i = 1, 4 do
        for j = 1, 4 do
          state[i][j] = string_byte(input, (j - 1) * 4 + i)
        end
      end

      -- Initial round
      add_round_key(state, expanded_key, 0)

      -- Main rounds
      for round = 1, nr - 1 do
        sub_bytes(state)
        shift_rows(state)
        mix_columns(state)
        add_round_key(state, expanded_key, round)
      end

      -- Final round (no MixColumns)
      sub_bytes(state)
      shift_rows(state)
      add_round_key(state, expanded_key, nr)

      -- Convert state to output (optimized with table)
      local output_bytes = {}
      local idx = 1
      for j = 1, 4 do
        for i = 1, 4 do
          output_bytes[idx] = string_char(state[i][j])
          idx = idx + 1
        end
      end

      return table_concat(output_bytes)
    end

    -- ============================================================================
    -- CCM MODE IMPLEMENTATION
    -- ============================================================================

    --- XOR two byte strings of equal length.
    --- @param a string First string
    --- @param b string Second string
    --- @return string result XOR result
    local function xor_strings(a, b)
      local result = {}
      for i = 1, #a do
        result[i] = string_char(bit32_raw_bxor(string_byte(a, i), string_byte(b, i)))
      end
      return table_concat(result)
    end

    --- Generate CTR counter blocks.
    --- @param nonce string CCM nonce
    --- @param counter integer Counter value (0 for CBC-MAC tag encryption, 1+ for CTR)
    --- @param L integer Size of length field (typically 2 for BTHome)
    --- @return string block 16-byte counter block
    local function generate_counter_block(nonce, counter, L)
      -- Counter block format: [Flags][Nonce][Counter]
      -- Flags = L-1 (for CTR blocks)
      local flags = math_floor(L - 1)

      -- Build counter block
      local block = string_char(flags) .. nonce

      -- Append counter (big-endian, L bytes)
      local counter_bytes = {}
      local temp_counter = counter
      for i = L, 1, -1 do
        counter_bytes[i] = string_char(math_floor(temp_counter % 256))
        temp_counter = math_floor(temp_counter / 256)
      end

      return block .. table_concat(counter_bytes)
    end

    --- Compute CBC-MAC authentication tag.
    --- @param expanded_key table Pre-expanded AES key
    --- @param nr integer Number of rounds
    --- @param nonce string CCM nonce
    --- @param aad string Associated authenticated data (can be empty)
    --- @param plaintext string Plaintext to authenticate
    --- @param M integer Tag length in bytes (4 for BTHome)
    --- @param L integer Length field size (typically 2)
    --- @return string tag Authentication tag (M bytes)
    local function cbc_mac(expanded_key, nr, nonce, aad, plaintext, M, L)
      -- Build B0 block
      -- Flags: [Reserved (1)][Adata (1)][M' (3)][L' (3)]
      -- M' = (M-2)/2, L' = L-1
      local adata_flag = #aad > 0 and 0x40 or 0x00
      local m_field = math_floor((M - 2) / 2) * 8 -- Shift left 3 bits
      local l_field = L - 1

      local flags = math_floor(adata_flag + m_field + l_field)

      -- B0 = Flags || Nonce || Q (message length, L bytes, big-endian)
      local b0 = string_char(flags) .. nonce

      -- Append message length (L bytes, big-endian)
      local msg_len = #plaintext
      local len_bytes = {}
      for i = L, 1, -1 do
        len_bytes[i] = string_char(math_floor(msg_len % 256))
        msg_len = math_floor(msg_len / 256)
      end
      b0 = b0 .. table_concat(len_bytes)

      -- Initialize CBC-MAC with B0
      local y = aes_encrypt_block(b0, expanded_key, nr)

      -- Process AAD if present
      if #aad > 0 then
        local aad_block
        if #aad < 0xFF00 then
          -- Short encoding: 2-byte length prefix
          aad_block = string_char(math_floor(#aad / 256), math_floor(#aad % 256)) .. aad
        else
          error("AAD too long")
        end

        -- Pad AAD to multiple of 16 bytes
        local pad_len = (16 - (#aad_block % 16)) % 16
        aad_block = aad_block .. string_rep("\0", pad_len)

        -- Process AAD blocks
        for i = 1, #aad_block, 16 do
          local block = string_sub(aad_block, i, i + 15)
          y = aes_encrypt_block(xor_strings(y, block), expanded_key, nr)
        end
      end

      -- Process plaintext blocks
      if #plaintext > 0 then
        -- Pad plaintext to multiple of 16 bytes
        local pad_len = (16 - (#plaintext % 16)) % 16
        local padded = plaintext .. string_rep("\0", pad_len)

        for i = 1, #padded, 16 do
          local block = string_sub(padded, i, i + 15)
          y = aes_encrypt_block(xor_strings(y, block), expanded_key, nr)
        end
      end

      -- Return first M bytes as tag
      return string_sub(y, 1, M)
    end

    -- ============================================================================
    -- AEAD INTERFACE
    -- ============================================================================

    --- Encrypt data using AES-CCM.
    --- @param key string 16-byte AES key
    --- @param nonce string CCM nonce (typically 13 bytes for BTHome V2)
    --- @param aad string Associated authenticated data (empty string for BTHome)
    --- @param plaintext string Data to encrypt
    --- @param tag_length integer Authentication tag length (4 bytes for BTHome)
    --- @return string|nil ciphertext Encrypted data with appended tag
    --- @return string|nil error Error message
    function aes_ccm.encrypt(key, nonce, aad, plaintext, tag_length)
      if #key ~= 16 then
        return nil, "key must be 16 bytes"
      end

      local M = math_floor(tag_length or 4)
      local L = 16 - 1 - #nonce -- Compute L from nonce length

      if L < 2 or L > 8 then
        return nil, "invalid nonce length"
      end

      -- Expand key
      local expanded_key, nr = key_expansion(key)

      -- Compute CBC-MAC tag
      local tag = cbc_mac(expanded_key, nr, nonce, aad, plaintext, M, L)

      -- Generate S0 for tag encryption
      local s0 = aes_encrypt_block(generate_counter_block(nonce, 0, L), expanded_key, nr)

      -- Encrypt tag
      local encrypted_tag = xor_strings(tag, string_sub(s0, 1, M))

      -- CTR encrypt plaintext
      local ciphertext = {}
      local block_num = 1

      for i = 1, #plaintext, 16 do
        local block = string_sub(plaintext, i, math_min(i + 15, #plaintext))
        local counter_block = generate_counter_block(nonce, block_num, L)
        local keystream = aes_encrypt_block(counter_block, expanded_key, nr)
        ciphertext[#ciphertext + 1] = xor_strings(block, string_sub(keystream, 1, #block))
        block_num = block_num + 1
      end

      return table_concat(ciphertext) .. encrypted_tag
    end

    --- Decrypt data using AES-CCM.
    --- @param key string 16-byte AES key
    --- @param nonce string CCM nonce
    --- @param aad string Associated authenticated data (empty string for BTHome)
    --- @param ciphertext_and_tag string Encrypted data with appended tag
    --- @param tag_length integer Authentication tag length (4 bytes for BTHome)
    --- @return string|nil plaintext Decrypted data
    --- @return string|nil error Error message (including authentication failure)
    function aes_ccm.decrypt(key, nonce, aad, ciphertext_and_tag, tag_length)
      if #key ~= 16 and #key ~= 24 and #key ~= 32 then
        return nil, "Key must be 16, 24, or 32 bytes"
      end

      local M = math_floor(tag_length or 4)
      local L = 16 - 1 - #nonce

      if L < 2 or L > 8 then
        return nil, "invalid nonce length"
      end

      if #ciphertext_and_tag < M then
        return nil, "ciphertext too short"
      end

      -- Split ciphertext and tag
      local ciphertext_len = #ciphertext_and_tag - M
      local ciphertext = string_sub(ciphertext_and_tag, 1, ciphertext_len)
      local encrypted_tag = string_sub(ciphertext_and_tag, ciphertext_len + 1)

      -- Expand key
      local expanded_key, nr = key_expansion(key)

      -- Generate S0 for tag decryption
      local s0 = aes_encrypt_block(generate_counter_block(nonce, 0, L), expanded_key, nr)

      -- Decrypt tag
      local received_tag = xor_strings(encrypted_tag, string_sub(s0, 1, M))

      -- CTR decrypt ciphertext
      local plaintext = {}
      local block_num = 1

      for i = 1, #ciphertext, 16 do
        local block = string_sub(ciphertext, i, math_min(i + 15, #ciphertext))
        local counter_block = generate_counter_block(nonce, block_num, L)
        local keystream = aes_encrypt_block(counter_block, expanded_key, nr)
        plaintext[#plaintext + 1] = xor_strings(block, string_sub(keystream, 1, #block))
        block_num = block_num + 1
      end

      local plaintext_str = table_concat(plaintext)

      -- Verify CBC-MAC
      local computed_tag = cbc_mac(expanded_key, nr, nonce, aad, plaintext_str, M, L)

      -- Constant-time comparison
      local tag_match = true
      for i = 1, M do
        if string_byte(computed_tag, i) ~= string_byte(received_tag, i) then
          tag_match = false
        end
      end

      if not tag_match then
        return nil, "authentication failed"
      end

      return plaintext_str
    end

    -- ============================================================================
    -- SELF-TEST
    -- ============================================================================

    --- Helper to convert hex string to binary
    --- @param hex string Hex string
    --- @return string binary Binary string
    local function hex_to_bin(hex)
      local bytes = {}
      for i = 1, #hex, 2 do
        bytes[#bytes + 1] = string_char(tonumber(string_sub(hex, i, i + 1), 16) or 0)
      end
      return table_concat(bytes)
    end

    --- Helper to convert binary to hex string
    --- @param bin string Binary string
    --- @return string hex Hex string
    local function bin_to_hex(bin)
      local hex = {}
      for i = 1, #bin do
        hex[#hex + 1] = string_format("%02x", string_byte(bin, i))
      end
      return table_concat(hex)
    end

    --- Run self-tests using NIST and RFC test vectors.
    --- @return boolean success True if all tests passed
    function aes_ccm.selftest()
      print("Testing AES-CCM module...")
      local passed = 0
      local total = 0

      -- ===========================================================================
      -- AES-128 Block Cipher Tests (NIST FIPS-197)
      -- ===========================================================================

      local aes_vectors = {
        {
          name = "NIST FIPS-197 Appendix B",
          key = "2b7e151628aed2a6abf7158809cf4f3c",
          plaintext = "3243f6a8885a308d313198a2e0370734",
          ciphertext = "3925841d02dc09fbdc118597196a0b32",
        },
        {
          name = "All zeros",
          key = "00000000000000000000000000000000",
          plaintext = "00000000000000000000000000000000",
          ciphertext = "66e94bd4ef8a2c3b884cfa59ca342b2e",
        },
        {
          name = "NIST SP 800-38A F.1.1",
          key = "2b7e151628aed2a6abf7158809cf4f3c",
          plaintext = "6bc1bee22e409f96e93d7e117393172a",
          ciphertext = "3ad77bb40d7a3660a89ecaf32466ef97",
        },
      }

      for _, tv in ipairs(aes_vectors) do
        total = total + 1
        local key = hex_to_bin(tv.key)
        local plaintext = hex_to_bin(tv.plaintext)
        local expected_ct = hex_to_bin(tv.ciphertext)

        local expanded_key, nr = key_expansion(key)
        local ciphertext = aes_encrypt_block(plaintext, expanded_key, nr)

        if ciphertext == expected_ct then
          print(string_format("  PASS: AES-128 %s", tv.name))
          passed = passed + 1
        else
          print(string_format("  FAIL: AES-128 %s", tv.name))
          print(string_format("    Expected: %s", tv.ciphertext))
          print(string_format("    Got: %s", bin_to_hex(ciphertext)))
        end
      end

      -- ===========================================================================
      -- AES-CCM Tests (RFC 3610)
      -- ===========================================================================

      local ccm_vectors = {
        {
          name = "RFC 3610 Vector #1",
          key = "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf",
          nonce = "00000003020100a0a1a2a3a4a5", -- 13 bytes
          aad = "0001020304050607",
          plaintext = "08090a0b0c0d0e0f101112131415161718191a1b1c1d1e",
          tag_length = 8,
          ciphertext = "588c979a61c663d2f066d0c2c0f989806d5f6b61dac38417e8d12cfdf926e0",
        },
      }

      for _, tv in ipairs(ccm_vectors) do
        local key = hex_to_bin(tv.key)
        local nonce = hex_to_bin(tv.nonce)
        local aad = hex_to_bin(tv.aad)
        local plaintext = hex_to_bin(tv.plaintext)
        local expected_ct = hex_to_bin(tv.ciphertext)

        -- Test encryption
        total = total + 1
        local ciphertext, err = aes_ccm.encrypt(key, nonce, aad, plaintext, tv.tag_length)
        if ciphertext and ciphertext == expected_ct then
          print(string_format("  PASS: CCM %s (encrypt)", tv.name))
          passed = passed + 1
        else
          print(string_format("  FAIL: CCM %s (encrypt)", tv.name))
          if err then
            print(string_format("    Error: %s", err))
          else
            print(string_format("    Expected: %s", tv.ciphertext))
            print(string_format("    Got: %s", ciphertext and bin_to_hex(ciphertext) or "nil"))
          end
        end

        -- Test decryption
        total = total + 1
        local decrypted, derr = aes_ccm.decrypt(key, nonce, aad, expected_ct, tv.tag_length)
        if decrypted and decrypted == plaintext then
          print(string_format("  PASS: CCM %s (decrypt)", tv.name))
          passed = passed + 1
        else
          print(string_format("  FAIL: CCM %s (decrypt)", tv.name))
          print(string_format("    Error: %s", derr or "decrypted data mismatch"))
        end
      end

      -- ===========================================================================
      -- Functional Tests
      -- ===========================================================================

      -- Roundtrip encryption/decryption
      total = total + 1
      local rt_key = hex_to_bin("231d39c1d7cc1ab1aee224cd096db932")
      local rt_nonce = hex_to_bin("aabbccddeeff00112233") -- 10 bytes -> L=5
      local rt_plaintext = hex_to_bin("48656c6c6f20576f726c6421") -- "Hello World!"

      local rt_ct, rt_err = aes_ccm.encrypt(rt_key, rt_nonce, "", rt_plaintext, 4)
      if rt_ct then
        local rt_dec = aes_ccm.decrypt(rt_key, rt_nonce, "", rt_ct, 4)
        if rt_dec and rt_dec == rt_plaintext then
          print("  PASS: Roundtrip encryption/decryption")
          passed = passed + 1
        else
          print("  FAIL: Roundtrip decryption")
          print("    Decryption did not match original plaintext")
        end
      else
        print("  FAIL: Roundtrip encryption")
        print(string_format("    Error: %s", rt_err or "unknown"))
      end

      -- Authentication failure on tampered data
      total = total + 1
      if rt_ct then
        local tampered = string_sub(rt_ct, 1, 1)
          .. string_char((string_byte(rt_ct, 2) + 1) % 256)
          .. string_sub(rt_ct, 3)
        local _, tamper_err = aes_ccm.decrypt(rt_key, rt_nonce, "", tampered, 4)
        if tamper_err and tamper_err:find("authentication") then
          print("  PASS: Tampered data rejected")
          passed = passed + 1
        else
          print("  FAIL: Tampered data should be rejected")
          print(string_format("    Error: %s", tamper_err or "no error returned"))
        end
      else
        print("  SKIP: Tampered data test (roundtrip encryption failed)")
      end

      print(string_format("\nAES-CCM module: %d/%d tests passed\n", passed, total))
      return passed == total
    end

    return aes_ccm
  end
end

do
  local _ENV = _ENV
  package.preload["bthome.event"] = function(...)
    local arg = _G.arg
    --- @module "bthome.event"
    --- BTHome button and dimmer event definitions.
    --- Provides decoding for button presses and dimmer rotations.
    --- @see https://bthome.io/format
    --- @class bthome.event
    local event = {}

    --- @class BTHomeButtonEvent
    --- @field raw_value integer Raw event byte value
    --- @field event_type integer Event type code
    --- @field event_name string Event name ("press", "double_press", "long_press", etc.)
    --- @field device_number integer|nil Device/button number for multi-button devices

    --- @class BTHomeDimmerEvent
    --- @field raw_value integer Raw 2-byte value (little-endian: event_type in low byte, steps in high byte)
    --- @field event_type integer Event type code (0=none, 1=rotate_left, 2=rotate_right)
    --- @field event_name string Event name ("none", "rotate_left", or "rotate_right")
    --- @field steps integer Number of rotation steps

    --- Button event types.
    --- The event value encodes both the event type (high nibble) and button number (low nibble).
    --- Event value format: [event_type (4 bits)][device_number (4 bits)]
    --- For single-button devices, device_number is typically 0.
    --- @enum BTHomeButtonEventType
    event.BUTTON = {
      NONE = 0x00,
      PRESS = 0x01,
      DOUBLE_PRESS = 0x02,
      TRIPLE_PRESS = 0x03,
      LONG_PRESS = 0x04,
      LONG_DOUBLE_PRESS = 0x05,
      LONG_TRIPLE_PRESS = 0x06,
      HOLD_PRESS = 0x80,
    }

    --- Button event names indexed by event type.
    --- @type table<integer, string?>
    event.BUTTON_NAMES = {
      [0x00] = "none",
      [0x01] = "press",
      [0x02] = "double_press",
      [0x03] = "triple_press",
      [0x04] = "long_press",
      [0x05] = "long_double_press",
      [0x06] = "long_triple_press",
      [0x80] = "hold_press",
    }

    --- Dimmer event types.
    --- The dimmer event uses 2 bytes: [event_type][steps]
    --- Event type: 0 = none, 1 = rotate left (counter-clockwise), 2 = rotate right (clockwise)
    --- Steps: number of rotation steps (0-255)
    --- @enum BTHomeDimmerEventType
    event.DIMMER = {
      NONE = 0x00,
      ROTATE_LEFT = 0x01, -- Counter-clockwise
      ROTATE_RIGHT = 0x02, -- Clockwise
    }

    --- Dimmer event names indexed by event type.
    --- @type table<integer, string?>
    event.DIMMER_NAMES = {
      [0x00] = "none",
      [0x01] = "rotate_left",
      [0x02] = "rotate_right",
    }

    --- Decode a button event byte.
    --- @param value integer The raw event byte value
    --- @return BTHomeButtonEvent result Decoded button event with device_number and event_type
    function event.decode_button(value)
      -- For button events with device numbers (multi-button devices):
      -- High nibble = event type, Low nibble = device number
      -- However, most implementations use the full byte as event type
      -- with separate multi-button handling via multiple object instances.

      local event_type = value
      local device_number = nil

      -- Check if this is a device-number encoded event (values > 0x06 except 0x80)
      if value > 0x06 and value ~= 0x80 then
        -- Multi-button event: low nibble is device number, high nibble is event type
        device_number = value % 0x10
        event_type = math.floor(value / 0x10) * 0x10
        if event_type == 0 then
          event_type = value -- Fall back to treating entire value as event type
          device_number = nil
        end
      end

      local event_name = event.BUTTON_NAMES[event_type] or "unknown"

      return {
        raw_value = value,
        event_type = event_type,
        event_name = event_name,
        device_number = device_number,
      }
    end

    --- Decode a dimmer event value.
    --- The format is 2 bytes: [event_type][steps], read as little-endian uint16.
    --- Low byte = event_type (0=none, 1=rotate_left, 2=rotate_right)
    --- High byte = steps (number of rotation steps)
    --- @param value integer The raw 2-byte dimmer value (as little-endian uint16)
    --- @return BTHomeDimmerEvent result Decoded dimmer event with event_type and steps
    function event.decode_dimmer(value)
      -- Value is read as little-endian uint16: low byte = event_type, high byte = steps
      local event_type = value % 256
      local steps = math.floor(value / 256)

      return {
        raw_value = value,
        event_type = event_type,
        event_name = event.DIMMER_NAMES[event_type] or "unknown",
        steps = steps,
      }
    end

    --- Decode an event based on the event type.
    --- @param event_type string The event type ("button" or "dimmer")
    --- @param value integer The raw event value
    --- @return BTHomeButtonEvent|BTHomeDimmerEvent result Decoded event
    function event.decode(event_type, value)
      if event_type == "button" then
        return event.decode_button(value)
      elseif event_type == "dimmer" then
        return event.decode_dimmer(value)
      else
        -- Return button-like structure for unknown event types
        return {
          raw_value = value,
          event_type = value,
          event_name = "unknown",
          device_number = nil,
        }
      end
    end

    --- Run self-tests.
    --- @return boolean success True if all tests passed
    function event.selftest()
      print("Testing event module...")
      local passed = 0
      local total = 0

      -- ===========================================================================
      -- Button Event Decoding Tests
      -- ===========================================================================

      local button_tests = {
        { value = 0x00, expected_name = "none" },
        { value = 0x01, expected_name = "press" },
        { value = 0x02, expected_name = "double_press" },
        { value = 0x03, expected_name = "triple_press" },
        { value = 0x04, expected_name = "long_press" },
        { value = 0x80, expected_name = "hold_press" },
      }

      for _, test in ipairs(button_tests) do
        total = total + 1
        local result = event.decode_button(test.value)
        if result.event_name == test.expected_name then
          print(string.format("  PASS: Button 0x%02X = %s", test.value, test.expected_name))
          passed = passed + 1
        else
          print(string.format("  FAIL: Button 0x%02X", test.value))
          print(string.format("    Expected: %s", test.expected_name))
          print(string.format("    Got: %s", result.event_name))
        end
      end

      -- ===========================================================================
      -- Dimmer Event Decoding Tests
      -- ===========================================================================

      -- Dimmer format: 2 bytes [event_type][steps] read as little-endian uint16
      -- So value = event_type + (steps * 256)
      local dimmer_tests = {
        { value = 0x0000, expected_name = "none", expected_steps = 0 }, -- event_type=0, steps=0
        { value = 0x0301, expected_name = "rotate_left", expected_steps = 3 }, -- event_type=1, steps=3
        { value = 0x0501, expected_name = "rotate_left", expected_steps = 5 }, -- event_type=1, steps=5
        { value = 0x0102, expected_name = "rotate_right", expected_steps = 1 }, -- event_type=2, steps=1
        { value = 0x0A02, expected_name = "rotate_right", expected_steps = 10 }, -- event_type=2, steps=10
      }

      for _, test in ipairs(dimmer_tests) do
        total = total + 1
        local result = event.decode_dimmer(test.value)
        if result.event_name == test.expected_name and result.steps == test.expected_steps then
          print(
            string.format("  PASS: Dimmer 0x%04X = %s, %d steps", test.value, test.expected_name, test.expected_steps)
          )
          passed = passed + 1
        else
          print(string.format("  FAIL: Dimmer 0x%04X", test.value))
          print(string.format("    Expected: %s, %d steps", test.expected_name, test.expected_steps))
          print(string.format("    Got: %s, %d steps", result.event_name, result.steps))
        end
      end

      print(string.format("\nevent module: %d/%d tests passed\n", passed, total))
      return passed == total
    end

    return event
  end
end

do
  local _ENV = _ENV
  package.preload["bthome.parser"] = function(...)
    local arg = _G.arg
    --- @module "bthome.parser"
    --- BTHome BLE advertisement parser.
    --- Parses both V1 and V2 BTHome advertisements, including encrypted payloads.
    --- @see https://bthome.io/format
    ---
    --- @class bthome.parser
    local parser = {}

    --- BTHome V1 unencrypted service UUID.
    --- @type integer
    parser.UUID_V1_UNENCRYPTED = 0x181C
    --- BTHome V1 encrypted service UUID.
    --- @type integer
    parser.UUID_V1_ENCRYPTED = 0x181E
    --- BTHome V2 service UUID.
    --- @type integer
    parser.UUID_V2 = 0xFCD2

    --- @class BTHomeDeviceInfo
    --- @field encrypted boolean True if the advertisement is encrypted
    --- @field trigger_based boolean True if this is a trigger-based device (buttons, events)
    --- @field version integer BTHome version (1 or 2)

    --- @class BTHomeReading
    --- @field name string Sensor name (e.g., "temperature", "humidity", "button")
    --- @field value integer|number|string The sensor value (scaled by factor)
    --- @field unit string|nil Unit of measurement (e.g., "°C", "%", nil)
    --- @field id integer Object ID from the BTHome specification
    --- @field instance integer Instance number for duplicate sensors (starts at 1)
    --- @field event BTHomeButtonEvent|BTHomeDimmerEvent|nil Decoded event data (for button/dimmer only)

    --- @class BTHomeParseResult
    --- @field device_info BTHomeDeviceInfo Parsed device information
    --- @field packet_id integer|nil Packet counter (if present in advertisement)
    --- @field readings BTHomeReading[] Array of sensor readings

    local const = require("bthome.const")
    local event = require("bthome.event")
    local crypto = require("bthome.crypto")

    --- Read a little-endian unsigned integer from a string.
    --- @param data string Input bytes
    --- @param offset integer Starting offset (1-based)
    --- @param length integer Number of bytes to read
    --- @return integer value Unsigned integer value
    local function read_uint_le(data, offset, length)
      local value = 0
      local multiplier = 1
      for i = 0, length - 1 do
        value = value + string.byte(data, offset + i) * multiplier
        multiplier = multiplier * 256
      end
      return value
    end

    --- Read a little-endian signed integer from a string.
    --- @param data string Input bytes
    --- @param offset integer Starting offset (1-based)
    --- @param length integer Number of bytes to read
    --- @return integer value Signed integer value
    local function read_sint_le(data, offset, length)
      local value = read_uint_le(data, offset, length)
      local max_positive = math.floor(2 ^ (length * 8 - 1))
      if value >= max_positive then
        return math.floor(value - 2 ^ (length * 8))
      end
      return value
    end

    --- Build nonce for BTHome V1 encrypted advertisements.
    --- Nonce format (12 bytes): MAC (6) || UUID16 (2 LE) || counter (4 LE)
    --- @param mac string 6-byte MAC address
    --- @param uuid integer UUID (0x181E for BTHome V1 encrypted)
    --- @param counter integer 32-bit counter
    --- @return string nonce 12-byte nonce
    local function build_v1_nonce(mac, uuid, counter)
      return mac
        .. string.char(uuid % 256, math.floor(uuid / 256))
        .. string.char(
          counter % 256,
          math.floor(counter / 256) % 256,
          math.floor(counter / 65536) % 256,
          math.floor(counter / 16777216) % 256
        )
    end

    --- Build nonce for BTHome V2 encrypted advertisements.
    --- Nonce format (13 bytes): MAC (6) || UUID (2 LE) || device_info (1) || counter (4 LE)
    --- @param mac string 6-byte MAC address
    --- @param uuid integer UUID (typically 0xFCD2 for BTHome)
    --- @param device_info integer Device info byte
    --- @param counter integer 32-bit counter
    --- @return string nonce 13-byte nonce
    local function build_v2_nonce(mac, uuid, device_info, counter)
      return mac
        .. string.char(uuid % 256, math.floor(uuid / 256))
        .. string.char(device_info)
        .. string.char(
          counter % 256,
          math.floor(counter / 256) % 256,
          math.floor(counter / 65536) % 256,
          math.floor(counter / 16777216) % 256
        )
    end

    --- Parse the device info byte to extract flags and version.
    --- @param device_info integer Device info byte
    --- @return BTHomeDeviceInfo info Parsed device info
    local function parse_device_info(device_info)
      local encrypted = (device_info % 2) == 1
      local trigger_based = (math.floor(device_info / 4) % 2) == 1
      local version = math.floor(device_info / 32)

      return {
        encrypted = encrypted,
        trigger_based = trigger_based,
        version = version,
      }
    end

    --- Read a value based on format type.
    --- @param data string Raw data
    --- @param offset integer Starting offset (1-based)
    --- @param format string Format type (uint8, sint8, uint16, etc.)
    --- @param length integer Byte length
    --- @return number|integer|string|nil value Parsed value
    --- @return integer bytes_consumed Number of bytes consumed
    local function read_value(data, offset, format, length)
      if offset + length - 1 > #data then
        return nil, 0
      end

      if format == "string" then
        -- Variable length: first byte is length
        local str_len = string.byte(data, offset)
        if offset + str_len > #data then
          return nil, 0
        end
        return data:sub(offset + 1, offset + str_len), str_len + 1
      elseif format == "mac" then
        return data:sub(offset, offset + length - 1), length
      elseif format:sub(1, 4) == "uint" then
        return read_uint_le(data, offset, length), length
      elseif format:sub(1, 4) == "sint" then
        return read_sint_le(data, offset, length), length
      else
        return read_uint_le(data, offset, length), length
      end
    end

    --- Parse firmware version bytes into a version string.
    --- Bytes are read in little-endian order and formatted as "major.minor.patch[.build]"
    --- @param data string Raw data
    --- @param offset integer Starting offset (1-based)
    --- @param length integer Number of bytes (3 or 4)
    --- @return string version Version string (e.g., "1.2.3" or "1.2.3.4")
    local function parse_firmware_version(data, offset, length)
      local parts = {}
      -- Read bytes in reverse order (little-endian: LSB first, but version is MSB first)
      for i = length, 1, -1 do
        parts[#parts + 1] = tostring(string.byte(data, offset + i - 1))
      end
      return table.concat(parts, ".")
    end

    --- Parse V2 BTHome payload (object IDs followed by values).
    --- @param payload string Payload data (after device info byte)
    --- @param start_offset integer Starting offset in payload (1-based)
    --- @return BTHomeReading[]|nil readings Array of parsed readings
    --- @return integer|nil packet_id Packet ID if present
    --- @return string|nil error Error message if parsing failed
    local function parse_v2_payload(payload, start_offset)
      local readings = {}
      local packet_id = nil
      local pos = start_offset

      while pos <= #payload do
        -- Read object ID
        local object_id = string.byte(payload, pos)
        pos = pos + 1

        -- Look up object definition
        local obj_def = const.get_object(object_id)
        if not obj_def then
          return nil, nil, string.format("unknown object ID: 0x%02X at position %d", object_id, pos - 1)
        end

        -- Handle variable-length fields
        local length = obj_def.length
        if length == 0 then
          -- Variable length: first byte is length
          if pos > #payload then
            return nil, nil, "truncated variable-length field"
          end
          length = string.byte(payload, pos) + 1 -- Include length byte
        end

        -- Read value
        local value, consumed = read_value(payload, pos, obj_def.format, length)
        if value == nil then
          return nil, nil, string.format("truncated data for object 0x%02X", object_id)
        end
        pos = pos + consumed

        -- Handle special object types
        if object_id == 0x00 and type(value) == "number" then
          -- Packet ID (always uint8)
          packet_id = math.floor(value)
        elseif object_id == 0xF1 or object_id == 0xF2 then
          -- Firmware version: parse as version string instead of raw integer
          local fw_version = parse_firmware_version(payload, pos - consumed, consumed)
          readings[#readings + 1] = {
            name = obj_def.name,
            value = fw_version,
            unit = obj_def.unit,
            id = object_id,
          }
        elseif obj_def.is_event and type(value) ~= "string" then
          -- Event (button, dimmer)
          local event_data = event.decode(obj_def.name, math.floor(value))
          readings[#readings + 1] = {
            name = obj_def.name,
            value = value,
            unit = obj_def.unit,
            id = object_id,
            event = event_data,
          }
        else
          -- Regular sensor reading: apply scaling factor
          if type(value) == "number" and obj_def.factor ~= 1 then
            value = value * obj_def.factor
          end
          readings[#readings + 1] = {
            name = obj_def.name,
            value = value,
            unit = obj_def.unit,
            id = object_id,
          }
        end
      end

      return readings, packet_id
    end

    --- Parse V1 BTHome payload (legacy format).
    --- V1 format per object (from bthome-ble):
    ---   Byte 0: Control byte (bits 0-4 = data length incl type byte, bits 5-7 = format type)
    ---   Byte 1: Object/measurement type (same IDs as V2)
    ---   Bytes 2+: Data value
    --- @param payload string Payload data
    --- @param start_offset integer Starting offset
    --- @return BTHomeReading[]|nil readings Array of parsed readings
    --- @return integer|nil packet_id Packet ID if present
    --- @return string|nil error Error message
    local function parse_v1_payload(payload, start_offset)
      local readings = {}
      local packet_id = nil
      local pos = start_offset

      while pos <= #payload do
        -- Read control byte
        local control_byte = string.byte(payload, pos)
        local data_length_with_type = control_byte % 32 -- bits 0-4: length including type byte
        local format_type = math.floor(control_byte / 32) -- bits 5-7: format type

        -- Need at least control byte + type byte
        if pos + 1 > #payload then
          return nil, nil, "truncated V1 payload: missing type byte"
        end

        -- Read object type (same as V2 object IDs)
        local object_id = string.byte(payload, pos + 1)

        -- Calculate positions
        -- data_length_with_type includes the type byte, so actual data length = data_length_with_type - 1
        -- next_obj = pos + data_length_with_type + 1 (the +1 is for control byte)
        local actual_data_length = data_length_with_type - 1
        local data_start = pos + 2
        local next_pos = pos + data_length_with_type + 1

        if actual_data_length < 1 then
          return nil, nil, string.format("invalid V1 data length for object 0x%02X", object_id)
        end

        if data_start + actual_data_length - 1 > #payload then
          return nil, nil, string.format("truncated V1 data for object 0x%02X", object_id)
        end

        -- Get format info for reading the value
        local v1_format = const.V1_FORMATS[format_type]
        if not v1_format then
          return nil, nil, string.format("unknown V1 format type: %d", format_type)
        end

        -- Read value using actual data length
        local value, _ = read_value(payload, data_start, v1_format.format, actual_data_length)
        if value == nil then
          return nil, nil, string.format("failed to read V1 data for object 0x%02X", object_id)
        end

        -- Look up object definition (V1 uses same object IDs as V2)
        local obj_def = const.get_object(object_id)
        local name = obj_def and obj_def.name or string.format("sensor_%d", object_id)
        local factor = obj_def and obj_def.factor or 1
        local unit = obj_def and obj_def.unit or nil

        -- Apply scaling
        if type(value) == "number" and factor ~= 1 then
          value = value * factor
        end

        if object_id == 0 and type(value) == "number" then
          packet_id = math.floor(value)
        else
          readings[#readings + 1] = {
            name = name,
            value = value,
            unit = unit,
            id = object_id,
          }
        end

        pos = next_pos
      end

      return readings, packet_id
    end

    --- Post-process readings to assign instance numbers for duplicate names.
    --- When the same sensor name appears multiple times, each gets an instance number starting at 1.
    --- Example: temperature (instance=1), temperature (instance=2), temperature (instance=3)
    --- @param readings BTHomeReading[] Array of readings to process
    local function assign_instance_numbers(readings)
      local name_counts = {}

      for _, reading in ipairs(readings) do
        local name = reading.name
        if name_counts[name] then
          name_counts[name] = name_counts[name] + 1
        else
          name_counts[name] = 1
        end
        reading.instance = name_counts[name]
      end
    end

    --- Decrypt an encrypted BTHome V1 advertisement.
    --- V1 encrypted format: [ciphertext][counter (4 bytes)][MIC (4 bytes)]
    --- V1 uses UUID 0x181E and AAD = 0x11
    --- @param encrypted_payload string Encrypted service data
    --- @param bind_key string 16-byte encryption key
    --- @param mac_address string 6-byte MAC address
    --- @return string|nil decrypted Decrypted payload
    --- @return string|nil error Error message
    local function decrypt_v1(encrypted_payload, bind_key, mac_address)
      -- Encrypted V1 format:
      -- [ciphertext][counter (4 bytes)][MIC (4 bytes)]

      if #encrypted_payload < 8 then
        return nil, "encrypted payload too short"
      end

      -- Calculate 1-indexed positions for MIC and counter
      local mic_start = #encrypted_payload - 4 + 1 -- First byte of MIC
      local counter_start = mic_start - 4 -- First byte of counter

      local counter = read_uint_le(encrypted_payload, counter_start, 4)

      -- Build nonce for V1: MAC (6) + UUID16 (2) + counter (4) = 12 bytes
      -- V1 encrypted uses UUID 0x181E
      local nonce = build_v1_nonce(mac_address, 0x181E, counter)

      -- V1 uses AAD = 0x11 (single byte)
      local aad = string.char(0x11)

      -- Decrypt (ciphertext + MIC, excluding counter bytes)
      local ciphertext_with_mic = encrypted_payload:sub(1, counter_start - 1) .. encrypted_payload:sub(mic_start)

      local plaintext, err = crypto.aes_ccm.decrypt(bind_key, nonce, aad, ciphertext_with_mic, 4)
      if not plaintext then
        return nil, "decryption failed: " .. (err or "unknown error")
      end

      return plaintext
    end

    --- Decrypt an encrypted BTHome V2 advertisement.
    --- @param encrypted_payload string Encrypted portion of service data
    --- @param bind_key string 16-byte encryption key
    --- @param mac_address string 6-byte MAC address
    --- @param device_info integer Device info byte
    --- @return string|nil decrypted Decrypted payload
    --- @return string|nil error Error message
    local function decrypt_v2(encrypted_payload, bind_key, mac_address, device_info)
      -- Encrypted V2 format:
      -- [encrypted data][counter (4 bytes)][MIC (4 bytes)]

      if #encrypted_payload < 8 then
        return nil, "encrypted payload too short"
      end

      -- Calculate 1-indexed positions for MIC and counter
      local mic_start = #encrypted_payload - 4 + 1 -- First byte of MIC
      local counter_start = mic_start - 4 -- First byte of counter

      local counter = read_uint_le(encrypted_payload, counter_start, 4)

      -- Build nonce for V2
      local nonce = build_v2_nonce(mac_address, 0xFCD2, device_info, counter)

      -- Decrypt (ciphertext + MIC, excluding counter bytes)
      local ciphertext_with_mic = encrypted_payload:sub(1, counter_start - 1) .. encrypted_payload:sub(mic_start)

      local plaintext, err = crypto.aes_ccm.decrypt(bind_key, nonce, "", ciphertext_with_mic, 4)
      if not plaintext then
        return nil, "decryption failed: " .. (err or "unknown error")
      end

      return plaintext
    end

    --- Parse a BTHome BLE advertisement.
    --- Supports both V1 and V2 formats, encrypted and unencrypted.
    ---
    --- The service UUID determines the format:
    --- - 0x181C (UUID_V1_UNENCRYPTED): V1 unencrypted
    --- - 0x181E (UUID_V1_ENCRYPTED): V1 encrypted (requires bind_key and mac_address)
    --- - 0xFCD2 (UUID_V2): V2 format (device_info byte determines encryption)
    ---
    --- @param uuid integer Service UUID (0x181C, 0x181E, or 0xFCD2)
    --- @param service_data string Raw service data bytes from BLE advertisement
    --- @param bind_key string|nil 16-byte encryption key (required for encrypted ads)
    --- @param mac_address string|nil 6-byte MAC address (required for encrypted ads)
    --- @return BTHomeParseResult|nil result Parsed result with device_info, packet_id, and readings
    --- @return string|nil error Error message if parsing failed
    function parser.parse(uuid, service_data, bind_key, mac_address)
      if not service_data or #service_data < 1 then
        return nil, "empty service data"
      end

      local device_info
      local payload
      local readings, packet_id, err

      -- V1 unencrypted (UUID 0x181C)
      if uuid == parser.UUID_V1_UNENCRYPTED then
        readings, packet_id, err = parse_v1_payload(service_data, 1)
        if not readings then
          return nil, err
        end

        device_info = {
          encrypted = false,
          trigger_based = false,
          version = 1,
        }

        assign_instance_numbers(readings)

        return {
          device_info = device_info,
          packet_id = packet_id,
          readings = readings,
        }
      end

      -- V1 encrypted (UUID 0x181E)
      if uuid == parser.UUID_V1_ENCRYPTED then
        if not bind_key then
          return nil, "bind_key required for encrypted advertisement"
        end
        if not mac_address then
          return nil, "MAC address required for encrypted advertisement"
        end
        if #bind_key ~= 16 then
          return nil, "bind_key must be 16 bytes"
        end
        if #mac_address ~= 6 then
          return nil, "MAC address must be 6 bytes"
        end

        local decrypted
        decrypted, err = decrypt_v1(service_data, bind_key, mac_address)
        if not decrypted then
          return nil, err
        end

        -- V1 encrypted payloads use V1 format internally
        readings, packet_id, err = parse_v1_payload(decrypted, 1)
        if not readings then
          return nil, err
        end

        device_info = {
          encrypted = true,
          trigger_based = false,
          version = 1,
        }

        assign_instance_numbers(readings)

        return {
          device_info = device_info,
          packet_id = packet_id,
          readings = readings,
        }
      end

      -- V2 (UUID 0xFCD2)
      if uuid ~= parser.UUID_V2 then
        return nil, string.format("unknown BTHome service UUID: 0x%04X", uuid)
      end

      -- Parse device info byte (first byte)
      local device_info_byte = string.byte(service_data, 1)
      device_info = parse_device_info(device_info_byte)

      -- Validate version in device_info byte
      if device_info.version ~= 2 then
        return nil, string.format("invalid BTHome V2 device_info version: %d", device_info.version)
      end

      payload = service_data:sub(2)

      if device_info.encrypted then
        -- Handle encrypted payload
        if not bind_key then
          return nil, "bind_key required for encrypted advertisement"
        end
        if not mac_address then
          return nil, "MAC address required for encrypted advertisement"
        end
        if #bind_key ~= 16 then
          return nil, "bind_key must be 16 bytes"
        end
        if #mac_address ~= 6 then
          return nil, "MAC address must be 6 bytes"
        end

        local decrypted
        decrypted, err = decrypt_v2(payload, bind_key, mac_address, device_info_byte)
        if not decrypted then
          return nil, err
        end

        payload = decrypted
      end

      -- Parse V2 payload
      readings, packet_id, err = parse_v2_payload(payload, 1)
      if not readings then
        return nil, err
      end

      -- Assign instance numbers for duplicate sensors (instance=1, instance=2, etc.)
      assign_instance_numbers(readings)

      return {
        device_info = device_info,
        packet_id = packet_id,
        readings = readings,
      }
    end

    --- Run self-tests.
    --- Test vectors derived from bthome-ble Python reference implementation.
    --- @see https://github.com/Bluetooth-Devices/bthome-ble
    --- @return boolean success True if all tests passed
    function parser.selftest()
      print("Testing parser module...")
      local passed = 0
      local total = 0

      -- Helper to convert hex string to binary
      local function hex_to_bin(hex)
        local bytes = {}
        for i = 1, #hex, 2 do
          local byte = tonumber(hex:sub(i, i + 1), 16) or 0
          bytes[#bytes + 1] = string.char(byte)
        end
        return table.concat(bytes)
      end

      -- Helper to check a single reading value
      local function check_reading(result, name, expected, tolerance)
        tolerance = tolerance or 0.01
        for _, reading in ipairs(result.readings) do
          if reading.name == name then
            if type(expected) == "number" then
              return math.abs(reading.value - expected) < tolerance
            else
              return reading.value == expected
            end
          end
        end
        return false
      end

      -- Helper to run a simple V2 parse test (most common case)
      local function run_test(test_name, hex_data, checks)
        total = total + 1
        local data = hex_to_bin(hex_data)
        local result, err = parser.parse(parser.UUID_V2, data)
        if result then
          local all_ok = true
          for name, expected in pairs(checks) do
            if not check_reading(result, name, expected) then
              all_ok = false
              print(string.format("  FAIL: %s", test_name))
              print(string.format("    Expected %s: %s", name, tostring(expected)))
              print("    Got readings:")
              for _, r in ipairs(result.readings) do
                print(string.format("      %s = %s", r.name, tostring(r.value)))
              end
              break
            end
          end
          if all_ok then
            print(string.format("  PASS: %s", test_name))
            passed = passed + 1
            return true
          end
        else
          print(string.format("  FAIL: %s", test_name))
          print(string.format("    Error: %s", err or "unknown"))
        end
        return false
      end

      -- ===========================================================================
      -- V2 Basic Sensor Tests (from bthome-ble test_parser_v2.py)
      -- ===========================================================================

      -- Temperature + Humidity (official test vector)
      -- 40 02 ca 09 03 bf 13 -> temp=25.06, humidity=50.55
      run_test("V2 temperature+humidity", "4002ca0903bf13", { temperature = 25.06, humidity = 50.55 })

      -- Pressure: 40 04 13 8a 01 -> 1008.83 mbar
      run_test("V2 pressure", "4004138a01", { pressure = 1008.83 })

      -- Illuminance: 40 05 13 8a 14 -> 13460.67 lux
      run_test("V2 illuminance", "4005138a14", { illuminance = 13460.67 })

      -- Mass (kg): 40 06 5e 1f -> 80.30 kg
      run_test("V2 mass_kg", "40065e1f", { mass_kg = 80.30 })

      -- Mass (lb): 40 07 3e 1d -> 74.86 lb
      run_test("V2 mass_lb", "40073e1d", { mass_lb = 74.86 })

      -- Dew point: 40 08 ca 06 -> 17.38 °C
      run_test("V2 dewpoint", "4008ca06", { dewpoint = 17.38 })

      -- Count: 40 09 60 -> 96
      run_test("V2 count", "400960", { count = 96 })

      -- Energy: 40 0a 13 8a 14 -> 1346.067 kWh
      run_test("V2 energy", "400a138a14", { energy = 1346.067 })

      -- Power: 40 0b 02 1b 00 -> 69.14 W
      run_test("V2 power", "400b021b00", { power = 69.14 })

      -- Voltage: 40 0c 02 0c -> 3.074 V
      run_test("V2 voltage", "400c020c", { voltage = 3.074 })

      -- PM2.5 + PM10: 40 0d 12 0c 0e 02 1c -> PM2.5=3090, PM10=7170
      run_test("V2 PM sensors", "400d120c0e021c", { pm2_5 = 3090, pm10 = 7170 })

      -- CO2: 40 12 e2 04 -> 1250 ppm
      run_test("V2 CO2", "4012e204", { co2 = 1250 })

      -- TVOC: 40 13 33 01 -> 307 µg/m³
      run_test("V2 TVOC", "40133301", { tvoc = 307 })

      -- Moisture: 40 14 02 0c -> 30.74 %
      run_test("V2 moisture", "4014020c", { moisture = 30.74 })

      -- Battery: 40 01 64 -> 100%
      run_test("V2 battery", "400164", { battery = 100 })

      -- ===========================================================================
      -- V2 Boolean Sensor Tests
      -- ===========================================================================

      -- Generic boolean: 40 0f 01 -> true
      run_test("V2 generic_boolean", "400f01", { generic_boolean = 1 })

      -- Power on: 40 10 01 -> true
      run_test("V2 power_on", "401001", { power_on = 1 })

      -- Opening: 40 11 00 -> false (closed)
      run_test("V2 opening closed", "401100", { opening = 0 })

      -- Opening: 40 11 01 -> true (open)
      run_test("V2 opening open", "401101", { opening = 1 })

      -- Motion: 40 21 01 -> detected (0x21 = motion)
      run_test("V2 motion", "402101", { motion = 1 })

      -- Smoke: 40 29 01 -> detected (0x29 = smoke_detected)
      run_test("V2 smoke_detected", "402901", { smoke_detected = 1 })

      -- Tamper: 40 2B 01 -> detected (0x2B = tamper)
      run_test("V2 tamper", "402B01", { tamper = 1 })

      -- ===========================================================================
      -- V2 Extended Numeric Sensors
      -- ===========================================================================

      -- Current: 40 43 4e 34 -> 13.39 A (0x344E = 13390, * 0.001)
      run_test("V2 current", "40434e34", { current = 13.390 })

      -- Speed: 40 44 4e 34 -> 133.90 m/s (0x344E = 13390, * 0.01)
      run_test("V2 speed", "40444e34", { speed = 133.90 })

      -- Temperature 0x45 (sint16, factor 0.1): 40 45 11 01 -> 27.3 °C (0x0111 = 273, * 0.1)
      run_test("V2 temperature 0x45", "40451101", { temperature = 27.3 })

      -- Temperature 0x57 (sint8, factor 1): 40 57 11 -> 17 °C
      run_test("V2 temperature 0x57", "405711", { temperature = 17 })

      -- UV Index: 40 46 32 -> 5.0 (0x32 = 50, * 0.1)
      run_test("V2 UV index", "404632", { uv_index = 5.0 })

      -- Volume (0x47): 40 47 87 56 -> 2215.1 L (0x5687 = 22151, * 0.1)
      run_test("V2 volume 0x47", "40478756", { volume = 2215.1 })

      -- Volume mL: 40 48 dc 87 -> 34780 mL
      run_test("V2 volume_ml", "4048dc87", { volume_ml = 34780 })

      -- Distance mm: 40 40 0c 00 -> 12 mm
      run_test("V2 distance_mm", "40400c00", { distance_mm = 12 })

      -- Distance m: 40 41 4e 00 -> 7.8 m
      run_test("V2 distance_m", "40414e00", { distance_m = 7.8 })

      -- Duration: 40 42 4e 34 00 -> 13.390 s
      run_test("V2 duration", "40424e3400", { duration = 13.390 })

      -- Rotation: 40 3f 02 0c -> 307.4 °
      run_test("V2 rotation", "403f020c", { rotation = 307.4 })

      -- Humidity 0x2E (uint8, factor 1): 40 2E 34 -> 52%
      run_test("V2 humidity 0x2E", "402E34", { humidity = 52 })

      -- Moisture 0x2F (uint8, factor 1): 40 2F 2D -> 45%
      run_test("V2 moisture 0x2F", "402F2D", { moisture = 45 })

      -- Voltage 0x4A (uint16, factor 0.1): 40 4A 02 0C -> 307.4V (0x0C02 = 3074, * 0.1)
      -- Reference: test_parser_v2.py uses this exact vector
      run_test("V2 voltage 0x4A", "404A020C", { voltage = 307.4 })

      -- Window 0x2D: 40 2D 01 -> 1 (open)
      -- Reference: test_parser_v2.py uses this exact vector
      run_test("V2 window", "402D01", { window = 1 })

      -- ===========================================================================
      -- V2 Firmware Version Tests
      -- ===========================================================================

      -- Firmware version uint32 (0xF1): 40 F1 04 03 02 01 -> "1.2.3.4"
      -- Bytes are in little-endian order, parsed as version string
      total = total + 1
      local fw32_data = hex_to_bin("40F104030201")
      local fw32_result = parser.parse(parser.UUID_V2, fw32_data)
      if fw32_result then
        local found = false
        for _, r in ipairs(fw32_result.readings) do
          if r.name == "firmware_version" and r.value == "1.2.3.4" then
            found = true
          end
        end
        if found then
          print("  PASS: V2 firmware_version uint32")
          passed = passed + 1
        else
          print("  FAIL: V2 firmware_version uint32")
          print("    Expected: firmware_version = '1.2.3.4'")
          print("    Got readings:")
          for _, r in ipairs(fw32_result.readings) do
            print(string.format("      %s = %s", r.name, tostring(r.value)))
          end
        end
      else
        print("  FAIL: V2 firmware_version uint32")
        print("    Error: parsing failed")
      end

      -- Firmware version uint24 (0xF2): 40 F2 03 02 01 -> "1.2.3"
      total = total + 1
      local fw24_data = hex_to_bin("40F2030201")
      local fw24_result = parser.parse(parser.UUID_V2, fw24_data)
      if fw24_result then
        local found = false
        for _, r in ipairs(fw24_result.readings) do
          if r.name == "firmware_version" and r.value == "1.2.3" then
            found = true
          end
        end
        if found then
          print("  PASS: V2 firmware_version uint24")
          passed = passed + 1
        else
          print("  FAIL: V2 firmware_version uint24")
          print("    Expected: firmware_version = '1.2.3'")
          print("    Got readings:")
          for _, r in ipairs(fw24_result.readings) do
            print(string.format("      %s = %s", r.name, tostring(r.value)))
          end
        end
      else
        print("  FAIL: V2 firmware_version uint24")
        print("    Error: parsing failed")
      end

      -- Firmware version with realistic values: 40 F1 01 00 05 02 -> "2.5.0.1"
      total = total + 1
      local fw_real_data = hex_to_bin("40F101000502")
      local fw_real_result = parser.parse(parser.UUID_V2, fw_real_data)
      if fw_real_result then
        local found = false
        for _, r in ipairs(fw_real_result.readings) do
          if r.name == "firmware_version" and r.value == "2.5.0.1" then
            found = true
          end
        end
        if found then
          print("  PASS: V2 firmware_version realistic")
          passed = passed + 1
        else
          print("  FAIL: V2 firmware_version realistic")
          print("    Expected: firmware_version = '2.5.0.1'")
          print("    Got readings:")
          for _, r in ipairs(fw_real_result.readings) do
            print(string.format("      %s = %s", r.name, tostring(r.value)))
          end
        end
      else
        print("  FAIL: V2 firmware_version realistic")
        print("    Error: parsing failed")
      end

      -- ===========================================================================
      -- V2 Event Tests
      -- ===========================================================================

      -- Button press (short)
      total = total + 1
      local btn_data = hex_to_bin("443a01")
      local btn_result = parser.parse(parser.UUID_V2, btn_data)
      if btn_result and btn_result.device_info.trigger_based then
        local found = false
        for _, r in ipairs(btn_result.readings) do
          if r.name == "button" and r.event and r.event.event_name == "press" then
            found = true
          end
        end
        if found then
          print("  PASS: V2 button press event")
          passed = passed + 1
        else
          print("  FAIL: V2 button press event")
          print("    Expected: button with event_name = 'press'")
        end
      else
        print("  FAIL: V2 button press event")
        print("    Error: parsing failed or trigger_based not set")
      end

      -- Button long press
      total = total + 1
      local btn_long_data = hex_to_bin("443a04")
      local btn_long_result = parser.parse(parser.UUID_V2, btn_long_data)
      if btn_long_result then
        local found = false
        for _, r in ipairs(btn_long_result.readings) do
          if r.name == "button" and r.event and r.event.event_name == "long_press" then
            found = true
          end
        end
        if found then
          print("  PASS: V2 button long_press event")
          passed = passed + 1
        else
          print("  FAIL: V2 button long_press event")
          print("    Expected: button with event_name = 'long_press'")
        end
      else
        print("  FAIL: V2 button long_press event")
        print("    Error: parsing failed")
      end

      -- Dimmer rotate left: 44 3C 01 03
      -- device_info=0x44 (trigger-based, V2), object_id=0x3C (dimmer)
      -- value bytes: 01 03 -> little-endian uint16 = 0x0301 -> event_type=1 (rotate_left), steps=3
      total = total + 1
      local dimmer_data = hex_to_bin("443c0103")
      local dimmer_result = parser.parse(parser.UUID_V2, dimmer_data)
      if dimmer_result then
        local found = false
        for _, r in ipairs(dimmer_result.readings) do
          if r.name == "dimmer" and r.event and r.event.event_name == "rotate_left" and r.event.steps == 3 then
            found = true
          end
        end
        if found then
          print("  PASS: V2 dimmer rotate_left event")
          passed = passed + 1
        else
          print("  FAIL: V2 dimmer rotate_left event")
          print("    Expected: dimmer with event_name = 'rotate_left', steps = 3")
        end
      else
        print("  FAIL: V2 dimmer rotate_left event")
        print("    Error: parsing failed")
      end

      -- Dimmer rotate right: 44 3C 02 05
      -- device_info=0x44, object_id=0x3C
      -- value bytes: 02 05 -> little-endian uint16 = 0x0502 -> event_type=2 (rotate_right), steps=5
      total = total + 1
      local dimmer_right_data = hex_to_bin("443c0205")
      local dimmer_right_result = parser.parse(parser.UUID_V2, dimmer_right_data)
      if dimmer_right_result then
        local found = false
        for _, r in ipairs(dimmer_right_result.readings) do
          if r.name == "dimmer" and r.event and r.event.event_name == "rotate_right" and r.event.steps == 5 then
            found = true
          end
        end
        if found then
          print("  PASS: V2 dimmer rotate_right event")
          passed = passed + 1
        else
          print("  FAIL: V2 dimmer rotate_right event")
          print("    Expected: dimmer with event_name = 'rotate_right', steps = 5")
        end
      else
        print("  FAIL: V2 dimmer rotate_right event")
        print("    Error: parsing failed")
      end

      -- ===========================================================================
      -- Packet ID Test
      -- ===========================================================================

      total = total + 1
      local pkt_data = hex_to_bin("400005020000")
      local pkt_result = parser.parse(parser.UUID_V2, pkt_data)
      if pkt_result and pkt_result.packet_id == 5 then
        print("  PASS: V2 packet ID parsing")
        passed = passed + 1
      else
        print("  FAIL: V2 packet ID parsing")
        print(string.format("    Expected: packet_id = 5"))
        print(string.format("    Got: packet_id = %s", pkt_result and tostring(pkt_result.packet_id) or "nil"))
      end

      -- ===========================================================================
      -- Multiple Readings Test
      -- ===========================================================================

      total = total + 1
      local multi_data = hex_to_bin("40015f02e8030310" .. "27")
      local multi_result = parser.parse(parser.UUID_V2, multi_data)
      if multi_result and #multi_result.readings == 3 then
        print("  PASS: Multiple readings in one advertisement")
        passed = passed + 1
      else
        print("  FAIL: Multiple readings parsing")
        print(string.format("    Expected: 3 readings"))
        print(string.format("    Got: %d readings", multi_result and #multi_result.readings or 0))
      end

      -- ===========================================================================
      -- Error Handling Tests
      -- ===========================================================================

      -- Empty data
      total = total + 1
      local _, err_empty = parser.parse(parser.UUID_V2, "")
      if err_empty then
        print("  PASS: Empty data rejected")
        passed = passed + 1
      else
        print("  FAIL: Empty data should be rejected")
        print("    Expected: error message")
        print("    Got: no error")
      end

      -- Invalid version (0)
      total = total + 1
      local _, err_ver = parser.parse(parser.UUID_V2, hex_to_bin("00"))
      if err_ver and err_ver:find("version") then
        print("  PASS: Invalid version rejected")
        passed = passed + 1
      else
        print("  FAIL: Invalid version should be rejected")
        print("    Expected: error containing 'version'")
        print(string.format("    Got: %s", err_ver or "no error"))
      end

      -- Encrypted without bind_key
      total = total + 1
      local _, err_key = parser.parse(parser.UUID_V2, hex_to_bin("41"))
      if err_key and err_key:find("bind_key") then
        print("  PASS: Encrypted without bind_key rejected")
        passed = passed + 1
      else
        print("  FAIL: Encrypted without bind_key should require key")
        print("    Expected: error containing 'bind_key'")
        print(string.format("    Got: %s", err_key or "no error"))
      end

      -- Encrypted without MAC
      total = total + 1
      local bind_key = hex_to_bin("231d39c1d7cc1ab1aee224cd096db932")
      local _, err_mac = parser.parse(parser.UUID_V2, hex_to_bin("41aabbccdd"), bind_key)
      if err_mac and err_mac:find("MAC") then
        print("  PASS: Encrypted without MAC rejected")
        passed = passed + 1
      else
        print("  FAIL: Encrypted without MAC should require address")
        print("    Expected: error containing 'MAC'")
        print(string.format("    Got: %s", err_mac or "no error"))
      end

      -- Truncated data (object ID without value)
      total = total + 1
      local _, err_trunc = parser.parse(parser.UUID_V2, hex_to_bin("4002"))
      if err_trunc and err_trunc:find("truncated") then
        print("  PASS: Truncated data rejected")
        passed = passed + 1
      else
        print("  FAIL: Truncated data should be rejected")
        print("    Expected: error containing 'truncated'")
        print(string.format("    Got: %s", err_trunc or "no error"))
      end

      -- ===========================================================================
      -- Negative Temperature Test (Signed Value)
      -- ===========================================================================

      -- Temperature: -10.0°C = -1000 = 0xFC18 in little-endian = 18 FC
      total = total + 1
      local neg_temp_data = hex_to_bin("400218fc")
      local neg_temp_result = parser.parse(parser.UUID_V2, neg_temp_data)
      if neg_temp_result then
        local found = false
        for _, r in ipairs(neg_temp_result.readings) do
          if r.name == "temperature" and math.abs(r.value - -10.0) < 0.01 then
            found = true
          end
        end
        if found then
          print("  PASS: V2 negative temperature")
          passed = passed + 1
        else
          print("  FAIL: V2 negative temperature")
          print("    Expected: temperature = -10.0")
          print("    Got readings:")
          for _, r in ipairs(neg_temp_result.readings) do
            print(string.format("      %s = %s", r.name, tostring(r.value)))
          end
        end
      else
        print("  FAIL: V2 negative temperature")
        print("    Error: parsing failed")
      end

      -- ===========================================================================
      -- V2 Encrypted Advertisement Test
      -- ===========================================================================

      -- Official BTHome test vector from https://bthome.io/encryption/
      -- Decrypted payload: 02ca09 03bf13 = temp 25.06°C, humidity 50.55%
      -- MAC: 5448E68F80A5
      -- Bind key: 231d39c1d7cc1ab1aee224cd096db932
      -- Service data: 41e445f3c9962b332211006c7c4519
      --   41 = device_info (encrypted=true, v2)
      --   e445f3c9962b = encrypted data (6 bytes)
      --   33221100 = counter (1122867 in LE)
      --   6c7c4519 = MIC (4 bytes)
      total = total + 1
      local enc_packet = hex_to_bin("41e445f3c9962b332211006c7c4519")
      local enc_bind_key = hex_to_bin("231d39c1d7cc1ab1aee224cd096db932")
      local enc_mac = hex_to_bin("5448E68F80A5")
      local enc_result, enc_err = parser.parse(parser.UUID_V2, enc_packet, enc_bind_key, enc_mac)
      if enc_result and enc_result.readings and #enc_result.readings > 0 then
        -- Check for expected values
        local found_temp = false
        local found_hum = false
        for _, r in ipairs(enc_result.readings) do
          if r.name == "temperature" and math.abs(r.value - 25.06) < 0.01 then
            found_temp = true
          end
          if r.name == "humidity" and math.abs(r.value - 50.55) < 0.01 then
            found_hum = true
          end
        end
        if found_temp and found_hum then
          print("  PASS: V2 encrypted advertisement decryption")
          passed = passed + 1
        else
          print("  FAIL: V2 encrypted advertisement decryption")
          print("    Expected: temperature = 25.06, humidity = 50.55")
          print("    Got readings:")
          for _, r in ipairs(enc_result.readings) do
            print(string.format("      %s = %s", r.name, tostring(r.value)))
          end
        end
      else
        print("  FAIL: V2 encrypted advertisement decryption")
        print(string.format("    Error: %s", enc_err or "unknown"))
      end

      -- ===========================================================================
      -- V1 Encrypted Advertisement Test
      -- ===========================================================================

      -- Official BTHome V1 test vector from bthome-ble test_parser_v1.py
      -- MAC: 54:48:E6:8F:80:A5
      -- Bind key: 231d39c1d7cc1ab1aee224cd096db932
      -- Service data (UUID 0x181E): fba435e4d3c312fb0011223357d90a99
      -- Decrypted payload uses V1 format: temp 25.06°C, humidity 50.55%
      total = total + 1
      local v1_enc_packet = hex_to_bin("fba435e4d3c312fb0011223357d90a99")
      local v1_enc_bind_key = hex_to_bin("231d39c1d7cc1ab1aee224cd096db932")
      local v1_enc_mac = hex_to_bin("5448E68F80A5")
      local v1_enc_result, v1_enc_err =
        parser.parse(parser.UUID_V1_ENCRYPTED, v1_enc_packet, v1_enc_bind_key, v1_enc_mac)
      if v1_enc_result and v1_enc_result.readings and #v1_enc_result.readings > 0 then
        local found_temp = false
        local found_hum = false
        for _, r in ipairs(v1_enc_result.readings) do
          if r.name == "temperature" and math.abs(r.value - 25.06) < 0.01 then
            found_temp = true
          end
          if r.name == "humidity" and math.abs(r.value - 50.55) < 0.01 then
            found_hum = true
          end
        end
        if
          found_temp
          and found_hum
          and v1_enc_result.device_info.version == 1
          and v1_enc_result.device_info.encrypted
        then
          print("  PASS: V1 encrypted advertisement decryption")
          passed = passed + 1
        else
          print("  FAIL: V1 encrypted advertisement decryption")
          print("    Expected: temperature = 25.06, humidity = 50.55, version = 1, encrypted = true")
          print(
            string.format(
              "    Got: version = %d, encrypted = %s",
              v1_enc_result.device_info.version,
              tostring(v1_enc_result.device_info.encrypted)
            )
          )
          print("    Got readings:")
          for _, r in ipairs(v1_enc_result.readings) do
            print(string.format("      %s = %s", r.name, tostring(r.value)))
          end
        end
      else
        print("  FAIL: V1 encrypted advertisement decryption")
        print(string.format("    Error: %s", v1_enc_err or "unknown"))
      end

      -- ===========================================================================
      -- V1 Unencrypted Advertisement Tests
      -- ===========================================================================

      -- Official BTHome V1 test vector from bthome-ble test_parser_v1.py
      -- test_bthome_temperature_humidity: temp 25.06°C, humidity 50.55%
      -- Data: 23 02 ca 09 03 03 bf 13
      --   23 = control (len=3, fmt=1), 02 = temperature, ca09 = 2506 -> 25.06
      --   03 = control (len=3, fmt=0), 03 = humidity, bf13 = 5055 -> 50.55
      total = total + 1
      local v1_temp_hum_data = hex_to_bin("2302ca090303bf13")
      local v1_temp_hum_result, v1_temp_hum_err = parser.parse(parser.UUID_V1_UNENCRYPTED, v1_temp_hum_data)
      if v1_temp_hum_result and v1_temp_hum_result.readings then
        local found_temp = false
        local found_hum = false
        for _, r in ipairs(v1_temp_hum_result.readings) do
          if r.name == "temperature" and math.abs(r.value - 25.06) < 0.01 then
            found_temp = true
          end
          if r.name == "humidity" and math.abs(r.value - 50.55) < 0.01 then
            found_hum = true
          end
        end
        if
          found_temp
          and found_hum
          and v1_temp_hum_result.device_info.version == 1
          and not v1_temp_hum_result.device_info.encrypted
        then
          print("  PASS: V1 unencrypted temperature+humidity")
          passed = passed + 1
        else
          print("  FAIL: V1 unencrypted temperature+humidity")
          print("    Expected: temperature = 25.06, humidity = 50.55, version = 1, encrypted = false")
          print("    Got readings:")
          for _, r in ipairs(v1_temp_hum_result.readings) do
            print(string.format("      %s = %s", r.name, tostring(r.value)))
          end
        end
      else
        print("  FAIL: V1 unencrypted temperature+humidity")
        print(string.format("    Error: %s", v1_temp_hum_err or "unknown"))
      end

      -- Official BTHome V1 test vector from bthome-ble test_parser_v1.py
      -- test_bthome_pressure: pressure 1008.83 mbar
      -- Data: 04 04 13 8a 01
      --   04 = control (len=4, fmt=0), 04 = pressure, 138a01 = 100883 -> 1008.83
      total = total + 1
      local v1_pressure_data = hex_to_bin("0404138a01")
      local v1_pressure_result, v1_pressure_err = parser.parse(parser.UUID_V1_UNENCRYPTED, v1_pressure_data)
      if v1_pressure_result and v1_pressure_result.readings then
        local found_pressure = false
        for _, r in ipairs(v1_pressure_result.readings) do
          if r.name == "pressure" and math.abs(r.value - 1008.83) < 0.01 then
            found_pressure = true
          end
        end
        if found_pressure then
          print("  PASS: V1 unencrypted pressure")
          passed = passed + 1
        else
          print("  FAIL: V1 unencrypted pressure")
          print("    Expected: pressure = 1008.83")
          print("    Got readings:")
          for _, r in ipairs(v1_pressure_result.readings) do
            print(string.format("      %s = %s", r.name, tostring(r.value)))
          end
        end
      else
        print("  FAIL: V1 unencrypted pressure")
        print(string.format("    Error: %s", v1_pressure_err or "unknown"))
      end

      -- ===========================================================================
      -- Duplicate Object ID Tests (instance field)
      -- ===========================================================================

      -- Two power readings (0x10) and two opening readings (0x11)
      -- This simulates pvvx firmware on LYWSD03MMC that sends multiple comfort zone triggers
      -- Format: 40 10 01 10 00 11 01 11 00
      --   40 = V2, not encrypted
      --   10 01 = power_on (object 0x10) = 1 (on)
      --   10 00 = power_on (object 0x10) = 0 (off)
      --   11 01 = opening (object 0x11) = 1 (open)
      --   11 00 = opening (object 0x11) = 0 (closed)
      total = total + 1
      local dup_data = hex_to_bin("401001100011011100")
      local dup_result = parser.parse(parser.UUID_V2, dup_data)
      if dup_result and #dup_result.readings == 4 then
        local r = dup_result.readings
        -- Check names are unchanged and instances are assigned correctly
        local all_match = r[1].name == "power_on"
          and r[1].instance == 1
          and r[2].name == "power_on"
          and r[2].instance == 2
          and r[3].name == "opening"
          and r[3].instance == 1
          and r[4].name == "opening"
          and r[4].instance == 2
        if all_match then
          print("  PASS: Duplicate object IDs get instance numbers")
          passed = passed + 1
        else
          print("  FAIL: Duplicate object IDs get instance numbers")
          print("    Expected: power_on(1), power_on(2), opening(1), opening(2)")
          print("    Got readings:")
          for i, reading in ipairs(r) do
            print(string.format("      [%d] name=%s, instance=%s", i, reading.name, tostring(reading.instance)))
          end
        end
      else
        print("  FAIL: Duplicate object IDs get instance numbers")
        print("    Expected: 4 readings")
        print(string.format("    Got: %d readings", dup_result and #dup_result.readings or 0))
      end

      -- Three identical temperature readings to test instance=1, 2, 3
      -- Format: 40 02 ca09 02 bf13 02 1027
      --   40 = V2, not encrypted
      --   02 ca09 = temperature = 25.06°C
      --   02 bf13 = temperature = 50.55°C (using humidity bytes as temp for variety)
      --   02 1027 = temperature = 100.00°C
      total = total + 1
      local triple_data = hex_to_bin("4002ca0902bf13021027")
      local triple_result = parser.parse(parser.UUID_V2, triple_data)
      if triple_result and #triple_result.readings == 3 then
        local r = triple_result.readings
        local all_match = r[1].name == "temperature"
          and r[1].instance == 1
          and r[2].name == "temperature"
          and r[2].instance == 2
          and r[3].name == "temperature"
          and r[3].instance == 3
        if all_match then
          print("  PASS: Triple duplicate gets instance=1, 2, 3")
          passed = passed + 1
        else
          print("  FAIL: Triple duplicate gets instance=1, 2, 3")
          print("    Expected: temperature(1), temperature(2), temperature(3)")
          print("    Got readings:")
          for i, reading in ipairs(r) do
            print(string.format("      [%d] name=%s, instance=%s", i, reading.name, tostring(reading.instance)))
          end
        end
      else
        print("  FAIL: Triple duplicate gets instance=1, 2, 3")
        print("    Expected: 3 readings")
        print(string.format("    Got: %d readings", triple_result and #triple_result.readings or 0))
      end

      print(string.format("\nparser module: %d/%d tests passed\n", passed, total))
      return passed == total
    end

    return parser
  end
end

--- @module "bthome"
--- Pure Lua BTHome BLE advertisement parser library.
--- This library provides parsing for BTHome V1 and V2 BLE advertisements,
--- supporting both unencrypted and encrypted payloads.
---
--- @usage
--- local bthome = require("bthome")
--- print(bthome.version())
---
--- -- Parse V2 unencrypted advertisement
--- local result = bthome.parse(bthome.UUID_V2, service_data)
---
--- -- Parse V2 encrypted advertisement
--- local result = bthome.parse(bthome.UUID_V2, service_data, bind_key, mac_address)
---
--- -- Parse V1 encrypted advertisement
--- local result = bthome.parse(bthome.UUID_V1_ENCRYPTED, service_data, bind_key, mac_address)
---
--- @class bthome
local bthome = {
  --- @type bthome.const
  const = require("bthome.const"),
  --- @type bthome.event
  event = require("bthome.event"),
  --- @type bthome.parser
  parser = require("bthome.parser"),
  --- @type bthome.crypto
  crypto = require("bthome.crypto"),
}
bthome.UUID_V1_UNENCRYPTED = bthome.parser.UUID_V1_UNENCRYPTED
bthome.UUID_V1_ENCRYPTED = bthome.parser.UUID_V1_ENCRYPTED
bthome.UUID_V2 = bthome.parser.UUID_V2

--- Library version (injected at build time for releases).
local VERSION = "v0.1.3"

--- Get the library version string.
--- @return string version Version string (e.g., "v1.0.0" or "dev")
function bthome.version()
  return VERSION
end

bthome.parse = bthome.parser.parse

--- Run self-tests for all modules.
--- @return boolean success True if all tests passed
function bthome.selftest()
  print("BTHome Library Self-Test")
  print("========================")
  print("")

  local all_passed = true

  -- Test const module
  local const_ok = bthome.const.selftest()
  if not const_ok then
    all_passed = false
  end

  -- Test event module
  local event_ok = bthome.event.selftest()
  if not event_ok then
    all_passed = false
  end

  -- Test crypto module
  local crypto_ok = bthome.crypto.selftest()
  if not crypto_ok then
    all_passed = false
  end

  -- Test parser module
  local parser_ok = bthome.parser.selftest()
  if not parser_ok then
    all_passed = false
  end

  print("")
  if all_passed then
    print("All BTHome tests passed!")
  else
    print("Some BTHome tests failed!")
  end

  return all_passed
end

return bthome
