--- Mirrors the load bound to an event's button link onto one of the device's
--- lights, the way a Control4 keypad lights its button.
---
--- A button is an event entity. Each of its event types has its own button link,
--- but like a keypad button it has one LED, which follows the first of its links
--- with a load bound, in the order the device declares them (normally press).

local log = require("lib.logging")
local bindings = require("lib.bindings")
local persist = require("lib.persist")
local values = require("lib.values")
local constants = require("constants")
local ESPHomeClient = require("esphome.client")
local ESPHomeProtoSchema = require("esphome.proto_schema")

local LABEL_PROPERTY = "Button LEDs"
local CONFIGURE_PROPERTY = "Configure Button LED"
local LED_PROPERTY = "Button LED"
local NONE_OPTION = "(None)"
--- The light chosen for each button, by button key: a light's ref, or "" for none chosen on purpose.
local PAIRS_KEY = "ButtonLedLights"
--- A button's colors while its load has sent none: blue when lit, dark when not.
local DEFAULT_ON_COLOR = "0000FF"
local DEFAULT_OFF_COLOR = "000000"

local ColorMode = ESPHomeProtoSchema.Enum.ColorMode
local RGB_MODES = {
  [ColorMode.COLOR_MODE_RGB] = true,
  [ColorMode.COLOR_MODE_RGB_WHITE] = true,
  [ColorMode.COLOR_MODE_RGB_COLOR_TEMPERATURE] = true,
  [ColorMode.COLOR_MODE_RGB_COLD_WARM_WHITE] = true,
}

--- @class ButtonLedButton
--- @field key string
--- @field label string
--- @field entity table<string, any>
--- @field links string[] Binding keys of its event types' button links, in the device's order.

--- @class ButtonLedLight
--- @field ref string
--- @field name string
--- @field entity table<string, any>
--- @field rgb boolean

--- @class ButtonLedFeedback
--- @field state boolean|nil
--- @field onColor string|nil Six uppercase hex digits.
--- @field offColor string|nil Six uppercase hex digits.

--- @class ButtonLeds
--- @field client ESPHomeClient
--- @field buttons table<string, ButtonLedButton>
--- @field buttonOrder ButtonLedButton[]
--- @field linkOwners table<string, ButtonLedButton> The button each link belongs to, by binding key.
--- @field lights table<string, ButtonLedLight>
--- @field lightOrder ButtonLedLight[]
--- @field feedback table<string, ButtonLedFeedback> What each link's load last reported, by binding key.
--- @field sent table<string, string> The command last sent to each light this connection.
--- @field selectedKey string|nil The button the Composer form is editing.
--- @field optionKeys table<string, string> Configure Button LED option text to button key.
local ButtonLeds = {}
ButtonLeds.__index = ButtonLeds

--- The key of the button link binding an event entity publishes for one event type.
--- @param entity table<string, any>
--- @param eventType string
--- @return string
function ButtonLeds.bindingKey(entity, eventType)
  return "event_" .. entity.ref .. ":" .. eventType
end

--- @param entity table<string, any> An event entity.
--- @return string
local function buttonKey(entity)
  return "event_" .. entity.ref
end

--- Property list options are comma separated, so a name cannot carry one.
--- @param name string
--- @return string
local function optionText(name)
  return (tostring(name):gsub(",", ""))
end

--- @param value any A Control4 color, e.g. "ff0000" or "#FF0000".
--- @return string|nil hex Six uppercase hex digits, or nil for none.
local function normalizeColor(value)
  if value == nil then
    return nil
  end
  local hex = tostring(value):gsub("^#", ""):gsub("^0[xX]", ""):upper()
  if hex:match("^%x%x%x%x%x%x$") then
    return hex
  end
  return nil
end

--- @param entity table<string, any> A light entity.
--- @return boolean
local function supportsRgb(entity)
  if toboolean(entity.legacy_supports_rgb) then
    return true
  end
  for _, mode in ipairs(entity.supported_color_modes or {}) do
    if RGB_MODES[mode] then
      return true
    end
  end
  return false
end

--- @return table<string, string>
local function getPairs()
  return persist:get(PAIRS_KEY, {})
end

--- @param client ESPHomeClient
--- @return ButtonLeds
function ButtonLeds:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  instance.buttons = {}
  instance.buttonOrder = {}
  instance.linkOwners = {}
  instance.lights = {}
  instance.lightOrder = {}
  instance.feedback = {}
  instance.sent = {}
  instance.selectedKey = nil
  instance.optionKeys = {}
  return instance
end

--- An entity's name with its sub-device's in front, which the client adds only
--- to tell apart two entities that would otherwise share a name.
--- @param entity table<string, any>
--- @return string
function ButtonLeds:displayName(entity)
  local name = entity.name or ""
  local device = (entity.device_id or 0) ~= 0 and self.client:getDeviceName(entity.device_id) or nil
  if device ~= nil and name:sub(1, #device) ~= device then
    name = device .. " " .. name
  end
  return optionText(name)
end

--- Hide the Button LEDs properties.
function ButtonLeds:hideProperties()
  C4:SetPropertyAttribs(LABEL_PROPERTY, constants.HIDE_PROPERTY)
  C4:SetPropertyAttribs(CONFIGURE_PROPERTY, constants.HIDE_PROPERTY)
  C4:SetPropertyAttribs(LED_PROPERTY, constants.HIDE_PROPERTY)
end

--- Refresh the Composer form from the current buttons, lights and pairs.
function ButtonLeds:updateProperties()
  if #self.buttonOrder == 0 or #self.lightOrder == 0 then
    self:hideProperties()
    return
  end
  local pairsByKey = getPairs()
  local options = { constants.SELECT_OPTION }
  local selectedText = constants.SELECT_OPTION
  self.optionKeys = {}
  for _, button in ipairs(self.buttonOrder) do
    local light = self.lights[pairsByKey[button.key] or ""]
    local text = light and (button.label .. " -> " .. light.name) or button.label
    table.insert(options, text)
    self.optionKeys[text] = button.key
    if button.key == self.selectedKey then
      selectedText = text
    end
  end
  if selectedText == constants.SELECT_OPTION then
    self.selectedKey = nil
  end
  C4:UpdatePropertyList(CONFIGURE_PROPERTY, table.concat(options, ","), selectedText)
  UpdateProperty(CONFIGURE_PROPERTY, selectedText)
  C4:SetPropertyAttribs(LABEL_PROPERTY, constants.SHOW_PROPERTY)
  C4:SetPropertyAttribs(CONFIGURE_PROPERTY, constants.SHOW_PROPERTY)

  if self.selectedKey == nil then
    C4:SetPropertyAttribs(LED_PROPERTY, constants.HIDE_PROPERTY)
    return
  end
  local ledOptions = { NONE_OPTION }
  local current = NONE_OPTION
  for _, light in ipairs(self.lightOrder) do
    table.insert(ledOptions, light.name)
    if light.ref == pairsByKey[self.selectedKey] then
      current = light.name
    end
  end
  C4:UpdatePropertyList(LED_PROPERTY, table.concat(ledOptions, ","), current)
  UpdateProperty(LED_PROPERTY, current)
  C4:SetPropertyAttribs(LED_PROPERTY, constants.SHOW_PROPERTY)
end

--- Pair a sub-device's light with its button when it has exactly one of each and
--- no pair was chosen yet, so a device grouped in its YAML needs no setup.
--- @param buttonsByDevice table<integer, ButtonLedButton[]>
--- @param lightsByDevice table<integer, ButtonLedLight[]>
local function prefill(buttonsByDevice, lightsByDevice)
  local pairsByKey = getPairs()
  local changed = false
  for deviceId, deviceButtons in pairs(buttonsByDevice) do
    local deviceLights = lightsByDevice[deviceId] or {}
    if deviceId ~= 0 and #deviceButtons == 1 and #deviceLights == 1 and pairsByKey[deviceButtons[1].key] == nil then
      log:info("Pairing %s with its sub-device's light %s", deviceButtons[1].label, deviceLights[1].name)
      pairsByKey[deviceButtons[1].key] = deviceLights[1].ref
      changed = true
    end
  end
  if changed then
    persist:set(PAIRS_KEY, pairsByKey)
  end
end

--- Take in the device's entities after a connect: rebuild the form, ask each
--- link's load for its state, and show what is already known.
--- @param entities table<string, table<string, any>>
function ButtonLeds:discovered(entities)
  log:trace("ButtonLeds:discovered()")
  self.buttons, self.buttonOrder, self.linkOwners, self.lights, self.lightOrder = {}, {}, {}, {}, {}
  self.sent = {}
  local buttonsByDevice, lightsByDevice = {}, {}
  for _, entity in pairs(entities) do
    local deviceId = entity.device_id or 0
    if entity.entity_type == ESPHomeClient.EntityType.EVENT then
      local button = { key = buttonKey(entity), label = self:displayName(entity), entity = entity, links = {} }
      for _, eventType in ipairs(entity.event_types or {}) do
        local link = self.bindingKey(entity, eventType)
        table.insert(button.links, link)
        self.linkOwners[link] = button
      end
      self.buttons[button.key] = button
      table.insert(self.buttonOrder, button)
      buttonsByDevice[deviceId] = buttonsByDevice[deviceId] or {}
      table.insert(buttonsByDevice[deviceId], button)
    elseif entity.entity_type == ESPHomeClient.EntityType.LIGHT then
      local light = { ref = entity.ref, name = self:displayName(entity), entity = entity, rgb = supportsRgb(entity) }
      self.lights[light.ref] = light
      table.insert(self.lightOrder, light)
      lightsByDevice[deviceId] = lightsByDevice[deviceId] or {}
      table.insert(lightsByDevice[deviceId], light)
    end
  end
  table.sort(self.buttonOrder, function(a, b)
    return a.label < b.label
  end)
  table.sort(self.lightOrder, function(a, b)
    return a.name < b.name
  end)

  prefill(buttonsByDevice, lightsByDevice)
  self:updateProperties()

  for _, button in ipairs(self.buttonOrder) do
    for _, link in ipairs(button.links) do
      local binding = bindings:getDynamicBinding(ESPHomeClient.EntityType.EVENT, link)
      if binding ~= nil then
        self:requestState(binding.bindingId)
      end
    end
    self:apply(button)
  end
end

--- The device is gone: whatever its lights showed is no longer known.
function ButtonLeds:disconnected()
  self.sent = {}
end

--- Ask the load on a button link for its LED state and colors, as a keypad does.
--- @param bindingId integer
function ButtonLeds:requestState(bindingId)
  SendToProxy(bindingId, "REQUEST_BUTTON_COLORS", {}, "COMMAND")
end

--- A button link lost its load: the LED follows the button's next linked load, or goes dark.
--- @param link string The link's binding key.
function ButtonLeds:linkUnbound(link)
  self.feedback[link] = nil
  local button = self.linkOwners[link]
  if button ~= nil then
    self:apply(button, true)
  end
end

--- Take a message the load sends back over a button link.
--- @param link string The link's binding key.
--- @param strCommand string
--- @param tParams table<string, any>|nil
function ButtonLeds:received(link, strCommand, tParams)
  log:debug("Button link %s received %s %s", link, strCommand, tParams)
  local feedback = self.feedback[link] or {}
  self.feedback[link] = feedback
  if strCommand == "MATCH_LED_STATE" then
    local state = Select(tParams, "STATE")
    if state == nil then
      return
    end
    feedback.state = toboolean(state)
  elseif strCommand == "BUTTON_COLORS" then
    if Select(tParams, "ON_COLOR") ~= nil then
      feedback.onColor = normalizeColor(tParams.ON_COLOR)
    end
    if Select(tParams, "OFF_COLOR") ~= nil then
      feedback.offColor = normalizeColor(tParams.OFF_COLOR)
    end
  else
    return
  end
  local button = self.linkOwners[link]
  if button ~= nil then
    self:apply(button)
  end
end

--- What the button's LED follows: the first of its links whose load has reported a state.
--- @param button ButtonLedButton
--- @return ButtonLedFeedback|nil
function ButtonLeds:followed(button)
  for _, link in ipairs(button.links) do
    local feedback = self.feedback[link]
    if feedback ~= nil and feedback.state ~= nil then
      return feedback
    end
  end
  return nil
end

--- Show a button's load on its paired light.
--- @param button ButtonLedButton
--- @param darkWithoutLoad? boolean Turn the light off when none of the button's links has a load.
function ButtonLeds:apply(button, darkWithoutLoad)
  local feedback = self:followed(button)
  if feedback == nil and not darkWithoutLoad then
    return
  end
  local state = feedback ~= nil and feedback.state or false
  values:update(button.label .. " LED", state, "BOOL")
  local ref = getPairs()[button.key]
  local light = ref and self.lights[ref]
  if light == nil or not self.client:isConnected() then
    return
  end

  local body = { key = light.entity.key, device_id = light.entity.device_id, has_state = true, state = state }
  local color
  if state then
    color = feedback.onColor or DEFAULT_ON_COLOR
  else
    color = feedback and feedback.offColor or DEFAULT_OFF_COLOR
  end
  if light.rgb and feedback ~= nil then
    local red = tonumber(color:sub(1, 2), 16)
    local green = tonumber(color:sub(3, 4), 16)
    local blue = tonumber(color:sub(5, 6), 16)
    local level = math.max(red, green, blue)
    body.state = level > 0
    if level > 0 then
      body.has_rgb = true
      body.red, body.green, body.blue = red / level, green / level, blue / level
      body.has_brightness = true
      body.brightness = level / 255
    end
  elseif state then
    body.has_brightness = true
    body.brightness = 1
  end

  local signature = table.concat({
    tostring(body.state),
    tostring(body.red),
    tostring(body.green),
    tostring(body.blue),
    tostring(body.brightness),
  }, "|")
  if self.sent[ref] == signature then
    return
  end
  self.sent[ref] = signature
  self.client:callServiceMethod(ESPHomeProtoSchema.RPC.APIConnection.light_command, body):next(function()
    log:debug("Showed %s on %s: %s", button.label, ESPHomeClient.describeEntity(light.entity), body)
  end, function(error)
    self.sent[ref] = nil
    log:warn("Could not show %s on %s; %s", button.label, ESPHomeClient.describeEntity(light.entity), error)
  end)
end

--- Configure Button LED changed: edit that button's light.
--- @param value string
function ButtonLeds:configureChanged(value)
  self.selectedKey = self.optionKeys[value]
  self:updateProperties()
end

--- Button LED changed: pair the button being edited with that light.
--- @param value string
function ButtonLeds:ledChanged(value)
  local button = self.selectedKey and self.buttons[self.selectedKey]
  if button == nil then
    return
  end
  local chosen
  for _, light in ipairs(self.lightOrder) do
    if light.name == value then
      chosen = light
    end
  end
  local pairsByKey = getPairs()
  if (pairsByKey[button.key] or "") == (chosen and chosen.ref or "") then
    return
  end
  pairsByKey[button.key] = chosen and chosen.ref or ""
  persist:set(PAIRS_KEY, pairsByKey)
  if chosen ~= nil then
    self.sent[chosen.ref] = nil
  end
  self:updateProperties()
  self:apply(button)
end

return ButtonLeds
