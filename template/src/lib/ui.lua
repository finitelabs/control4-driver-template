--- Messages between a driver and its custom page.
---
--- The broker handles messages one at a time and its cost grows with the square of a message's
--- size, so a push to an open page stays near 4 KB however much it carries. A push with no page
--- subscribed costs nothing. The REST reply drops what a handler returns unless it is XML, so a
--- handler pushes its answer and returns nothing.
---
--- ```lua
--- function UIR._GET_CONFIG()
---   ui:send("CONFIG_DATA", config)
--- end
--- -- For a value that changes often: at most one push a second, last value wins.
--- ui:coalesce("STATE", function()
---   return device:uiState()
--- end)
--- ```
---
--- The page pastes src/lib/ui-join.js into its script and joins each socket message:
---
--- ```js
--- var message = uiJoin(command, params.data);
--- if (message !== null) render(message);
--- ```

local log = require("lib.logging")

require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

--- A part's largest size once the socket has escaped it. Its header and the socket's wrapper
--- take it to about 4 KB.
--- @type integer
local MAX_PART_BYTES = 3850

--- @type integer
local COALESCE_MS = 1000

--- A byte the socket escapes takes two bytes on the wire.
--- @type integer, integer
local QUOTE, BACKSLASH = 34, 92

--- @class UI
--- @field _nextId integer The id of the next message.
--- @field _pending table[] Coalesced pushes waiting for the timer, oldest first.
local UI = {}
UI.__index = UI

--- The most base64 characters a page sends in one upload command. A command's DATA is base64
--- itself, so these take 4/3 of their length there: 3,888 B, and about 4 KB with its wrapper.
--- @type integer
UI.UPLOAD_CHUNK = 2916

--- @return UI
function UI:new()
  return setmetatable({ _nextId = 1, _pending = {} }, self)
end

--- The last byte of the part that starts at `first`.
--- @param json string
--- @param first integer
--- @return integer
local function partEnd(json, first)
  local size = 0
  for i = first, #json do
    local byte = json:byte(i)
    size = size + ((byte == QUOTE or byte == BACKSLASH) and 2 or 1)
    if size > MAX_PART_BYTES then
      -- A part travels alone, so it cannot stop partway through a UTF-8 character.
      local last = i - 1
      while last > first and json:byte(last + 1) >= 0x80 and json:byte(last + 1) < 0xC0 do
        last = last - 1
      end
      return last
    end
  end
  return #json
end

--- Push a message to the page, in parts of about 4 KB or less. Each part is one string param,
--- which also keeps the socket from coercing a value that looks like a number or a boolean.
--- @param command string The message's name.
--- @param data table|string The message, as a table or already JSON encoded.
function UI:send(command, data)
  for i = #self._pending, 1, -1 do
    if self._pending[i].key == command then
      table.remove(self._pending, i)
    end
  end
  local json = type(data) == "string" and data or JSON:encode(data)
  local parts, first = {}, 1
  repeat
    local last = partEnd(json, first)
    parts[#parts + 1] = json:sub(first, last)
    first = last + 1
  until first > #json
  local id = self._nextId
  self._nextId = id + 1
  log:trace("UI:send(%s): %d B in %d parts", command, #json, #parts)
  for i, part in ipairs(parts) do
    C4:SendDataToUI(command, { data = string.format("%d:%d:%d:%s", id, i, #parts, part) })
  end
end

--- Push a value within a second, replaced by any newer value for the same key until then.
--- @param command string The message's name.
--- @param data table|string|fun():table|string|nil The message, or a function that builds it as it goes out, or
--- returns nil to send nothing.
--- @param key? string The value this one replaces, by default the command's. A key per entity keeps each one's own.
function UI:coalesce(command, data, key)
  key = key or command
  for _, item in ipairs(self._pending) do
    if item.key == key then
      item.data = data
      return
    end
  end
  table.insert(self._pending, { key = key, command = command, data = data })
  if #self._pending == 1 then
    SetTimer("UICoalesce", COALESCE_MS, function()
      local pending = self._pending
      self._pending = {}
      for _, item in ipairs(pending) do
        local message = item.data
        if type(message) == "function" then
          message = message()
        end
        if message ~= nil then
          self:send(item.command, message)
        end
      end
    end)
  end
end

return UI:new()
