--- The light's facts: the checks and defaults of the profile and of each device, the static capabilities
--- the build writes into driver.xml, and the dynamic set the proxy is told. Pure.

local Caps = {}

--- The light_v2 proxy binding a profile names by default.
--- @type integer
Caps.PROXY = 5001

--- The longest rate one device command carries (ms), and a fade's maxMs by default.
--- @type integer
Caps.RATE_MAX = 65535

--- The color temperature range shown before a device names its own (K).
Caps.CCT_MIN, Caps.CCT_MAX = 2000, 6500

--- A device's brightness steps by default.
--- @type integer
Caps.LEVEL_STEPS = 255

--- How long after a landing a report may still predate it, by default (ms).
--- @type integer
Caps.WAIT_MS = 1000

--- The time between a walk's steps by default (ms).
--- @type integer
Caps.STEP_MS = 100

--- The dynamic capabilities the proxy's Navigator Dynamic Capabilities variable (6661) shows. It rewrites
--- the variable only when one of these changes, so the rest can lag what the proxy holds.
--- @type table<string, boolean>
Caps.REFLECTED = {
  dimmer = true,
  supports_target = true,
  supports_color = true,
  supports_color_correlated_temperature = true,
  has_extras = true,
  cold_start = true,
  color_rate_behavior = true,
  color_rate_min = true,
  color_rate_max = true,
  color_correlated_temperature_min = true,
  color_correlated_temperature_max = true,
}

--- One static capability, as the build writes it.
--- @class LightCapRow
--- @field key string
--- @field value string
--- @field comment string|nil Written as an XML comment above the key.

--- @alias LightDynamicCaps table<string, boolean|number>

local PROFILE_BOOLEANS = {
  dims = true,
  color = true,
  known = true,
  fades = true,
  defaultOn = true,
  scenes = true,
  onModes = true,
  flash = true,
  extras = true,
}

local PROFILE_FIELDS = { api = true, proxy = true, links = true, cct = true }

local DEVICE_FIELDS = {
  dims = true,
  color = true,
  cct = true,
  colorWhileOff = true,
  levelSteps = true,
  fade = true,
  feedback = true,
}

local FADE_FIELDS = { kind = true, curve = true, preOn = true, maxMs = true, own = true, stepMs = true }
local FEEDBACK_FIELDS = { shows = true, waitMs = true, refresh = true }
local FADE_KINDS = { device = true, own = true, walk = true }
local CURVES = { linear = true, smootherstep = true }
local SHOWS = { target = true, position = true }
local COLOR_WHILE_OFF = { send = true, hold = true }
local LINKS = { "top", "toggle", "bottom" }

--- The keys of a table, sorted, so errors come in one order.
--- @param t table<string, any>
--- @return string[]
local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)
  return keys
end

--- @param v any
--- @return boolean
local function whole(v)
  return type(v) == "number" and v == v and v >= 0 and v < math.huge and v == math.floor(v)
end

--- @param errors string[]
--- @param where string
--- @param t table<string, any>
--- @param known table<string, boolean>
local function unknown(errors, where, t, known)
  for _, k in ipairs(sortedKeys(t)) do
    if not known[k] then
      errors[#errors + 1] = string.format("%s%s is not a field this version knows; ignored", where, k)
    end
  end
end

--- A color temperature range checked and rounded, or nil with the reason.
--- @param v any
--- @return LightCctRange|nil
local function cctRange(v)
  if type(v) ~= "table" then
    return nil
  end
  local lo, hi = tonumber(v.minK), tonumber(v.maxK)
  if not (lo and hi and lo > 0 and lo <= hi and hi < math.huge) then
    return nil
  end
  return { minK = math.floor(lo + 0.5), maxK = math.floor(hi + 0.5) }
end

-----------------------------------------------------------------------------------------------------
-- The profile
-----------------------------------------------------------------------------------------------------

--- Check a driver's profile and fill its defaults: every boolean false, proxy 5001, no links. An error is
--- the driver's own, so Light.new raises with it; the api itself is Light.new's to check.
--- @param p table|nil
--- @return LightProfile|nil profile Nil with the errors.
--- @return string[] errors
function Caps.profile(p)
  if type(p) ~= "table" then
    return nil, { "the profile is required: what every device behind this driver can do" }
  end
  local errors = {}
  --- @type LightProfile
  local out = { api = p.api, proxy = Caps.PROXY }
  for _, k in ipairs(sortedKeys(p)) do
    local v = p[k]
    if PROFILE_BOOLEANS[k] then
      if type(v) ~= "boolean" then
        errors[#errors + 1] = string.format("profile.%s must be true or false", k)
      end
    elseif not PROFILE_FIELDS[k] then
      errors[#errors + 1] = string.format("profile.%s is not a field this version knows", k)
    end
  end
  for k in pairs(PROFILE_BOOLEANS) do
    out[k] = p[k] == true
  end
  if p.proxy ~= nil then
    if whole(p.proxy) and p.proxy > 0 then
      out.proxy = p.proxy
    else
      errors[#errors + 1] = "profile.proxy must be a binding id"
    end
  end
  if p.links ~= nil and p.links ~= false then
    if type(p.links) ~= "table" then
      errors[#errors + 1] = "profile.links must be { top, toggle, bottom } binding ids"
    else
      unknown(errors, "profile.links.", p.links, { top = true, toggle = true, bottom = true })
      local links = {}
      for _, name in ipairs(LINKS) do
        local id = p.links[name]
        if whole(id) and id > 0 then
          links[name] = id
        else
          errors[#errors + 1] = string.format("profile.links.%s must be a binding id", name)
        end
      end
      out.links = links
    end
  end
  if p.cct == true then
    out.cct = true
  elseif p.cct ~= nil and p.cct ~= false then
    out.cct = cctRange(p.cct)
    if not out.cct then
      errors[#errors + 1] = "profile.cct must be true or { minK, maxK } in Kelvin, minK no more than maxK"
    end
  end
  if out.known and out.cct == true then
    errors[#errors + 1] = "a known profile with cct names its range: cct = { minK, maxK }"
  end
  if #errors > 0 then
    return nil, errors
  end
  return out, {}
end

-----------------------------------------------------------------------------------------------------
-- The device
-----------------------------------------------------------------------------------------------------

--- @param errors string[]
--- @param d table
--- @param name string
--- @return boolean
local function flag(errors, d, name)
  local v = d[name]
  if v == nil then
    return false
  end
  if type(v) ~= "boolean" then
    errors[#errors + 1] = string.format("%s must be true or false; taken as false", name)
    return false
  end
  return v
end

--- The device's capabilities, held to the profile: beyond it a capability is dropped, and under a known
--- profile the capabilities are the profile's.
--- @param errors string[]
--- @param d table
--- @param profile LightProfile
--- @param out LightDevice
local function capabilities(errors, d, profile, out)
  out.dims = flag(errors, d, "dims")
  out.color = flag(errors, d, "color")
  local given = nil
  if d.cct ~= nil then
    given = cctRange(d.cct)
    if not given then
      errors[#errors + 1] = "cct must be { minK, maxK } in Kelvin, minK no more than maxK; ignored"
    end
  end
  local range = type(profile.cct) == "table" and profile.cct or nil
  if profile.known then
    if d.dims ~= nil and out.dims ~= profile.dims then
      errors[#errors + 1] = "the profile is known, so dims is the profile's"
    end
    if d.color ~= nil and out.color ~= profile.color then
      errors[#errors + 1] = "the profile is known, so color is the profile's"
    end
    if given and not (range and given.minK == range.minK and given.maxK == range.maxK) then
      errors[#errors + 1] = "the profile is known, so cct is the profile's"
    end
    out.dims, out.color = profile.dims, profile.color
    out.cct = range and { minK = range.minK, maxK = range.maxK } or nil
    return
  end
  if out.dims and not profile.dims then
    errors[#errors + 1] = "dims is beyond the profile; dropped"
    out.dims = false
  end
  if out.color and not profile.color then
    errors[#errors + 1] = "color is beyond the profile; dropped"
    out.color = false
  end
  if given and not profile.cct then
    errors[#errors + 1] = "cct is beyond the profile; dropped"
    given = nil
  end
  if range then
    if given and (given.minK < range.minK or given.maxK > range.maxK) then
      errors[#errors + 1] = "cct reaches beyond the profile's range; held to it"
      given = { minK = math.max(given.minK, range.minK), maxK = math.min(given.maxK, range.maxK) }
      if given.minK > given.maxK then
        given = nil
      end
    end
    out.cct = given or { minK = range.minK, maxK = range.maxK }
  else
    out.cct = given
  end
end

--- @param errors string[]
--- @param f table|nil
--- @param profile LightProfile
--- @param dims boolean
--- @return LightFade
local function fade(errors, f, profile, dims)
  if f ~= nil and type(f) ~= "table" then
    errors[#errors + 1] = "fade must be a table; ignored"
    f = nil
  end
  if f == nil then
    -- A profile with no fades leaves a device nothing to fade with: it runs its own, at once.
    if not profile.fades then
      return { kind = "own", maxMs = Caps.RATE_MAX, own = { onMs = 0, offMs = 0, changeMs = 0 } }
    end
    return { kind = "device", curve = "linear", preOn = false, maxMs = Caps.RATE_MAX }
  end
  unknown(errors, "fade.", f, FADE_FIELDS)
  local kind = "device"
  if f.kind ~= nil then
    if FADE_KINDS[f.kind] then
      kind = f.kind
    else
      errors[#errors + 1] = string.format("fade.kind %q is not a kind this version runs; ignored", tostring(f.kind))
    end
  end
  if kind ~= "own" and not profile.fades then
    errors[#errors + 1] = string.format('fade.kind "%s" is beyond a profile without fades; taken as "own"', kind)
    kind = "own"
  end
  --- @type LightFade
  local out = { kind = kind, maxMs = Caps.RATE_MAX }
  if f.maxMs ~= nil then
    if whole(f.maxMs) and f.maxMs > 0 then
      out.maxMs = f.maxMs
    else
      errors[#errors + 1] = "fade.maxMs must be a whole number of ms above 0; ignored"
    end
  end
  if kind == "device" then
    out.curve, out.preOn = "linear", false
    if f.curve ~= nil then
      if CURVES[f.curve] then
        out.curve = f.curve
      else
        errors[#errors + 1] =
          string.format("fade.curve %q is not a curve this version runs; ignored", tostring(f.curve))
      end
    end
    if f.preOn ~= nil then
      if type(f.preOn) ~= "boolean" then
        errors[#errors + 1] = "fade.preOn must be true or false; ignored"
      elseif f.preOn and not dims then
        errors[#errors + 1] = "fade.preOn needs dims; ignored"
      else
        out.preOn = f.preOn
      end
    end
  else
    if f.curve ~= nil then
      errors[#errors + 1] = 'fade.curve is for a "device" fade; ignored'
    end
    if f.preOn ~= nil then
      errors[#errors + 1] = 'fade.preOn is for a "device" fade; ignored'
    end
  end
  if kind == "own" then
    local own = type(f.own) == "table" and f.own or nil
    if not own then
      errors[#errors + 1] = 'fade.own is required for an "own" fade: { onMs, offMs, changeMs }; taken as 0'
    else
      unknown(errors, "fade.own.", own, { onMs = true, offMs = true, changeMs = true })
    end
    out.own = { onMs = 0, offMs = 0, changeMs = 0 }
    for _, name in ipairs({ "onMs", "offMs", "changeMs" }) do
      local v = own and own[name]
      if whole(v) then
        out.own[name] = v
      elseif own then
        errors[#errors + 1] = string.format("fade.own.%s must be a whole number of ms; taken as 0", name)
      end
    end
  elseif f.own ~= nil then
    errors[#errors + 1] = 'fade.own is for an "own" fade; ignored'
  end
  if kind == "walk" then
    out.stepMs = Caps.STEP_MS
    if f.stepMs ~= nil then
      if whole(f.stepMs) and f.stepMs > 0 then
        out.stepMs = f.stepMs
      else
        errors[#errors + 1] = "fade.stepMs must be a whole number of ms above 0; ignored"
      end
    end
  elseif f.stepMs ~= nil then
    errors[#errors + 1] = 'fade.stepMs is for a "walk" fade; ignored'
  end
  return out
end

--- @param errors string[]
--- @param f table|nil
--- @return LightFeedback
local function feedback(errors, f)
  --- @type LightFeedback
  local out = { shows = "target", waitMs = Caps.WAIT_MS, refresh = false }
  if f == nil then
    return out
  end
  if type(f) ~= "table" then
    errors[#errors + 1] = "feedback must be a table; ignored"
    return out
  end
  unknown(errors, "feedback.", f, FEEDBACK_FIELDS)
  if f.shows ~= nil then
    if SHOWS[f.shows] then
      out.shows = f.shows
    else
      errors[#errors + 1] = string.format('feedback.shows %q is not "target" or "position"; ignored', tostring(f.shows))
    end
  end
  if f.waitMs ~= nil then
    if whole(f.waitMs) then
      out.waitMs = f.waitMs
    else
      errors[#errors + 1] = "feedback.waitMs must be a whole number of ms; ignored"
    end
  end
  if f.refresh ~= nil then
    if type(f.refresh) == "boolean" then
      out.refresh = f.refresh
    else
      errors[#errors + 1] = "feedback.refresh must be true or false; ignored"
    end
  end
  return out
end

--- Check a connection's facts against the profile and fill their defaults. Nothing here refuses the
--- device whole: a field that fails is logged and takes its default, and a capability beyond the profile
--- is dropped.
--- @param d table|nil
--- @param profile LightProfile A checked profile.
--- @return LightDevice|nil device Nil only when d is not a table.
--- @return string[] errors
function Caps.device(d, profile)
  if type(d) ~= "table" then
    return nil, { "the device is not a table" }
  end
  local errors = {}
  unknown(errors, "", d, DEVICE_FIELDS)
  --- @type LightDevice
  local out = {}
  capabilities(errors, d, profile, out)
  out.colorWhileOff = "send"
  if d.colorWhileOff ~= nil then
    if COLOR_WHILE_OFF[d.colorWhileOff] then
      out.colorWhileOff = d.colorWhileOff
    else
      errors[#errors + 1] =
        string.format('colorWhileOff %q is not "send" or "hold"; ignored', tostring(d.colorWhileOff))
    end
  end
  out.levelSteps = Caps.LEVEL_STEPS
  if d.levelSteps ~= nil then
    if whole(d.levelSteps) and d.levelSteps > 0 then
      out.levelSteps = d.levelSteps
    else
      errors[#errors + 1] = "levelSteps must be a whole number of steps above 0; ignored"
    end
  end
  out.fade = fade(errors, d.fade, profile, out.dims)
  out.feedback = feedback(errors, d.feedback)
  return out, errors
end

--- Whether two checked values are the same, compared all the way down.
--- @param a any
--- @param b any
--- @return boolean
function Caps.same(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not Caps.same(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

--- Whether a device's change can be stopped part way: an "own" fade runs its lengths to the end.
--- @param device LightDevice
--- @return boolean
function Caps.stops(device)
  return device.fade.kind ~= "own"
end

-----------------------------------------------------------------------------------------------------
-- What the proxy is told
-----------------------------------------------------------------------------------------------------

--- @param v boolean
--- @return string
local function bool(v)
  return v and "True" or "False"
end

--- The static capabilities of a driver.xml, derived from the profile, in the order the build writes them.
--- @param profile LightProfile A checked profile.
--- @return LightCapRow[]
function Caps.static(profile)
  local dims, color, cct = profile.dims, profile.color, profile.cct ~= nil
  local fades = profile.fades
  local links = profile.links ~= nil
  local known = profile.known
  local range = type(profile.cct) == "table" and profile.cct or { minK = Caps.CCT_MIN, maxK = Caps.CCT_MAX }
  --- @param key string
  --- @param value string
  --- @param comment string|nil
  --- @return LightCapRow
  local function row(key, value, comment)
    return { key = key, value = value, comment = comment }
  end
  return {
    row("dimmer", bool(dims)),
    row("set_level", bool(dims)),
    row("supports_target", bool(dims)),
    row(
      "on_off",
      "True",
      "on_off, ramp_level and supports_default_on are deprecated in OS 3.3.2, but Composer's test panel "
        .. "still shows the On and Off buttons, the Ramp button and the Default On preset editor by them."
    ),
    row("ramp_level", bool(dims)),
    row("supports_default_on", bool(profile.defaultOn)),
    row("supports_brightness_stop", bool(dims and fades)),
    row("click_rates", bool(dims and fades)),
    row("hold_rates", bool(dims and fades)),
    row(
      "has_fixed_ramp_rate",
      "False",
      "Declared rather than left out, as Composer's test panel can treat a missing capability apart from "
        .. "its default."
    ),
    row("fixed_ramp_rate", "0"),
    row("brightness_rate_min", "0"),
    row("brightness_rate_max", tostring(Caps.RATE_MAX)),
    row(
      "brightness_rate_default",
      "0",
      "The proxy reads no rate default from either list, so this and color_rate_default are inert."
    ),
    row("click_rate_min", "0"),
    row("click_rate_max", "65535"),
    row("hold_rate_min", "1000"),
    row("hold_rate_max", "86400000"),
    row("supports_color", bool(known and color)),
    row("supports_color_correlated_temperature", bool(known and cct)),
    row("color_correlated_temperature_min", tostring(known and cct and range.minK or Caps.CCT_MIN)),
    row("color_correlated_temperature_max", tostring(known and cct and range.maxK or Caps.CCT_MAX)),
    row("color_trace_tolerance", "2"),
    row("supports_color_stop", bool((dims or color or cct) and fades)),
    row("color_rate_behavior", fades and "1" or "0"),
    row("color_rate_min", "0"),
    row("color_rate_max", tostring(Caps.RATE_MAX)),
    row("color_rate_default", "0"),
    row("has_button_events", bool(links)),
    row("has_leds", bool(links)),
    row("advanced_scene_support", bool(profile.scenes)),
    row("reduced_als_support", "False"),
    row("brightness_on_mode_preset", bool(profile.onModes and dims)),
    row("brightness_on_mode_previous", bool(profile.onModes and dims)),
    row("color_on_mode_fade", bool(profile.onModes and (color or cct))),
    row("color_on_mode_preset", bool(profile.onModes and (color or cct))),
    row("color_on_mode_previous", bool(profile.onModes and (color or cct))),
    row("has_extras", bool(profile.extras)),
    row("disable_flash", bool(not profile.flash)),
    row("cold_start", "False"),
    row("hide_proxy_properties", "False"),
    row("hide_proxy_events", "False"),
    row("multi_click", "False"),
    row("supports_broadcast_scenes", "False"),
    row("supports_multichannel_scenes", "False"),
    row("load_group_support", "False"),
  }
end

--- The full dynamic set the proxy is told for a device: every key, every time. The rate bounds go with
--- every send, since bounds of 0 and 0 make the proxy reject its own 750 ms default.
--- @param device LightDevice A checked device.
--- @param profile LightProfile A checked profile.
--- @return LightDynamicCaps
function Caps.dynamic(device, profile)
  local dims, color, cct = device.dims, device.color, device.cct ~= nil
  local stops = Caps.stops(device)
  local own = device.fade.own
  -- An "own" fade that takes time to change has one rate, which the proxy shows as fixed.
  local fixed = own and own.changeMs > 0 and own.changeMs or nil
  local maxMs = device.fade.maxMs
  --- @type LightDynamicCaps
  local caps = {
    dimmer = dims,
    set_level = dims,
    supports_target = dims,
    ramp_level = dims,
    supports_brightness_stop = dims and stops,
    has_fixed_ramp_rate = fixed ~= nil,
    fixed_ramp_rate = fixed or 0,
    brightness_rate_min = fixed or 0,
    brightness_rate_max = fixed or maxMs,
    supports_color = color,
    supports_color_correlated_temperature = cct,
    -- The proxy passes a brightness stop on only to a light that has a color stop, so one that dims has both.
    supports_color_stop = (dims or color or cct) and stops,
    color_rate_behavior = stops and 1 or 0,
    color_rate_min = 0,
    color_rate_max = maxMs,
    has_extras = profile.extras,
    cold_start = false,
    color_trace_tolerance = 2,
  }
  if cct then
    caps.color_correlated_temperature_min = device.cct.minK
    caps.color_correlated_temperature_max = device.cct.maxK
  end
  return caps
end

--- The keys of a dynamic set the proxy's 6661 does not show, which the light keeps a record of to know
--- whether the proxy holds them.
--- @param caps LightDynamicCaps
--- @return LightDynamicCaps
function Caps.unreflected(caps)
  local out = {}
  for k, v in pairs(caps) do
    if not Caps.REFLECTED[k] then
      out[k] = v
    end
  end
  return out
end

return Caps
