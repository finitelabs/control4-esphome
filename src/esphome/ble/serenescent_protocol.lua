--- Homedics SereneScent BLE diffuser protocol.
--- Frames and offsets follow the Home Assistant integration, whose authors captured
--- them from the vendor app; the intensity trailer bytes are an unexplained
--- checksum, so only the three captured frames are ever sent.
--- Sources:
---  - https://github.com/john-k-mcdowell/Homedics-SereneScent/blob/main/docs/PROTOCOL.md
---  - https://github.com/john-k-mcdowell/Homedics-SereneScent/blob/main/custom_components/homedics_serenescent/const.py

local serenescent_protocol = {}

serenescent_protocol.UUID = {
  SERVICE = "53527AA4-29F7-AE11-4E74-997334782568",
  TX = "EE684B1A-1E9B-ED3E-EE55-F894667E92AC",
  RX = "654B749C-E37F-AE1F-EBAB-40CA133E3690",
}

--- Command byte echoed in the third byte of every response.
serenescent_protocol.Opcode = {
  POWER_ON = 0x10,
  POWER_OFF = 0x11,
  COLOR = 0x16,
  INTENSITY = 0x17,
  STATUS = 0x40,
  MODE = 0x43,
}

--- Byte 15 of a status frame. Intensity and color only take effect in HOME mode.
serenescent_protocol.Mode = {
  HOME = 0,
  SCHEDULE = 1,
}

--- In cycling order.
serenescent_protocol.INTENSITIES = { "low", "medium", "high" }

--- In wire order: the index is the color byte plus one.
serenescent_protocol.COLORS = { "off", "rotating", "white", "red", "blue", "violet", "green", "orange" }

local INTENSITY_BYTES = { low = 0x0A, medium = 0x14, high = 0x1E }
local INTENSITY_TRAILERS = { low = 0xF0, medium = 0x82, high = 0x3C }

local STATUS_LENGTH = 16
local STATUS_BYTE_INTENSITY = 9
local STATUS_BYTE_COLOR = 13
local STATUS_BYTE_SCHEDULE = 14
local STATUS_BYTE_POWER = 15
local STATUS_BYTE_MODE = 16

local function frame(...)
  return string.char(0xFF, 0xFA, ...)
end

--- @return string frame
function serenescent_protocol.powerCommand(on)
  return on and frame(serenescent_protocol.Opcode.POWER_ON, 0x04) or frame(serenescent_protocol.Opcode.POWER_OFF, 0x04)
end

--- @param level string One of INTENSITIES
--- @return string|nil frame Nil for an unknown level
function serenescent_protocol.intensityCommand(level)
  local value = INTENSITY_BYTES[level]
  if not value then
    return nil
  end
  return frame(serenescent_protocol.Opcode.INTENSITY, 0x08, 0x00, value, 0x00, INTENSITY_TRAILERS[level])
end

--- @param color string One of COLORS
--- @return string|nil frame Nil for an unknown color
function serenescent_protocol.colorCommand(color)
  for index, name in ipairs(serenescent_protocol.COLORS) do
    if name == color then
      return frame(serenescent_protocol.Opcode.COLOR, 0x05, index - 1)
    end
  end
  return nil
end

--- The query must name the mode the device is in or it goes unanswered.
--- @param mode integer|nil Last known Mode; nil queries as HOME
--- @return string frame
function serenescent_protocol.statusQuery(mode)
  return frame(serenescent_protocol.Opcode.STATUS, 0x05, mode == serenescent_protocol.Mode.SCHEDULE and 0x01 or 0x00)
end

--- @return string frame
function serenescent_protocol.homeModeCommand()
  return frame(serenescent_protocol.Opcode.MODE, 0x05, serenescent_protocol.Mode.HOME)
end

--- The device pads its notifications with all-0xFF and all-0x00 packets.
--- @param data string
--- @return boolean
function serenescent_protocol.isFiller(data)
  if #data == 0 then
    return true
  end
  local first = data:byte(1)
  if first ~= 0xFF and first ~= 0x00 then
    return false
  end
  return not data:find("[^" .. (first == 0 and "%z" or "\255") .. "]")
end

--- @class SereneScentStatus
--- @field power boolean
--- @field intensity string|nil Nil when the byte is not a known level
--- @field color string|nil Nil when the byte is not a known color
--- @field schedule boolean
--- @field mode integer

--- @class SereneScentFrame
--- @field opcode integer The echoed command byte
--- @field status SereneScentStatus|nil Present only on a status response

--- Parse one response notification.
--- @param data string Raw notification bytes
--- @return SereneScentFrame|nil frame Nil when it is not a response
--- @return string|nil err Why it was rejected
function serenescent_protocol.parseResponse(data)
  if #data < 3 or data:byte(1) ~= 0xFF or data:byte(2) ~= 0xFB then
    return nil, "not a response"
  end
  local opcode = data:byte(3)
  if opcode ~= serenescent_protocol.Opcode.STATUS then
    return { opcode = opcode }
  end
  if #data < STATUS_LENGTH then
    return nil, string.format("status response too short: %d bytes", #data)
  end
  local intensityByte = data:byte(STATUS_BYTE_INTENSITY)
  local intensity
  for level, value in pairs(INTENSITY_BYTES) do
    if value == intensityByte then
      intensity = level
    end
  end
  return {
    opcode = opcode,
    status = {
      power = data:byte(STATUS_BYTE_POWER) == 1,
      intensity = intensity,
      color = serenescent_protocol.COLORS[data:byte(STATUS_BYTE_COLOR) + 1],
      schedule = data:byte(STATUS_BYTE_SCHEDULE) == 1,
      mode = data:byte(STATUS_BYTE_MODE),
    },
  }
end

return serenescent_protocol
