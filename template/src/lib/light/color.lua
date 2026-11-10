--- Color helpers for the Light V2 library and its adapters: CIE xy, kelvin, mireds, RGB and HSV.
--- Every C4:Color* conversion is looked up when it is called, since a test may stub them at any time.

local Color = {}

--- Full color, as the proxy's color mode 0 names it.
--- @type integer
Color.FULL = 0

--- A color temperature, the proxy's color mode 1.
--- @type integer
Color.CCT = 1

--- D65, the color a light is taken to be in before anything is known.
--- @type table
Color.D65 = { x = 0.3127, y = 0.3290 }

--- How far apart two xy colors still read as one: a round trip through RGB or HSV drifts 1 to 2e-3.
--- @type number
Color.TOLERANCE = 5e-3

--- HSV (h 0 to 360, s and v 0 to 100) to RGB, each 0 to 1.
--- @param h number|nil
--- @param s number|nil
--- @param v number|nil
--- @return number r, number g, number b
function Color.hsvToRGB(h, s, v)
  local sf, vf = (s or 0) / 100, (v or 0) / 100
  local c = vf * sf
  local hh = ((h or 0) / 60) % 6
  local x = c * (1 - math.abs((hh % 2) - 1))
  local m = vf - c
  local r, g, b = 0, 0, 0
  if hh < 1 then
    r, g, b = c, x, 0
  elseif hh < 2 then
    r, g, b = x, c, 0
  elseif hh < 3 then
    r, g, b = 0, c, x
  elseif hh < 4 then
    r, g, b = 0, x, c
  elseif hh < 5 then
    r, g, b = x, 0, c
  else
    r, g, b = c, 0, x
  end
  return r + m, g + m, b + m
end

--- RGB, each 0 to 1, to HSV (h 0 to 360, s and v 0 to 100).
--- @param r number|nil
--- @param g number|nil
--- @param b number|nil
--- @return number h, number s, number v
function Color.rgbToHSV(r, g, b)
  r, g, b = r or 0, g or 0, b or 0
  local mx = math.max(r, g, b)
  local mn = math.min(r, g, b)
  local d = mx - mn
  local h = 0
  if d > 0 then
    if mx == r then
      h = 60 * (((g - b) / d) % 6)
    elseif mx == g then
      h = 60 * ((b - r) / d + 2)
    else
      h = 60 * ((r - g) / d + 4)
    end
  end
  if h < 0 then
    h = h + 360
  end
  local s = mx > 0 and (d / mx) * 100 or 0
  return h, s, mx * 100
end

--- A CIE xy color as RGB at full intensity, each 0 to 1: brightness rides the level.
--- @param x number
--- @param y number
--- @return number r, number g, number b
function Color.xyToRGB(x, y)
  local h, s = C4:ColorXYtoHSV(x, y)
  return Color.hsvToRGB(h or 0, s or 100, 100)
end

--- An RGB color, each 0 to 1, as CIE xy.
--- @param r number
--- @param g number
--- @param b number
--- @return number|nil x, number|nil y nil for black.
function Color.rgbToXY(r, g, b)
  if (r or 0) <= 0 and (g or 0) <= 0 and (b or 0) <= 0 then
    return nil, nil
  end
  local h, s = Color.rgbToHSV(r, g, b)
  return C4:ColorHSVtoXY(h, s, 100)
end

--- Mireds as kelvin, to the nearest whole kelvin.
--- @param mireds number|nil
--- @return integer kelvin 0 for none.
function Color.miredsToKelvin(mireds)
  if not mireds or mireds <= 0 then
    return 0
  end
  return math.floor(1e6 / mireds + 0.5)
end

--- Kelvin as mireds, unrounded.
--- @param kelvin number|nil
--- @return number mireds 0 for none.
function Color.kelvinToMireds(kelvin)
  if not kelvin or kelvin <= 0 then
    return 0
  end
  return 1e6 / kelvin
end

--- The color temperature a point reads as, or nil where the controller gives none.
--- @param x number
--- @param y number
--- @return number|nil kelvin
function Color.kelvin(x, y)
  local k = tonumber(C4:ColorXYtoCCT(x, y))
  return k and k > 0 and k or nil
end

--- Whether two colors read as one: the same mode, and each coordinate within the tolerance.
--- @param x1 number
--- @param y1 number
--- @param mode1 integer|nil
--- @param x2 number
--- @param y2 number
--- @param mode2 integer|nil
--- @param tolerance number|nil Defaults to Color.TOLERANCE.
--- @return boolean
function Color.same(x1, y1, mode1, x2, y2, mode2, tolerance)
  tolerance = tolerance or Color.TOLERANCE
  return mode1 == mode2 and math.abs(x1 - x2) <= tolerance and math.abs(y1 - y2) <= tolerance
end

--- A color as a light takes it, by whether it declared `color` and `cct`, and so as its reports read.
--- A white goes out at its color temperature's own point on a light with cct, and as a full color on
--- one with color and no cct.
--- @param x number
--- @param y number
--- @param mode integer
--- @param hasColor boolean
--- @param hasCct boolean
--- @return number x, number y, integer mode
function Color.taken(x, y, mode, hasColor, hasCct)
  if mode ~= Color.CCT then
    return x, y, mode
  end
  if not hasCct then
    return x, y, hasColor and Color.FULL or mode
  end
  local k = tonumber(C4:ColorXYtoCCT(x, y))
  if k and k > 0 then
    x, y = C4:ColorCCTtoXY(k)
  end
  return x, y, mode
end

return Color
