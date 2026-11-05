-- Tests for lib/ui.lua and the page's src/lib/ui-join.js: a message reaches the page whole, each
-- part stays near 4 KB on the socket, and a burst of coalesced values makes one push.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_ui.lua

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.lib") -- JSON

local ui = require("lib.ui")

local libDir = package.searchpath("lib.ui", package.path):match("^(.*)/ui%.lua$")
local root = libDir:gsub("/src/lib$", "")

local function readFile(path)
  local file = assert(io.open(path, "r"))
  local body = file:read("*a")
  file:close()
  return body
end

--- The pushes since the last call, as the page's socket handler sees them.
local function pushes()
  local sent = {}
  for _, push in ipairs(ShimUIPushes()) do
    local only = next(push.params)
    T.check(
      "a part is one string param",
      only == "data" and next(push.params, only) == nil and type(push.params.data) == "string"
    )
    sent[#sent + 1] = { command = push.command, data = push.params.data }
  end
  ShimResetUIPushes()
  return sent
end

--- A part's size on the socket: the broker's JSON around it, which escapes it once more.
local function socketBytes(push)
  return #JSON:encode({
    data = {
      devicecommand = {
        command = push.command,
        params = { param = { name = "data", value = { static = push.data } } },
      },
    },
  })
end

local function hasNode()
  local pipe = io.popen("command -v node 2>/dev/null")
  local found = pipe:read("*a") ~= ""
  pipe:close()
  return found
end

--- Run the page's join under node over these pushes and return the messages it delivers.
local function pageReceives(sent)
  local path = os.tmpname()
  local file = assert(io.open(path, "w"))
  file:write(JSON:encode(sent))
  file:close()
  local script = [[
    const fs = require("fs"), vm = require("vm");
    const page = vm.createContext({});
    vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), page);
    const delivered = [];
    for (const push of JSON.parse(fs.readFileSync(process.argv[2], "utf8"))) {
      const message = page.uiJoin(push.command, push.data);
      if (message !== null) delivered.push(message);
    }
    process.stdout.write(JSON.stringify(delivered));
  ]]
  local pipe = io.popen(string.format("node -e '%s' '%s/ui-join.js' '%s'", script, libDir, path))
  local out = pipe:read("*a")
  pipe:close()
  os.remove(path)
  return JSON:decode(out)
end

--- A message with what makes splitting hard: quotes and backslashes the socket escapes, UTF-8
--- characters of every length, and runs of spaces a part could end on.
local function hardMessage()
  local rows = {}
  for i = 1, 400 do
    rows[i] = {
      name = 'Row "' .. i .. '" \\ caf\195\169 \230\151\165\230\156\172 \240\159\146\161',
      note = string.rep(" ", i % 7) .. "<a&b> ]]> 50.0 true" .. string.rep(" ", i % 11),
    }
  end
  return { rows = rows }
end

T.section("send: a small message")

ui:send("STATUS_DATA", { ok = true, count = 3 })
local small = pushes()
T.eq("goes in one part", #small, 1)
T.check("under a header of id, part and parts", small[1].data:match("^%d+:1:1:{") ~= nil, small[1].data)
T.eq("under its own command", small[1].command, "STATUS_DATA")

ui:send("STATUS_DATA", '{"already":"encoded"}')
T.check("a string goes as it is", pushes()[1].data:match(':{"already":"encoded"}$') ~= nil)

T.section("send: a large message")

ui:send("CONFIG_DATA", hardMessage())
local large = pushes()
T.check("goes in several parts", #large > 1, #large)
local biggest = 0
for _, push in ipairs(large) do
  biggest = math.max(biggest, socketBytes(push))
end
T.check("each part is at or under 4 KB on the socket", biggest <= 4096, biggest)
T.check("each part uses most of that", biggest > 3700, biggest)

T.section("send: a message of nothing but escaped bytes")

ui:send("CONFIG_DATA", string.rep('"\\', 4000))
local escaped = pushes()
for _, push in ipairs(escaped) do
  biggest = math.max(biggest, socketBytes(push))
end
T.check("still fits, in more parts", #escaped >= 4 and biggest <= 4096, biggest)

T.section("send: a part stops between UTF-8 characters")

ui:send("CONFIG_DATA", string.rep("\230\151\165", 5000))
local wide = pushes()
T.check("takes several parts", #wide > 1, #wide)
for _, push in ipairs(wide) do
  local body = push.data:match("^%d+:%d+:%d+:(.*)$")
  T.eq("a part holds whole characters", #body % 3, 0)
end

T.section("send: the id changes per message")

ui:send("A", {})
ui:send("A", {})
local twice = pushes()
T.check("two messages have two ids", twice[1].data:match("^%d+") ~= twice[2].data:match("^%d+"))

T.section("coalesce")

local delays = {}
local realSetTimer = C4.SetTimer
function C4:SetTimer(ms, ...)
  delays[#delays + 1] = ms
  return realSetTimer(self, ms, ...)
end

ui:coalesce("STATE", { n = 1 })
ui:coalesce("STATE", { n = 2 })
ui:coalesce("STATE", { n = 3 })
T.eq("nothing goes out before the timer", #pushes(), 0)
T.eq("a burst arms one timer of a second", delays, { 1000 })
ShimFireTimers()
local burst = pushes()
T.eq("a burst makes one push", #burst, 1)
T.check("the last value wins", burst[1].data:match('{"n":3}$') ~= nil, burst[1].data)

ui:coalesce("STATE", { n = 4 })
T.eq("a value after the timer arms it again", #delays, 2)
ShimFireTimers()
T.eq("and goes out", #pushes(), 1)

local builds = 0
for _ = 1, 3 do
  ui:coalesce("STATE", function()
    builds = builds + 1
    return { built = builds }
  end)
end
T.eq("a function is not called yet", builds, 0)
ShimFireTimers()
local built = pushes()
T.eq("a burst of functions builds once", builds, 1)
T.check("and sends what it built", built[1].data:match('{"built":1}$') ~= nil, built[1].data)

ui:coalesce("STATE", function() end)
ui:coalesce("OTHER", { after = true })
ShimFireTimers()
local afterNil = pushes()
T.eq("a function returning nil sends nothing", #afterNil, 1)
T.check("and costs the value behind it nothing", afterNil[1].command == "OTHER", afterNil[1].command)

ui:coalesce("RESULT", { name = "a" }, "RESULT:a")
ui:coalesce("RESULT", { name = "b" }, "RESULT:b")
ui:coalesce("RESULT", { name = "a2" }, "RESULT:a")
ShimFireTimers()
local keyed = pushes()
T.eq("each key keeps its own last value", #keyed, 2)
T.check("in the order they first came", keyed[1].data:match('"a2"') ~= nil, keyed[1].data)
T.check("under the command", keyed[2].command == "RESULT" and keyed[2].data:match('"b"') ~= nil, keyed[2].data)

ui:coalesce("STATE", { old = true })
ui:send("STATE", { new = true })
ShimFireTimers()
local direct = pushes()
T.eq("a direct send replaces a value still waiting", #direct, 1)
T.check("the newer one", direct[1].data:match('"new"') ~= nil, direct[1].data)

T.section("UPLOAD_CHUNK")

T.eq("is a multiple of 4, so each chunk decodes alone", ui.UPLOAD_CHUNK % 4, 0)
local command = JSON:encode({
  command = "_PUT_IMAGE",
  tParams = { DATA = C4:Base64Encode(JSON:encode({ look = 1, index = 1, data = string.rep("A", ui.UPLOAD_CHUNK) })) },
  async = false,
})
T.check("a chunk's command is at or under 4 KB", #command <= 4096, #command)

T.section("the page's join")

if hasNode() then
  ui:send("CONFIG_DATA", hardMessage())
  local message = pageReceives(pushes())
  T.eq("a large message arrives once", #message, 1)
  T.eq("and whole", message[1], hardMessage())

  ui:send("A", { which = "a" })
  local a = pushes()
  ui:send("LONG", hardMessage())
  local long = pushes()
  table.insert(long, 2, a[1])
  local interleaved = pageReceives(long)
  T.eq("a message between two parts of another", interleaved[1], { which = "a" })
  T.eq("leaves the other whole", interleaved[2], hardMessage())

  T.unload("^lib%.ui$")
  require("lib.ui"):send("LONG", hardMessage())
  local held = { pushes()[1] }
  T.unload("^lib%.ui$")
  require("lib.ui"):send("LONG", hardMessage())
  for _, push in ipairs(pushes()) do
    held[#held + 1] = push
  end
  T.eq("a driver's reload under an open page leaves its next message whole", pageReceives(held), { hardMessage() })

  ui:send("LONG", hardMessage())
  local lost = pushes()
  table.remove(lost, 3)
  ui:send("LONG", { next = true })
  for _, push in ipairs(pushes()) do
    lost[#lost + 1] = push
  end
  T.eq("a lost part costs only its own message", pageReceives(lost), { { next = true } })

  ui:send("LONG", hardMessage())
  local started = pushes()
  ui:send("LONG", hardMessage())
  local missedStart = pushes()
  table.remove(missedStart, 1)
  local joining = { started[1] }
  for _, push in ipairs(missedStart) do
    joining[#joining + 1] = push
  end
  ui:send("LONG", { next = true })
  joining[#joining + 1] = pushes()[1]
  T.eq(
    "the rest of a message whose start was missed costs only that message",
    pageReceives(joining),
    { { next = true } }
  )

  T.eq("a push with no frame delivers nothing", pageReceives({ { command = "X" } }), {})
else
  print("SKIP: node not installed; the page's join was not run")
end

T.section("a page's pasted join is src/lib/ui-join.js")

local join = readFile(libDir .. "/ui-join.js")
local pages = io.popen(string.format("ls '%s'/drivers/*/www/html/*.html 2>/dev/null", root))
for path in pages:lines() do
  local page = readFile(path)
  if page:find("function uiJoin(", 1, true) then
    T.check(path, page:find(join, 1, true) ~= nil, "paste src/lib/ui-join.js into it again")
  end
end
pages:close()

T.finish()
