-- Copyright 2026 Snap One, LLC. All rights reserved.
--
-- LOCAL FORK of Snap One's drivers-common-public make_short_link module, upstream
-- MAKE_SHORT_LINK 8 (4a99695, which added duration). Re-vendoring from upstream silently
-- drops everything listed here, in every repo the template renders. Keep this list current.
--
-- Deltas against upstream MAKE_SHORT_LINK 8:
--   1. A transport error hands the callback the long link. Upstream returned without
--      calling it, so auth_code_grant never showed a link at all.
--   2. A response whose body is not a decoded table (url.lua wraps a body it cannot
--      decode as { body }) keeps the long link rather than indexing it.
--   3. A callback that raises is reported with its traceback. Upstream's pcall dropped
--      the error.
--   4. An apiKey that is not a string hands the callback the long link. Upstream
--      returned without calling it, which left no link to show.
--   5. MakeShortLink and MakeShortLinkResponse carry LuaDoc.
--
-- test/test_oauth_short_link.lua covers 1 to 4.

MAKE_SHORT_LINK_VER = 8

require("drivers-common-public.global.url")

--- Shorten link through Control4's link service, then call callback with the result.
--- The service is link.ctrl4.co when IN_PRODUCTION is set, else the development one,
--- and each takes its own API key. The callback always receives a usable link: the
--- short one, or link itself when the service fails.
--- @param link string The URL to shorten.
--- @param callback fun(link: string, expiresAt: number|nil)|nil Receives the link.
--- @param apiKey string The link service API key Control4 issues.
--- @param duration number|nil Seconds the short link lasts; the service caps it at 600
--- and uses its own default when it is nil.
function MakeShortLink(link, callback, apiKey, duration)
  local url
  if IN_PRODUCTION then
    url = "https://link.ctrl4.co/new"
  else
    url = "https://link.control4driversdev.com/new"
  end

  if type(link) ~= "string" then
    dbg("Error MakeShortLink: link must be a string", link)
    return
  end

  if type(duration) ~= "number" then
    dbg("Warning MakeShortLink: duration must be a number", duration)
    duration = nil
  end

  if type(callback) ~= "function" then
    dbg("Warning MakeShortLink: callback must be a function", callback)
    callback = nil
  end

  if type(apiKey) ~= "string" then
    dbg("Error MakeShortLink: apiKey must be a string", apiKey)
    MakeShortLinkResponse("apiKey must be a string", nil, nil, nil, { link = link, callback = callback }, url)
    return
  end

  local data = {
    url = link,
    duration = duration,
  }

  local headers = {
    Authorization = apiKey,
  }

  local contextInfo = {
    link = link,
    callback = callback,
  }

  urlPost(url, data, headers, MakeShortLinkResponse, contextInfo)
end

--- urlPost's callback for MakeShortLink.
--- @param strError string|nil The transport error, if any.
--- @param responseCode number|nil The HTTP status.
--- @param tHeaders table|nil The response headers.
--- @param data any The decoded body.
--- @param context table The contextInfo MakeShortLink passed.
--- @param url string The request URL.
function MakeShortLinkResponse(strError, responseCode, tHeaders, data, context, url)
  local link = context.link -- original link to allow fallback if short link creation fails
  local callback = context.callback

  local expiresAt

  if strError then
    dbg("Error with MakeShortLinkResponse:", strError)
  elseif responseCode == 200 and type(data) == "table" and type(data.url) == "string" then
    link = data.url
    expiresAt = data.expiresAt
  end

  if link then
    if type(callback) == "function" then
      local success, err = xpcall(function()
        return callback(link, expiresAt)
      end, debug.traceback)
      if not success then
        print("MakeShortLink callback Lua error:", err)
      end
    end
  end
end
