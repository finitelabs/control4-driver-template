--- A simple HTTP client module for making HTTP requests with Deferred support.

local deferred = require("deferred")

local log = require("lib.logging")

--- Maximum timeout for HTTP requests.
--- @type number
local MAX_TIMEOUT = 300

--- Default timeout for HTTP requests.
--- @type number
local DEFAULT_TIMEOUT = 30

--- Placeholder substituted for any credential-bearing value before it is logged.
--- @type string
local REDACTED = "***REDACTED***"

--- Key fragments specific enough to match anywhere in the key. Matched against
--- the key with every non-alphanumeric character stripped, so "X-Api-Key" ->
--- "xapikey" and "client_secret" -> "clientsecret" both match.
--- @type string[]
local SENSITIVE_SUBSTRINGS = {
  "password",
  "passwd",
  "secret",
  "credential",
  "apikey",
  "authorization",
  "accesstoken",
  "refreshtoken",
  "sessiontoken",
  "idtoken",
  "signature",
}

--- Fragments too generic to match as substrings. These match only as the final
--- word of the key, which is where naming conventions put them ("X-Auth",
--- "access_token", "Set-Cookie"). Anchoring to the last word is what keeps
--- "AuthFlow", "AuthParameters" and "author" readable: those carry no secret,
--- and blanking them hides the diagnostics an installer needs during exactly
--- the auth failure this redaction exists for.
--- @type string[]
local SENSITIVE_LAST_WORDS = {
  "auth",
  "token",
  "cookie",
  "signature",
  "sig",
}

--- Split a key into lowercase words, breaking on punctuation and camelCase, so
--- "X-HatchBaby-Auth" -> { "x", "hatch", "baby", "auth" }.
--- @param key any
--- @return string[]
local function keyWords(key)
  local spaced = tostring(key):gsub("(%l)(%u)", "%1_%2"):gsub("(%d)(%a)", "%1_%2"):gsub("(%a)(%d)", "%1_%2")
  local words = {}
  for word in spaced:lower():gmatch("[%a%d]+") do
    words[#words + 1] = word
  end
  return words
end

--- Does this key name mark its value as a credential?
--- @param key any
--- @return boolean
local function isSensitiveKey(key)
  local normalized = tostring(key):lower():gsub("[^%a%d]", "")
  for _, fragment in ipairs(SENSITIVE_SUBSTRINGS) do
    if normalized:find(fragment, 1, true) then
      return true
    end
  end
  local words = keyWords(key)
  local last = words[#words]
  if last then
    for _, fragment in ipairs(SENSITIVE_LAST_WORDS) do
      if last == fragment then
        return true
      end
    end
  end
  return false
end

--- Does this value look like a bearer credential regardless of its key? Catches
--- JWTs (three base64url segments), which arrive under innocuous keys such as
--- the identity-provider name in a Cognito `Logins` map.
--- @param value any
--- @return boolean
local function looksLikeSecret(value)
  return type(value) == "string" and value:match("^[%w_-]+%.[%w_-]+%.[%w_-]+$") ~= nil and #value > 60
end

--- Mask credentials inside an already-encoded body, query string, or URL.
--- @param text string
--- @return string
local function redactSerialized(text)
  -- JSON object members: "password":"hunter2"
  text = text:gsub('("[%w_%-%.]-")(%s*:%s*)"[^"]*"', function(key, separator)
    if isSensitiveKey(key) then
      return key .. separator .. '"' .. REDACTED .. '"'
    end
  end)
  -- Form-encoded and query-string pairs: password=hunter2
  text = text:gsub("([%w_%-%.]+)=([^&%s]+)", function(key, value)
    if isSensitiveKey(key) then
      return key .. "=" .. REDACTED
    end
  end)
  return text
end

--- Maximum table nesting redacted before the value is masked outright.
--- @type number
local MAX_REDACT_DEPTH = 8

--- Copy `value` with every credential masked, so secrets never reach the log.
--- Tables are copied rather than mutated, leaving the caller's request intact.
---
--- Both guards below fail closed, returning REDACTED rather than the original
--- value: a redaction control that stops redacting is worse than one that hides
--- too much, and the raw table would otherwise reach JSON:encode intact. The
--- cycle guard also keeps a self-referencing table from throwing in the encoder,
--- which it did before this function existed.
--- @param value any
--- @param depth? number Current nesting level.
--- @param seen? table<table, boolean> Tables already being redacted on this path.
--- @return any
local function redact(value, depth, seen)
  depth = (depth or 0) + 1
  if type(value) == "string" then
    return looksLikeSecret(value) and REDACTED or redactSerialized(value)
  end
  if type(value) ~= "table" then
    return value
  end
  if depth > MAX_REDACT_DEPTH then
    return REDACTED
  end
  seen = seen or {}
  if seen[value] then
    return REDACTED
  end
  seen[value] = true
  local copy = {}
  for k, v in pairs(value) do
    if looksLikeSecret(v) then
      copy[k] = REDACTED
    elseif isSensitiveKey(k) then
      -- Recurse into a sensitive parent rather than blanking the whole subtree,
      -- so its non-secret siblings stay visible.
      copy[k] = type(v) == "table" and redact(v, depth, seen) or REDACTED
    else
      copy[k] = redact(v, depth, seen)
    end
  end
  seen[value] = nil
  return copy
end

--- @class Http
--- A class representing an HTTP client.
local Http = {}
Http.__index = Http

--- Internal. Exposed only so test/test_http_redact.lua can exercise the
--- redaction helpers, which are otherwise file-locals. Not part of the API.
Http._redact = redact
Http._isSensitiveKey = isSensitiveKey

--- Creates a new instance of the Http class.
--- @return Http http A new instance of the Http class.
function Http:new()
  log:trace("Http:new()")
  local instance = setmetatable({}, self)
  return instance
end

--- @class HTTPResponse
--- @field url string The URL of the request.
--- @field code number The HTTP response code.
--- @field headers table<string, string> The headers of the response.
--- @field body string|table<string, any> The body of the response.

--- @class HTTPErrorResponse
--- @field error string The error message.
--- @field url string The URL of the request.
--- @field code number The HTTP response code.
--- @field headers table<string, string> The headers of the response.
--- @field body string|table<string, any> The body of the response.

--- Makes an HTTP request.
--- @param method string The HTTP method (e.g., "GET", "POST").
--- @param url string The URL to send the request to.
--- @param data? string|table<string, any> The data to send with the request (optional).
--- @param headers? table<string, string> The headers to include in the request (optional).
--- @param options? table<string, any> Options for the request (e.g., timeout) (optional).
--- @return Deferred<HTTPResponse, HTTPErrorResponse> response A Deferred that resolves or rejects with the response.
--- @diagnostic disable-next-line: unused
function Http:request(method, url, data, headers, options)
  -- Redaction deep-copies the request, so skip it entirely unless the line will
  -- actually be emitted. Arguments are evaluated before the level is checked
  -- inside the logger, which would otherwise pay this cost on every request at
  -- the default INFO level.
  if log:getLogLevel() >= log.LogLevel.TRACE then
    log:trace("Http:request(%s, %s, %s, %s, %s)", method, redact(url), redact(data), redact(headers), redact(options))
  end
  local d = deferred.new()

  options = options or {}
  if options.timeout == nil then
    options.timeout = DEFAULT_TIMEOUT
  end
  if options.timeout <= 0 then
    options.timeout = MAX_TIMEOUT
  end
  options.timeout = InRange(options.timeout, 0, MAX_TIMEOUT)

  urlDo(method, url, data, headers, function(strError, responseCode, responseHeaders, responseBody, _, responseUrl)
    local result = {
      url = responseUrl,
      code = responseCode,
      headers = responseHeaders,
      body = responseBody,
    }
    if strError or IsEmpty(responseCode) or responseCode < 200 or responseCode >= 300 then
      -- Redacted: this string is rejected to the caller and drivers log it at
      -- WARN, which is emitted at the default level with nobody enabling trace.
      -- A URL carrying a token in its query string leaks here otherwise.
      result.error = string.format(
        "HTTP %s request to %s failed%s%s",
        method,
        redact(url),
        not IsEmpty(responseCode) and (" with status code " .. responseCode) or "",
        not IsEmpty(strError) and ("; " .. strError) or ""
      )
      d:reject(result)
    else
      d:resolve(result)
    end
  end, nil, options)
  return d
end

--- Makes an HTTP GET request.
--- @param url string The URL to send the request to.
--- @param headers? table<string, string> The headers to include in the request (optional).
--- @param options? table<string, any> Options for the request (e.g., timeout) (optional).
--- @return Deferred<HTTPResponse, HTTPErrorResponse> response A Deferred that resolves or rejects with the response.
function Http:get(url, headers, options)
  return self:request("GET", url, nil, headers, options)
end

--- Makes an HTTP POST request.
--- @param url string The URL to send the request to.
--- @param data? string|table The data to send with the request (optional).
--- @param headers? table<string, string> The headers to include in the request (optional).
--- @param options? table<string, any> Options for the request (e.g., timeout) (optional).
--- @return Deferred<HTTPResponse, HTTPErrorResponse> response A Deferred that resolves or rejects with the response.
function Http:post(url, data, headers, options)
  return self:request("POST", url, data, headers, options)
end

--- Makes an HTTP PUT request.
--- @param url string The URL to send the request to.
--- @param data? string|table The data to send with the request (optional).
--- @param headers? table<string, string> The headers to include in the request (optional).
--- @param options? table<string, any> Options for the request (e.g., timeout) (optional).
--- @return Deferred<HTTPResponse, HTTPErrorResponse> response A Deferred that resolves or rejects with the response.
function Http:put(url, data, headers, options)
  return self:request("PUT", url, data, headers, options)
end

--- Makes an HTTP DELETE request.
--- @param url string The URL to send the request to.
--- @param headers? table<string, string> The headers to include in the request (optional).
--- @param options? table<string, any> Options for the request (e.g., timeout) (optional).
--- @return Deferred<HTTPResponse, HTTPErrorResponse> response A Deferred that resolves or rejects with the response.
function Http:delete(url, headers, options)
  return self:request("DELETE", url, nil, headers, options)
end

return Http:new()
