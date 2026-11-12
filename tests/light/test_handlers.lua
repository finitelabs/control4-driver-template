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
  function light.settings:colorPreset(id)
    return id == 4 and PRESET or nil
  end
  for _, name in ipairs({ "command", "button", "scene", "setting", "ask" }) do
    light[name] = function(self, ...)
      self.calls[#self.calls + 1] = { name, ... }
    end
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
    "GET_LIGHT_LEVEL",
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
  for _, command in ipairs({ "ON", "SET_COLOR_TARGET", "PUSH_SCENE", "SET_PRESET_LEVEL", "GET_LIGHT_LEVEL", "DO_PUSH" }) do
    T.check("includes " .. command, seen[command])
  end
end

T.finish()
