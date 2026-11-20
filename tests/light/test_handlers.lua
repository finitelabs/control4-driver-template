-- The handlers: each proxy and link command parsed into one of Light's five entry points, behind the
-- device gate and the profile's families. A fake Light records the calls, so only the handlers and the
-- pure color module run.

local T = require("testlib")

require("c4_shim")

local Handlers = require("lib.light.handlers")
local Color = require("lib.light.color")

local PROXY = 5001
local LINKS = { top = 300, toggle = 301, bottom = 302 }
local PRESET = { x = 0.2, y = 0.5, mode = "xy" }

--- A Light stand-in: its profile, its online flag, a settings with colorPreset, and every entry point
--- it was called through.
local function fakeLight(profile, online)
  local light = {
    profile = profile,
    online = online ~= false,
    calls = {},
    settings = {},
  }
  function light.settings:colorPreset(id, origin)
    return id == 4 and origin == 1 and PRESET or nil
  end
  for _, name in ipairs({ "command", "button", "scene", "setting", "ask", "membership", "groupHold" }) do
    light[name] = function(self, ...)
      self.calls[#self.calls + 1] = { name, ... }
    end
  end
  -- A group in sync takes what is handed to it.
  light.synced = false
  function light:toGroups(...)
    self.calls[#self.calls + 1] = { "toGroups", ... }
    return self.synced
  end
  return light
end

local FULL = { api = 1, proxy = PROXY, links = LINKS, dims = true, color = true, scenes = true, onModes = true }

--- The light's calls for one command on a binding, through the vendored dispatcher.
local function run(light, idBinding, strCommand, tParams)
  light.calls = {}
  ReceivedFromProxy(idBinding, strCommand, tParams or {})
  return light.calls
end

T.section("register: one function per owned binding, no command-keyed RFP")
do
  RFP = { suppressDebug = {} }
  Handlers.register(fakeLight(FULL))
  T.eq("the proxy binding and the three links", {
    type(RFP[PROXY]),
    type(RFP[300]),
    type(RFP[301]),
    type(RFP[302]),
  }, { "function", "function", "function", "function" })
  local keyed = {}
  for key, value in pairs(RFP) do
    if type(key) == "string" and type(value) == "function" then
      keyed[#keyed + 1] = key
    end
  end
  T.eq("no handler keyed by a command name", keyed, {})

  RFP = { suppressDebug = {} }
  Handlers.register(fakeLight({ api = 1, proxy = 5002 }))
  T.eq("another proxy binding, and no links without them", { type(RFP[5002]), RFP[300] }, { "function", nil })
end

T.section("motion commands become intents, from the proxy")
do
  RFP = { suppressDebug = {} }
  local light = fakeLight(FULL)
  Handlers.register(light)
  local cases = {
    { "ON", {}, { kind = "on", source = "proxy" } },
    { "DYNAMIC_ON", {}, { kind = "on", source = "proxy" } },
    { "OFF", {}, { kind = "off", source = "proxy" } },
    { "DYNAMIC_OFF", {}, { kind = "off", source = "proxy" } },
    { "TOGGLE", {}, { kind = "toggle", source = "proxy" } },
    { "SET_LEVEL", { LEVEL = "40" }, { kind = "level", level = 40, rateMs = 0, source = "proxy" } },
    { "SET_LEVEL", { LEVEL = "140" }, { kind = "level", level = 100, rateMs = 0, source = "proxy" } },
    {
      "RAMP_TO_LEVEL",
      { LEVEL = "60", TIME = "2000" },
      { kind = "level", level = 60, rateMs = 2000, source = "proxy" },
    },
    {
      "SET_BRIGHTNESS_TARGET",
      { LIGHT_BRIGHTNESS_TARGET = "33.6", RATE = "750", LIGHT_BRIGHTNESS_TARGET_PRESET_ID = "2" },
      { kind = "level", level = 34, rateMs = 750, presetId = 2, source = "proxy" },
    },
    {
      "SET_BRIGHTNESS_TARGET",
      { LIGHT_BRIGHTNESS_TARGET = "0" },
      { kind = "level", level = 0, source = "proxy" },
    },
    {
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_X = "0.64", LIGHT_COLOR_TARGET_Y = "0.33", LIGHT_COLOR_TARGET_MODE = "0", RATE = "500" },
      { kind = "color", color = { x = 0.64, y = 0.33, mode = "xy" }, rateMs = 500, source = "proxy" },
    },
    {
      "SET_COLOR_TARGET",
      {
        LIGHT_COLOR_TARGET_X = "0.64",
        LIGHT_COLOR_TARGET_Y = "0.33",
        LIGHT_COLOR_TARGET_COLOR_RATE = "900",
        LIGHT_COLOR_TARGET_RATE = "100",
        LIGHT_COLOR_TARGET_PRESET_ID = "7",
        LIGHT_COLOR_TARGET_PRESET_ORIGIN = "2",
      },
      {
        kind = "color",
        color = { x = 0.64, y = 0.33, mode = "xy" },
        rateMs = 900,
        presetId = 7,
        presetOrigin = 2,
        source = "proxy",
      },
    },
    {
      "SET_COLOR_TARGET",
      { LIGHT_COLOR_TARGET_PRESET_ID = "4", LIGHT_COLOR_TARGET_PRESET_ORIGIN = "1" },
      { kind = "color", color = PRESET, presetId = 4, presetOrigin = 1, source = "proxy" },
    },
    { "SET_BRIGHTNESS_STOP", {}, { kind = "stopLevel", source = "proxy" } },
    { "SET_COLOR_STOP", {}, { kind = "stopColor", source = "proxy" } },
  }
  for _, case in ipairs(cases) do
    local calls = run(light, PROXY, case[1], case[2])
    T.eq(case[1] .. " " .. tostring(next(case[2]) and (case[2].LEVEL or case[2].RATE or "params") or ""), calls, {
      { "command", case[3] },
    })
  end

  local calls = run(light, PROXY, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_COLOR_CORRELATED_TEMPERATURE = "2700" })
  local color = calls[1][2].color
  local x, y = Color.kelvinToXY(2700)
  T.eq("a Kelvin is a cct color on the locus, with its kelvin", { color.x, color.y, color.mode, color.kelvin }, {
    x,
    y,
    "cct",
    2700,
  })
  calls = run(
    light,
    PROXY,
    "SET_COLOR_TARGET",
    { LIGHT_COLOR_TARGET_X = tostring(x), LIGHT_COLOR_TARGET_Y = tostring(y), LIGHT_COLOR_TARGET_MODE = "1" }
  )
  color = calls[1][2].color
  T.eq("xy in mode 1 is cct", color.mode, "cct")
  T.check("and gets its kelvin", color.kelvin and math.abs(color.kelvin - 2700) <= 10, color)
  T.eq(
    "a preset with no coordinates is looked up with its origin",
    run(light, PROXY, "SET_COLOR_TARGET", {
      LIGHT_COLOR_TARGET_PRESET_ID = "4",
      LIGHT_COLOR_TARGET_PRESET_ORIGIN = "2",
    }),
    {}
  )
  T.eq(
    "an unknown preset with no coordinates is dropped",
    run(light, PROXY, "SET_COLOR_TARGET", {
      LIGHT_COLOR_TARGET_PRESET_ID = "99",
    }),
    {}
  )
end

T.section("scenes, settings, asks and button actions each reach their entry point")
do
  RFP = { suppressDebug = {} }
  local light = fakeLight(FULL)
  Handlers.register(light)
  local scenes = {
    PUSH_SCENE = "push",
    REMOVE_SCENE = "remove",
    CLEAR_ALL_SCENES = "clear",
    ACTIVATE_SCENE = "activate",
    DEACTIVATE_SCENE = "deactivate",
    RAMP_SCENE_UP = "rampUp",
    RAMP_SCENE_DOWN = "rampDown",
    STOP_SCENE_RAMP = "stopRamp",
    STOP_RAMP_SCENE = "stopRamp",
    TOGGLE_SCENE = "toggle",
  }
  for command, op in pairs(scenes) do
    local params = { SCENE_ID = "3" }
    T.eq(command, run(light, PROXY, command, params), { { "scene", op, params } })
  end
  for _, command in ipairs({
    "SET_MAX_ON_LEVEL",
    "SET_MIN_ON_LEVEL",
    "SET_PRESET_LEVEL",
    "UPDATE_BRIGHTNESS_ON_MODE",
    "SET_BRIGHTNESS_ON_MODE",
    "UPDATE_BRIGHTNESS_PRESET",
    "UPDATE_BRIGHTNESS_RATE_DEFAULT",
    "UPDATE_COLOR_RATE_DEFAULT",
    "UPDATE_COLOR_PRESET",
    "UPDATE_COLOR_ON_MODE",
    "SET_CLICK_RATE_UP",
    "SET_CLICK_RATE_DOWN",
    "SET_HOLD_RATE_UP",
    "SET_HOLD_RATE_DOWN",
    "SET_BUTTON_COLOR",
  }) do
    local params = { LEVEL = "5" }
    T.eq(command, run(light, PROXY, command, params), { { "setting", command, params } })
  end
  for _, command in ipairs({ "GET_CONNECTED_STATE", "GET_LIGHT_LEVEL", "REQUEST_BUTTON_COLORS" }) do
    T.eq(command .. ", with the proxy binding", run(light, PROXY, command, {}), { { "ask", command, {}, PROXY } })
  end
  T.eq(
    "BUTTON_ACTION is a press the proxy hears echoed",
    run(light, PROXY, "BUTTON_ACTION", {
      BUTTON_ID = "2",
      ACTION = "1",
    }),
    { { "button", 2, 1, true } }
  )
  T.eq(
    "a link's DO_PUSH is a press on its button, not echoed",
    run(light, 300, "DO_PUSH"),
    { { "button", 0, 1, false } }
  )
  T.eq("DO_CLICK on the bottom link", run(light, 302, "DO_CLICK"), { { "button", 1, 2, false } })
  T.eq("DO_RELEASE on the toggle link", run(light, 301, "DO_RELEASE"), { { "button", 2, 0, false } })
  T.eq("another command on a link is dropped", run(light, 300, "SOMETHING"), {})
  T.eq(
    "REQUEST_BUTTON_COLORS on a link is asked with that link, to be answered there",
    run(light, 302, "REQUEST_BUTTON_COLORS", {}),
    { { "ask", "REQUEST_BUTTON_COLORS", {}, 302 } }
  )
  T.eq("ALL_SCENES_PUSHED is taken and does nothing", run(light, PROXY, "ALL_SCENES_PUSHED"), {})
  T.eq("SET_COLOR_ON_MODE likewise", run(light, PROXY, "SET_COLOR_ON_MODE"), {})
  T.eq("an unknown command is dropped", run(light, PROXY, "NOT_A_LIGHT_COMMAND"), {})
end

T.section("the device gate: no motion or device read until the device's first report")
do
  RFP = { suppressDebug = {} }
  local light = fakeLight(FULL, false)
  Handlers.register(light)
  for _, command in ipairs({
    "ON",
    "OFF",
    "TOGGLE",
    "SET_LEVEL",
    "SET_BRIGHTNESS_TARGET",
    "SET_COLOR_TARGET",
    "SET_BRIGHTNESS_STOP",
    "ACTIVATE_SCENE",
    "TOGGLE_SCENE",
    "STOP_RAMP_SCENE",
    "BUTTON_ACTION",
  }) do
    T.eq(command .. " is dropped", run(light, PROXY, command, { LEVEL = "5", BUTTON_ID = "0", ACTION = "1" }), {})
  end
  T.eq("a link press is dropped", run(light, 300, "DO_PUSH"), {})
  T.eq("a setting still lands", #run(light, PROXY, "SET_MAX_ON_LEVEL", { LEVEL = "80" }), 1)
  T.eq("a scene is still stored", #run(light, PROXY, "PUSH_SCENE", {}), 1)
  T.eq("the connected state is still answered", #run(light, PROXY, "GET_CONNECTED_STATE", {}), 1)
  T.eq(
    "GET_LIGHT_LEVEL still reaches the light, which answers a lost light's kept level",
    #run(light, PROXY, "GET_LIGHT_LEVEL", {}),
    1
  )
end

T.section("families the profile leaves out take none of their commands")
do
  RFP = { suppressDebug = {} }
  local light = fakeLight({ api = 1, proxy = PROXY, dims = true })
  Handlers.register(light)
  for _, command in ipairs({
    "PUSH_SCENE",
    "ACTIVATE_SCENE",
    "UPDATE_BRIGHTNESS_ON_MODE",
    "UPDATE_COLOR_ON_MODE",
    "BUTTON_ACTION",
    "SET_BUTTON_COLOR",
    "REQUEST_BUTTON_COLORS",
  }) do
    T.eq(command .. " is dropped", run(light, PROXY, command, { BUTTON_ID = "0", ACTION = "1" }), {})
  end
  T.eq("a level still lands", #run(light, PROXY, "SET_LEVEL", { LEVEL = "5" }), 1)
end

T.section("load group commands: membership, a group level or ramp as its single light twin, a hold and its stop")
do
  RFP = { suppressDebug = {} }
  local profile = { api = 1, proxy = PROXY, links = LINKS, dims = true, loadGroups = true }
  local light = fakeLight(profile)
  Handlers.register(light)
  for _, command in ipairs({ "JOIN_GROUP", "LEAVE_GROUP", "SET_GROUP_SYNC" }) do
    local params = { GROUP_ID = "1205", KEEP_SYNC = "1" }
    T.eq(command .. " is membership", run(light, PROXY, command, params), { { "membership", command, params } })
  end
  T.eq(
    "GROUP_SET_LEVEL is SET_LEVEL",
    run(light, PROXY, "GROUP_SET_LEVEL", { GROUP_ID = "1205", LEVEL = "100" }),
    { { "command", { kind = "level", level = 100, rateMs = 0, source = "proxy" } } }
  )
  T.eq(
    "GROUP_RAMP_TO_LEVEL is RAMP_TO_LEVEL",
    run(light, PROXY, "GROUP_RAMP_TO_LEVEL", { GROUP_ID = "1205", LEVEL = "80", TIME = "2000" }),
    { { "command", { kind = "level", level = 80, rateMs = 2000, source = "proxy" } } }
  )
  T.eq("GROUP_START_RAMP is a hold, up or down at the group's rate", {
    run(light, PROXY, "GROUP_START_RAMP", { GROUP_ID = "1205", RAMP_UP = "1", RATE = "5000" }),
    run(light, PROXY, "GROUP_START_RAMP", { GROUP_ID = "1205", RAMP_UP = "0", RATE = "5000" }),
  }, { { { "groupHold", true, 5000 } }, { { "groupHold", false, 5000 } } })
  T.eq(
    "GROUP_STOP_RAMP stops the level",
    run(light, PROXY, "GROUP_STOP_RAMP", { GROUP_ID = "1205" }),
    { { "command", { kind = "stopLevel", source = "proxy" } } }
  )

  light.online = false
  for _, command in ipairs({ "GROUP_SET_LEVEL", "GROUP_RAMP_TO_LEVEL", "GROUP_START_RAMP", "GROUP_STOP_RAMP" }) do
    T.eq(command .. " waits for the device like any motion", run(light, PROXY, command, { LEVEL = "5" }), {})
  end
  T.eq("membership does not", #run(light, PROXY, "JOIN_GROUP", { GROUP_ID = "1205" }), 1)
  light.online = true

  RFP = { suppressDebug = {} }
  local without = fakeLight(FULL)
  Handlers.register(without)
  for _, command in ipairs({ "JOIN_GROUP", "SET_GROUP_SYNC", "GROUP_SET_LEVEL", "GROUP_START_RAMP" }) do
    T.eq(command .. " is dropped by a profile without load groups", run(without, PROXY, command, { LEVEL = "5" }), {})
  end
  T.eq(
    "and its own commands are never handed on",
    run(without, PROXY, "ON"),
    { { "command", { kind = "on", source = "proxy" } } }
  )
end

T.section("a light a group keeps in sync hands its own commands to the group and does not act on them")
do
  RFP = { suppressDebug = {} }
  local light = fakeLight({ api = 1, proxy = PROXY, links = LINKS, dims = true, color = true, loadGroups = true })
  Handlers.register(light)
  light.synced = true
  local cases = {
    { "ON", {}, "ON", {} },
    { "DYNAMIC_ON", {}, "ON", {} },
    { "OFF", {}, "OFF", {} },
    { "DYNAMIC_OFF", {}, "OFF", {} },
    { "TOGGLE", {}, "TOGGLE", {} },
    { "SET_LEVEL", { LEVEL = "40" }, "SET_LEVEL", { LEVEL = "40" } },
    { "RAMP_TO_LEVEL", { LEVEL = "60", TIME = "900" }, "RAMP_TO_LEVEL", { LEVEL = "60", TIME = "900" } },
    {
      "SET_BRIGHTNESS_TARGET",
      { LIGHT_BRIGHTNESS_TARGET = "30", RATE = "750" },
      "RAMP_TO_LEVEL",
      { LEVEL = "30", TIME = "750" },
    },
    { "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" }, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" } },
  }
  for _, c in ipairs(cases) do
    T.eq(c[1] .. " goes to the group as " .. c[3], run(light, PROXY, c[1], c[2]), { { "toGroups", c[3], c[4] } })
  end
  T.eq(
    "a link press goes as BUTTON_ACTION",
    run(light, 302, "DO_PUSH"),
    { { "toGroups", "BUTTON_ACTION", { BUTTON_ID = "1", ACTION = "1" } } }
  )
  light.online = false
  T.eq("even before the device's first report", run(light, PROXY, "ON"), { { "toGroups", "ON", {} } })
  light.online = true
  T.eq(
    "a color is the light's own: a load group carries level only",
    #run(light, PROXY, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.3", LIGHT_COLOR_TARGET_Y = "0.3" }),
    1
  )
  T.eq(
    "the group's own commands are never handed back",
    run(light, PROXY, "GROUP_SET_LEVEL", { GROUP_ID = "1205", LEVEL = "20" }),
    { { "command", { kind = "level", level = 20, rateMs = 0, source = "proxy" } } }
  )
  light.synced = false
  T.eq(
    "with no group in sync the light acts",
    run(light, PROXY, "ON"),
    { { "toGroups", "ON", {} }, { "command", { kind = "on", source = "proxy" } } }
  )
end

T.section("a driver's command-keyed handler for a command the library leaves runs first")
do
  RFP = { suppressDebug = {} }
  local light = fakeLight(FULL)
  Handlers.register(light)
  local extra = nil
  RFP.EXTRA_SET = function(idBinding, strCommand)
    extra = { idBinding, strCommand }
  end
  T.eq("the library does not see it", run(light, PROXY, "EXTRA_SET", { ID = "1" }), {})
  T.eq("the driver does", extra, { PROXY, "EXTRA_SET" })
  T.eq("the light's commands still reach the light", #run(light, PROXY, "ON"), 1)
end

T.section("COMMANDS: every command the handlers take, once, sorted")
do
  local Handlers = require("lib.light.handlers")
  local seen, sorted = {}, true
  for i, command in ipairs(Handlers.COMMANDS) do
    T.check("listed once: " .. command, not seen[command])
    seen[command] = true
    sorted = sorted and (i == 1 or Handlers.COMMANDS[i - 1] < command)
  end
  T.check("sorted", sorted)
  -- One of each set the handlers dispatch on: a motion command, a family member, a scene op, a setting, an
  -- ask, both ignored ones, and a link action.
  for _, command in ipairs({
    "ON",
    "SET_COLOR_TARGET",
    "UPDATE_BRIGHTNESS_ON_MODE",
    "REQUEST_BUTTON_COLORS",
    "PUSH_SCENE",
    "STOP_SCENE_RAMP",
    "SET_PRESET_LEVEL",
    "GET_LIGHT_LEVEL",
    "ALL_SCENES_PUSHED",
    "SET_COLOR_ON_MODE",
    "DO_PUSH",
    "JOIN_GROUP",
    "GROUP_SET_LEVEL",
    "LIGHT_GROUP_COMMAND",
  }) do
    T.check("includes " .. command, seen[command])
  end
  T.eq("and no more than them", #Handlers.COMMANDS, 55)
end

T.finish()
