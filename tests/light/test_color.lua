-- lib.light.color: its conversions agree with the controller's C4:Color* (the shim's, in tests), the
-- white-locus test, Color.taken, Color.forDevice and the Dim-To-Warm formula.

local T = require("testlib")

require("c4_shim")

local Color = require("lib.light.color")

local TOL = Color.TOLERANCE

local function near(a, b, tol)
  return math.abs(a - b) <= (tol or TOL)
end

T.section("modes: the contract's strings, and the proxy's numbers")
do
  T.eq("full color is xy", Color.FULL, "xy")
  T.eq("a white is cct", Color.CCT, "cct")
  T.eq("tolerance", TOL, 5e-3)
  for _, case in ipairs({
    { 0, "xy" },
    { 1, "cct" },
    { "1", "cct" },
    { "0", "xy" },
    { nil, "xy" },
    { 7, "xy" },
  }) do
    T.eq("from proxy mode " .. tostring(case[1]), Color.fromProxyMode(case[1]), case[2])
  end
  T.eq("to proxy mode xy", Color.toProxyMode("xy"), 0)
  T.eq("to proxy mode cct", Color.toProxyMode("cct"), 1)
  T.eq("to proxy mode nil", Color.toProxyMode(nil), 0)
end

T.section("xyToRGB: the brightest RGB for the chromaticity, as the controller converts it")
do
  for _, xy in ipairs({
    { 0.64, 0.33 },
    { 0.30, 0.60 },
    { 0.15, 0.06 },
    { 0.3127, 0.3290 },
    { 0.45, 0.41 },
    { 0.25, 0.20 },
  }) do
    local r, g, b = Color.xyToRGB(xy[1], xy[2])
    local label = string.format("(%.4f, %.4f)", xy[1], xy[2])
    T.check(label .. " has a channel at 1", near(math.max(r, g, b), 1, 1e-9), { r, g, b })
    T.check(label .. " has no channel past 0 to 1", math.min(r, g, b) >= 0 and math.max(r, g, b) <= 1 + 1e-9)
    local h, s = C4:ColorXYtoHSV(xy[1], xy[2])
    local cr, cg, cb = C4:ColorHSVtoRGB(h, s, 100)
    T.check(
      label .. " agrees with C4:ColorXYtoHSV and ColorHSVtoRGB",
      near(r, cr / 255, 2 / 255) and near(g, cg / 255, 2 / 255) and near(b, cb / 255, 2 / 255),
      { { r, g, b }, { cr / 255, cg / 255, cb / 255 } }
    )
    local x, y = Color.rgbToXY(r, g, b)
    T.check(label .. " comes back through rgbToXY", near(x, xy[1]) and near(y, xy[2]), { x, y })
  end
end

T.section("rgbToXY: as C4:ColorHSVtoXY gives it; black has none")
do
  for _, rgb in ipairs({ { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, { 1, 1, 1 }, { 1, 0.5, 0.25 }, { 0.2, 0.1, 0.05 } }) do
    local x, y = Color.rgbToXY(rgb[1], rgb[2], rgb[3])
    local h, s = C4:ColorRGBtoHSV(rgb[1] * 255, rgb[2] * 255, rgb[3] * 255)
    local cx, cy = C4:ColorHSVtoXY(h, s, 100)
    T.check(
      string.format("(%.2f, %.2f, %.2f)", rgb[1], rgb[2], rgb[3]),
      near(x, cx) and near(y, cy),
      { { x, y }, { cx, cy } }
    )
  end
  local half = { Color.rgbToXY(0.5, 0.25, 0.125) }
  local full = { Color.rgbToXY(1, 0.5, 0.25) }
  T.check("only the ratio counts", near(half[1], full[1]) and near(half[2], full[2]), { half, full })
  T.eq("black", { Color.rgbToXY(0, 0, 0) }, {})
end

T.section("kelvinToXY and kelvin: the locus, as C4:ColorCCTtoXY and ColorXYtoCCT give it")
do
  for _, k in ipairs({ 2000, 2700, 3000, 4000, 5000, 6500 }) do
    local x, y = Color.kelvinToXY(k)
    local cx, cy = C4:ColorCCTtoXY(k)
    T.check(k .. " K to xy", near(x, cx, 1e-12) and near(y, cy, 1e-12), { x, y })
    T.eq(k .. " K back", Color.kelvin(x, y), C4:ColorXYtoCCT(x, y))
    T.check(k .. " K back within 10 K", math.abs(Color.kelvin(x, y) - k) <= 10, Color.kelvin(x, y))
  end
  T.eq("mireds to kelvin", Color.miredsToKelvin(370), 2703)
  T.eq("no mireds", Color.miredsToKelvin(0), 0)
  T.check("kelvin to mireds", near(Color.kelvinToMireds(2500), 400, 1e-9))
  T.eq("no kelvin", Color.kelvinToMireds(nil), 0)
end

T.section("onLocus: within the white band of the locus between two Kelvins")
do
  local x, y = Color.kelvinToXY(3000)
  local BAND = Color.WHITE_BAND
  T.eq("the white band is 0.012 in xy", BAND, 0.012)
  T.eq("a point on the locus inside the range", Color.onLocus(x, y, 2000, 6500), true)
  -- Off the locus along its normal at 3000 K, so the nearest point on it stays near 3000 K.
  local ax, ay = Color.kelvinToXY(2990)
  local bx, by = Color.kelvinToXY(3010)
  local length = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
  local nx, ny = -(by - ay) / length, (bx - ax) / length
  T.eq("a point inside the band", Color.onLocus(x + nx * BAND * 0.8, y + ny * BAND * 0.8, 2000, 6500), true)
  T.eq("a point outside it", Color.onLocus(x + nx * BAND * 1.25, y + ny * BAND * 1.25, 2000, 6500), false)
  T.eq("a point off by more", Color.onLocus(x + BAND * 3, y + BAND * 3, 2000, 6500), false)
  T.eq("a saturated red", Color.onLocus(0.64, 0.33, 2000, 6500), false)
  local hx, hy = Color.kelvinToXY(9000)
  T.eq("a white past the range's cool end", Color.onLocus(hx, hy, 2000, 6500), false)
  T.eq("the same white in a range that reaches it", Color.onLocus(hx, hy, 2000, 10000), true)
  local ex, ey = Color.kelvinToXY(6500)
  T.eq("the range's own end", Color.onLocus(ex, ey, 2000, 6500), true)
end

T.section("same and alike")
do
  T.eq("same within tolerance", Color.same(0.3, 0.3, "xy", 0.3 + TOL * 0.9, 0.3, "xy"), true)
  T.eq("not past it", Color.same(0.3, 0.3, "xy", 0.3 + TOL * 2, 0.3, "xy"), false)
  T.eq("not across modes", Color.same(0.3, 0.3, "xy", 0.3, 0.3, "cct"), false)
  T.eq("two nils", Color.alike(nil, nil), true)
  T.eq("one nil", Color.alike({ x = 0.3, y = 0.3, mode = "xy" }, nil), false)
  T.eq(
    "two colors",
    Color.alike({ x = 0.3, y = 0.3, mode = "xy" }, { x = 0.302, y = 0.299, mode = "xy", kelvin = nil }),
    true
  )
end

T.section("taken: a white by what the light has")
do
  local x, y = 0.45, 0.41
  local k = Color.kelvin(x, y)
  local lx, ly = Color.kelvinToXY(k)
  for _, case in ipairs({
    { "full color stays", { 0.64, 0.33, "xy", true, true }, { 0.64, 0.33, "xy" } },
    { "a white on a CCT light goes to its locus point", { x, y, "cct", true, true }, { lx, ly, "cct" } },
    { "a white on a CCT-only light likewise", { x, y, "cct", false, true }, { lx, ly, "cct" } },
    { "a white on a color-only light is a full color on the locus", { x, y, "cct", true, false }, { lx, ly, "xy" } },
    { "a white on neither stays as given", { x, y, "cct", false, false }, { x, y, "cct" } },
  }) do
    local a = case[2]
    T.eq(case[1], { Color.taken(a[1], a[2], a[3], a[4], a[5]) }, case[3])
  end
end

T.section("forDevice: the form a device takes, with its Kelvin clamped to the range")
do
  local both = { color = true, cct = { minK = 2700, maxK = 6500 } }
  local cctOnly = { color = false, cct = { minK = 2700, maxK = 6500 } }
  local colorOnly = { color = true }
  local neither = { color = false }
  local function white(k)
    local x, y = Color.kelvinToXY(k)
    return { x = x, y = y, mode = "cct" }
  end
  local inside = Color.forDevice(white(3000), both)
  T.check("a white inside the range has its Kelvin", inside.kelvin ~= nil and math.abs(inside.kelvin - 3000) <= 10)
  T.eq("and its mode", inside.mode, "cct")
  local warm = Color.forDevice(white(2000), cctOnly)
  T.eq("a white warmer than the range is clamped", warm.kelvin, 2700)
  local wx, wy = Color.kelvinToXY(2700)
  T.check("to the range's own point", near(warm.x, wx, 1e-12) and near(warm.y, wy, 1e-12))
  T.eq(
    "a given Kelvin inside the range is kept",
    Color.forDevice({ x = 0, y = 0, mode = "cct", kelvin = 4000 }, both).kelvin,
    4000
  )
  T.eq(
    "a given Kelvin past it is clamped",
    Color.forDevice({ x = 0, y = 0, mode = "cct", kelvin = 9000 }, both).kelvin,
    6500
  )
  T.eq("full color on a color light", Color.forDevice({ x = 0.64, y = 0.33, mode = "xy" }, both), {
    x = 0.64,
    y = 0.33,
    mode = "xy",
  })
  local nearest = Color.forDevice({ x = 0.64, y = 0.33, mode = "xy" }, cctOnly)
  T.check(
    "a full color on a CCT-only light is its nearest white, in the range",
    nearest ~= nil and nearest.mode == "cct" and nearest.kelvin >= 2700 and nearest.kelvin <= 6500,
    nearest
  )
  local hot = Color.forDevice(white(9000), colorOnly)
  local hx, hy = Color.kelvinToXY(Color.WHITE_MAX_K)
  T.check(
    "a white past the default range on a color-only light is the range's end, as a full color",
    hot.mode == "xy" and near(hot.x, hx, 1e-9) and near(hot.y, hy, 1e-9),
    hot
  )
  local asColor = Color.forDevice(white(3000), colorOnly)
  T.eq("a white on a color-only light is a full color", asColor.mode, "xy")
  T.eq("any color on neither", Color.forDevice(white(3000), neither), nil)
end

T.section("dimToWarm: the Dim color at 0 to the On color at 100, straight across xy, in the On color's mode")
do
  local dim = { x = 0.30, y = 0.60, mode = "xy" }
  local on = { x = 0.64, y = 0.33, mode = "xy" }
  for _, case in ipairs({
    { 0, 0.30, 0.60 },
    { 100, 0.64, 0.33 },
    { 50, 0.47, 0.465 },
    { -5, 0.30, 0.60 },
    { 150, 0.64, 0.33 },
  }) do
    local c = Color.dimToWarm(dim, on, case[1])
    T.check("level " .. case[1], near(c.x, case[2], 1e-12) and near(c.y, case[3], 1e-12) and c.mode == "xy", c)
  end
  T.eq("an On color with no mode is full color", Color.dimToWarm(dim, { x = 0.4, y = 0.2 }, 50).mode, "xy")
end

T.section("dimToWarm between two whites is straight across xy too, in the On color's mode (Control4's formula)")
do
  local dim = { x = 0.55, y = 0.40, mode = "cct" }
  local on = { x = 0.45, y = 0.41, mode = "cct" }
  for _, case in ipairs({
    { 0, 0.55, 0.40 },
    { 100, 0.45, 0.41 },
    { 50, 0.50, 0.405 },
  }) do
    local c = Color.dimToWarm(dim, on, case[1])
    T.check("level " .. case[1], near(c.x, case[2], 1e-12) and near(c.y, case[3], 1e-12) and c.mode == "cct", c)
  end
end

T.section("mixXY: parts that light together show the sum of their light")
do
  local RED, D65 = { x = 0.64, y = 0.33 }, { x = 0.3127, y = 0.329 }
  local x, y = Color.mixXY({ { x = RED.x, y = RED.y, Y = 0.4 } })
  T.check("one part is its own color", near(x, RED.x, 1e-12) and near(y, RED.y, 1e-12), { x, y })
  x, y = Color.mixXY({ { x = RED.x, y = RED.y, Y = 0.14 }, { x = D65.x, y = D65.y, Y = 0.35 } })
  -- Each part weighs in by Y / y, its X + Y + Z.
  local wr, ww = 0.14 / RED.y, 0.35 / D65.y
  T.check(
    "red with white LEDs is between them, weighted by each part's light",
    near(x, (RED.x * wr + D65.x * ww) / (wr + ww), 1e-12) and near(y, (RED.y * wr + D65.y * ww) / (wr + ww), 1e-12),
    { x, y }
  )
  local cross = (D65.x - RED.x) * (y - RED.y) - (D65.y - RED.y) * (x - RED.x)
  T.check("on the line between the two", math.abs(cross) < 1e-12, cross)
  x, y = Color.mixXY({ { x = RED.x, y = RED.y, Y = 0.14 }, { x = D65.x, y = D65.y, Y = 0 } })
  T.check(
    "a part that gives no light leaves the rest as it is",
    near(x, RED.x, 1e-12) and near(y, RED.y, 1e-12),
    { x, y }
  )
  T.eq("no light at all is no color", { Color.mixXY({ { x = RED.x, y = RED.y, Y = 0 } }) }, {})
end

T.finish()
