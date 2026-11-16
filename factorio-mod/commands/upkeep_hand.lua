-- The burners and fuel chests the fuel upkeep served by hand (0.16.189; factorio-ai
-- docs/architecture_roles.md Decided 8: the list goes to the controller, which plans
-- supply lines from it). storage.upkeep.hand[cid][surface index][key] = {tick (of the
-- last serving), fills ("fuel" / "insert"), item, x, y, supply: "broken" -- its line
-- delivered nothing (the fuel upkeep's down book) -- or "none"}; kept KEEP_TICKS after
-- the last serving, reported for her current surface only and only while something
-- still stands there (a device taken down leaves the list).

local M = {}

M.KEEP_TICKS = 36000
-- what may stand at a served spot: a burner, or the fuel chest it was filled through
local TYPES = {"furnace", "mining-drill", "boiler", "inserter", "container"}

-- Book a finished fuel task `t` of `cid` under its key (upkeep.lua prune). Only while
-- her upkeep is on (switched off, its down book is gone: a broken line would read
-- "none").
function M.note(cid, key, t)
  local up = storage.upkeep
  if not (up and up.enabled and up.enabled[cid]) then return end
  local s = t.steps and t.steps[1]
  if not (s and s.x and s.y) then return end
  local c = storage.companions and storage.companions[cid]
  local surface = c and c.entity and c.entity.valid and c.entity.surface.index
  if not surface then return end
  up.hand = up.hand or {}
  up.hand[cid] = up.hand[cid] or {}
  up.hand[cid][surface] = up.hand[cid][surface] or {}
  local book = up.hand[cid][surface]
  for k, h in pairs(book) do
    if game.tick - (h.tick or 0) >= M.KEEP_TICKS then book[k] = nil end
  end
  local d = up.down and up.down[cid] and up.down[cid][key]
  book[key] = {tick = game.tick, fills = s.type, item = s.item, x = s.x, y = s.y,
               supply = d and "broken" or "none"}
end

-- The report for /fac_upkeep: [{at "x,y", fills, item, tick, supply}] of her current
-- surface -- an entry past KEEP_TICKS or whose spot holds nothing any more is dropped.
function M.status(cid)
  local out = {}
  local c = storage.companions and storage.companions[cid]
  if not (c and c.entity and c.entity.valid) then return out end
  local surface = c.entity.surface
  local up = storage.upkeep
  local book = up and up.hand and up.hand[cid] and up.hand[cid][surface.index]
  for key, h in pairs(book or {}) do
    local stands = h.x and surface.count_entities_filtered{
      position = {h.x, h.y}, radius = 0.6, type = TYPES} > 0
    if game.tick - (h.tick or 0) >= M.KEEP_TICKS or not stands then
      book[key] = nil
    else
      out[#out + 1] = {at = string.format("%.1f,%.1f", h.x, h.y), fills = h.fills,
                       item = h.item, tick = h.tick, supply = h.supply}
    end
  end
  return out
end

return M
