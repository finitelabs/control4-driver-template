--- A light's declaration: its defaults and checks, the dynamic capabilities the proxy is told from
--- it, and the static block of driver.xml the library relies on.

local Caps = {}

--- The report policies this version runs. A declaration naming no other is refused.
--- @type table<string, boolean>
Caps.POLICIES = { trust = true, settle = true, echo = true }

--- The fade models this version runs.
--- @type table<string, boolean>
Caps.FADES = { device = true, none = true }

--- The color match tolerance in xy a report is judged with by default.
--- @type number
Caps.MATCH = 5e-3

--- How long past 1.5 times its transition a command waits for its word by default (ms).
--- @type integer
Caps.ACK_MS = 40000

--- How long a report from before the newest command waits for that command's echo by default (ms).
--- @type integer
Caps.WAIT_MS = 1000

--- The longest rate the proxy offers once a long fade runs as legs (24 h, in ms), and the one a
--- single device command carries (65535 ms).
Caps.LONG_RATE_MAX, Caps.RATE_MAX = 86400000, 65535

--- The color temperature range a light whose range varies, or is unknown, starts from (K).
Caps.CCT_MIN, Caps.CCT_MAX = 2000, 6500

--- The profile's fields and their defaults: the most any device behind the driver can do.
local PROFILE = {
  dims = false,
  color = false,
  cct = false,
  fixed = false,
  fades = true,
  scenes = true,
  onModes = true,
  flash = true,
  extras = false,
}

--- Check a driver's static profile and fill in its defaults. An error here is the driver's own, so
--- Light.new raises with it.
--- @param profile table|nil
--- @return table|nil profile The profile in force, or nil with the errors.
--- @return string[] errors
function Caps.profile(profile)
  if type(profile) ~= "table" then
    return nil, { "opts.profile is required: what the devices behind this driver can do" }
  end
  local errors, out = {}, {}
  for k, v in pairs(profile) do
    if PROFILE[k] == nil then
      errors[#errors + 1] = string.format("profile.%s is not a field this version knows", tostring(k))
    elseif k == "cct" then
      if type(v) == "table" then
        if not (type(v.min) == "number" and type(v.max) == "number" and v.min > 0 and v.min <= v.max) then
          errors[#errors + 1] = "profile.cct must be true, false or { min, max } in kelvin"
        end
      elseif type(v) ~= "boolean" then
        errors[#errors + 1] = "profile.cct must be true, false or { min, max } in kelvin"
      end
    elseif k == "fades" then
      if type(v) == "table" then
        if not (type(v.maxMs) == "number" and v.maxMs > 0) then
          errors[#errors + 1] = "profile.fades must be true, false or { maxMs = n }"
        end
      elseif type(v) ~= "boolean" then
        errors[#errors + 1] = "profile.fades must be true, false or { maxMs = n }"
      end
    elseif type(v) ~= "boolean" then
      errors[#errors + 1] = string.format("profile.%s must be true or false", k)
    end
  end
  if #errors > 0 then
    return nil, errors
  end
  for k, default in pairs(PROFILE) do
    local v = profile[k]
    if v == nil then
      v = default
    end
    out[k] = v
  end
  if out.fixed and out.cct == true then
    return nil, { "a fixed profile with cct names its range: cct = { min, max }" }
  end
  if type(out.cct) == "table" then
    out.cct = { min = math.floor(out.cct.min + 0.5), max = math.floor(out.cct.max + 0.5) }
  end
  if type(out.fades) == "table" then
    out.fades = { maxMs = out.fades.maxMs }
  end
  return out, {}
end

local function bool(v)
  return v and "True" or "False"
end

--- The static capabilities of a driver.xml, derived from its profile, in the order they are written.
--- Nothing in the block is written by hand: make light-caps writes it, and the contract fails one
--- that differs.
--- @param profile table A checked profile.
--- @param links boolean Whether the driver has button links.
--- @return table[] rows { key, value, note } in order; a note is the comment written above its key.
function Caps.static(profile, links)
  local dims, color, cct = profile.dims, profile.color, profile.cct ~= false
  local fades = profile.fades ~= false
  local rateMax = type(profile.fades) == "table" and Caps.LONG_RATE_MAX or Caps.RATE_MAX
  local shown = profile.fixed
  local range = type(profile.cct) == "table" and profile.cct or { min = Caps.CCT_MIN, max = Caps.CCT_MAX }
  return {
    { "dimmer", bool(dims) },
    { "set_level", bool(dims) },
    { "supports_target", bool(dims) },
    {
      "on_off",
      "True",
      "on_off, ramp_level and supports_default_on are deprecated in OS 3.3.2, but Composer's test panel "
        .. "still shows the On and Off buttons, the Ramp button and the Default On preset editor by them.",
    },
    { "ramp_level", bool(dims) },
    { "supports_default_on", "True" },
    { "supports_brightness_stop", bool(dims and fades) },
    { "click_rates", bool(dims and fades) },
    { "hold_rates", bool(dims and fades) },
    {
      "has_fixed_ramp_rate",
      "False",
      "Declared rather than left out, as Composer's test panel can treat a missing capability apart from "
        .. "its default.",
    },
    { "fixed_ramp_rate", "0" },
    { "brightness_rate_min", "0" },
    { "brightness_rate_max", tostring(rateMax) },
    {
      "brightness_rate_default",
      "0",
      "The proxy reads no rate default from either list, so this and color_rate_default are inert.",
    },
    { "click_rate_min", "0" },
    { "click_rate_max", "65535" },
    { "hold_rate_min", "1000" },
    { "hold_rate_max", "86400000" },
    { "supports_color", bool(shown and color) },
    { "supports_color_correlated_temperature", bool(shown and cct) },
    { "color_correlated_temperature_min", tostring(shown and cct and range.min or Caps.CCT_MIN) },
    { "color_correlated_temperature_max", tostring(shown and cct and range.max or Caps.CCT_MAX) },
    { "color_trace_tolerance", "2" },
    { "supports_color_stop", bool((dims or color or cct) and fades) },
    { "color_rate_behavior", fades and "1" or "0" },
    { "color_rate_min", "0" },
    { "color_rate_max", tostring(rateMax) },
    { "color_rate_default", "0" },
    { "has_button_events", bool(links) },
    { "has_leds", bool(links) },
    { "advanced_scene_support", bool(profile.scenes) },
    { "reduced_als_support", "False" },
    { "brightness_on_mode_preset", bool(profile.onModes and dims) },
    { "brightness_on_mode_previous", bool(profile.onModes and dims) },
    { "color_on_mode_fade", bool(profile.onModes and (color or cct)) },
    { "color_on_mode_preset", bool(profile.onModes and (color or cct)) },
    { "color_on_mode_previous", bool(profile.onModes and (color or cct)) },
    { "has_extras", bool(profile.extras) },
    { "disable_flash", bool(not profile.flash) },
    { "cold_start", "False" },
    { "hide_proxy_properties", "False" },
    { "hide_proxy_events", "False" },
    { "multi_click", "False" },
    { "supports_broadcast_scenes", "False" },
    { "supports_multichannel_scenes", "False" },
    { "load_group_support", "False" },
  }
end

--- The comments that mark the block make light-caps writes in a driver.xml.
Caps.BEGIN = "<!-- lib.light: make light-caps writes the capabilities from the driver's profile -->"
Caps.END = "<!-- lib.light: end of the capabilities -->"

--- The block make light-caps writes, markers included, indented as a driver.xml's top level.
--- @param profile table A checked profile.
--- @param links boolean
--- @return string
function Caps.block(profile, links)
  local lines = { "  " .. Caps.BEGIN, "  <capabilities>" }
  for _, row in ipairs(Caps.static(profile, links)) do
    if row[3] then
      lines[#lines + 1] = "    <!-- " .. row[3] .. " -->"
    end
    lines[#lines + 1] = string.format("    <%s>%s</%s>", row[1], row[2], row[1])
  end
  lines[#lines + 1] = "  </capabilities>"
  lines[#lines + 1] = "  " .. Caps.END
  return table.concat(lines, "\n")
end

--- The driver.xml with its capabilities block written from the profile. The block between the markers
--- is replaced; a driver.xml without them has its whole <capabilities> element replaced, markers added.
--- @param xml string
--- @param profile table A checked profile.
--- @param links boolean
--- @return string|nil xml Nil with an error when there is no block to replace.
--- @return string|nil err
function Caps.write(xml, profile, links)
  local block = Caps.block(profile, links)
  local function escape(text)
    return (text:gsub("%p", "%%%0"))
  end
  local a, b = xml:find("[ \t]*" .. escape(Caps.BEGIN) .. ".-" .. escape(Caps.END))
  if not a then
    a, b = xml:find("[ \t]*<capabilities%s*/>")
  end
  if not a then
    a, b = xml:find("[ \t]*<capabilities>.-</capabilities>")
  end
  if not a then
    return nil, "driver.xml has no <capabilities> element"
  end
  return xml:sub(1, a - 1) .. block .. xml:sub(b + 1), nil
end

local KNOWN = {
  top = { dims = true, color = true, cct = true, levelSteps = true, tolerance = true, fade = true, reports = true },
  fade = { by = true, curve = true, retimes = true, preOn = true, darkBetweenModes = true },
  reports = { policy = true, settleMs = true, waitMs = true, match = true, ack = true, ackMs = true },
}

local function unknown(errors, where, t, known)
  for k in pairs(t) do
    if not known[k] then
      errors[#errors + 1] = string.format("%s%s is not a field this version knows", where, tostring(k))
    end
  end
end

local function positive(v)
  return type(v) == "number" and v == v and v > 0 and v < math.huge
end

--- What a declaration claims beyond its profile, or, for a fixed profile, where it differs from it.
--- @param decl table A checked declaration.
--- @param profile table A checked profile.
--- @return string|nil err
local function beyond(decl, profile)
  local claims = {}
  if decl.dims and not profile.dims then
    claims[#claims + 1] = "dims"
  end
  if decl.color and not profile.color then
    claims[#claims + 1] = "color"
  end
  if decl.cct and profile.cct == false then
    claims[#claims + 1] = "cct"
  end
  if decl.fade.by ~= "none" and profile.fades == false then
    claims[#claims + 1] = "a fade"
  end
  if #claims > 0 then
    return "the declaration claims " .. table.concat(claims, ", ") .. " beyond the driver's profile"
  end
  if profile.fixed then
    local cct = type(profile.cct) == "table" and profile.cct
    local same = decl.dims == profile.dims
      and decl.color == profile.color
      and (decl.cct == nil) == (cct == false)
      and (not cct or (decl.cct.min == cct.min and decl.cct.max == cct.max))
    if not same then
      return "the profile is fixed, so the declaration is its dims, color and cct exactly"
    end
  end
  return nil
end

--- Check a declaration and fill in its defaults.
--- @param caps table The adapter's declaration, a LightCaps.
--- @param profile table|nil The driver's checked profile: a declaration beyond it is refused whole.
--- @return table|nil decl The declaration in force, or nil when it is refused whole.
--- @return string[] errors Each field logged as an error: a refused declaration, or a bad or unknown field ignored.
function Caps.check(caps, profile)
  local errors = {}
  if type(caps) ~= "table" then
    return nil, { "the declaration is not a table" }
  end
  local reports = type(caps.reports) == "table" and caps.reports or {}
  if not Caps.POLICIES[reports.policy] then
    errors[1] = reports.policy == nil and "reports.policy is required: name the policy the device's reports prove"
      or string.format("reports.policy %q is not a policy this version runs", tostring(reports.policy))
    return nil, errors
  end
  unknown(errors, "", caps, KNOWN.top)
  local decl = { dims = caps.dims == true, color = caps.color == true }

  if caps.cct ~= nil then
    local cct = caps.cct
    if type(cct) == "table" and positive(cct.min) and positive(cct.max) and cct.min <= cct.max then
      decl.cct = { min = math.floor(cct.min + 0.5), max = math.floor(cct.max + 0.5) }
    else
      errors[#errors + 1] = "cct must be { min, max } in kelvin, min no more than max; ignored"
    end
  end
  if caps.levelSteps ~= nil then
    if positive(caps.levelSteps) and caps.levelSteps == math.floor(caps.levelSteps) then
      decl.levelSteps = caps.levelSteps
    else
      errors[#errors + 1] = "levelSteps must be a whole number of steps; ignored"
    end
  end
  decl.tolerance = 2
  if caps.tolerance ~= nil then
    if positive(caps.tolerance) then
      decl.tolerance = caps.tolerance
    else
      errors[#errors + 1] = "tolerance must be a number above 0; ignored"
    end
  end

  local fade = type(caps.fade) == "table" and caps.fade or {}
  if caps.fade ~= nil and type(caps.fade) ~= "table" then
    errors[#errors + 1] = "fade must be a table; ignored"
  end
  unknown(errors, "fade.", fade, KNOWN.fade)
  decl.fade = { by = "device", curve = "linear" }
  if fade.by ~= nil then
    if Caps.FADES[fade.by] then
      decl.fade.by = fade.by
    else
      errors[#errors + 1] = string.format("fade.by %q is not a fade this version runs; ignored", tostring(fade.by))
    end
  end
  if fade.curve ~= nil then
    if fade.curve ~= "linear" and fade.curve ~= "eased" then
      errors[#errors + 1] =
        string.format("fade.curve %q is not a curve this version runs; ignored", tostring(fade.curve))
    elseif decl.fade.by ~= "device" then
      errors[#errors + 1] = "fade.curve is for a fade the device runs; ignored"
    else
      decl.fade.curve = fade.curve
    end
  end
  if fade.retimes ~= nil then
    if type(fade.retimes) ~= "boolean" then
      errors[#errors + 1] = "fade.retimes must be true or false; ignored"
    elseif decl.fade.by ~= "device" then
      errors[#errors + 1] = "fade.retimes is for a fade the device runs; ignored"
    elseif fade.retimes then
      decl.fade.retimes = true
    end
  end
  if fade.preOn ~= nil then
    if not decl.dims then
      errors[#errors + 1] = "fade.preOn needs dims; ignored"
    elseif decl.fade.by ~= "device" then
      errors[#errors + 1] = "fade.preOn is for a fade the device runs; ignored"
    elseif positive(fade.preOn) and fade.preOn < 1 then
      decl.fade.preOn = fade.preOn
    else
      errors[#errors + 1] = "fade.preOn must be a brightness between 0 and 1; ignored"
    end
  end

  if fade.darkBetweenModes ~= nil then
    if decl.fade.by ~= "device" then
      errors[#errors + 1] = "fade.darkBetweenModes is for a fade the device runs; ignored"
    elseif positive(fade.darkBetweenModes) then
      decl.fade.darkBetweenModes = fade.darkBetweenModes
    else
      errors[#errors + 1] = "fade.darkBetweenModes must be a number of ms; ignored"
    end
  end

  unknown(errors, "reports.", reports, KNOWN.reports)
  decl.reports = { policy = reports.policy, match = Caps.MATCH, ack = "send" }
  if reports.settleMs ~= nil and not (type(reports.settleMs) == "number" and reports.settleMs >= 0) then
    errors[#errors + 1] = "reports.settleMs must be a number of ms; ignored"
  elseif reports.policy == "settle" then
    if reports.settleMs == nil then
      errors[#errors + 1] = "reports.settleMs is required under settle"
    end
    decl.reports.settleMs = reports.settleMs or 0
  elseif reports.settleMs ~= nil then
    errors[#errors + 1] = "reports.settleMs is for settle; ignored"
  end
  if reports.waitMs ~= nil and not (type(reports.waitMs) == "number" and reports.waitMs >= 0) then
    errors[#errors + 1] = "reports.waitMs must be a number of ms; ignored"
  elseif reports.policy == "echo" then
    decl.reports.waitMs = reports.waitMs or Caps.WAIT_MS
  elseif reports.waitMs ~= nil then
    errors[#errors + 1] = "reports.waitMs is for echo; ignored"
  end
  if reports.match ~= nil then
    if positive(reports.match) then
      decl.reports.match = reports.match
    else
      errors[#errors + 1] = "reports.match must be a number above 0; ignored"
    end
  end
  if reports.ack ~= nil then
    if reports.ack == "send" or reports.ack == "done" then
      decl.reports.ack = reports.ack
    else
      errors[#errors + 1] = string.format('reports.ack %q is not "send" or "done"; ignored', tostring(reports.ack))
    end
  end
  if reports.ackMs ~= nil then
    if decl.reports.ack ~= "done" then
      errors[#errors + 1] = 'reports.ackMs needs ack = "done"; ignored'
    elseif positive(reports.ackMs) then
      decl.reports.ackMs = reports.ackMs
    else
      errors[#errors + 1] = "reports.ackMs must be a number of ms; ignored"
    end
  end
  if decl.reports.ack == "done" then
    decl.reports.ackMs = decl.reports.ackMs or Caps.ACK_MS
  end
  local over = profile and beyond(decl, profile)
  if over then
    errors[#errors + 1] = over
    return nil, errors
  end
  return decl, errors
end

--- Whether two checked declarations are the same.
--- @param a table|nil
--- @param b table|nil
--- @return boolean
function Caps.same(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not Caps.same(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

--- Whether a fade model stops part way: the device's fade does; nothing moves under `none`.
--- @param decl table|nil
--- @return boolean
function Caps.stops(decl)
  return decl ~= nil and decl.fade.by == "device"
end

--- The full dynamic set the proxy is told for a declaration: every field, every time.
--- @param decl table
--- @param profile table|nil The driver's checked profile, for has_extras.
--- @return table capabilities
function Caps.dynamic(decl, profile)
  local dims = decl.dims
  local color, cct = decl.color, decl.cct ~= nil
  local stops = Caps.stops(decl)
  -- Every rate's bounds ride every send: bounds of 0 and 0 make the proxy reject its own 750 ms default.
  local caps = {
    dimmer = dims,
    set_level = dims,
    supports_target = dims,
    supports_brightness_stop = dims and stops,
    ramp_level = dims,
    has_fixed_ramp_rate = false,
    fixed_ramp_rate = 0,
    brightness_rate_min = 0,
    brightness_rate_max = 65535,
    supports_color = color,
    supports_color_correlated_temperature = cct,
    supports_color_stop = (dims or color or cct) and stops,
    color_rate_behavior = stops and 1 or 0,
    color_rate_min = 0,
    color_rate_max = 65535,
    has_extras = profile ~= nil and profile.extras == true,
    cold_start = false,
    color_trace_tolerance = decl.tolerance,
  }
  if cct then
    caps.color_correlated_temperature_min = decl.cct.min
    caps.color_correlated_temperature_max = decl.cct.max
  end
  return caps
end

return Caps
