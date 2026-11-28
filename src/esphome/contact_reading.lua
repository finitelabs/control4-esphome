--- What a contact reads while its sensor is active: open, motion seen, present or occupied. An item
--- added from this build reads Opened, with the Contact When Active property hidden. An item added
--- before keeps reading Closed, as it always has, until that property is set to Opened.

local persist = require("lib.persist")
local constants = require("constants")

local PROPERTY = "Contact When Active"
--- Set on an item added from this build.
local ADDED_KEY = "ContactsReadOpened"
--- The reading last applied, so a change of the property can be told apart from its replay at load.
local APPLIED_KEY = "ContactReading"

local ContactReading = {}

--- Mark an item being added, and hide the property on an item so marked. Call from OnDriverInit.
--- @param driverInitType string|nil Director's init type: "DIT_ADDING", "DIT_STARTUP" or "DIT_UPDATING".
function ContactReading.init(driverInitType)
  if driverInitType == "DIT_ADDING" then
    persist:set(ADDED_KEY, true)
    C4:UpdateProperty(PROPERTY, "Opened")
  end
  if persist:get(ADDED_KEY) then
    C4:SetPropertyAttribs(PROPERTY, constants.HIDE_PROPERTY)
  end
end

--- Whether an active sensor's contact reads Opened.
--- @return boolean
function ContactReading.opensWhenActive()
  return persist:get(ADDED_KEY) == true or Properties[PROPERTY] == "Opened"
end

--- The state a contact reads.
--- @param active boolean Whether the sensor is active.
--- @return string state "OPENED" or "CLOSED".
function ContactReading.state(active)
  if ContactReading.opensWhenActive() then
    return active and "OPENED" or "CLOSED"
  end
  return active and "CLOSED" or "OPENED"
end

--- Run `retell` when the reading differs from the one last applied. Call from the property's handler,
--- which also runs at each load.
--- @param retell fun() Tells each kept contact state again in the new reading.
function ContactReading.applied(retell)
  local reading = ContactReading.opensWhenActive() and "Opened" or "Closed"
  local before = persist:get(APPLIED_KEY)
  if before == reading then
    return
  end
  persist:set(APPLIED_KEY, reading)
  if before ~= nil then
    retell()
  end
end

return ContactReading
