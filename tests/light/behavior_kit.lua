--- What the light library's behavior suites share: the devices they run on, a world over each, and the
--- proxy commands they send. The suites assert only what the fake proxy shows and where the device ends.

local M = require("memory_light")

local K = {}

K.case = M.case
K.copy = M.copy

-- The proxy's color modes.
K.FULL, K.CCT = 0, 1

-- A Zigbee bulb through its device driver: it fades itself, keeps its level while off, reports where it
-- has got to, and the transport reads it back after each change, answering moving or final.
K.ZB = {
  dims = true,
  color = true,
  cct = { minK = 2000, maxK = 6500 },
  levelSteps = 254,
  fade = { kind = "device", preOn = true },
  feedback = { shows = "position", waitMs = 2500, refresh = true },
  answers = true,
  readbackMs = 1500,
}

-- An ESPHome light: it fades on a smootherstep, keeps its level while off, and reports its targets.
K.ES = {
  dims = true,
  color = true,
  cct = { minK = 2000, maxK = 6500 },
  levelSteps = 255,
  fade = { kind = "device", curve = "smootherstep", preOn = true },
  feedback = { shows = "target", waitMs = 1000, refresh = false },
}

-- A light that changes at once, whose fades the library walks, and that drops a color sent while off.
K.WALK = {
  dims = true,
  color = true,
  cct = { minK = 2500, maxK = 6500 },
  levelSteps = 100,
  fade = { kind = "walk", stepMs = 100 },
  feedback = { shows = "target", waitMs = 2000, refresh = true },
  colorWhileOff = "hold",
}

-- A cloud light that takes no fade time and drops a color sent while off.
K.HOLD = {
  dims = true,
  color = true,
  levelSteps = 100,
  fade = { kind = "own", own = { onMs = 0, offMs = 0, changeMs = 0 } },
  feedback = { shows = "target", waitMs = 5000, refresh = true },
  colorWhileOff = "hold",
}

-- A light that takes no fade time from a command and runs its own lengths.
K.OWN = {
  dims = true,
  color = true,
  levelSteps = 255,
  fade = { kind = "own", own = { onMs = 400, offMs = 800, changeMs = 300 } },
  feedback = { shows = "target", waitMs = 1000, refresh = true },
}

-- A relay: on and off only.
K.RELAY = {
  dims = false,
  color = false,
  fade = { kind = "own", own = { onMs = 0, offMs = 0, changeMs = 0 } },
  feedback = { shows = "target", waitMs = 1000, refresh = true },
}

--- A world over `base` with `o` on top, lit to `level` (a C4 level) when given.
--- @param base MemoryOptions
--- @param o MemoryWorldOptions|nil
--- @param level integer|nil
--- @return MemoryWorld
function K.world(base, o, level)
  local opts = M.copy(base)
  for k, v in pairs(o or {}) do
    opts[k] = v
  end
  local w = M.world(opts)
  if level then
    w.proxy:send("SET_LEVEL", { LEVEL = level })
    w.run(10000)
    w.proxy:mark()
    w.m.sent = {}
  end
  return w
end

--- @param a number|nil
--- @param b number|nil
--- @param tolerance number|nil
--- @return boolean
function K.near(a, b, tolerance)
  return a ~= nil and b ~= nil and math.abs(a - b) <= (tolerance or 1e-3)
end

--- The colors told by CHANGED since the mark, as { x, y }.
--- @param w MemoryWorld
--- @return {x: number, y: number}[]
function K.toldColors(w)
  local out = {}
  for _, q in ipairs(w.proxy:told("LIGHT_COLOR_CHANGED")) do
    out[#out + 1] = { x = q.LIGHT_COLOR_CURRENT_X, y = q.LIGHT_COLOR_CURRENT_Y }
  end
  return out
end

--- The device's state now.
--- @param w MemoryWorld
--- @return LightValues
function K.device(w)
  return w.device:state(w.clock.now())
end

--- The device's level now, as a C4-like percent: 0 when off.
--- @param w MemoryWorld
--- @return integer
function K.devicePercent(w)
  local s = K.device(w)
  if not s.on then
    return 0
  end
  return math.floor(s.level * 100 + 0.5)
end

--- A SET_COLOR_TARGET.
--- @param w MemoryWorld
--- @param x number
--- @param y number
--- @param rate integer|nil
--- @param mode integer|nil
--- @param preset {id: integer, origin: integer}|nil
function K.color(w, x, y, rate, mode, preset)
  w.proxy:send("SET_COLOR_TARGET", {
    LIGHT_COLOR_TARGET_X = x,
    LIGHT_COLOR_TARGET_Y = y,
    LIGHT_COLOR_TARGET_MODE = mode or K.FULL,
    LIGHT_COLOR_TARGET_COLOR_RATE = rate or 0,
    LIGHT_COLOR_TARGET_PRESET_ID = preset and preset.id or nil,
    LIGHT_COLOR_TARGET_PRESET_ORIGIN = preset and preset.origin or nil,
  })
end

--- A SET_BRIGHTNESS_TARGET.
--- @param w MemoryWorld
--- @param level integer
--- @param rate integer|nil
function K.target(w, level, rate)
  w.proxy:send("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = level, RATE = rate or 0 })
end

--- @class KitPreset
--- @field id integer
--- @field origin integer
--- @field x number
--- @field y number
--- @field mode integer|nil

K.RED = { x = 0.6, y = 0.3 }
K.GREEN = { x = 0.3, y = 0.6 }
K.ON_PRESET = { id = 1, origin = 1, x = 0.6, y = 0.3 }
K.WARM = { id = 1, origin = 1, x = 0.45, y = 0.41, mode = K.CCT }
K.DIM = { id = 2, origin = 1, x = 0.53, y = 0.41, mode = K.CCT }

--- The proxy's On Color and Dim Color as UPDATE_COLOR_ON_MODE names them: a preset, or Dim-To-Warm.
--- @param w MemoryWorld
--- @param on KitPreset
--- @param dim KitPreset|nil
function K.onMode(w, on, dim)
  dim = dim or { id = 0, origin = 0 }
  w.proxy:send("UPDATE_COLOR_ON_MODE", {
    COLOR_PRESET_ID = on.id,
    COLOR_PRESET_ORIGIN = on.origin,
    COLOR_PRESET_COLOR_X = on.x,
    COLOR_PRESET_COLOR_Y = on.y,
    COLOR_PRESET_COLOR_MODE = on.mode or K.FULL,
    COLOR_FADE_PRESET_ID = dim.id,
    COLOR_FADE_PRESET_ORIGIN = dim.origin,
    COLOR_FADE_PRESET_COLOR_X = dim.x,
    COLOR_FADE_PRESET_COLOR_Y = dim.y,
    COLOR_FADE_PRESET_COLOR_MODE = dim.mode or K.FULL,
  })
end

--- @class KitStep
--- @field delay integer|nil
--- @field level integer|nil
--- @field color {x: number, y: number, mode: integer|nil}|nil
--- @field rate integer|nil

--- Push a scene of steps, as the proxy does.
--- @param w MemoryWorld
--- @param id integer
--- @param steps KitStep[]
--- @param flash boolean|nil
function K.scene(w, id, steps, flash)
  local xml = {}
  for _, s in ipairs(steps) do
    local parts = { "<element>", "<delay>" .. (s.delay or 0) .. "</delay>" }
    if s.level then
      parts[#parts + 1] = "<brightnessEnabled>True</brightnessEnabled><brightness>" .. s.level .. "</brightness>"
      parts[#parts + 1] = "<brightnessRate>" .. (s.rate or 0) .. "</brightnessRate>"
    end
    if s.color then
      parts[#parts + 1] = "<colorEnabled>True</colorEnabled><colorX>"
        .. s.color.x
        .. "</colorX><colorY>"
        .. s.color.y
        .. "</colorY>"
      parts[#parts + 1] = "<colorMode>"
        .. (s.color.mode or 0)
        .. "</colorMode><colorRate>"
        .. (s.rate or 0)
        .. "</colorRate>"
    end
    parts[#parts + 1] = "</element>"
    xml[#xml + 1] = table.concat(parts)
  end
  w.proxy:send(
    "PUSH_SCENE",
    { SCENE_ID = id, ELEMENTS = table.concat(xml), FLASH = flash and "True" or "False", FROM_GROUP = "True" }
  )
end

--- A BUTTON_ACTION: button 0 top, 1 bottom, 2 toggle; action 0 release after a hold, 1 press, 2 release
--- after a click.
--- @param w MemoryWorld
--- @param button integer
--- @param action integer
function K.button(w, button, action)
  w.proxy:send("BUTTON_ACTION", { BUTTON_ID = button, ACTION = action })
end

--- Every LIGHT_* notify's command and level or color since the mark, compact, for a failure's detail.
--- @param w MemoryWorld
--- @return string
function K.story(w)
  local out = {}
  for _, n in ipairs(w.proxy.notes) do
    local p = n.params or {}
    if type(p) ~= "table" then
      out[#out + 1] = string.format("%d %s %s", n.at, n.cmd, tostring(p))
    elseif n.cmd:match("BRIGHTNESS") then
      out[#out + 1] = string.format(
        "%d %s %s->%s r%s",
        n.at,
        n.cmd,
        tostring(p.LIGHT_BRIGHTNESS_CURRENT),
        tostring(p.LIGHT_BRIGHTNESS_TARGET),
        tostring(p.RATE)
      )
    elseif n.cmd:match("COLOR") then
      out[#out + 1] = string.format(
        "%d %s %.3f,%.3f->%s",
        n.at,
        n.cmd,
        tonumber(p.LIGHT_COLOR_CURRENT_X) or -1,
        tonumber(p.LIGHT_COLOR_CURRENT_Y) or -1,
        tostring(p.LIGHT_COLOR_TARGET_X)
      )
    else
      out[#out + 1] = string.format("%d %s", n.at, n.cmd)
    end
  end
  return table.concat(out, " | ")
end

return K
