-- make_short_link.lua's deltas against upstream MAKE_SHORT_LINK 8: a transport error,
-- a body that did not decode or an apiKey that is not a string hands the callback the
-- long link, and a callback that raises is reported rather than dropped. Also the
-- duration it passes to the link service.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_oauth_short_link.lua

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.make_short_link")

local LONG = "https://auth.example.invalid/authorize?client_id=x&state=y"

--- Answer the next urlPost with (strError, responseCode, data) and record the request.
local function answer(strError, responseCode, data)
  local sent = {}
  urlPost = function(url, body, headers, callback, context)
    sent.url, sent.body, sent.headers = url, body, headers
    callback(strError, responseCode, {}, data, context, url)
  end
  return sent
end

--- Shorten LONG and return what the callback received.
local function shorten()
  local got = {}
  MakeShortLink(LONG, function(link, expiresAt)
    got.link, got.expiresAt, got.calls = link, expiresAt, (got.calls or 0) + 1
  end, "link-key")
  return got
end

T.section("a 200 with the service's body gives the short link")
local sent = answer(nil, 200, { url = "https://link.ctrl4.co/abc", expiresAt = 1700000300 })
local got = shorten()
T.eq("the short link", got.link, "https://link.ctrl4.co/abc")
T.eq("its expiry", got.expiresAt, 1700000300)
T.eq("the long link is posted, with no duration", sent.body, { url = LONG })
T.eq("with the API key as Authorization", sent.headers, { Authorization = "link-key" })

T.section("a duration is posted with the link")
sent = answer(nil, 200, { url = "s" })
MakeShortLink(LONG, function() end, "link-key", 600)
T.eq("in the body", sent.body, { url = LONG, duration = 600 })
sent = answer(nil, 200, { url = "s" })
MakeShortLink(LONG, function() end, "link-key", "600")
T.eq("one that is not a number is left out", sent.body, { url = LONG })

T.section("the service follows IN_PRODUCTION")
IN_PRODUCTION = nil
sent = answer(nil, 200, { url = "s" })
shorten()
T.eq("development without it", sent.url, "https://link.control4driversdev.com/new")
IN_PRODUCTION = true
sent = answer(nil, 200, { url = "s" })
shorten()
T.eq("production with it", sent.url, "https://link.ctrl4.co/new")
IN_PRODUCTION = nil

T.section("delta 1: a transport error gives the long link")
answer("Couldn't resolve host name", nil, nil)
got = shorten()
T.eq("the callback runs once", got.calls, 1)
T.eq("with the long link", got.link, LONG)

T.section("delta 2: a body that is not the service's gives the long link")
for label, data in pairs({
  ["a wrapped body"] = { "<html>502 Bad Gateway</html>" },
  ["a string"] = "<html>502</html>",
  ["no url field"] = { error = "nope" },
}) do
  answer(nil, 200, data)
  T.eq(label, shorten().link, LONG)
end
answer(nil, 401, { error = "unauthorized" })
T.eq("a 401 keeps the long link", shorten().link, LONG)

T.section("delta 4: an apiKey that is not a string gives the long link")
sent = answer(nil, 200, { url = "s" })
sent.url = nil
got = {}
MakeShortLink(LONG, function(link)
  got.link, got.calls = link, (got.calls or 0) + 1
end, nil)
T.eq("nothing is posted", sent.url, nil)
T.eq("the callback runs once", got.calls, 1)
T.eq("with the long link", got.link, LONG)

T.section("a link that is not a string is refused")
sent = answer(nil, 200, { url = "s" })
got = {}
MakeShortLink(nil, function(link)
  got.link = link
end, "link-key")
T.eq("nothing is posted", sent.url, nil)
T.eq("and no link is given", got.link, nil)

T.section("delta 3: a callback that raises is reported, not dropped")
answer(nil, 200, { url = "https://link.ctrl4.co/abc" })
local ok, _, out = T.capture(function()
  MakeShortLink(LONG, function()
    error("callback broke")
  end, "link-key")
end)
T.check("MakeShortLink does not raise", ok)
T.contains("the error is printed", out, "callback broke")
T.contains("with a traceback", out, "stack traceback")

T.finish()
