--- @module "constants"
--- Constants used throughout the ESPHome driver.

return {
  --- Constant for showing a property in the UI.
  --- @type number
  SHOW_PROPERTY = 0,

  --- Constant for hiding a property in the UI.
  --- @type number
  HIDE_PROPERTY = 1,

  --- Constant for button action IDs.
  --- @type table<string, integer>
  ButtonIds = {
    TOP = 0,
    BOTTOM = 1,
    TOGGLE = 2,
  },

  --- Constant for button action types.
  --- @type table<string, integer>
  ButtonActions = {
    RELEASE_HOLD = 0,
    PRESS = 1,
    RELEASE_CLICK = 2,
  },
}
