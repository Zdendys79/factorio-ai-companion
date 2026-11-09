-- Her material from the drills' supply chests (Zdendys 2026-11-09, factorio-ai
-- docs/no_hand_mining.md: neither coal nor anything else is mined by hand once a drill
-- of it can be had -- too few drills or stocks: more are built). Shared by the fuel
-- upkeep's getting coal (commands/upkeep_fetch.lua) and a build's ensure_item
-- (commands/task_pool_ensure_item.lua):
-- - can_be_had(c, item): a drill of her force within RADIUS of her mining `item` now
--   (working, at low power, or its output full) into a plain chest that is a store of
--   it (upkeep_feeds.is_store) -- read again after RECHECK_TICKS or a RECHECK_MOVE walk;
-- - report(cid, item, short, mining): a shortage for the controller (no store holds
--   enough although such a drill stands -- nothing is mined then -- or, mining = true,
--   mined by hand for want of one), kept KEEP_TICKS, read by shorts(cid) for
--   /fac_upkeep's status (build_short).
local u = require("commands.init")
local F = require("commands.upkeep_feeds")

local M = {}

M.RADIUS = 300
M.RECHECK_TICKS = 3600
M.RECHECK_MOVE = 50
M.KEEP_TICKS = 18000

-- the drill statuses in which a drill makes its material (a full chest is a store too)
local MINING = {[defines.entity_status.working] = true,
                [defines.entity_status.low_power] = true,
                [defines.entity_status.waiting_for_space_in_destination] = true}

-- storage.supply_stores = {drill = {[cid] = {[item] = {tick, yes, x, y}}},
--   short = {[cid] = {[item] = {short, tick, mining}}}}
local function book(name, cid)
  storage.supply_stores = storage.supply_stores or {}
  storage.supply_stores[name] = storage.supply_stores[name] or {}
  storage.supply_stores[name][cid] = storage.supply_stores[name][cid] or {}
  return storage.supply_stores[name][cid]
end

-- Whether a drill of `item` can be had by companion cid (c: her record; module header).
function M.can_be_had(cid, c, item)
  local seen_book = book("drill", cid)
  local pos = c.entity.position
  local seen = seen_book[item]
  if seen and game.tick - seen.tick < M.RECHECK_TICKS and seen.x
     and u.distance(pos, {x = seen.x, y = seen.y}) < M.RECHECK_MOVE then
    return seen.yes
  end
  local yes = false
  local surface, force = c.entity.surface, c.entity.force
  for _, d in pairs(surface.find_entities_filtered{type = "mining-drill", position = pos,
                                                    radius = M.RADIUS, force = force}) do
    if d.valid and MINING[d.status] and F.mines_item(d, item) then
      for _, chest in pairs(surface.find_entities_filtered{position = d.drop_position,
          type = "container", force = force}) do
        if chest.valid and F.is_store(chest, item) then
          yes = true
          break
        end
      end
      if yes then break end
    end
  end
  seen_book[item] = {tick = game.tick, yes = yes, x = pos.x, y = pos.y}
  return yes
end

-- A shortage of `item` for the controller (module header).
function M.report(cid, item, short, mining)
  book("short", cid)[item] = {short = short, tick = game.tick, mining = mining or nil}
end

-- The shortage of `item` over (a step got it -- review: it stayed listed KEEP_TICKS):
-- dropped unless it is a hand mining's (that one says a drill with a chest is wanted,
-- KEEP_TICKS) or another active task of hers still waits for it (review: a taken-over
-- waiting step's shortage was cleared by another task's step).
function M.clear(cid, item)
  local s = storage.supply_stores and storage.supply_stores.short
  local entry = s and s[cid] and s[cid][item]
  if not entry or entry.mining then return end
  for _, t in pairs(storage.tasks or {}) do
    if t.cid == cid and t.status == "active" and t.ctx and t.ctx.raw_wait_deadline
       and t.ctx.raw_wait_deadline[item] then
      return
    end
  end
  s[cid][item] = nil
end

-- The shortages of cid reported within KEEP_TICKS: {[item] = {short, tick, mining}}
-- (older ones dropped; the books of a companion no longer there too -- review).
function M.shorts(cid)
  for _, name in ipairs({"drill", "short"}) do
    for other in pairs((storage.supply_stores and storage.supply_stores[name]) or {}) do
      if other ~= cid and not (storage.companions and storage.companions[other]) then
        storage.supply_stores[name][other] = nil
      end
    end
  end
  local b = book("short", cid)
  for item, s in pairs(b) do
    if game.tick - s.tick >= M.KEEP_TICKS then b[item] = nil end
  end
  return b
end

return M
