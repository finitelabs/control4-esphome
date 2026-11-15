-- A light group driver's rig for the conformance run: the group driver as it ships (lib.light.group), its device
-- two fake member lights. Each member takes the group's LIGHT_GROUP_COMMAND, fades over the RATE it is given, keeps
-- its level through an off, and tells the group LIGHT_GROUP_STATE with its target and again once its fade has run.
-- It answers a join inside the call, as a member on a controller does. Both members move together, so the rig's
-- device is the first. The driver folder is the runner's: the key the rig is listed under in test/light_rigs.lua.

local D = require("light_drivers")
local F = require("c4_fixtures")
local Light = require("lib.light")
local Range = require("lib.light.range")

local MEMBERS = { 801, 802 }
local CCT_MIN, CCT_MAX = 2000, 6500

--- @class GroupRigFade
--- @field from number
--- @field to number
--- @field t0 integer
--- @field ms integer

--- @class GroupRigMember
--- @field id integer
--- @field online boolean
--- @field on boolean
--- @field level GroupRigFade C4 level 0-100 along its fade.
--- @field lit number The level it comes back on at.
--- @field x GroupRigFade
--- @field y GroupRigFade
--- @field kelvin GroupRigFade
--- @field mode "xy"|"cct"
--- @field offAt integer|nil When the fade that turns it off ends.

--- @param v number
--- @return GroupRigFade
local function still(v)
  return { from = v, to = v, t0 = 0, ms = 0 }
end

--- @param f GroupRigFade
--- @param now integer
--- @return number
local function at(f, now)
  if f.ms <= 0 or now >= f.t0 + f.ms then
    return f.to
  end
  return f.from + (f.to - f.from) * (now - f.t0) / f.ms
end

--- @param f GroupRigFade
--- @param to number
--- @param now integer
--- @param ms integer
local function fade(f, to, now, ms)
  f.from, f.to, f.t0, f.ms = at(f, now), to, now, ms
end

--- @param h LightRigHarness
--- @param state LightValues|nil
--- @return GroupRigMember
local function newMember(h, id, state)
  local x, y = 0.3127, 0.329
  local mode, kelvin = "xy", 4000
  local c = state and state.color
  if c and c.kelvin and c.x == nil then
    mode, kelvin = "cct", c.kelvin
    x, y = C4:ColorCCTtoXY(c.kelvin)
  elseif c then
    x, y = c.x, c.y
  end
  local on = state ~= nil and state.on == true
  local level = Range.toLevel((state and state.level) or 1, h.lo or 1, h.hi or 100)
  return {
    id = id,
    online = true,
    on = on,
    level = still(on and level or 0),
    lit = level,
    x = still(x),
    y = still(y),
    kelvin = still(kelvin),
    mode = mode,
  }
end

--- A member's LIGHT_GROUP_STATE.
--- @param m GroupRigMember
--- @param now integer
--- @param final boolean Its targets, or where it is.
--- @return table<string, string>
local function stateOf(m, now, final)
  local function v(f)
    return final and f.to or at(f, now)
  end
  local level = v(m.level)
  local on = m.on and level > 0
  return {
    MEMBER_ID = tostring(m.id),
    ONLINE = m.online and "1" or "0",
    DIMS = "1",
    HAS_COLOR = "1",
    CCT_MIN = tostring(CCT_MIN),
    CCT_MAX = tostring(CCT_MAX),
    ON = on and "1" or "0",
    LEVEL = tostring(math.floor((on and level or 0) + 0.5)),
    X = string.format("%.4f", v(m.x)),
    Y = string.format("%.4f", v(m.y)),
    MODE = m.mode,
    KELVIN = m.mode == "cct" and tostring(math.floor(v(m.kelvin) + 0.5)) or nil,
  }
end

--- @param name string|nil What its checks are named by.
--- @param property string|nil The driver's member list property, ids joined by commas. Default "Member Lights".
--- @return LightRig
local function rig(name, property)
  --- @type LightRig
  local r = { name = name, folder = "" }

  function r.load(h, state)
    local members, byId = {}, {}
    for _, id in ipairs(MEMBERS) do
      local m = newMember(h, id, state)
      members[#members + 1], byId[id] = m, m
    end

    local function tell(m, final)
      local params = stateOf(m, h.clock.now(), final)
      h.clock.at(1, function()
        ExecuteCommand("LIGHT_GROUP_STATE", params)
      end)
    end

    --- @param m GroupRigMember
    --- @param p table<string, string>
    local function take(m, p)
      local now, ms = h.clock.now(), tonumber(p.RATE) or 0
      local kind = p.KIND
      if p.X and p.Y and (kind == "level" or kind == "color") then
        fade(m.x, tonumber(p.X), now, ms)
        fade(m.y, tonumber(p.Y), now, ms)
        if p.MODE == "cct" and p.KELVIN then
          fade(m.kelvin, tonumber(p.KELVIN), now, ms)
        end
        m.mode = p.MODE == "cct" and "cct" or "xy"
      end
      local level = kind == "off" and 0 or (kind == "level" and tonumber(p.LEVEL)) or nil
      if level and level > 0 then
        if not m.on then
          m.level = still(0)
        end
        m.on, m.lit, m.offAt = true, level, nil
        fade(m.level, level, now, ms)
      elseif level == 0 and m.on then
        fade(m.level, 0, now, ms)
        m.offAt = now + ms
        h.clock.at(ms, function()
          if m.offAt and h.clock.now() >= m.offAt then
            m.on, m.offAt = false, nil
            m.level = still(0)
          end
        end)
      end
      tell(m, true)
      h.clock.at(ms + 1, function()
        tell(m, false)
      end)
    end

    -- The clock's restore runs on every way a case ends, a raised error too.
    local send, restoreClock = C4.SendToDevice, h.clock.restore
    h.clock.restore = function()
      C4.SendToDevice = send
      restoreClock()
    end
    C4.SendToDevice = function(c4, id, cmd, params, ...)
      local m = byId[tonumber(id)]
      if not m then
        return send(c4, id, cmd, params, ...)
      end
      if not m.online then
        return
      end
      if cmd == "LIGHT_GROUP_JOIN" then
        ExecuteCommand("LIGHT_GROUP_STATE", stateOf(m, h.clock.now(), false))
      elseif cmd == "LIGHT_GROUP_COMMAND" then
        take(m, params or {})
      end
    end

    F.dofileBuild(D.path(D.root(), r.folder), "oss")
    h.light = Light.made[#Light.made]
    Properties[property or "Member Lights"] = table.concat(MEMBERS, ",")
    OnDriverInit()
    OnDriverLateInit()

    local function shown(m)
      local now = h.clock.now()
      local level = at(m.level, now)
      local on = m.on and level > 0
      local values = { on = on, level = Range.toDevice(on and level or m.lit, h.lo or 1, h.hi or 100) }
      if m.mode == "cct" then
        values.color = { kelvin = math.floor(at(m.kelvin, now) + 0.5) }
      else
        values.color = { x = at(m.x, now), y = at(m.y, now) }
      end
      return values
    end

    return {
      state = function()
        return shown(members[1])
      end,
      set = function(change)
        for _, m in ipairs(members) do
          if change.level then
            m.lit = Range.toLevel(change.level, h.lo or 1, h.hi or 100)
            if m.on or change.on then
              m.level = still(m.lit)
            end
          end
          if change.on ~= nil then
            m.on = change.on
            m.level = still(change.on and m.lit or 0)
            m.offAt = nil
          end
          if change.color then
            if change.color.kelvin and change.color.x == nil then
              m.mode, m.kelvin = "cct", still(change.color.kelvin)
              local x, y = C4:ColorCCTtoXY(change.color.kelvin)
              m.x, m.y = still(x), still(y)
            else
              m.mode, m.x, m.y = "xy", still(change.color.x), still(change.color.y)
            end
          end
          tell(m, false)
        end
      end,
      drop = function()
        for _, m in ipairs(members) do
          m.online = false
          tell(m, false)
        end
      end,
      back = function()
        for _, m in ipairs(members) do
          m.online = true
          tell(m, false)
        end
      end,
    }
  end

  return r
end

return { rig = rig }
