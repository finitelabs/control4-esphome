--- The groups the light belongs to: Control4 load groups, from JOIN_GROUP, LEAVE_GROUP and SET_GROUP_SYNC, and
--- group drivers built on lib.light.group, from LIGHT_GROUP_JOIN and LIGHT_GROUP_LEAVE.
---
--- A load group in sync takes the light's own on, off, toggle, level and button commands: the light hands each to
--- every group it keeps in sync with and does not act on it, and the group then moves all its members. The group's
--- own commands are never handed back. A group driver is told what the light shows whenever it changes, so it can
--- show its members' state. Membership is kept through lib.persist, since a group tells it only when its members
--- change.

local log = require("lib.logging")
local persist = require("lib.persist")

require("lib.utils")

local P_GROUPS = "load_groups"
local P_DRIVERS = "light_groups"

--- What the light tells a group driver: its facts and what its proxy shows, at the end of any change.
--- @class LightMemberState
--- @field online boolean
--- @field dims boolean
--- @field hasColor boolean
--- @field cct LightCctRange|nil
--- @field on boolean
--- @field level integer C4 level 0-100.
--- @field color LightColor|nil

--- @class LightGroups
--- @field told table<string, string> What each group driver was last told, by group id, as its params' text.
local Groups = {}
Groups.__index = Groups

Groups.P_GROUPS = P_GROUPS
Groups.P_DRIVERS = P_DRIVERS

--- @return LightGroups
function Groups.new()
  return setmetatable({ told = {} }, Groups)
end

--- The groups by id, each with whether it keeps the light in sync.
--- @return table<string, boolean>
function Groups:all()
  return persist:get(P_GROUPS, {})
end

--- Join a group, or change whether it keeps the light in sync.
--- @param groupId integer
--- @param keepSync boolean
function Groups:join(groupId, keepSync)
  local groups = self:all()
  groups[tostring(groupId)] = keepSync
  persist:set(P_GROUPS, groups)
end

--- Leave a group.
--- @param groupId integer
function Groups:leave(groupId)
  local groups = self:all()
  if groups[tostring(groupId)] == nil then
    return
  end
  groups[tostring(groupId)] = nil
  persist:set(P_GROUPS, groups)
end

--- The groups that keep the light in sync, in id order.
--- @return integer[]
function Groups:synced()
  local ids = {}
  for id, keepSync in pairs(self:all()) do
    local n = tointeger(id)
    if keepSync and n then
      ids[#ids + 1] = n
    end
  end
  table.sort(ids)
  return ids
end

--- Hand a command to every group in sync. Returns whether any took it, in which case the light does not act.
--- @param strCommand string
--- @param tParams table<string, string>
--- @return boolean
function Groups:forward(strCommand, tParams)
  local ids = self:synced()
  for _, id in ipairs(ids) do
    log:debug("%s handed to load group %d, which keeps the light in sync", strCommand, id)
    C4:SendToDevice(id, strCommand, tParams)
  end
  return #ids > 0
end

-----------------------------------------------------------------------------------------------------
-- Group drivers
-----------------------------------------------------------------------------------------------------

--- The group drivers the light is a member of: the id each knows the light by, by group id.
--- @return table<string, string>
function Groups:drivers()
  return persist:get(P_DRIVERS, {})
end

--- Join a group driver, which knows the light as `memberId`. It is told the light's state at once.
--- @param groupId integer
--- @param memberId string
function Groups:enroll(groupId, memberId)
  local drivers = self:drivers()
  drivers[tostring(groupId)] = memberId
  persist:set(P_DRIVERS, drivers)
  self.told[tostring(groupId)] = nil
end

--- Leave a group driver.
--- @param groupId integer
function Groups:withdraw(groupId)
  local drivers = self:drivers()
  if drivers[tostring(groupId)] == nil then
    return
  end
  drivers[tostring(groupId)] = nil
  persist:set(P_DRIVERS, drivers)
  self.told[tostring(groupId)] = nil
end

--- @param n number|nil
--- @return string|nil
local function fixed(n)
  return n ~= nil and string.format("%.4f", n) or nil
end

--- Tell each group driver the light's state, where it differs from what that group was last told.
--- @param state LightMemberState
function Groups:tell(state)
  local color = state.color
  local params = {
    ONLINE = tostring(state.online),
    DIMS = tostring(state.dims),
    HAS_COLOR = tostring(state.hasColor),
    CCT_MIN = state.cct and tostring(state.cct.minK) or nil,
    CCT_MAX = state.cct and tostring(state.cct.maxK) or nil,
    ON = tostring(state.on),
    LEVEL = tostring(state.level),
    X = color and fixed(color.x) or nil,
    Y = color and fixed(color.y) or nil,
    MODE = color and color.mode or nil,
    KELVIN = color and color.kelvin and tostring(color.kelvin) or nil,
  }
  local keys = {}
  for k in pairs(params) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = k .. "=" .. params[k]
  end
  local text = table.concat(parts, ";")
  for groupId, memberId in pairs(self:drivers()) do
    local id = tointeger(groupId)
    if id and self.told[groupId] ~= text then
      self.told[groupId] = text
      local sent = { MEMBER_ID = memberId }
      for k, v in pairs(params) do
        sent[k] = v
      end
      C4:SendToDevice(id, "LIGHT_GROUP_STATE", sent)
    end
  end
end

return Groups
