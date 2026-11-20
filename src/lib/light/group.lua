--- A group driver's kit: the adapter of a light whose device is its members, other lights built on lib.light
--- that offer load groups.
---
--- The group's own Light decides each command once, with the group's on modes, Dim-To-Warm, presets, scenes and
--- rates and Min and Max On, and this adapter hands it to every member as LIGHT_GROUP_COMMAND, the final level (a
--- percent of the device's brightness) and color. Each member goes there inside its own Min and Max On, takes what it
--- can do and fades itself. A member tells the group what
--- it shows as LIGHT_GROUP_STATE, and the group shows its members by one rule: what most of them show, or the
--- lowest or highest member. After a command the group waits out the fade before it reconciles, so members
--- reporting one by one do not move it.
---
--- A driver makes the kit, gives it to Light.new as the adapter, attaches the light, and passes on its member list
--- and its report rule:
---   local group = Group.new()
---   light = Light.new(group, profile)
---   group:attach(light)
---   group:setMembers(ids)     -- from the member list property
---   group:setRule("most")     -- "most", "lowest" or "highest"
---   group:onChange(fn)        -- optional: fn(online, total) after each member change
---   group:dissolve()          -- from OnDriverRemovedFromProject
--- The group's profile says cct = true and leaves loadGroups out: a group is not a member of a group.

local log = require("lib.logging")
local Range = require("lib.light.range")
local Timer = require("lib.light.timer")

require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("lib.utils")

local TIMER_QUIET = "LightGroup.Quiet"

--- @alias LightGroupRule "most"|"lowest"|"highest"

--- What a member last told the group.
--- @class LightGroupMember
--- @field online boolean
--- @field dims boolean
--- @field hasColor boolean
--- @field cct LightCctRange|nil
--- @field on boolean
--- @field level integer C4 level 0-100.
--- @field color LightColor|nil

--- @class LightGroup : LightAdapter
--- @field light Light|nil
--- @field members integer[] The member ids, in the order the list gives them.
--- @field states table<string, LightGroupMember> What each member last told, by member id.
--- @field rule LightGroupRule
--- @field quietUntil integer C4:GetTime() ms until which members' reports wait.
--- @field asked boolean A refresh waits for the quiet to end.
--- @field connected boolean A member is online, so the group light is.
--- @field changed fun(online: integer, total: integer)|nil The driver's hook, told after every member change.
local Group = {}
Group.__index = Group

--- How long after a command's fade the group waits for its members' last reports.
Group.SETTLE_MS = 500

--- The level a member is sent for the group's device brightness, and a member tells back: a percent of the device's
--- brightness, which the group's Min and Max On have placed.
--- @param brightness number 0-1.
--- @return integer level 1-100.
function Group.levelOf(brightness)
  return Range.percent(brightness)
end

--- @type table<string, boolean>
Group.RULES = { most = true, lowest = true, highest = true }

--- @return LightGroup
function Group.new()
  return setmetatable({
    members = {},
    states = {},
    rule = "most",
    quietUntil = 0,
    asked = false,
    connected = false,
  }, Group)
end

--- The group's light, made with this kit as its adapter. It takes its members' LIGHT_GROUP_STATE from here on.
--- @param light Light
function Group:attach(light)
  self.light = light
  EC.LIGHT_GROUP_STATE = function(tParams)
    self:state(tParams or {})
  end
end

--- The driver's hook, told how many members are online of how many listed after every member state, list or rule
--- change. The kit's own handlers stay the kit's.
--- @param fn fun(online: integer, total: integer)
function Group:onChange(fn)
  self.changed = fn
end

--- The one delivery step: a command to every member, in one pass.
--- @param strCommand string
--- @param tParams table<string, string>
function Group:deliver(strCommand, tParams)
  for _, id in ipairs(self.members) do
    C4:SendToDevice(id, strCommand, tParams)
  end
end

--- The member list: members gone are told they left, members new are joined and tell their state.
--- @param ids integer[]
function Group:setMembers(ids)
  local was = {}
  for _, id in ipairs(self.members) do
    was[id] = true
  end
  local now = {}
  for _, id in ipairs(ids) do
    now[id] = true
  end
  local me = tostring(C4:GetDeviceID())
  for _, id in ipairs(self.members) do
    if not now[id] then
      self:_leave(id)
    end
  end
  -- A member's state can come back within its join, so the list is set before any join goes out.
  self.members = {}
  for _, id in ipairs(ids) do
    self.members[#self.members + 1] = id
  end
  for _, id in ipairs(ids) do
    if not was[id] or not self.states[tostring(id)] then
      C4:SendToDevice(id, "LIGHT_GROUP_JOIN", { GROUP_ID = me, MEMBER_ID = tostring(id) })
    end
  end
  self:_changed()
end

--- The group's driver is deleted from the project: every member is told it left, so none keeps telling a group that
--- is gone. A driver update or a controller restart never calls it, and the members stay joined.
function Group:dissolve()
  for _, id in ipairs(self.members) do
    self:_leave(id)
  end
  self.members = {}
end

--- How the group shows its members.
--- @param rule string
function Group:setRule(rule)
  if not Group.RULES[rule] then
    log:warn("LightGroup: no report rule %s", tostring(rule))
    return
  end
  self.rule = rule
  self:_changed()
end

--- A member's LIGHT_GROUP_STATE.
--- @param tParams table<string, string>
function Group:state(tParams)
  local id = Select(tParams, "MEMBER_ID")
  local member = id and tointeger(id)
  local listed = false
  for _, m in ipairs(self.members) do
    listed = listed or m == member
  end
  if not listed then
    log:debug("LightGroup: state from %s, which is not a member: dropped", tostring(id))
    return
  end
  local color
  local x, y = tonumber(Select(tParams, "X")), tonumber(Select(tParams, "Y"))
  if x and y then
    local mode = Select(tParams, "MODE") == "cct" and "cct" or "xy"
    color = { x = x, y = y, mode = mode, kelvin = mode == "cct" and tointeger(Select(tParams, "KELVIN")) or nil }
  end
  local minK, maxK = tointeger(Select(tParams, "CCT_MIN")), tointeger(Select(tParams, "CCT_MAX"))
  self.states[id] = {
    online = toboolean(Select(tParams, "ONLINE")),
    dims = toboolean(Select(tParams, "DIMS")),
    hasColor = toboolean(Select(tParams, "HAS_COLOR")),
    cct = minK and maxK and { minK = minK, maxK = maxK } or nil,
    on = toboolean(Select(tParams, "ON")),
    level = tointeger(Select(tParams, "LEVEL")) or 0,
    color = color,
  }
  self:_changed()
end

-----------------------------------------------------------------------------------------------------
-- The adapter
-----------------------------------------------------------------------------------------------------

--- @param color LightColor
--- @param params table<string, string>
local function putColor(color, params)
  params.X = string.format("%.4f", color.x)
  params.Y = string.format("%.4f", color.y)
  params.MODE = color.mode
  params.KELVIN = color.kelvin and tostring(color.kelvin) or nil
end

--- The group light's command, handed to every member as the level and color it decided.
--- @param cmd LightCommand
function Group:send(cmd)
  if cmd.kind == "preOn" then
    -- Each member opens its own rated on from off as its device needs.
    return nil
  end
  -- A stop rests each member where the group's estimate is, at once.
  local params = {
    GROUP_ID = tostring(C4:GetDeviceID()),
    RATE = tostring(cmd.kind == "stop" and 0 or cmd.transitionMs),
  }
  if cmd.setsLevel then
    if cmd.on then
      params.KIND, params.LEVEL = "level", tostring(Group.levelOf(cmd.level))
    else
      params.KIND = cmd.setsColor and "level" or "off"
      params.LEVEL = cmd.setsColor and "0" or nil
    end
    if cmd.setsColor and cmd.color then
      putColor(cmd.color, params)
    end
  elseif cmd.setsColor and cmd.color then
    params.KIND = "color"
    putColor(cmd.color, params)
  else
    return nil
  end
  self.quietUntil = math.max(self.quietUntil, C4:GetTime() + tonumber(params.RATE) + Group.SETTLE_MS)
  self:deliver("LIGHT_GROUP_COMMAND", params)
  self:_armQuiet()
  return nil
end

--- The group light asks for its state: it is the members', once the quiet after a command has ended.
function Group:refresh()
  if C4:GetTime() < self.quietUntil then
    self.asked = true
    self:_armQuiet()
    return
  end
  self:_report("final")
end

--- A group has no device page.
--- @param _ LightShown
function Group:show(_) end

-----------------------------------------------------------------------------------------------------
-- The rule
-----------------------------------------------------------------------------------------------------

--- @param member LightGroupMember
--- @return integer
local function shownLevel(member)
  return member.on and member.level or 0
end

--- A member's state as one key, for counting the members that show the same.
--- @param member LightGroupMember
--- @return string
local function key(member)
  local c = member.color
  local color = c and string.format("%.2f,%.2f", c.x, c.y) or "-"
  return string.format("%s/%d/%s", tostring(member.on), shownLevel(member), member.on and color or "-")
end

--- The member that stands for the group under the rule, of those online. Ties go to the higher level, then the
--- earlier member in the list.
--- @return LightGroupMember|nil
function Group:_chosen()
  local online = {}
  for _, id in ipairs(self.members) do
    local s = self.states[tostring(id)]
    if s and s.online then
      online[#online + 1] = s
    end
  end
  local best, bestScore
  local counts = {}
  if self.rule == "most" then
    for _, s in ipairs(online) do
      counts[key(s)] = (counts[key(s)] or 0) + 1
    end
  end
  for _, s in ipairs(online) do
    local score
    if self.rule == "most" then
      score = counts[key(s)] * 1000 + shownLevel(s)
    elseif self.rule == "lowest" then
      score = -shownLevel(s)
    else
      score = shownLevel(s)
    end
    if bestScore == nil or score > bestScore then
      best, bestScore = s, score
    end
  end
  return best
end

--- The group's device: what any online member can do, and the widest white range among them. Members fade
--- themselves over the time each command asks and tell where they head.
--- @return LightDevice|nil
function Group:_device()
  local device = { dims = false, color = false, fade = { kind = "device" }, feedback = { shows = "target" } }
  local any = false
  for _, id in ipairs(self.members) do
    local s = self.states[tostring(id)]
    if s and s.online then
      any = true
      device.dims = device.dims or s.dims
      device.color = device.color or s.hasColor
      if s.cct then
        local cct = device.cct
        device.cct = cct and { minK = math.min(cct.minK, s.cct.minK), maxK = math.max(cct.maxK, s.cct.maxK) }
          or { minK = s.cct.minK, maxK = s.cct.maxK }
      end
    end
  end
  return any and device or nil
end

--- The members changed: the group's device facts, and its state once no command's fade is running.
--- @private
function Group:_changed()
  if self.changed then
    local online = 0
    for _, id in ipairs(self.members) do
      local s = self.states[tostring(id)]
      if s and s.online then
        online = online + 1
      end
    end
    self.changed(online, #self.members)
  end
  local light = self.light
  if not light then
    return
  end
  local device = self:_device()
  if not device then
    if self.connected then
      self.connected = false
      light:lost()
    end
    return
  end
  light:declare(device)
  self.connected = true
  if C4:GetTime() < self.quietUntil then
    self:_armQuiet()
    return
  end
  self:_report(self.asked and "final" or "push")
end

--- Report the chosen member's state to the group light.
--- @private
--- @param kind LightReportKind
function Group:_report(kind)
  local chosen = self:_chosen()
  if not chosen or not self.light then
    return
  end
  self.asked = false
  self.light:report({
    kind = kind,
    on = chosen.on,
    level = chosen.on and chosen.level / 100 or nil,
    color = chosen.on and chosen.color or nil,
  })
end

--- Tell a member it left the group, and forget what it told.
--- @private
--- @param id integer
function Group:_leave(id)
  C4:SendToDevice(id, "LIGHT_GROUP_LEAVE", { GROUP_ID = tostring(C4:GetDeviceID()) })
  self.states[tostring(id)] = nil
end

--- Reconcile once the quiet after the newest command ends.
--- @private
function Group:_armQuiet()
  Timer.arm(TIMER_QUIET, self.quietUntil - C4:GetTime(), function()
    self:_changed()
  end)
end

return Group
