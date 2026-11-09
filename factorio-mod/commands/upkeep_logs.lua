-- The upkeep's log books (commands/upkeep.lua and its parts): a message logged at most
-- once per interval per key, the books pruned of entries older than their interval
-- (review: one entry per key ever logged stayed for the whole game). Book:
-- storage.upkeep.logs[name][cid][key] = the tick it was last logged.
local M = {}

-- Log `msg` at most once per `every` ticks per key of the named book.
function M.log_once(name, cid, key, every, msg)
  storage.upkeep.logs = storage.upkeep.logs or {}
  storage.upkeep.logs[name] = storage.upkeep.logs[name] or {}
  local book = storage.upkeep.logs[name]
  book[cid] = book[cid] or {}
  local last = book[cid][key]
  if not last or game.tick - last >= every then
    book[cid][key] = game.tick
    log("[ai-companion] " .. msg)
  end
end

-- The companion's entries older than their book's interval dropped (`books`: {[name] =
-- interval in ticks}).
function M.prune(cid, books)
  local logs = storage.upkeep.logs or {}
  for name, every in pairs(books) do
    local book = logs[name] and logs[name][cid]
    for key, tick in pairs(book or {}) do
      if game.tick - tick >= every then book[key] = nil end
    end
  end
end

return M
