--- The Control4 load groups the light belongs to, from JOIN_GROUP, LEAVE_GROUP and SET_GROUP_SYNC.
---
--- A group in sync takes the light's own on, off, toggle, level and button commands: the light hands each to every
--- group it keeps in sync with and does not act on it, and the group then moves all its members. The group's own
--- commands are never handed back. Membership is kept through lib.persist, since a group tells it only when its
--- members change.

local log = require("lib.logging")
local persist = require("lib.persist")

require("lib.utils")

local P_GROUPS = "load_groups"

--- @class LightGroups
local Groups = {}
Groups.__index = Groups

Groups.P_GROUPS = P_GROUPS

--- @return LightGroups
function Groups.new()
  return setmetatable({}, Groups)
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

return Groups
