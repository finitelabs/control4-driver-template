-- lib/persist.lua's peek(), commit(), and durable():
--   * get() still hands out copies; peek() hands out the stored table itself;
--   * commit() stores a table without copying it, set() still copies;
--   * durable() inside defer() writes once, when the outermost scope closes, even
--     when the scope ends in an error; outside defer() it writes at once;
--   * a migration still runs exactly once, whether get() or peek() reads first.
--
-- Run from the driver root:
--   make test
-- or:
--   ./test/run_test.sh test_persist_peek.lua

local T = require("testlib")

require("c4_shim")
require("drivers-common-public.global.lib") -- Serialize

local writes = {}
local realSet = C4.PersistSetValue
function C4:PersistSetValue(key, value, encrypted)
  writes[key] = (writes[key] or 0) + 1
  return realSet(self, key, value, encrypted)
end

--- A fresh Persist instance, so no cache, registration, or timer carries over.
local function newPersist()
  ShimFireTimers()
  writes = {}
  return getmetatable(require("lib.persist")):new()
end

T.section("get() copies, peek() does not")
do
  local p = newPersist()
  p:set("Table", { list = { 1, 2 } })
  local copy = p:get("Table")
  copy.list[1] = 99
  T.eq("changing a get() copy leaves the store alone", p:get("Table").list[1], 1)
  T.check("peek() returns the same table each time", p:peek("Table") == p:peek("Table"))
  T.check("get() returns a different table each time", p:get("Table") ~= p:get("Table"))
  local default = {}
  T.check("an unknown key peeks as the default", p:peek("Missing", default) == default)
  p:delete("Gone")
  T.check("a deleted key gets the default itself, as before", p:get("Gone", default) == default)
end

T.section("commit() stores the table itself")
do
  local p = newPersist()
  local mine = { n = 1 }
  p:set("Copied", mine)
  T.check("set() stores a copy", p:peek("Copied") ~= mine)
  p:commit("Owned", mine)
  T.check("commit() stores the table", p:peek("Owned") == mine)
  T.eq("and writes it", Deserialize(C4:PersistGetValue("Owned")), { n = 1 })
  local live = p:peek("Owned")
  live.n = 2
  p:commit("Owned", live)
  T.eq("a peeked table changed and committed is written", Deserialize(C4:PersistGetValue("Owned")), { n = 2 })
  p:commit("Owned", nil)
  T.eq("committing nil deletes", p:get("Owned", "default"), "default")
end

T.section("durable() inside defer() writes once, when the outermost scope closes")
do
  local p = newPersist()
  p:setWriteBehind("Batch", 60000)
  p:defer(function()
    for i = 1, 50 do
      p:set("Batch", { n = i })
      p:durable("Batch")
    end
    p:defer(function()
      p:set("Batch", { n = 51 })
      p:durable("Batch")
    end)
    T.eq("nothing written while the outer scope runs", writes["Batch"], nil)
  end)
  T.eq("written once at the close", writes["Batch"], 1)
  T.eq("with the last value", Deserialize(C4:PersistGetValue("Batch")), { n = 51 })
  ShimFireTimers()
  T.eq("the write-behind timer finds nothing left", writes["Batch"], 1)
end

T.section("durable() writes even when the scope ends in an error")
do
  local p = newPersist()
  p:setWriteBehind("Batch", 60000)
  local ok = pcall(p.defer, p, function()
    p:set("Batch", { n = 1 })
    p:durable("Batch")
    error("boom")
  end)
  T.falsy("the error is rethrown", ok)
  T.eq("and the durable write went out", writes["Batch"], 1)
end

T.section("durable() outside defer() writes at once")
do
  local p = newPersist()
  p:setWriteBehind("Batch", 60000)
  p:set("Batch", { n = 1 })
  T.eq("a set outside defer() writes at once, as before", writes["Batch"], 1)
  p:durable("Batch")
  T.eq("and durable() has nothing left to write", writes["Batch"], 1)
  p:defer(function()
    p:set("Batch", { n = 2 })
  end)
  T.eq("a deferred set waits", writes["Batch"], 1)
  p:durable("Batch")
  T.eq("durable() outside a scope writes it now", writes["Batch"], 2)
end

T.section("a migration runs once, whichever read comes first")
do
  local runs = 0
  T.unload("^lib%.persist$", "^migrations$")
  package.preload["migrations"] = function()
    return {
      Migrated = function(value)
        runs = runs + 1
        return { version = 2, old = value and value.version }
      end,
    }
  end
  C4:PersistSetValue("Migrated", Serialize({ version = 1 }))
  local p = require("lib.persist")
  T.eq("peek() sees the migrated value", p:peek("Migrated"), { version = 2, old = 1 })
  T.eq("get() sees it too", p:get("Migrated"), { version = 2, old = 1 })
  T.eq("the migration ran once", runs, 1)
  package.preload["migrations"] = nil
  T.unload("^lib%.persist$", "^migrations$")
end

T.finish()
