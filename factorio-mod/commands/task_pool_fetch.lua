-- A hand craft's material fetched from places (factorio-ai docs/mod_upkeep_supply.md D;
-- game rule 34 -- Zdendys: finding the material is the mod's, queued by what she holds:
-- no walk while her inventory has enough). An ensure_item step short of an item she
-- cannot hand-craft (a smelted plate) takes the missing amount from the nearest place
-- holding it: a furnace's or an assembler's output, a chest -- never one an inserter
-- picks from (it feeds a line or a machine: a fuel chest, a plate row's output) nor a
-- furnace the controller loads itself (upkeep_feed_regs "own" / "loading"). Within
-- FETCH_REACH of her it is taken at once; farther she walks there (a bounded walk) and
-- the place is judged again on arrival. A place she could not reach or take from is
-- not tried again by that step for that item (t.ctx.fetch_tried, cleared with the other
-- fetch books when the step ends -- task_pool_ledger.clear_ensure_ctx, done or a failed
-- optional step). Never more than fits her inventory (a full one fetches nothing -- review: she
-- walked to every holder taking 0), never from a furnace output a stock task of the
-- upkeep is about to take from (upkeep_stock.claimed). While no place holds it, the
-- places are searched again every RESCAN_TICKS only (the step's smelt wait calls this
-- every tick).
local u = require("commands.init")
local F = require("commands.upkeep_feeds")
local Regs = require("commands.upkeep_feed_regs")
local Stock = require("commands.upkeep_stock")

local M = {}

M.FETCH_REACH = 8        -- tiles: within her reach (10) without a walk
M.MIN_TAKE = 10          -- a place holding less (unless the whole shortfall) is no source
M.RESCAN_TICKS = 60      -- no place held it: searched again after this
local SOURCE_TYPES = {"furnace", "assembling-machine", "container", "logistic-container"}
local MACHINE_TYPES = {furnace = true, ["assembling-machine"] = true}

local function pos_key(e)
  return string.format("%.1f,%.1f", e.position.x, e.position.y)
end

-- The inventory a place gives from: a machine's output, a chest's chest.
local function source_inv(e)
  return e.get_inventory(MACHINE_TYPES[e.type] and defines.inventory.crafter_output
                         or defines.inventory.chest)
end

-- Whether she may take `item` from the place `e`: not a furnace the controller loads
-- itself, nor one whose output a stock task is about to take it from, nor one an
-- inserter picks from.
local function allowed(e, item)
  if e.type == "furnace" and (Regs.own(e) or Stock.claimed(pos_key(e), item)) then
    return false
  end
  return not F.picked_from(e)
end

-- The tried-book key of a place for an item.
local function tried_key(e, item)
  return pos_key(e) .. "|" .. item
end

-- The place to take `want` of `item` from: the nearest holding the whole of it, else
-- the nearest holding MIN_TAKE (or the whole shortfall, when less); `tried`: the places
-- this step gave up on. Returns the entity or nil.
local function pick(c, item, want, tried)
  local pos = c.entity.position
  local least = math.min(M.MIN_TAKE, want)
  local whole, whole_d, some, some_d = nil, math.huge, nil, math.huge
  for _, e in pairs(c.entity.surface.find_entities_filtered{type = SOURCE_TYPES,
                                                            force = c.entity.force}) do
    local inv = e.valid and not tried[tried_key(e, item)] and source_inv(e)
    local n = inv and inv.get_item_count(item) or 0
    if n >= least then
      local d = u.distance(pos, e.position)
      if (d < whole_d and n >= want) or d < some_d then
        if allowed(e, item) then
          if n >= want and d < whole_d then whole, whole_d = e, d end
          if d < some_d then some, some_d = e, d end
        end
      end
    end
  end
  return whole or some
end

-- Take up to `want` of `item` out of the place `e` into her inventory (what does not
-- fit goes back); judged again first (an inserter set up meanwhile). Returns the count.
local function take(c, e, item, want)
  if not (e and e.valid) or not allowed(e, item) then return 0 end
  local inv = source_inv(e)
  local n = inv and math.min(want, inv.get_item_count(item)) or 0
  if n <= 0 then return 0 end
  local removed = inv.remove{name = item, count = n}
  if removed <= 0 then return 0 end
  local put = c.entity.insert{name = item, count = removed}
  if put < removed then inv.insert{name = item, count = removed - put} end
  return put
end

-- The step's shortfall of `item` (`want`): taken from a place within reach ("taken",
-- with the count), or a walk to a farther one set up in t.ctx.fetch ("fetch"), or nil
-- (no place holds it).
function M.start(c, t, item, want)
  t.ctx.fetch_tried = t.ctx.fetch_tried or {}
  -- (per item: a step's ingredients are fetched one after another)
  local next_scan = t.ctx.fetch_next_scan
  if type(next_scan) == "table" and next_scan.item == item and game.tick < next_scan.tick then
    return nil
  end
  want = math.min(want, c.entity.get_main_inventory().get_insertable_count(item))
  if want <= 0 then
    t.ctx.fetch_noroom_logged = t.ctx.fetch_noroom_logged or {}
    if not t.ctx.fetch_noroom_logged[item] then
      t.ctx.fetch_noroom_logged[item] = true
      log("[ai-companion] ensure_item: no room in her inventory for " .. item
          .. " -- nothing fetched")
    end
    t.ctx.fetch_next_scan = {item = item, tick = game.tick + M.RESCAN_TICKS}
    return nil
  end
  local e = pick(c, item, want, t.ctx.fetch_tried)
  if not e then
    t.ctx.fetch_next_scan = {item = item, tick = game.tick + M.RESCAN_TICKS}
    return nil
  end
  t.ctx.fetch_next_scan = nil
  if u.distance(c.entity.position, e.position) <= M.FETCH_REACH then
    local got = take(c, e, item, want)
    if got <= 0 then
      t.ctx.fetch_tried[tried_key(e, item)] = true
      log("[ai-companion] ensure_item: nothing of " .. item .. " could be taken from the "
          .. e.name .. " at " .. pos_key(e) .. " -- not tried again by this step")
      return nil
    end
    return "taken", got
  end
  t.ctx.fetch = {x = e.position.x, y = e.position.y, key = tried_key(e, item),
                 item = item, want = want}
  return "fetch"
end

-- Start the walk to the place in t.ctx.fetch (the step's state "ensuring", kind
-- "fetch_walk", a bounded approach deadline).
function M.begin_walk(c, cid, active, t)
  local f = t.ctx.fetch
  -- (her walk: dropped with the step if the task ends meanwhile -- task_pool.lua)
  storage.walking_queues[cid] = {target = {x = f.x, y = f.y}}
  active.state = "ensuring"
  active.ensuring_kind = "fetch_walk"
  active.fetch_deadline = u.approach_deadline(c.entity.position, {x = f.x, y = f.y})
end

-- The walk's tick: true while she is still on her way; else the take is done (or the
-- walk given up -- that place not tried again, logged) and the step goes back to
-- "acting", which judges her stock afresh.
function M.poll(c, cid, active, t)
  local f = t.ctx.fetch
  local near = f and u.distance(c.entity.position, f) <= M.FETCH_REACH
  local timed_out = active.fetch_deadline and game.tick >= active.fetch_deadline
  if storage.walking_queues[cid] and not near and not timed_out then return true end
  if storage.walking_queues[cid] then
    storage.walking_queues[cid] = nil
    c.entity.walking_state = {walking = false}
  end
  active.state = "acting"
  t.ctx.fetch = nil
  if not f then return false end
  local got = 0
  if near then
    local found = c.entity.surface.find_entities_filtered{type = SOURCE_TYPES,
                                                          position = f, radius = 0.6,
                                                          force = c.entity.force}
    local best, bd = nil, math.huge
    for _, e in pairs(found) do
      local d = u.distance(e.position, f)
      if d < bd then best, bd = e, d end
    end
    got = take(c, best, f.item, f.want)
  end
  if got <= 0 then
    t.ctx.fetch_tried = t.ctx.fetch_tried or {}
    t.ctx.fetch_tried[f.key] = true
    log("[ai-companion] ensure_item: " .. f.item .. " not fetched from " .. f.key .. " ("
        .. (near and "nothing to take there" or "not reached") .. ") -- not tried again "
        .. "by this step")
  end
  return false
end

return M
