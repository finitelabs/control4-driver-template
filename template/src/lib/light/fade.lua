--- How a light moves between two states, by its declared fade model. `device`: the device fades
--- itself over the time each command asks, along its curve, with a pre-on for a light that keeps its
--- last level while off; with `retimes`, every command restarts every channel over its own time.
--- `none`: nothing moves; every change is at once and told as CHANGED only.

--- @class LightFadeModels
local Fade = {}

--- Where a level ramp has a light: its place between `from` and `to` at progress `p` along its
--- curve, in the units of its ends.
--- @param from number
--- @param to number
--- @param p number 0 to 1
--- @return number
function Fade.along(from, to, p)
  return from + (to - from) * p
end

--- The eased curve, ESPHome's smoothed progress: 6p^5 - 15p^4 + 10p^3.
--- @param p number 0 to 1
--- @return number
function Fade.eased(p)
  return p * p * p * (p * (p * 6 - 15) + 10)
end

--- How far through a color ramp a light is, 0 to 1 once the start has passed.
--- @param elapsed number
--- @param duration number
--- @return number
function Fade.progress(elapsed, duration)
  return math.max(0, elapsed) / duration
end

--- How far along its path a fade has the light at fraction `p` of its time, by the declared curve.
--- @private
--- @param p number
--- @return number
function Fade:_curve(p)
  local decl = self.device.live
  if decl and decl.fade.curve == "eased" then
    return Fade.eased(p)
  end
  return p
end

--- Whether a command restarts every channel of the light over its own time, named or not.
--- @private
--- @return boolean
function Fade:_retimes()
  local decl = self.device.live
  return decl ~= nil and decl.fade.retimes == true
end

--- The rate a command goes with: the one asked, or 0 for a light that dims and does not fade.
--- A light that does not dim keeps every rate as asked, for now.
--- @private
--- @param rate integer
--- @return integer
function Fade:_rate(rate)
  local decl = self.device.live
  if decl and decl.dims and decl.fade.by == "none" then
    return 0
  end
  return rate
end

--- The brightness a rated on from off first lights the light at, or nil for none. The declaration
--- keeps a pre-on only for a light that dims under a fade the device runs.
--- @private
--- @return number|nil
function Fade:_preOnLevel()
  local decl = self.device.live
  return decl and decl.fade.preOn or nil
end

return Fade
