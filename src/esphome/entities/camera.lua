local log = require("lib.logging")
local bindings = require("lib.bindings")
local ESPHomeClient = require("esphome.client")

--- @class CameraEntity:Entity
local CameraEntity = {
  TYPE = ESPHomeClient.EntityType.CAMERA,
}
CameraEntity.__index = CameraEntity

--- Create a new instance of the camera entity.
--- @param client ESPHomeClient The ESPHome client instance.
--- @return CameraEntity entity A new instance of the CameraEntity entity.
function CameraEntity:new(client)
  local instance = setmetatable({}, self)
  instance.client = client
  return instance
end

--- Handle the discovery of a camera entity.
--- Creates an ESPHOME_CAMERA companion driver binding. The companion driver
--- exposes the C4 camera proxy and points it at the device's MJPEG stream URL.
--- No binary data handling (CameraImageRequest/CameraImageResponse) is needed;
--- the ESPHome device must have `esp32_camera_web_server` enabled to provide
--- the MJPEG stream endpoint.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @return void
function CameraEntity:discovered(entity)
  log:trace("CameraEntity:discovered(%s)", entity)
  local bindingId = assert(
    bindings:getOrAddDynamicBinding(self.TYPE, "camera_" .. entity.key, "PROXY", true, entity.name, "ESPHOME_CAMERA")
  ).bindingId
  RFP[bindingId] = function(idBinding, strCommand, tParams, args)
    log:trace("RFP idBinding=%s strCommand=%s tParams=%s args=%s", idBinding, strCommand, tParams, args)
    if strCommand == "REFRESH_STATE" then
      RefreshStatus()
    end
  end
  OBC[bindingId] = RefreshStatus
end

--- Notify sub-drivers that the ESPHome device has disconnected.
--- @return void
function CameraEntity:disconnected()
  log:trace("CameraEntity:disconnected()")
  for _, binding in pairs(bindings:getDynamicBindings(self.TYPE)) do
    SendToProxy(binding.bindingId, "UPDATE_DISCONNECT", {}, "NOTIFY")
  end
end

--- Handle a state update for a camera entity.
--- Camera state updates are forwarded to the companion driver via the dynamic binding.
--- @param entity table<string, any> The entity data received from the ESPHome client.
--- @param state table<string, any> The state data received from the ESPHome client.
--- @return void
function CameraEntity:updated(entity, state)
  log:trace("CameraEntity:updated(%s, %s)", entity, state)
  local binding = bindings:getDynamicBinding(self.TYPE, "camera_" .. entity.key)
  if binding ~= nil then
    SendToProxy(binding.bindingId, "UPDATE_STATE", {
      entity = SerializeSafe(entity),
      state = SerializeSafe(state),
    }, "NOTIFY")
  end
end

return CameraEntity
