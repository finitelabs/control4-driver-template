-- Copyright 2026 Snap One, LLC. All rights reserved.
--
-- LOCAL FORK of Snap One's drivers-common-public auth_code_grant module, upstream
-- AUTH_CODE_GRANT 36. Re-vendoring from upstream silently drops everything listed here,
-- in every repo the template renders. Keep this list current.
--
-- Deltas against upstream AUTH_CODE_GRANT 36:
--   1. Metrics are removed, with the require of module/metrics.
--   2. TOKEN_HEADERS is merged only when it is a table. Upstream tested
--      type (self.TOKEN_HEADERS == 'table'), which is always a string, so a non-table
--      value reached pairs and threw.
--   3. A response body that is not a decoded table (url.lua wraps a body it cannot
--      decode as { body }) is read as an empty table, where upstream indexed it.
--   4. A token response that is neither 200 nor 4xx (a 5xx, a redirect) retries the
--      refresh in 30 seconds, as a transport error does. Upstream did nothing, so no
--      refresh was ever scheduled again and the access token lapsed.
--   5. A state request that fails, by transport error or by any status but 200 (a
--      wrong C4 OAuth API key answers 401), prints why and notifies MakeStateFailed.
--      Upstream returned silently and no link ever appeared.
--   6. URL callbacks, notify handlers and LINK_CHANGE_CALLBACK run through xpcall
--      with debug.traceback, and a failure prints the traceback. Upstream's URL
--      callback pcall dropped the error.
--   7. A token response with no refresh token, and none held from before, stores
--      nothing. Upstream passed nil to SaltedEncrypt, which threw before
--      AccessTokenGranted, so a provider that issues no refresh token never connected.
--   8. The class and its public methods carry LuaDoc.
--
-- test/test_oauth_auth_code_grant.lua covers 2 to 7.

AUTH_CODE_GRANT_VER = 36

require("drivers-common-public.global.lib")
require("drivers-common-public.global.url")
require("drivers-common-public.global.timer")

pcall(require, "drivers-common-public.global.make_short_link")

--- An OAuth 2.0 authorization code grant through Control4's OAuth redirect service.
--- notifyHandler's functions, all optional, are called with (contextInfo, ...):
--- LinkCodeReceived (link), LinkCodeWaiting, LinkCodeConfirmed (code), LinkCodeError,
--- LinkCodeDenied (error, description, uri), LinkCodeExpired, ActivationTimeOut,
--- MakeStateFailed (responseCode, strError), AccessTokenGranted (accessToken,
--- refreshToken), AccessTokenDenied (error, description, uri) and RefreshTokenDeleted
--- (existed).
--- @class OAuthAuthCodeGrant
--- @field notifyHandler table<string, function> Event callbacks, keyed by event name.
--- @field ACCESS_TOKEN string|nil The current access token.
--- @field REFRESH_TOKEN string|nil The current refresh token.
--- @field API_CLIENT_ID string The OAuth client ID.
--- @field timerPrefix string Prefixes the name of every timer this grant sets.
local oauthObject = {}

--- Run fn through xpcall and print a failure with its traceback.
--- @param label string What failed, for the printed line.
--- @param fn function The function to run.
--- @return boolean success
--- @return any result
local function guarded(label, fn, ...)
  local args = { n = select("#", ...), ... }
  local success, ret = xpcall(function()
    return fn(unpack(args, 1, args.n))
  end, debug.traceback)
  if not success then
    print(label .. " Lua error:", ret)
  end
  return success, ret
end

--- A response body as a table, or an empty one when it did not decode to a table.
--- @param data any
--- @return table
local function bodyTable(data)
  if type(data) == "table" then
    return data
  end
  return {}
end

--- Merge TOKEN_HEADERS into headers without replacing a header already set.
--- @param headers table
--- @param extra any
local function mergeTokenHeaders(headers, extra)
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      if not headers[k] then
        headers[k] = v
      end
    end
  end
end

--- Create the grant. tParams carries NAME, AUTHORIZATION (the C4 OAuth API key),
--- SHORT_LINK_AUTHORIZATION (the C4 Link API key), LINK_CHANGE_CALLBACK, REDIRECT_URI
--- (the redirect server's base URL, with a trailing slash), AUTH_ENDPOINT_URI,
--- TOKEN_ENDPOINT_URI, REDIRECT_DURATION, API_CLIENT_ID, API_SECRET, SCOPES,
--- TOKEN_HEADERS, USE_PKCE, USE_BASIC_AUTH_HEADER, MAX_EXPIRES_IN and
--- DEFAULT_EXPIRES_IN. A refresh token stored by an earlier grant with the same client
--- ID on this device is refreshed a second after creation.
--- @param tParams table
--- @param providedRefreshToken string|nil A refresh token to use instead of the stored one.
--- @return OAuthAuthCodeGrant grant
--- @return boolean willGenerateRefreshEvent Whether a refresh is about to run.
function oauthObject:new(tParams, providedRefreshToken)
  local o = {
    NAME = tParams.NAME,
    AUTHORIZATION = tParams.AUTHORIZATION,

    SHORT_LINK_AUTHORIZATION = tParams.SHORT_LINK_AUTHORIZATION,
    LINK_CHANGE_CALLBACK = tParams.LINK_CHANGE_CALLBACK,

    REDIRECT_URI = tParams.REDIRECT_URI,
    AUTH_ENDPOINT_URI = tParams.AUTH_ENDPOINT_URI,
    TOKEN_ENDPOINT_URI = tParams.TOKEN_ENDPOINT_URI,

    REDIRECT_DURATION = tParams.REDIRECT_DURATION,

    API_CLIENT_ID = tParams.API_CLIENT_ID,
    API_SECRET = tParams.API_SECRET,

    SCOPES = tParams.SCOPES,

    TOKEN_HEADERS = tParams.TOKEN_HEADERS,

    USE_PKCE = tParams.USE_PKCE,

    MAX_EXPIRES_IN = tParams.MAX_EXPIRES_IN or 86400, -- one day
    DEFAULT_EXPIRES_IN = tParams.DEFAULT_EXPIRES_IN or 3600, -- one hour

    notifyHandler = {},
  }

  if tParams.USE_BASIC_AUTH_HEADER then
    o.BasicAuthHeader = "Basic " .. C4:Base64Encode(o.API_CLIENT_ID .. ":" .. o.API_SECRET)
  end

  o.timerPrefix = "OAuth_" .. (o.NAME or o.API_CLIENT_ID or GetRandomString(10)) .. "_Timer_"

  setmetatable(o, self)
  self.__index = self

  local initialRefreshToken

  if providedRefreshToken then
    initialRefreshToken = providedRefreshToken
  else
    local persistStoreKey = C4:Hash("SHA256", C4:GetDeviceID() .. o.API_CLIENT_ID, SHA_ENC_DEFAULTS)
    local encryptedToken = PersistGetValue(persistStoreKey)
    if encryptedToken then
      local encryptionKey = C4:GetDeviceID() .. o.API_SECRET .. o.API_CLIENT_ID
      local refreshToken = SaltedDecrypt(encryptionKey, encryptedToken)
      if refreshToken then
        initialRefreshToken = refreshToken
      end
    end
  end

  if initialRefreshToken then
    local _timer = function(timer)
      o:RefreshToken(nil, initialRefreshToken)
    end
    SetTimer(o.timerPrefix .. "InitWithToken", ONE_SECOND, _timer)
  end

  local willGenerateRefreshEvent = (initialRefreshToken ~= nil)

  return o, willGenerateRefreshEvent
end

--- Register a state with the redirect server, then build the authorization link and
--- poll the server for the code it receives.
--- @param contextInfo table|nil Passed back to every notify handler.
--- @param extraParamsForAuthLink table|nil Extra query arguments for the authorization link.
--- @param uriToCompletePage string|nil Where the redirect server sends the browser afterwards.
function oauthObject:MakeState(contextInfo, extraParamsForAuthLink, uriToCompletePage)
  if type(contextInfo) ~= "table" then
    contextInfo = {}
  end

  local state = GetRandomString(50)

  local url = MakeURL(self.REDIRECT_URI .. "state")

  local headers = {
    Authorization = self.AUTHORIZATION,
  }

  local data = {
    duration = self.REDIRECT_DURATION,
    clientId = self.API_CLIENT_ID,
    authEndpointURI = self.AUTH_ENDPOINT_URI,
    state = state,
    redirectURI = uriToCompletePage,
  }

  local context = {
    contextInfo = contextInfo,
    state = state,
    extraParamsForAuthLink = extraParamsForAuthLink,
  }

  self:urlPost(url, data, headers, "MakeStateResponse", context)
end

function oauthObject:MakeStateResponse(strError, responseCode, tHeaders, data, context, url)
  local contextInfo = context.contextInfo

  if strError or responseCode ~= 200 then
    print((self.NAME or "OAuth") .. ": state request failed:", strError or ("HTTP " .. tostring(responseCode)))
    self:notify("MakeStateFailed", contextInfo, responseCode, strError)
    return
  end

  data = bodyTable(data)

  local state = context.state
  local extraParamsForAuthLink = context.extraParamsForAuthLink

  local nonce = data.nonce
  local expiresAt = tonumber(data.expiresAt) or (os.time() + self.REDIRECT_DURATION)

  local timeRemaining = expiresAt - os.time()

  local _timedOut = function(timer)
    CancelTimer(self.timerPrefix .. "CheckState")

    self:setLink("")

    self:notify("ActivationTimeOut", contextInfo)
  end

  SetTimer(self.timerPrefix .. "GetCodeStatusExpired", timeRemaining * ONE_SECOND, _timedOut)

  local _timer = function(timer)
    self:CheckState(state, contextInfo, nonce)
  end
  SetTimer(self.timerPrefix .. "CheckState", 5 * ONE_SECOND, _timer, true)

  self:GetLinkCode(state, contextInfo, extraParamsForAuthLink)
end

function oauthObject:GetLinkCode(state, contextInfo, extraParamsForAuthLink)
  if type(contextInfo) ~= "table" then
    contextInfo = {}
  end

  local scope
  if self.SCOPES then
    if type(self.SCOPES) == "table" then
      scope = table.concat(self.SCOPES, " ")
    elseif type(self.SCOPES) == "string" then
      scope = self.SCOPES
    end
  end

  local args = {
    client_id = self.API_CLIENT_ID,
    response_type = "code",
    redirect_uri = self.REDIRECT_URI .. "callback",
    state = state,
    scope = scope,
  }

  if self.USE_PKCE then
    self.code_verifier = GetRandomString(128)

    local code_challenge = C4:Hash("SHA256", self.code_verifier, SHA_ENC_DEFAULTS)
    local code_challenge_b64 = C4:Base64Encode(code_challenge)
    local code_challenge_b64_url = code_challenge_b64:gsub("%+", "-"):gsub("%/", "_"):gsub("%=", "")

    args.code_challenge = code_challenge_b64_url
    args.code_challenge_method = "S256"
  end

  if extraParamsForAuthLink and type(extraParamsForAuthLink) == "table" then
    for k, v in pairs(extraParamsForAuthLink) do
      args[k] = v
    end
  end

  local link = MakeURL(self.AUTH_ENDPOINT_URI, args)

  if self.SHORT_LINK_AUTHORIZATION and MakeShortLink then
    local _linkCallback = function(shortLink)
      self:setLink(shortLink, contextInfo)
    end
    MakeShortLink(link, _linkCallback, self.SHORT_LINK_AUTHORIZATION)
  else
    self:setLink(link, contextInfo)
  end
end

function oauthObject:CheckState(state, contextInfo, nonce)
  if type(contextInfo) ~= "table" then
    contextInfo = {}
  end

  local url = MakeURL(self.REDIRECT_URI .. "state", { state = state, nonce = nonce })

  self:urlGet(url, nil, "CheckStateResponse", { state = state, contextInfo = contextInfo })
end

function oauthObject:CheckStateResponse(strError, responseCode, tHeaders, data, context, url)
  if strError then
    dbg("Error with CheckState:", strError)
    return
  end

  local contextInfo = context.contextInfo
  data = bodyTable(data)

  if responseCode == 200 and data.code then
    -- state exists and has been authorized

    CancelTimer(self.timerPrefix .. "CheckState")
    CancelTimer(self.timerPrefix .. "GetCodeStatusExpired")

    self:notify("LinkCodeConfirmed", contextInfo, data.code)

    if self.TOKEN_ENDPOINT_URI then
      self:GetUserToken(data.code, contextInfo)
    end
  elseif responseCode == 204 then
    self:notify("LinkCodeWaiting", contextInfo)
  elseif responseCode == 401 then
    -- nonce value incorrect or missing for this state

    CancelTimer(self.timerPrefix .. "CheckState")
    CancelTimer(self.timerPrefix .. "GetCodeStatusExpired")

    self:setLink("")

    self:notify("LinkCodeError", contextInfo)
  elseif responseCode == 403 then
    -- state exists and has been denied authorization by the service

    CancelTimer(self.timerPrefix .. "CheckState")
    CancelTimer(self.timerPrefix .. "GetCodeStatusExpired")

    self:setLink("")

    self:notify("LinkCodeDenied", contextInfo, data.error, data.error_description, data.error_uri)
  elseif responseCode == 404 then
    -- state doesn't exist

    CancelTimer(self.timerPrefix .. "CheckState")
    CancelTimer(self.timerPrefix .. "GetCodeStatusExpired")

    self:setLink("")

    self:notify("LinkCodeExpired", contextInfo)
  end
end

--- Exchange an authorization code for tokens.
--- @param code string The code the redirect server received.
--- @param contextInfo table|nil Passed back to the notify handlers.
function oauthObject:GetUserToken(code, contextInfo)
  if type(contextInfo) ~= "table" then
    contextInfo = {}
  end

  if code then
    local args = {
      client_id = self.API_CLIENT_ID,
      client_secret = self.API_SECRET,
      grant_type = "authorization_code",
      code = code,
      redirect_uri = self.REDIRECT_URI .. "callback",
    }

    if self.USE_PKCE then
      args.code_verifier = self.code_verifier
    end

    local url = self.TOKEN_ENDPOINT_URI

    local data = MakeURL(nil, args)

    local headers = {
      ["Content-Type"] = "application/x-www-form-urlencoded",
      ["Authorization"] = self.BasicAuthHeader,
    }

    mergeTokenHeaders(headers, self.TOKEN_HEADERS)

    local context = {
      contextInfo = contextInfo,
      reason = "authorization_code",
    }

    self:urlPost(url, data, headers, "GetTokenResponse", context)
  end
end

--- Refresh the access token. A refresh already in flight is not repeated.
--- @param contextInfo table|nil Passed back to the notify handlers.
--- @param newRefreshToken string|nil A refresh token to use from now on.
--- @return boolean|nil false when there is no refresh token to use.
function oauthObject:RefreshToken(contextInfo, newRefreshToken)
  if newRefreshToken then
    self.REFRESH_TOKEN = newRefreshToken
  end

  if self.REFRESH_TOKEN == nil then
    return false
  end

  if self.RefreshingToken then
    return
  end

  if type(contextInfo) ~= "table" then
    contextInfo = {}
  end

  local args = {
    refresh_token = self.REFRESH_TOKEN,
    client_id = self.API_CLIENT_ID,
    client_secret = self.API_SECRET,
    grant_type = "refresh_token",
  }

  local url = self.TOKEN_ENDPOINT_URI

  local data = MakeURL(nil, args)

  local headers = {
    ["Content-Type"] = "application/x-www-form-urlencoded",
    ["Authorization"] = self.BasicAuthHeader,
  }

  mergeTokenHeaders(headers, self.TOKEN_HEADERS)

  local _timer = function(timer)
    self.RefreshingToken = false
    self:RefreshToken()
  end
  SetTimer(self.timerPrefix .. "RefreshCollisionAvoidance", 30 * ONE_SECOND, _timer)
  self.RefreshingToken = true

  local context = {
    contextInfo = contextInfo,
    reason = "refresh_token",
  }

  self:urlPost(url, data, headers, "GetTokenResponse", context)
end

function oauthObject:GetTokenResponse(strError, responseCode, tHeaders, data, context, url)
  CancelTimer(self.timerPrefix .. "RefreshCollisionAvoidance")
  self.RefreshingToken = false

  local retryLater = function(reason)
    dbg("Error with GetToken:", reason)
    local _timer = function(timer)
      self:RefreshToken()
    end
    SetTimer(self.timerPrefix .. "RefreshToken", 30 * ONE_SECOND, _timer)
  end

  if strError then
    retryLater(strError)
    return
  end

  local contextInfo = context.contextInfo
  data = bodyTable(data)

  if responseCode == 200 then
    self.ACCESS_TOKEN = data.access_token
    self.REFRESH_TOKEN = data.refresh_token or self.REFRESH_TOKEN

    if self.REFRESH_TOKEN then
      local persistStoreKey = C4:Hash("SHA256", C4:GetDeviceID() .. self.API_CLIENT_ID, SHA_ENC_DEFAULTS)

      local encryptionKey = C4:GetDeviceID() .. self.API_SECRET .. self.API_CLIENT_ID
      local encryptedToken = SaltedEncrypt(encryptionKey, self.REFRESH_TOKEN)

      PersistSetValue(persistStoreKey, encryptedToken)
    end

    self.SCOPE = data.scope or self.SCOPE

    self.EXPIRES_IN = tonumber(data.expires_in) or self.EXPIRES_IN or self.DEFAULT_EXPIRES_IN

    if self.EXPIRES_IN and self.REFRESH_TOKEN then
      local _timer = function(timer)
        self:RefreshToken()
      end
      if self.EXPIRES_IN > self.MAX_EXPIRES_IN then
        self.EXPIRES_IN_ORIGINAL = self.EXPIRES_IN
        self.EXPIRES_IN = self.MAX_EXPIRES_IN
      end

      -- smear out refreshing the token to avoid all tokens across entire system being refreshed at the same time
      local delay = self.EXPIRES_IN * math.random(750, 950)

      SetTimer(self.timerPrefix .. "RefreshToken", delay, _timer)
    end

    print(
      (self.NAME or "OAuth")
        .. ": Access Token received, accessToken:"
        .. tostring(self.ACCESS_TOKEN ~= nil)
        .. ", refreshToken:"
        .. tostring(self.REFRESH_TOKEN ~= nil)
    )

    self:setLink("")

    self:notify("AccessTokenGranted", contextInfo, self.ACCESS_TOKEN, self.REFRESH_TOKEN)
  elseif type(responseCode) == "number" and responseCode >= 400 and responseCode < 500 then
    self.ACCESS_TOKEN = nil
    self.REFRESH_TOKEN = nil

    local persistStoreKey = C4:Hash("SHA256", C4:GetDeviceID() .. self.API_CLIENT_ID, SHA_ENC_DEFAULTS)

    PersistDeleteValue(persistStoreKey)

    print((self.NAME or "OAuth") .. ": Access Token denied:", data.error, data.error_description, data.error_uri)

    self:setLink("")

    self:notify("AccessTokenDenied", contextInfo, data.error, data.error_description, data.error_uri)
  else
    retryLater("HTTP " .. tostring(responseCode))
  end
end

--- Forget the tokens, here and in persistent storage, and stop refreshing.
function oauthObject:DeleteRefreshToken()
  local existed = (self.REFRESH_TOKEN ~= nil)

  local persistStoreKey = C4:Hash("SHA256", C4:GetDeviceID() .. self.API_CLIENT_ID, SHA_ENC_DEFAULTS)
  PersistDeleteValue(persistStoreKey)
  self.ACCESS_TOKEN = nil
  self.REFRESH_TOKEN = nil

  CancelTimer(self.timerPrefix .. "RefreshToken")

  self:notify("RefreshTokenDeleted", nil, existed)
end

function oauthObject:setLink(link, contextInfo)
  self:notify("LinkCodeReceived", contextInfo, link)

  if self.LINK_CHANGE_CALLBACK and type(self.LINK_CHANGE_CALLBACK) == "function" then
    guarded((self.NAME or "OAuth") .. ":LINK_CHANGE_CALLBACK", self.LINK_CHANGE_CALLBACK, link, contextInfo)
  end
end

function oauthObject:notify(handler, contextInfo, ...)
  if self.notifyHandler[handler] and type(self.notifyHandler[handler]) == "function" then
    guarded((self.NAME or "OAuth") .. ":" .. handler, self.notifyHandler[handler], contextInfo, ...)
  end
end

function oauthObject:urlDo(method, url, data, headers, callback, context)
  local ticketHandler = function(strError, responseCode, tHeaders, data, context, url)
    local func = self[callback]
    guarded((self.NAME or "OAuth") .. ":" .. callback, func, self, strError, responseCode, tHeaders, data, context, url)
  end

  urlDo(method, url, data, headers, ticketHandler, context)
end

function oauthObject:urlGet(url, headers, callback, context)
  self:urlDo("GET", url, nil, headers, callback, context)
end

function oauthObject:urlPost(url, data, headers, callback, context)
  self:urlDo("POST", url, data, headers, callback, context)
end

function oauthObject:urlPut(url, data, headers, callback, context)
  self:urlDo("PUT", url, data, headers, callback, context)
end

function oauthObject:urlDelete(url, headers, callback, context)
  self:urlDo("DELETE", url, nil, headers, callback, context)
end

function oauthObject:urlCustom(url, method, data, headers, callback, context)
  self:urlDo(method, url, data, headers, callback, context)
end

return oauthObject
