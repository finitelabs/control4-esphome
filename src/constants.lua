--- Constants used throughout the ESPHome driver.

return {
  --- Constant for showing a property in the UI.
  --- @type number
  SHOW_PROPERTY = 0,

  --- Constant for hiding a property in the UI.
  --- @type number
  HIDE_PROPERTY = 1,

  --- Default option for dynamic list properties.
  --- @type string
  SELECT_OPTION = "(Select)",

  --- Refresh list option for dynamic list properties.
  --- @type string
  REFRESH_LIST_OPTION = " --  Refresh List",

  --- Scanning indicator for dynamic list properties.
  --- @type string
  SCANNING_OPTION = " --  Scanning...",

  --- Stop scan option for dynamic list properties (keeps discovered devices).
  --- @type string
  STOP_SCAN_OPTION = " --  Stop Scan",

  --- Abort scan option for dynamic list properties (discards discovered devices).
  --- @type string
  ABORT_SCAN_OPTION = " --  Abort Scan",

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
