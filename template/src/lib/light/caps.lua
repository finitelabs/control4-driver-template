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

--- The static capabilities driver.xml must declare, with the value the library relies on. Each of
--- them is "Dynamic Capability: No" on the Light V2 pages, or a tier Composer's test panel reads from
--- the static list as well as the dynamic one. has_button_events is True only with button links.
--- @type table<string, string>
Caps.STATIC = {
  dimmer = "True",
  set_level = "True",
  supports_target = "True",
  supports_brightness_stop = "True",
  ramp_level = "True",
  click_rates = "True",
  hold_rates = "True",
  advanced_scene_support = "True",
  multi_click = "False",
  supports_broadcast_scenes = "False",
  load_group_support = "False",
  brightness_on_mode_preset = "True",
  brightness_on_mode_previous = "True",
  color_on_mode_fade = "True",
  color_on_mode_preset = "True",
  color_on_mode_previous = "True",
}

local KNOWN = {
  top = { dims = true, color = true, cct = true, levelSteps = true, tolerance = true, fade = true, reports = true },
  fade = { by = true, curve = true, retimes = true, preOn = true },
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

--- Check a declaration and fill in its defaults.
--- @param caps table The adapter's declaration, a LightCaps.
--- @return table|nil decl The declaration in force, or nil when it is refused whole.
--- @return string[] errors Each field logged as an error: a refused declaration, or a bad or unknown field ignored.
function Caps.check(caps)
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
--- @return table capabilities
function Caps.dynamic(decl)
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
    supports_color_stop = (color or cct) and stops,
    color_rate_behavior = 1,
    color_rate_min = 0,
    color_rate_max = 65535,
    has_extras = false,
    cold_start = false,
    color_trace_tolerance = decl.tolerance,
  }
  if cct then
    caps.color_correlated_temperature_min = decl.cct.min
    caps.color_correlated_temperature_max = decl.cct.max
  end
  return caps
end

--- Each static capability of a driver.xml that differs from what the library relies on.
--- @param xml string The driver's driver.xml.
--- @param links boolean Whether the driver has button links.
--- @return table<string, string> mismatches Capability to the value found, "missing" where absent.
function Caps.staticMismatches(xml, links)
  local want = {}
  for k, v in pairs(Caps.STATIC) do
    want[k] = v
  end
  want.has_button_events = links and "True" or "False"
  local block = xml:match("<capabilities>(.-)</capabilities>") or ""
  local out = {}
  for k, v in pairs(want) do
    local got = block:match("<" .. k .. ">%s*([^<]-)%s*</" .. k .. ">")
    if got ~= v then
      out[k] = got or "missing"
    end
  end
  return out
end

return Caps
