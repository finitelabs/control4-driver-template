-- Group drivers built on lib.light.group: a member taking a group's decided commands and telling what it shows,
-- over MemoryLight behind the fake proxy, and the kit itself over a group light whose members are recorded. The
-- template's own test: no driver repo gets it.

local HERE = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
package.path = HERE .. "?.lua;" .. package.path

local T = require("testlib")

require("c4_shim")

local F = require("c4_fixtures")
local Fake = require("light_proxy_fake")
local K = require("behavior_kit")
local M = require("memory_light")

local GROUP = 3301

local function case(fn)
  K.case(T, fn)
end

local near = K.near

--- Record what is handed to other devices until `restore` is called.
--- @return {[1]: integer, [2]: string, [3]: table}[] handed
--- @return fun() restore
local function recordHanded()
  local handed = {}
  local sendToDevice = C4.SendToDevice
  C4.SendToDevice = function(c4, id, cmd, params, ...)
    handed[#handed + 1] = { id, cmd, params }
    return sendToDevice(c4, id, cmd, params, ...)
  end
  return handed, function()
    C4.SendToDevice = sendToDevice
  end
end

--- The handed commands named `cmd`.
--- @param handed {[1]: integer, [2]: string, [3]: table}[]
--- @param cmd string
--- @return {[1]: integer, [2]: string, [3]: table}[]
local function named(handed, cmd)
  local out = {}
  for _, h in ipairs(handed) do
    if h[2] == cmd then
      out[#out + 1] = h
    end
  end
  return out
end

-----------------------------------------------------------------------------------------------------
-- A member
-----------------------------------------------------------------------------------------------------

--- A world over a light that offers load groups, lit to `level` when given.
--- @param level integer|nil
--- @param o table|nil
--- @return MemoryWorld
local function member(level, o)
  local base = M.copy(o or K.ES)
  base.profile = M.profile(base)
  base.profile.loadGroups = true
  return K.world(base, {}, level)
end

--- A group driver's command to the member, on the proxy binding.
local function take(w, params)
  params.GROUP_ID = tostring(GROUP)
  w.proxy:send("LIGHT_GROUP_COMMAND", params)
end

T.section("a member joined tells the group its facts and what it shows")
case(function()
  local w = member(40)
  local handed, restore = recordHanded()
  w.proxy:send("LIGHT_GROUP_JOIN", { GROUP_ID = tostring(GROUP), MEMBER_ID = "77" })
  local told = named(handed, "LIGHT_GROUP_STATE")
  T.eq("one state, to the group", { #told, told[1] and told[1][1] }, { 1, GROUP })
  local p = told[1][3]
  T.eq(
    "as the member the group knows, with its facts and level",
    { p.MEMBER_ID, p.ONLINE, p.DIMS, p.HAS_COLOR, p.CCT_MIN, p.CCT_MAX, p.ON, p.LEVEL },
    { "77", "true", "true", "true", "2000", "6500", "true", "40" }
  )
  restore()
  w.restore()
end)

T.section("a group's level goes over its rate, with the member's on mode left out")
case(function()
  local w = member()
  K.onMode(w, K.ON_PRESET)
  w.proxy:send("OFF", {})
  w.run(5000)
  w.m.sent = {}
  take(w, { KIND = "level", LEVEL = "60", RATE = "1000" })
  local first = w.m.sent[#w.m.sent]
  T.eq("one change to 60 over 1000 ms", { first and first.kind, first and first.transitionMs }, { "change", 1000 })
  T.eq("its On Color is not applied", first and first.setsColor, false)
  w.run(5000)
  T.eq("the proxy shows 60", w.proxy.level, 60)
  w.restore()
end)

T.section("a group's color goes with its level, and an off with its Dim color")
case(function()
  local w = member(30)
  take(w, { KIND = "level", LEVEL = "70", RATE = "0", X = "0.6", Y = "0.3", MODE = "xy" })
  local cmd = w.m.sent[#w.m.sent]
  T.truthy("level and color in one command", cmd.setsLevel and cmd.setsColor and near(cmd.color.x, 0.6, 0.01))
  w.run(5000)
  w.m.sent = {}
  take(w, { KIND = "level", LEVEL = "0", RATE = "0", X = "0.53", Y = "0.41", MODE = "xy" })
  cmd = w.m.sent[#w.m.sent]
  T.truthy("an off that carries its color", cmd and not cmd.on and cmd.setsColor and near(cmd.color.x, 0.53, 0.01))
  w.restore()
end)

T.section("a group's off and color")
case(function()
  local w = member(50)
  take(w, { KIND = "color", X = "0.3", Y = "0.6", MODE = "xy", RATE = "0" })
  w.run(5000)
  T.truthy("the color", near(K.device(w).color.x, 0.3, 0.01))
  take(w, { KIND = "off", RATE = "0" })
  w.run(5000)
  T.eq("off", { w.proxy.level, K.device(w).on }, { 0, false })
  w.m.sent = {}
  take(w, { KIND = "color", RATE = "0" })
  take(w, { KIND = "blink" })
  take(w, { KIND = "stopLevel" })
  T.eq("a color with no color, and a kind there is none of, send nothing", #w.m.sent, 0)
  w.restore()
end)

T.section("a member tells the group where a command takes it, once")
case(function()
  local w = member(20)
  w.proxy:send("LIGHT_GROUP_JOIN", { GROUP_ID = tostring(GROUP), MEMBER_ID = "77" })
  local handed, restore = recordHanded()
  take(w, { KIND = "level", LEVEL = "80", RATE = "2000" })
  w.run(5000)
  local told = named(handed, "LIGHT_GROUP_STATE")
  T.eq("told 80 as the command goes out, and nothing more", { #told, told[1] and told[1][3].LEVEL }, { 1, "80" })
  w.proxy:send("SET_LEVEL", { LEVEL = 10 })
  w.run(5000)
  told = named(handed, "LIGHT_GROUP_STATE")
  T.eq("its own command is told too", told[#told] and told[#told][3].LEVEL, "10")
  restore()
  w.restore()
end)

T.section("a member with its own Min and Max On goes to the percent the group sends, and tells it back")
case(function()
  local w = member(20)
  w.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 90 })
  w.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 10 })
  w.run(5000)
  w.proxy:send("LIGHT_GROUP_JOIN", { GROUP_ID = tostring(GROUP), MEMBER_ID = "77" })
  local handed, restore = recordHanded()
  take(w, { KIND = "level", LEVEL = "80", RATE = "0" })
  w.run(5000)
  T.eq("the group's 80 is 80 % of the device, not 80 % of its own range", K.devicePercent(w), 80)
  local told = named(handed, "LIGHT_GROUP_STATE")
  T.eq("and it tells the group 80", told[#told] and told[#told][3].LEVEL, "80")
  take(w, { KIND = "level", LEVEL = "95", RATE = "0" })
  w.run(5000)
  T.eq("a percent past its own Max On stops at its Max On", K.devicePercent(w), 90)
  take(w, { KIND = "level", LEVEL = "5", RATE = "0" })
  w.run(5000)
  T.eq("and one under its Min On at its Min On", K.devicePercent(w), 10)
  w.proxy:send("SET_LEVEL", { LEVEL = 100 })
  w.run(5000)
  told = named(handed, "LIGHT_GROUP_STATE")
  T.eq("its own 100 at Max On 90 is told as 90", told[#told] and told[#told][3].LEVEL, "90")
  restore()
  w.restore()
end)

T.section("a member that loses its device tells the group it is offline")
case(function()
  local w = member(20)
  w.proxy:send("LIGHT_GROUP_JOIN", { GROUP_ID = tostring(GROUP), MEMBER_ID = "77" })
  local handed, restore = recordHanded()
  w.light:lost(false)
  local told = named(handed, "LIGHT_GROUP_STATE")
  T.eq("offline", told[#told] and told[#told][3].ONLINE, "false")
  restore()
  w.restore()
end)

T.section("a group driver's command arrives as ExecuteCommand too")
case(function()
  local w = member(20)
  ExecuteCommand("LIGHT_GROUP_COMMAND", { GROUP_ID = tostring(GROUP), KIND = "level", LEVEL = "90", RATE = "0" })
  w.run(5000)
  T.eq("at 90", w.proxy.level, 90)
  w.restore()
end)

T.section("a member that left tells the group nothing more, and membership survives a restart")
case(function()
  local w = member(20)
  w.proxy:send("LIGHT_GROUP_JOIN", { GROUP_ID = tostring(GROUP), MEMBER_ID = "77" })
  w.restart()
  w.run(5000)
  local handed, restore = recordHanded()
  w.proxy:send("SET_LEVEL", { LEVEL = 55 })
  w.run(5000)
  T.eq("still a member after the restart", #named(handed, "LIGHT_GROUP_STATE") > 0, true)
  w.proxy:send("LIGHT_GROUP_LEAVE", { GROUP_ID = tostring(GROUP) })
  local before = #named(handed, "LIGHT_GROUP_STATE")
  w.proxy:send("SET_LEVEL", { LEVEL = 5 })
  w.run(5000)
  T.eq("nothing after it left", #named(handed, "LIGHT_GROUP_STATE"), before)
  restore()
  w.restore()
end)

T.section("a light that does not offer load groups takes no group driver's command")
case(function()
  local base = M.copy(K.ES)
  base.profile = M.profile(base)
  local w = K.world(base, {}, 20)
  take(w, { KIND = "level", LEVEL = "90", RATE = "0" })
  w.run(5000)
  T.eq("still at 20", w.proxy.level, 20)
  w.restore()
end)

-----------------------------------------------------------------------------------------------------
-- The kit
-----------------------------------------------------------------------------------------------------

local MEMBERS = { 11, 12, 13 }

--- A group light over the kit, with members whose commands are recorded.
local function groupWorld()
  local persist = require("lib.persist")
  for _, key in ipairs(M.KEYS) do
    persist:delete(key)
  end
  local clock = F.virtualClock()
  local proxy = Fake.install(clock, { links = false })
  local Light = require("lib.light")
  local Group = require("lib.light.group")
  local group = Group.new()
  local light = Light.new(group, {
    api = Light.API,
    dims = true,
    color = true,
    cct = true,
    fades = true,
    defaultOn = true,
    scenes = true,
    onModes = true,
  })
  group:attach(light)
  local handed, unrecord = recordHanded()
  light:start()
  group:setMembers(MEMBERS)
  local g = { clock = clock, proxy = proxy, group = group, light = light, handed = handed }
  function g.run(ms)
    clock.run(ms)
  end
  function g.restore()
    unrecord()
    proxy:restore()
    clock.restore()
  end
  return g
end

--- A member's LIGHT_GROUP_STATE.
--- @param id integer
--- @param on boolean
--- @param level integer
--- @param o table|nil online, dims, color, cct, x, y
local function state(id, on, level, o)
  o = o or {}
  ExecuteCommand("LIGHT_GROUP_STATE", {
    MEMBER_ID = tostring(id),
    ONLINE = tostring(o.online ~= false),
    DIMS = "true",
    HAS_COLOR = tostring(o.color ~= false),
    CCT_MIN = o.cct and tostring(o.cct[1]) or nil,
    CCT_MAX = o.cct and tostring(o.cct[2]) or nil,
    ON = tostring(on),
    LEVEL = tostring(level),
    X = o.x and tostring(o.x) or nil,
    Y = o.y and tostring(o.y) or nil,
    MODE = o.x and "xy" or nil,
  })
end

T.section("the kit joins each member, and the group is online once one tells its state")
case(function()
  local g = groupWorld()
  local joins = named(g.handed, "LIGHT_GROUP_JOIN")
  T.eq("one join each, naming the member", #joins, 3)
  T.eq("as the id the group knows", joins[2][1] == 12 and joins[2][3].MEMBER_ID, "12")
  T.eq("offline with no state", g.proxy.online, false)
  state(11, true, 40)
  g.run(1000)
  T.eq("online, at the member's level", { g.proxy.online, g.proxy.level }, { true, 40 })
  g.restore()
end)

T.section("a member that tells its state within its join is taken")
case(function()
  local g = groupWorld()
  g.group:setMembers({})
  local send = C4.SendToDevice
  C4.SendToDevice = function(c4, id, cmd, params, ...)
    if cmd == "LIGHT_GROUP_JOIN" then
      state(id, true, 30)
      return
    end
    return send(c4, id, cmd, params, ...)
  end
  g.group:setMembers({ 11, 12 })
  C4.SendToDevice = send
  g.run(1000)
  T.eq("online, at the members' level", { g.proxy.online, g.proxy.level }, { true, 30 })
  g.restore()
end)

T.section("the report rule: most members, the lowest or the highest")
case(function()
  local g = groupWorld()
  state(11, true, 20)
  state(12, true, 20)
  state(13, true, 70)
  g.run(1000)
  T.eq("most show 20", g.proxy.level, 20)
  g.group:setRule("highest")
  g.run(1000)
  T.eq("highest", g.proxy.level, 70)
  state(12, true, 70)
  g.group:setRule("lowest")
  g.run(1000)
  T.eq("lowest", g.proxy.level, 20)
  g.group:setRule("highest")
  state(12, false, 0)
  state(13, false, 0)
  g.run(1000)
  T.eq("highest: on while any member is", g.proxy.level, 20)
  g.group:setRule("lowest")
  g.run(1000)
  T.eq("lowest: off unless every member is on", g.proxy.level, 0)
  g.restore()
end)

T.section("the group offers what any member can, and the widest white range")
case(function()
  local g = groupWorld()
  state(11, true, 40, { color = false, cct = { 2700, 5000 } })
  state(12, true, 40, { color = false, cct = { 2200, 4000 } })
  state(13, true, 40, { color = false })
  g.run(1000)
  local d = g.light.device
  T.eq("white only, 2200 to 5000 K", { d.color, d.cct and d.cct.minK, d.cct and d.cct.maxK }, { false, 2200, 5000 })
  state(13, true, 40, { color = true })
  g.run(1000)
  T.eq("color once a member has it", g.light.device.color, true)
  g.restore()
end)

T.section("a group command goes to every member once, as the level and color the group decided")
case(function()
  local g = groupWorld()
  for _, id in ipairs(MEMBERS) do
    state(id, false, 0)
  end
  g.run(1000)
  local mark = #g.handed
  g.proxy:send("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = 1,
    COLOR_PRESET_ORIGIN = 1,
    COLOR_PRESET_COLOR_X = 0.6,
    COLOR_PRESET_COLOR_Y = 0.3,
    COLOR_PRESET_COLOR_MODE = 0,
    COLOR_FADE_PRESET_ID = 0,
    COLOR_FADE_PRESET_ORIGIN = 0,
  })
  g.proxy:send("RAMP_TO_LEVEL", { LEVEL = 60, TIME = 1500 })
  local sent = {}
  for i = mark + 1, #g.handed do
    if g.handed[i][2] == "LIGHT_GROUP_COMMAND" then
      sent[#sent + 1] = g.handed[i]
    end
  end
  T.eq("one each, in the list's order", { #sent, sent[1][1], sent[2][1], sent[3][1] }, { 3, 11, 12, 13 })
  local p = sent[1][3]
  T.eq("level 60 over 1500 ms", { p.KIND, p.LEVEL, p.RATE }, { "level", "60", "1500" })
  T.truthy("with the group's On Color", near(tonumber(p.X), 0.6, 0.01) and near(tonumber(p.Y), 0.3, 0.01))
  g.restore()
end)

T.section("a group's Min and Max On place the level its members are sent, and its report back")
case(function()
  local g = groupWorld()
  for _, id in ipairs(MEMBERS) do
    state(id, true, 50)
  end
  g.run(1000)
  g.proxy:send("SET_MIN_ON_LEVEL", { LEVEL = 20 })
  g.proxy:send("SET_MAX_ON_LEVEL", { LEVEL = 80 })
  local function last()
    local cmds = named(g.handed, "LIGHT_GROUP_COMMAND")
    return cmds[#cmds][3]
  end
  g.proxy:send("SET_LEVEL", { LEVEL = 100 })
  T.eq("100 is the group's Max On", last().LEVEL, "80")
  for _, id in ipairs(MEMBERS) do
    state(id, true, 80)
  end
  g.run(3000)
  T.eq("members at 80 show as 100", g.proxy.level, 100)
  g.proxy:send("SET_LEVEL", { LEVEL = 1 })
  T.eq("1 is the group's Min On", last().LEVEL, "20")
  g.restore()
end)

T.section("a group's off, color and stop reach the members as such")
case(function()
  local g = groupWorld()
  for _, id in ipairs(MEMBERS) do
    state(id, true, 50)
  end
  g.run(1000)
  local function last()
    local cmds = named(g.handed, "LIGHT_GROUP_COMMAND")
    return cmds[#cmds][3]
  end
  g.proxy:send("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = 0.3,
    LIGHT_COLOR_TARGET_Y = 0.6,
    LIGHT_COLOR_TARGET_MODE = 0,
    LIGHT_COLOR_TARGET_COLOR_RATE = 0,
  })
  T.eq("color", last().KIND, "color")
  g.run(2000)
  g.proxy:send("RAMP_TO_LEVEL", { LEVEL = 100, TIME = 5000 })
  g.run(1000)
  g.proxy:send("SET_BRIGHTNESS_STOP", {})
  local stop = last()
  T.eq("a stop rests them at the group's estimate at once", { stop.KIND, stop.RATE }, { "level", "0" })
  T.truthy("part way up", tonumber(stop.LEVEL) > 50 and tonumber(stop.LEVEL) < 100)
  g.run(2000)
  g.proxy:send("OFF", {})
  T.eq("off", last().KIND, "off")
  g.restore()
end)

T.section("members reporting where they are during a fade do not move the group; it reconciles once the fade ends")
case(function()
  local g = groupWorld()
  for _, id in ipairs(MEMBERS) do
    state(id, true, 20)
  end
  g.run(1000)
  g.proxy:mark()
  g.proxy:send("RAMP_TO_LEVEL", { LEVEL = 80, TIME = 2000 })
  g.run(300)
  for _, id in ipairs(MEMBERS) do
    state(id, true, 50)
  end
  g.run(300)
  for _, id in ipairs(MEMBERS) do
    state(id, true, 60)
  end
  g.run(1700)
  for _, id in ipairs(MEMBERS) do
    state(id, true, 80)
  end
  g.run(3000)
  local told = {}
  for _, n in ipairs(g.proxy.notes) do
    if n.cmd == "LIGHT_BRIGHTNESS_CHANGED" then
      told[#told + 1] = tonumber(n.params.LIGHT_BRIGHTNESS_CURRENT)
    end
  end
  T.eq("only 80 told", told, { 80 })
  T.eq("80 at the end", g.proxy.level, 80)
  g.restore()
end)

T.section("a member changed on its own moves the group by the rule")
case(function()
  local g = groupWorld()
  for _, id in ipairs(MEMBERS) do
    state(id, true, 30)
  end
  g.run(1000)
  g.group:setRule("highest")
  state(13, true, 90)
  g.run(1000)
  T.eq("highest now 90", g.proxy.level, 90)
  g.restore()
end)

T.section("a member removed is told it left and no longer counts; a stranger's state is dropped")
case(function()
  local g = groupWorld()
  state(11, true, 30)
  state(12, true, 90)
  state(13, true, 90)
  g.run(1000)
  g.group:setMembers({ 11 })
  local leaves = named(g.handed, "LIGHT_GROUP_LEAVE")
  T.eq("two told they left", { #leaves, leaves[1][1], leaves[2][1] }, { 2, 12, 13 })
  g.run(1000)
  T.eq("the one left shows", g.proxy.level, 30)
  state(99, true, 100)
  g.run(1000)
  T.eq("a stranger moves nothing", g.proxy.level, 30)
  g.restore()
end)

T.section("the group is offline while no member is online")
case(function()
  local g = groupWorld()
  state(11, true, 30)
  g.run(1000)
  state(11, true, 30, { online = false })
  g.run(1000)
  T.eq("offline", g.proxy.online, false)
  state(12, true, 60)
  g.run(1000)
  T.eq("back with a member", { g.proxy.online, g.proxy.level }, { true, 60 })
  g.restore()
end)

T.finish()
