-- lib.light.caps: the profile's and the device's checks and defaults, held to what lib.light.types states,
-- the static block the build writes, and the dynamic set the proxy is told.

local T = require("testlib")

local Caps = require("lib.light.caps")

local function hasError(errors, fragment)
  for _, e in ipairs(errors) do
    if e:find(fragment, 1, true) then
      return true
    end
  end
  return false
end

local function profileOf(fields)
  local p = { api = 1 }
  for k, v in pairs(fields or {}) do
    p[k] = v
  end
  local checked, errors = Caps.profile(p)
  assert(checked, table.concat(errors, "; "))
  return checked
end

local FULL = profileOf({ dims = true, color = true, cct = true, fades = true })

local function rows(profile)
  local out = {}
  for _, row in ipairs(Caps.static(profile)) do
    out[row.key] = row.value
  end
  return out
end

T.section("the profile's defaults are the contract's: every boolean false, proxy 5001, no links, 65535 ms")
do
  local p, errors = Caps.profile({ api = 1 })
  T.eq("no errors", errors, {})
  T.eq("defaults", p, {
    api = 1,
    proxy = 5001,
    maxMs = 65535,
    dims = false,
    color = false,
    known = false,
    fades = false,
    defaultOn = false,
    scenes = false,
    onModes = false,
    flash = false,
    extras = false,
    maxMs = 65535,
  })
end

T.section("a profile's maxMs is the longest rate its static capabilities offer")
do
  local p, errors = Caps.profile({ api = 1, dims = true, color = true, fades = true, maxMs = 86400000 })
  T.eq("no errors", errors, {})
  local r = rows(p)
  T.eq("brightness and color rates reach it", { r.brightness_rate_max, r.color_rate_max }, { "86400000", "86400000" })
  T.eq("the default", { rows(FULL).brightness_rate_max, rows(FULL).color_rate_max }, { "65535", "65535" })
  for _, bad in ipairs({ 0, -1, 1.5, "1000", true }) do
    local q, errs = Caps.profile({ api = 1, maxMs = bad })
    T.check(
      "maxMs " .. tostring(bad) .. " is an error",
      q == nil and (errs[1] or ""):find("profile.maxMs") ~= nil,
      errs
    )
  end
end

T.section("the profile's checks")
do
  for _, case in ipairs({
    { "not a table", nil, "required" },
    { "a boolean that is not one", { dims = 1 }, "profile.dims must be true or false" },
    { "an unknown field", { dimmable = true }, "profile.dimmable is not a field" },
    { "a bad proxy", { proxy = "5001" }, "profile.proxy" },
    { "links with a missing id", { links = { top = 300, toggle = 301 } }, "profile.links.bottom" },
    { "links not a table", { links = 300 }, "profile.links must be" },
    { "a bad cct", { cct = { minK = 6500, maxK = 2700 } }, "profile.cct must be" },
    { "a known profile with an open cct", { known = true, cct = true }, "a known profile with cct names its range" },
  }) do
    local p = case[2]
    if p then
      p.api = 1
    end
    local checked, errors = Caps.profile(p)
    T.eq(case[1] .. ": refused", checked, nil)
    T.check(case[1] .. ": says why", hasError(errors, case[3]), errors)
  end
  local p = profileOf({
    proxy = 5005,
    links = { top = 300, toggle = 301, bottom = 302 },
    cct = { minK = 2700.4, maxK = 6499.6 },
  })
  T.eq("proxy kept", p.proxy, 5005)
  T.eq("links kept", p.links, { top = 300, toggle = 301, bottom = 302 })
  T.eq("a cct range rounded", p.cct, { minK = 2700, maxK = 6500 })
  T.eq("cct false is none", profileOf({ cct = false }).cct, nil)
  T.eq("links false is none", profileOf({ links = false }).links, nil)
  T.eq("cct true kept", profileOf({ cct = true }).cct, true)
end

T.section("the device's defaults are the contract's")
do
  local d, errors = Caps.device({ dims = true }, FULL)
  T.eq("no errors", errors, {})
  T.eq("defaults", d, {
    dims = true,
    color = false,
    colorWhileOff = "send",
    levelSteps = 255,
    fade = { kind = "device", curve = "linear", preOn = false, retimes = false, maxMs = 65535 },
    feedback = { shows = "target", waitMs = 1000, refresh = false },
  })
  local walk = Caps.device({ dims = true, fade = { kind = "walk" } }, FULL)
  T.eq("a walk steps every 100 ms", walk.fade, { kind = "walk", maxMs = 65535, stepMs = 100 })
  local own = Caps.device({ fade = { kind = "own", own = { onMs = 300, offMs = 200, changeMs = 0 } } }, FULL)
  T.eq("an own fade keeps its lengths", own.fade, {
    kind = "own",
    maxMs = 65535,
    own = { onMs = 300, offMs = 200, changeMs = 0 },
  })
  T.eq("a device that is not a table", { Caps.device(nil, FULL) }, { nil, { "the device is not a table" } })
end

T.section("a profile without fades: a device runs its own, at once")
do
  local still = profileOf({ dims = true })
  local d, errors = Caps.device({ dims = true }, still)
  T.eq("no fade given: an own fade of 0 and no error", { d.fade, errors }, {
    { kind = "own", maxMs = 65535, own = { onMs = 0, offMs = 0, changeMs = 0 } },
    {},
  })
  local d2, errors2 = Caps.device({ dims = true, fade = { kind = "device" } }, still)
  T.eq("a device fade given is beyond it", d2.fade.kind, "own")
  T.check("and says so", hasError(errors2, "beyond a profile without fades"), errors2)
  local d3 = Caps.device({ dims = true, fade = { kind = "own", own = { onMs = 0, offMs = 0, changeMs = 500 } } }, still)
  T.eq("an own fade of its own lengths is kept", d3.fade.own.changeMs, 500)
end

T.section("a fade field set for the wrong kind is dropped with an error")
do
  local ZERO = { onMs = 0, offMs = 0, changeMs = 0 }
  for _, case in ipairs({
    -- the fade given, the error, the field and what it is after the check
    { { kind = "own", own = ZERO, curve = "smootherstep" }, "fade.curve", "curve", nil },
    { { kind = "walk", preOn = true }, "fade.preOn", "preOn", nil },
    { { kind = "device", own = { onMs = 1, offMs = 1, changeMs = 1 } }, "fade.own", "own", nil },
    { { kind = "device", stepMs = 50 }, "fade.stepMs", "stepMs", nil },
    { { kind = "own", own = ZERO, stepMs = 50 }, "fade.stepMs", "stepMs", nil },
    { { kind = "glide" }, "fade.kind", "kind", "device" },
    { { kind = "device", curve = "eased" }, "fade.curve", "curve", "linear" },
    { { kind = "device", maxMs = -1 }, "fade.maxMs", "maxMs", 65535 },
    { { kind = "walk", stepMs = 0 }, "fade.stepMs", "stepMs", 100 },
    { { kind = "own" }, "fade.own is required", "own", ZERO },
    { { kind = "device", speed = 2 }, "fade.speed", "speed", nil },
    { { kind = "walk", retimes = true }, "fade.retimes", "retimes", nil },
    { { kind = "own", own = ZERO, retimes = false }, "fade.retimes", "retimes", nil },
    { { kind = "device", retimes = "yes" }, "fade.retimes must be true or false", "retimes", false },
  }) do
    local d, errors = Caps.device({ dims = true, fade = case[1] }, FULL)
    local label = case[2] .. " on " .. tostring(case[1].kind)
    T.check(label .. " is an error", hasError(errors, case[2]), errors)
    T.eq(label .. ": " .. case[3] .. " after the check", d.fade[case[3]], case[4])
  end
  local own = Caps.device({ fade = { kind = "own" } }, FULL)
  T.eq("an own fade with no lengths takes 0", own.fade.own, { onMs = 0, offMs = 0, changeMs = 0 })
  local noDims, errors = Caps.device({ fade = { kind = "device", preOn = true } }, FULL)
  T.eq("preOn needs dims", noDims.fade.preOn, false)
  T.check("and says so", hasError(errors, "fade.preOn needs dims"), errors)
  local smooth = Caps.device(
    { dims = true, fade = { curve = "smootherstep", preOn = true, retimes = true, maxMs = 86400000 } },
    FULL
  )
  T.eq("a device fade keeps its own fields", smooth.fade, {
    kind = "device",
    curve = "smootherstep",
    preOn = true,
    retimes = true,
    maxMs = 86400000,
  })
end

T.section("feedback and the other facts: a bad value takes its default with an error")
do
  for _, case in ipairs({
    {
      { feedback = { shows = "middle" } },
      "feedback.shows",
      function(d)
        return d.feedback.shows == "target"
      end,
    },
    {
      { feedback = { waitMs = 1.5 } },
      "feedback.waitMs",
      function(d)
        return d.feedback.waitMs == 1000
      end,
    },
    {
      { feedback = { refresh = "yes" } },
      "feedback.refresh",
      function(d)
        return d.feedback.refresh == false
      end,
    },
    {
      { feedback = { tries = 3 } },
      "feedback.tries",
      function(d)
        return d.feedback.tries == nil
      end,
    },
    {
      { feedback = 5 },
      "feedback must be a table",
      function(d)
        return d.feedback.shows == "target"
      end,
    },
    {
      { colorWhileOff = "drop" },
      "colorWhileOff",
      function(d)
        return d.colorWhileOff == "send"
      end,
    },
    {
      { levelSteps = 0 },
      "levelSteps",
      function(d)
        return d.levelSteps == 255
      end,
    },
    {
      { dims = "yes" },
      "dims must be true or false",
      function(d)
        return d.dims == false
      end,
    },
    {
      { cct = { minK = 1 } },
      "cct must be",
      function(d)
        return d.cct == nil
      end,
    },
    {
      { glow = true },
      "glow is not a field",
      function(d)
        return d.glow == nil
      end,
    },
  }) do
    local d, errors = Caps.device(case[1], FULL)
    T.check(case[2] .. " is an error", hasError(errors, case[2]), errors)
    T.check(case[2] .. " takes its default", case[3](d), d)
  end
  local d = Caps.device(
    { colorWhileOff = "hold", levelSteps = 100, feedback = { shows = "position", waitMs = 0, refresh = true } },
    FULL
  )
  T.eq("good values kept", { d.colorWhileOff, d.levelSteps, d.feedback }, {
    "hold",
    100,
    { shows = "position", waitMs = 0, refresh = true },
  })
end

T.section("a device holds to its profile, over every profile and device capability")
do
  local profileCcts = { false, true, { minK = 2700, maxK = 6500 } }
  local deviceCcts = { false, { minK = 2000, maxK = 5000 }, { minK = 3000, maxK = 4000 } }
  local held, quiet = true, true
  for _, pd in ipairs({ false, true }) do
    for _, pc in ipairs({ false, true }) do
      for _, pcct in ipairs(profileCcts) do
        local profile = profileOf({ dims = pd, color = pc, cct = pcct })
        for _, dd in ipairs({ false, true }) do
          for _, dc in ipairs({ false, true }) do
            for _, dcct in ipairs(deviceCcts) do
              local given = { dims = dd, color = dc, cct = dcct or nil }
              local d, errors = Caps.device(given, profile)
              local within = (not dd or pd) and (not dc or pc) and (not dcct or pcct ~= false)
              if type(pcct) == "table" and dcct and (dcct.minK < pcct.minK or dcct.maxK > pcct.maxK) then
                within = false
              end
              held = held
                and (not d.dims or pd)
                and (not d.color or pc)
                and (d.cct == nil or pcct ~= false)
                and (type(pcct) ~= "table" or (d.cct and d.cct.minK >= pcct.minK and d.cct.maxK <= pcct.maxK))
              if within then
                quiet = quiet and #errors == 0
              else
                held = held and #errors > 0
              end
            end
          end
        end
      end
    end
  end
  T.check("nothing beyond the profile is kept, and each drop is an error", held)
  T.check("a device within its profile logs nothing", quiet)
  local d = Caps.device({ color = true }, profileOf({ color = true, cct = { minK = 2700, maxK = 6500 } }))
  T.eq("a range profile gives its range to a device that names none", d.cct, { minK = 2700, maxK = 6500 })
  local wide, errors =
    Caps.device({ cct = { minK = 2000, maxK = 5000 } }, profileOf({ cct = { minK = 2700, maxK = 6500 } }))
  T.eq("a wider range is held to the profile's", wide.cct, { minK = 2700, maxK = 5000 })
  T.check("with an error", hasError(errors, "beyond the profile's range"), errors)
end

T.section("a known profile: the device's capabilities are the profile's")
do
  local known = profileOf({ known = true, color = true, cct = { minK = 2700, maxK = 6500 } })
  local d, errors = Caps.device({}, known)
  T.eq("none given: the profile's", { d.dims, d.color, d.cct }, { false, true, { minK = 2700, maxK = 6500 } })
  T.eq("and no error", errors, {})
  local d2, errors2 = Caps.device({ dims = true, color = false, cct = { minK = 3000, maxK = 4000 } }, known)
  T.eq(
    "others given: still the profile's",
    { d2.dims, d2.color, d2.cct },
    { false, true, { minK = 2700, maxK = 6500 } }
  )
  T.check("with an error for each", #errors2 == 3, errors2)
end

T.section("same")
do
  local a = Caps.device({ dims = true }, FULL)
  local b = Caps.device({ dims = true }, FULL)
  T.eq("two checks of one device", Caps.same(a, b), true)
  b.fade.maxMs = 1000
  T.eq("a fade field apart", Caps.same(a, b), false)
  T.eq("nil and nil", Caps.same(nil, nil), true)
  T.eq("a device and nil", Caps.same(a, nil), false)
  T.eq("an extra field", Caps.same({ x = 1 }, { x = 1, y = 2 }), false)
end

T.section("static: one row per key, and each flag where the profile puts it")
do
  local seen, unique = {}, true
  for _, row in ipairs(Caps.static(FULL)) do
    unique = unique and not seen[row.key] and type(row.value) == "string"
    seen[row.key] = true
  end
  T.check("unique keys, string values", unique)
  local names =
    { "dims", "color", "cct", "known", "fades", "defaultOn", "scenes", "onModes", "flash", "extras", "links" }
  local ok = true
  for mask = 0, 2 ^ #names - 1 do
    local fields = {}
    for i, name in ipairs(names) do
      fields[name] = math.floor(mask / 2 ^ (i - 1)) % 2 == 1
    end
    if fields.known and fields.cct then
      fields.cct = { minK = 2700, maxK = 6000 }
    end
    fields.links = fields.links and { top = 300, toggle = 301, bottom = 302 } or nil
    local p = profileOf(fields)
    local r = rows(p)
    local dims, color, cct = p.dims, p.color, p.cct ~= nil
    local function is(key, want)
      ok = ok and r[key] == (want and "True" or "False")
    end
    is("dimmer", dims)
    is("set_level", dims)
    is("supports_target", dims)
    is("ramp_level", dims and p.fades)
    is("on_off", true)
    is("supports_default_on", p.defaultOn)
    is("supports_brightness_stop", dims and p.fades)
    is("click_rates", dims and p.fades)
    is("hold_rates", dims and p.fades)
    is("supports_color", p.known and color)
    is("supports_color_correlated_temperature", p.known and cct)
    is("supports_color_stop", (dims or color or cct) and p.fades)
    is("has_button_events", p.links ~= nil)
    is("has_leds", p.links ~= nil)
    is("advanced_scene_support", p.scenes)
    is("brightness_on_mode_preset", p.onModes and dims)
    is("color_on_mode_fade", p.onModes and (color or cct))
    is("has_extras", p.extras)
    is("disable_flash", not p.flash)
    ok = ok and r.color_rate_behavior == (p.fades and "1" or "0")
    ok = ok and r.color_correlated_temperature_min == (p.known and cct and "2700" or "2000")
    ok = ok and r.color_correlated_temperature_max == (p.known and cct and "6000" or "6500")
  end
  T.check("every flag over all 2048 profiles", ok)
end

T.section("dynamic: by the device's fade kind")
do
  local profile = profileOf({ dims = true, color = true, cct = true, fades = true, extras = true })
  for _, case in ipairs({
    {
      "a device fade",
      { kind = "device", maxMs = 86400000 },
      { stop = true, behavior = 1, fixed = false, rate = 0, min = 0, max = 86400000 },
    },
    { "a walk", { kind = "walk" }, { stop = true, behavior = 1, fixed = false, rate = 0, min = 0, max = 65535 } },
    {
      "an own fade at once",
      { kind = "own", own = { onMs = 0, offMs = 0, changeMs = 0 } },
      { stop = false, behavior = 0, fixed = false, rate = 0, min = 0, max = 65535 },
    },
    {
      "an own fade with a change length",
      { kind = "own", own = { onMs = 0, offMs = 0, changeMs = 1500 } },
      { stop = false, behavior = 0, fixed = true, rate = 1500, min = 1500, max = 1500 },
    },
  }) do
    local d = Caps.device({ dims = true, color = true, cct = { minK = 2200, maxK = 6000 }, fade = case[2] }, profile)
    local c = Caps.dynamic(d, profile)
    local want = case[3]
    T.eq(case[1], {
      c.supports_brightness_stop,
      c.supports_color_stop,
      c.color_rate_behavior,
      c.has_fixed_ramp_rate,
      c.fixed_ramp_rate,
      c.brightness_rate_min,
      c.brightness_rate_max,
    }, { want.stop, want.stop, want.behavior, want.fixed, want.rate, want.min, want.max })
    T.eq(case[1] .. ": the color rate's bound", c.color_rate_max, case[2].maxMs or 65535)
  end
  local d = Caps.device({ dims = true, color = true, cct = { minK = 2200, maxK = 6000 } }, profile)
  local c = Caps.dynamic(d, profile)
  T.eq("capabilities", {
    c.dimmer,
    c.set_level,
    c.supports_target,
    c.ramp_level,
    c.supports_color,
    c.supports_color_correlated_temperature,
    c.color_correlated_temperature_min,
    c.color_correlated_temperature_max,
    c.has_extras,
    c.cold_start,
    c.color_trace_tolerance,
    c.color_rate_min,
  }, { true, true, true, true, true, true, 2200, 6000, true, false, 2, 0 })
  local onOff = Caps.dynamic(Caps.device({}, profile), profile)
  T.eq("an on/off light stops nothing and has no range", {
    onOff.dimmer,
    onOff.supports_brightness_stop,
    onOff.supports_color_stop,
    onOff.color_correlated_temperature_min,
  }, { false, false, false, nil })
  local colorOnly = Caps.dynamic(Caps.device({ color = true }, profile), profile)
  T.eq("a color light that does not dim still has a color stop", colorOnly.supports_color_stop, true)
end

T.section("a profile without fades offers no Ramp, in driver.xml and in what the proxy is told")
do
  local profile = assert(Caps.profile({ api = 1, dims = true, color = true }))
  local ramp
  for _, row in ipairs(Caps.static(profile)) do
    if row.key == "ramp_level" then
      ramp = row.value
    end
  end
  T.eq("driver.xml: ramp_level False", ramp, "False")
  local device = assert(Caps.device({ dims = true, color = true }, profile))
  T.eq("dynamic: ramp_level false", Caps.dynamic(device, profile).ramp_level, false)
  local fading = assert(Caps.profile({ api = 1, dims = true, fades = true }))
  local d = assert(Caps.device({ dims = true, color = false }, fading))
  T.eq("a profile with fades: ramp_level true", Caps.dynamic(d, fading).ramp_level, true)
end

T.finish()
