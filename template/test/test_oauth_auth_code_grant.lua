-- auth_code_grant.lua against a scripted redirect server and token endpoint: the
-- golden path from state to stored refresh token, the short link getting the
-- redirect duration, and the deltas against upstream AUTH_CODE_GRANT 37
-- (TOKEN_HEADERS guard, bodies that are not tables, retry on a token response that
-- is neither 200 nor 4xx, MakeStateFailed, reported callback errors).
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_oauth_auth_code_grant.lua

local T = require("testlib")

require("c4_shim")
local OAuth = require("drivers-common-public.module.auth_code_grant")

local REDIRECT = "https://apps.control4driversdev.com/"

-- Every request the grant makes, answered by `respond`, which tests replace.
local requests = {}
local respond = function(req)
  return nil, 204, nil
end
urlDo = function(method, url, data, headers, callback, context)
  local req = { method = method, url = url, data = data, headers = headers }
  table.insert(requests, req)
  local strError, code, body = respond(req)
  callback(strError, code, {}, body, context, url)
end

-- Timers are recorded by name rather than run, so a test fires the one it means.
local timers = {}
SetTimer = function(name, delay, callback, repeating)
  timers[name] = { delay = delay, callback = callback, repeating = repeating }
end
CancelTimer = function(name)
  timers[name] = nil
end

local function reset()
  requests, timers = {}, {}
end

--- A grant with handlers that record every event.
local function newGrant(extra)
  local params = {
    NAME = "Test",
    AUTHORIZATION = "c4-oauth-key",
    REDIRECT_URI = REDIRECT,
    AUTH_ENDPOINT_URI = "https://id.example.invalid/connect/authorize",
    TOKEN_ENDPOINT_URI = "https://id.example.invalid/connect/token",
    REDIRECT_DURATION = 300,
    API_CLIENT_ID = "client-" .. tostring(math.random(1e9)),
    API_SECRET = "secret",
    SCOPES = { "openapi", "offline_access" },
  }
  for k, v in pairs(extra or {}) do
    params[k] = v
  end
  local grant = OAuth:new(params)
  local events = {}
  for _, name in ipairs({
    "LinkCodeReceived",
    "LinkCodeConfirmed",
    "LinkCodeDenied",
    "MakeStateFailed",
    "AccessTokenGranted",
    "AccessTokenDenied",
  }) do
    grant.notifyHandler[name] = function(_, ...)
      table.insert(events, { name = name, args = { ... } })
    end
  end
  return grant, events
end

local function lastEvent(events, name)
  for i = #events, 1, -1 do
    if events[i].name == name then
      return events[i]
    end
  end
end

T.section("golden path: state, link, code, tokens, stored refresh token")
reset()
local links = {}
local grant, events = newGrant({
  LINK_CHANGE_CALLBACK = function(link)
    table.insert(links, link)
  end,
})
respond = function(req)
  if req.url:find("state$") then
    return nil, 200, { nonce = "n1", expiresAt = os.time() + 300 }
  end
end
grant:MakeState()
T.eq("the state is posted to the redirect server", requests[1].url, REDIRECT .. "state")
T.eq("with the C4 OAuth API key", requests[1].headers.Authorization, "c4-oauth-key")
T.truthy("CheckState polls", timers[grant.timerPrefix .. "CheckState"])
T.truthy("the link expires", timers[grant.timerPrefix .. "GetCodeStatusExpired"])
T.contains("the link names the client", links[1], "client_id=" .. grant.API_CLIENT_ID)
T.contains("and the redirect server's callback", links[1], "redirect_uri=")

respond = function(req)
  if req.url:find("/state%?") then
    return nil, 200, { code = "the-code" }
  end
  return nil, 200, { access_token = "at1", refresh_token = "rt1", expires_in = 3600 }
end
timers[grant.timerPrefix .. "CheckState"].callback()
T.eq("the code is confirmed", lastEvent(events, "LinkCodeConfirmed").args[1], "the-code")
local tokenReq = requests[#requests]
T.eq("then exchanged at the token endpoint", tokenReq.url, "https://id.example.invalid/connect/token")
T.contains("as an authorization_code grant", tokenReq.data, "grant_type=authorization_code")
T.eq("polling stops", timers[grant.timerPrefix .. "CheckState"], nil)
T.eq("the access token is granted", lastEvent(events, "AccessTokenGranted").args[1], "at1")
T.truthy("a refresh is scheduled", timers[grant.timerPrefix .. "RefreshToken"])

reset()
local again = OAuth:new({
  NAME = "Again",
  API_CLIENT_ID = grant.API_CLIENT_ID,
  API_SECRET = "secret",
  TOKEN_ENDPOINT_URI = "https://id.example.invalid/connect/token",
})
T.truthy("a new grant for the client finds the stored token", timers[again.timerPrefix .. "InitWithToken"])

T.section("a short link is made for the redirect duration")
reset()
local realMakeShortLink = MakeShortLink
local shortened
MakeShortLink = function(link, callback, apiKey, duration)
  shortened = { link = link, apiKey = apiKey, duration = duration }
  callback("https://link.example.invalid/abc")
end
local shortLinks = {}
local short = newGrant({
  SHORT_LINK_AUTHORIZATION = "link-key",
  REDIRECT_DURATION = 600,
  LINK_CHANGE_CALLBACK = function(link)
    table.insert(shortLinks, link)
  end,
})
respond = function(req)
  if req.url:find("state$") then
    return nil, 200, { nonce = "n1", expiresAt = os.time() + 600 }
  end
end
short:MakeState()
MakeShortLink = realMakeShortLink
T.truthy("the link is shortened", shortened)
T.eq("with the link API key", shortened and shortened.apiKey, "link-key")
T.eq("for the redirect duration", shortened and shortened.duration, 600)
T.contains("of the authorize link", shortened and shortened.link, "client_id=" .. short.API_CLIENT_ID)
T.eq("and the short link is shown", shortLinks[1], "https://link.example.invalid/abc")

T.section("delta 2: TOKEN_HEADERS is merged only when it is a table")
reset()
respond = function()
  return nil, 200, { access_token = "a" }
end
grant = newGrant({ TOKEN_HEADERS = "not a table" })
local ok = pcall(grant.GetUserToken, grant, "c")
T.check("a string TOKEN_HEADERS does not raise", ok)
grant = newGrant({ TOKEN_HEADERS = { ["X-Extra"] = "1", ["Content-Type"] = "text/plain" } })
grant:GetUserToken("c")
T.eq("a table adds its headers", requests[#requests].headers["X-Extra"], "1")
T.eq(
  "without replacing one already set",
  requests[#requests].headers["Content-Type"],
  "application/x-www-form-urlencoded"
)

T.section("delta 3: a body that is not a table is read as empty")
reset()
grant, events = newGrant()
respond = function()
  return nil, 400, { "<html>Bad Request</html>" }
end
grant:GetUserToken("c")
T.truthy("a 400 with a wrapped body is AccessTokenDenied", lastEvent(events, "AccessTokenDenied"))
respond = function()
  return nil, 403, "<html>Forbidden</html>"
end
grant:CheckState("s", nil, "n")
T.truthy("a 403 with a string body is LinkCodeDenied", lastEvent(events, "LinkCodeDenied"))

T.section("delta 4: a token response neither 200 nor 4xx retries the refresh")
for _, code in ipairs({ 500, 503, 302 }) do
  reset()
  grant = newGrant()
  respond = function()
    return nil, code, {}
  end
  grant:RefreshToken(nil, "rt")
  local retry = timers[grant.timerPrefix .. "RefreshToken"]
  T.truthy("HTTP " .. code .. " schedules a retry", retry)
  T.eq("in 30 seconds for " .. code, retry and retry.delay, 30 * ONE_SECOND)
  T.eq("and keeps the refresh token for " .. code, grant.REFRESH_TOKEN, "rt")
end

T.section("delta 5: a failed state request notifies MakeStateFailed")
reset()
links = {}
grant, events = newGrant({
  LINK_CHANGE_CALLBACK = function(link)
    table.insert(links, link)
  end,
})
respond = function()
  return nil, 401, { message = "Unauthorized" }
end
local _, _, out = T.capture(function()
  grant:MakeState()
end)
T.eq("with the status", lastEvent(events, "MakeStateFailed").args[1], 401)
T.contains("and prints why", out, "HTTP 401")
T.eq("no link is offered", #links, 0)
T.eq("and nothing polls", timers[grant.timerPrefix .. "CheckState"], nil)
respond = function()
  return "Couldn't connect", nil, nil
end
grant:MakeState()
T.eq("a transport error too", lastEvent(events, "MakeStateFailed").args[2], "Couldn't connect")

T.section("delta 7: a token response with no refresh token still grants")
reset()
grant, events = newGrant()
respond = function()
  return nil, 200, { access_token = "only-access", expires_in = 60 }
end
ok, _, out = T.capture(function()
  grant:GetUserToken("c")
end)
T.excludes("nothing raises inside the response", out, "Lua error")
T.eq("the access token is granted", lastEvent(events, "AccessTokenGranted").args[1], "only-access")
T.eq("with no refresh scheduled", timers[grant.timerPrefix .. "RefreshToken"], nil)

T.section("delta 6: callback errors are reported with a traceback")
reset()
grant = newGrant()
grant.notifyHandler.AccessTokenGranted = function()
  error("handler broke")
end
respond = function()
  return nil, 200, { access_token = "a", refresh_token = "r", expires_in = 60 }
end
ok, _, out = T.capture(function()
  grant:GetUserToken("c")
end)
T.check("the grant does not raise", ok)
T.contains("the handler's error is printed", out, "handler broke")
T.contains("with a traceback", out, "stack traceback")

reset()
grant = newGrant()
grant.GetTokenResponse = function()
  error("response handler broke")
end
ok, _, out = T.capture(function()
  grant:GetUserToken("c")
end)
T.check("a URL callback that raises does not escape", ok)
T.contains("and is printed, where upstream dropped it", out, "response handler broke")

T.finish()
