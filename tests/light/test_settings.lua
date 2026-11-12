-- lib.light.settings: the setting commands as plain setters, the getters LightProxy, Motion and Buttons
-- read, what an on reads (forOn), and the proxy's setup from the GET_SETUP captures in template/test/light_setup.

local T = require("testlib")
local persist = require("lib.persist")
local Settings = require("lib.light.settings")

local HERE = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/[^/]*$") or "."
local SETUPS = HERE .. "/../../template/test/light_setup/"

--- A GET_SETUP answer the proxy gave on OS 4.3.0.
local function setupFile(name)
  local f = assert(io.open(SETUPS .. name, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

local KEYS = {
  Settings.P_PRESET_LEVEL,
  Settings.P_CLICK_RATE_UP,
  Settings.P_CLICK_RATE_DOWN,
  Settings.P_HOLD_RATE_UP,
  Settings.P_HOLD_RATE_DOWN,
  Settings.P_RATE_DEFAULT,
  Settings.P_COLOR_RATE_DEFAULT,
  Settings.P_ON_MODE,
  Settings.P_BUTTON_COLORS,
  Settings.P_BRIGHTNESS_PRESETS,
  Settings.P_COLOR_PRESETS,
  Settings.P_COLOR_ON_MODE,
  Settings.P_PREVIOUS_COLOR,
  Settings.P_BRIGHTNESS_ON_MODE_PRESET,
  Settings.P_MAX_ON_LEVEL,
  Settings.P_MIN_ON_LEVEL,
}

--- A fresh Settings over nothing stored.
local function fresh(profile)
  for _, key in ipairs(KEYS) do
    persist:delete(key)
  end
  return Settings.new(profile or { api = 1, proxy = 5001, dims = true, color = true, onModes = true, defaultOn = true })
end

local function near(a, b)
  return a ~= nil and b ~= nil and math.abs(a - b) < 1e-6
end

T.section("the persisted keys are the 16 of the copies, verbatim, and scenes is not one")
do
  local names = {}
  for _, key in ipairs(KEYS) do
    names[key] = true
  end
  T.eq("16 keys", #KEYS, 16)
  T.eq("scenes belongs to Scenes", names.scenes, nil)
  T.eq("color_presets stays", names.color_presets, true)
end

T.section("every getter has its default with nothing stored")
do
  local s = fresh()
  T.eq("Min and Max On", { s:onRange() }, { 1, 100 })
  T.eq("Default On", s:presetLevel(), 100)
  T.eq(
    "rates",
    { s:defaultRate(), s:defaultColorRate(), s:clickRate(true), s:clickRate(false) },
    { 500, 500, 500, 500 }
  )
  T.eq("hold rates", { s:holdRate(true), s:holdRate(false) }, { 3000, 3000 })
  T.eq("button colors: none invented", { s:buttonColors(0) }, { "", "" })
  T.eq("no Previous On level", s:previousOnLevel(), nil)
  local on = s:forOn()
  T.eq("an on reads no on mode", { on.onModeLevel, on.colorOnMode, on.onColor, on.previousColor }, { nil, "none" })
  T.eq("and the profile's Default On", { on.defaultOn, on.presetLevel, on.onLo, on.onHi }, { true, 100, 1, 100 })
end

T.section("the setting commands are plain setters, and send nothing")
do
  local s = fresh()
  local sent = 0
  local prior = C4.SendToProxy
  C4.SendToProxy = function()
    sent = sent + 1
  end
  local cases = {
    {
      "SET_PRESET_LEVEL",
      { LEVEL = "70" },
      function()
        return s:presetLevel()
      end,
      70,
    },
    {
      "SET_CLICK_RATE_UP",
      { RATE = "250" },
      function()
        return s:clickRate(true)
      end,
      250,
    },
    {
      "SET_CLICK_RATE_DOWN",
      { RATE = "750" },
      function()
        return s:clickRate(false)
      end,
      750,
    },
    {
      "SET_HOLD_RATE_UP",
      { RATE = "5000" },
      function()
        return s:holdRate(true)
      end,
      5000,
    },
    {
      "SET_HOLD_RATE_DOWN",
      { RATE = "4000" },
      function()
        return s:holdRate(false)
      end,
      4000,
    },
    {
      "SET_MIN_ON_LEVEL",
      { LEVEL = "20" },
      function()
        return select(1, s:onRange())
      end,
      20,
    },
    {
      "SET_MAX_ON_LEVEL",
      { LEVEL = "80" },
      function()
        return select(2, s:onRange())
      end,
      80,
    },
    {
      "UPDATE_BRIGHTNESS_RATE_DEFAULT",
      { RATE = "900" },
      function()
        return { s:defaultRate(), s:defaultColorRate() }
      end,
      { 900, 900 },
    },
    {
      "UPDATE_COLOR_RATE_DEFAULT",
      { RATE = "300" },
      function()
        return { s:defaultRate(), s:defaultColorRate() }
      end,
      { 300, 300 },
    },
    {
      "SET_BUTTON_COLOR",
      { BUTTON_ID = "2", ON_COLOR = "ff0000" },
      function()
        return { s:buttonColors(2) }
      end,
      { "ff0000", "" },
    },
  }
  for _, c in ipairs(cases) do
    T.eq(c[1] .. " is taken", s:apply(c[1], c[2]), true)
    T.eq(c[1] .. " reads back", c[3](), c[4])
  end
  s:apply("SET_BUTTON_COLOR", { BUTTON_ID = "2", OFF_COLOR = "00ff00" })
  T.eq("a button color named alone keeps the other", { s:buttonColors(2) }, { "ff0000", "00ff00" })
  T.eq("no notify went out", sent, 0)
  T.eq("a command that is no setting is not taken", s:apply("SET_LEVEL", { LEVEL = "5" }), false)
  C4.SendToProxy = prior
end

T.section("the On levels and the range keep a usable light")
do
  local s = fresh()
  s:apply("SET_PRESET_LEVEL", { LEVEL = "0" })
  T.eq("a Default On of 0 is 100, so an On never turns the light off", s:presetLevel(), 100)
  s:apply("SET_MIN_ON_LEVEL", { LEVEL = "0" })
  T.eq("a Min On of 0 reads as 1", select(1, s:onRange()), 1)
  s:apply("SET_MIN_ON_LEVEL", { LEVEL = "60" })
  s:apply("SET_MAX_ON_LEVEL", { LEVEL = "40" })
  T.eq("a Max On under the Min reads as the Min", { s:onRange() }, { 60, 60 })
  s:apply("SET_MAX_ON_LEVEL", { LEVEL = "250" })
  T.eq("a Max On past 100 is 100", select(2, s:onRange()), 100)
  T.eq("forOn carries the range", { s:forOn().onLo, s:forOn().onHi }, { 60, 100 })
end

T.section("the brightness on mode follows its preset's edits")
do
  local s = fresh()
  s:apply("UPDATE_BRIGHTNESS_PRESET", { ID = "3", NAME = "Evening", LEVEL = "40" })
  s:apply("SET_BRIGHTNESS_ON_MODE", { PRESET_ID = "3" })
  T.eq("an On goes to the preset's level", s:forOn().onModeLevel, 40)
  s:apply("UPDATE_BRIGHTNESS_PRESET", { ID = "3", NAME = "Evening", LEVEL = "55" })
  T.eq("an edit of it moves the on level", s:forOn().onModeLevel, 55)
  s:apply("UPDATE_BRIGHTNESS_PRESET", { ID = "4", LEVEL = "90" })
  T.eq("an edit of another preset does not", s:forOn().onModeLevel, 55)
  s:apply("UPDATE_BRIGHTNESS_PRESET", { ID = "3", COMMAND = "REMOVED" })
  T.eq("removing it leaves no on mode", s:forOn().onModeLevel, nil)
  s:apply("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = "1", BRIGHTNESS_PRESET_LEVEL = "65" })
  T.eq("UPDATE_BRIGHTNESS_ON_MODE sets it at once", s:forOn().onModeLevel, 65)
  s:apply("UPDATE_BRIGHTNESS_PRESET", { ID = "10", LEVEL = "33" })
  T.eq("Previous On's level is its preset 10's", s:previousOnLevel(), 33)
end

T.section("a profile without on modes reads none, whatever is stored")
do
  local s = fresh({ api = 1, proxy = 5001, dims = true, color = true, onModes = false, defaultOn = false })
  s:apply("UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = "1", BRIGHTNESS_PRESET_LEVEL = "65" })
  s:apply("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = "1",
    COLOR_PRESET_ORIGIN = "1",
    COLOR_PRESET_COLOR_X = "0.5",
    COLOR_PRESET_COLOR_Y = "0.4",
    COLOR_PRESET_COLOR_MODE = "0",
    COLOR_FADE_PRESET_ID = "0",
    COLOR_FADE_PRESET_ORIGIN = "0",
  })
  local on = s:forOn()
  T.eq("no brightness on mode and no color on mode", { on.onModeLevel, on.colorOnMode }, { nil, "none" })
  T.eq("and the profile's Default On", on.defaultOn, false)
end

T.section("the color on modes, as UPDATE_COLOR_ON_MODE's presets tell them apart")
do
  local function mode(on, fade)
    return {
      COLOR_PRESET_ID = on.id,
      COLOR_PRESET_ORIGIN = on.origin,
      COLOR_PRESET_COLOR_X = on.x,
      COLOR_PRESET_COLOR_Y = on.y,
      COLOR_PRESET_COLOR_MODE = on.mode,
      COLOR_FADE_PRESET_ID = fade.id,
      COLOR_FADE_PRESET_ORIGIN = fade.origin,
      COLOR_FADE_PRESET_COLOR_X = fade.x,
      COLOR_FADE_PRESET_COLOR_Y = fade.y,
      COLOR_FADE_PRESET_COLOR_MODE = fade.mode,
    }
  end
  local s = fresh()
  local cases = {
    {
      "a fade preset with an origin is Dim-To-Warm",
      mode(
        { id = "1", origin = "1", x = "0.38", y = "0.38", mode = "1" },
        { id = "2", origin = "1", x = "0.52", y = "0.41", mode = "1" }
      ),
      "fade",
    },
    {
      "no fade preset and the device's preset 10 is Previous",
      mode({ id = "10", origin = "1", x = "0.3", y = "0.3", mode = "0" }, { id = "0", origin = "0" }),
      "previous",
    },
    {
      "no fade preset and another with a color is a preset",
      mode({ id = "4", origin = "2", x = "0.6", y = "0.32", mode = "0" }, { id = "0", origin = "0" }),
      "preset",
    },
  }
  for _, c in ipairs(cases) do
    s:apply("UPDATE_COLOR_ON_MODE", c[2])
    T.eq(c[1], s:forOn().colorOnMode, c[3])
  end
  local on = s:forOn()
  T.eq("the preset's id and origin come with it", { on.onPresetId, on.onPresetOrigin }, { 4, 2 })
  T.check(
    "and its color as a LightColor",
    on.onColor and near(on.onColor.x, 0.6) and on.onColor.mode == "xy",
    on.onColor
  )
  s:apply("UPDATE_COLOR_ON_MODE", cases[1][2])
  on = s:forOn()
  T.check(
    "Dim-To-Warm has both ends, as whites",
    on.dimColor and near(on.dimColor.x, 0.52) and on.dimColor.mode == "cct" and on.onColor.mode == "cct",
    on
  )
end

T.section("an edit of the device preset the on mode names moves its color")
do
  local s = fresh()
  s:apply("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = "3",
    COLOR_PRESET_ORIGIN = "1",
    COLOR_PRESET_COLOR_X = "0.5",
    COLOR_PRESET_COLOR_Y = "0.4",
    COLOR_PRESET_COLOR_MODE = "0",
    COLOR_FADE_PRESET_ID = "0",
    COLOR_FADE_PRESET_ORIGIN = "0",
  })
  s:apply("UPDATE_COLOR_PRESET", { ID = "3", NAME = "Rose", COLOR_X = "0.45", COLOR_Y = "0.3", COLOR_MODE = "0" })
  T.check("the On color is the edit's", near(s:forOn().onColor.x, 0.45), s:forOn().onColor)
  s:apply("UPDATE_COLOR_PRESET", { ID = "3", COMMAND = "REMOVED" })
  T.check("removing the preset keeps the mode's color", near(s:forOn().onColor.x, 0.45), s:forOn().onColor)
end

T.section("colorPreset: a pushed color preset's color, for a SET_COLOR_TARGET that names only its id")
do
  local s = fresh()
  T.eq("an id never pushed has none", s:colorPreset(9), nil)
  s:apply("UPDATE_COLOR_PRESET", { ID = "9", NAME = "Teal", COLOR_X = "0.2", COLOR_Y = "0.35", COLOR_MODE = "0" })
  local color = s:colorPreset(9)
  T.check("a pushed preset's xy", color ~= nil and near(color.x, 0.2) and near(color.y, 0.35), color)
  T.eq("in the contract's mode", color and color.mode, "xy")
  s:apply("UPDATE_COLOR_PRESET", { ID = "9", COMMAND = "REMOVED" })
  T.eq("a removed preset has none", s:colorPreset(9), nil)
end

T.section("forOn carries the profile's onModes, and forMotion what Motion reads")
do
  local s = fresh()
  T.eq("on modes offered", s:forOn().onModes, true)
  T.eq("none offered", fresh({ api = 1, proxy = 5001, dims = true }):forOn().onModes, false)
  s:apply("SET_MIN_ON_LEVEL", { LEVEL = "20" })
  s:apply("UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = "800" })
  local m = s:forMotion()
  T.eq("the range and the default rates", { m.lo, m.hi, m.rate, m.colorRate }, { 20, 100, 800, s:defaultColorRate() })
  T.eq("and the on settings", { m.on.onLo, m.on.onModes }, { 20, true })
end

T.section("the color the light went off in is Previous's")
do
  local s = fresh()
  s:setPreviousColor({ x = 0.31, y = 0.33, mode = "cct" })
  local prev = s:forOn().previousColor
  T.check("kept with its mode", prev and near(prev.x, 0.31) and prev.mode == "cct", prev)
  T.eq("as the proxy's own mode value", persist:get(Settings.P_PREVIOUS_COLOR).mode, 1)
end

T.section("the proxy's setup: its Color On Mode, rates and presets")
do
  local s = fresh()
  s:readSetup(setupFile("setup-607.xml"))
  local mode = persist:get(Settings.P_COLOR_ON_MODE)
  T.eq("the on preset is the device's On Color", mode and mode.onPreset.id, 1)
  T.eq("and the fade preset the Dim Color, so Dim-To-Warm", mode and mode.fadePreset.id, 2)
  T.check(
    "with the colors the setup lists",
    mode and near(mode.onPreset.x, 0.380438) and near(mode.fadePreset.x, 0.526676),
    mode
  )
  T.eq("the default rates are the setup's", { s:defaultRate(), s:defaultColorRate() }, { 750, 750 })
  T.eq("so an on reads Dim-To-Warm", s:forOn().colorOnMode, "fade")

  s = fresh()
  s:readSetup(setupFile("setup-626.xml"))
  mode = persist:get(Settings.P_COLOR_ON_MODE)
  T.eq("a preset is found by its id and origin together", mode and { mode.onPreset.id, mode.onPreset.origin }, { 8, 2 })
  T.eq("so is the fade preset, not the device's 10", mode and { mode.fadePreset.id, mode.fadePreset.origin }, { 10, 2 })

  for _, name in ipairs({ "setup-643.xml", "setup-727.xml", "setup-732.xml", "setup-732-new.xml" }) do
    s = fresh()
    T.check(name .. " reads", pcall(Settings.readSetup, s, setupFile(name)))
  end
  s = fresh()
  s:readSetup(setupFile("setup-732-new.xml"))
  T.eq("a new light's setup lists no colors: no mode", persist:get(Settings.P_COLOR_ON_MODE, false), false)
end

T.section("button colors: saved, else the setup's, else empty")
do
  local s = fresh()
  s:readSetup(setupFile("setup-607.xml"))
  T.eq("Top's from the setup", { s:buttonColors(0) }, { "0000ff", "000000" })
  T.eq("Bottom's from the setup, the Off look", { s:buttonColors(1) }, { "000000", "0000ff" })
  T.eq("Toggle's from the setup", { s:buttonColors(2) }, { "0000ff", "000000" })
  s:apply("SET_BUTTON_COLOR", { BUTTON_ID = "1", ON_COLOR = "ff0000" })
  T.eq("a saved color wins, and the other keeps the setup's", { s:buttonColors(1) }, { "ff0000", "0000ff" })
  T.eq("a button with neither has empty colors", { fresh():buttonColors(2) }, { "", "" })
end

T.section("a setup that cannot be read leaves what is stored")
do
  local function stored()
    return {
      persist:get(Settings.P_COLOR_ON_MODE, false),
      persist:get(Settings.P_ON_MODE, false),
      persist:get(Settings.P_RATE_DEFAULT, false),
    }
  end
  for _, c in ipairs({
    { "no answer", nil },
    { "an empty answer", "" },
    { "an answer that is not whole", setupFile("setup-607.xml"):sub(1, 2000) },
  }) do
    local s = fresh()
    persist:set(
      Settings.P_COLOR_ON_MODE,
      { onPreset = { id = 3, origin = 1, x = 0.5, y = 0.4 }, fadePreset = { id = 0, origin = 0 } }
    )
    persist:set(Settings.P_RATE_DEFAULT, 1234)
    local before = stored()
    s:readSetup(c[2])
    T.eq(c[1] .. ": nothing stored changes", stored(), before)
  end
end

fresh()
T.finish()
