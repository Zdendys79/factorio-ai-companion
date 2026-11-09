-- Getting material for the fuel upkeep (Zdendys: when she lacks the material to supply
-- a production or a chest no belt with it reaches yet, getting it is an action of its
-- own; its priority grows with the shortage in her inventory and in the production and
-- falls with the distance to the source that covers it). Called by commands/upkeep.lua's
-- scan with the needs she had no free coal for.
--
-- - p = log2(S) + log2(T / max(1, t)): S = the coal those needs want beyond her free
--   coal (at least 1 -- "missing" is never zero), t and T = the time left and the own
--   target (min(TARGET_S, what its full slot / chest lasts)) of the most urgent of
--   them (the least t / T); the task pool's scheduler then raises it by nearness to
--   the source (p ^ (1 / (distance + 1))).
-- - S counts her coal under her floor too. The source: a coal store within
--   SOURCE_RADIUS of her -- a plain chest by its store share (upkeep_feeds.store_share:
--   a coal drill's output chest, less what its partner's inserter keeps -- a coal
--   pair's, a coal-row unit's; any other chest no inserter picks from), never a fuel
--   chest the upkeep fills: the nearest whose share covers max(S, the least), else the
--   largest of at least the least -- min(S, MIN_TAKE) while a need is urgent (under
--   T / 2: a starving burner takes what a drill's chest has), min(the amount,
--   CALM_TAKE) else -- taken by a "take" step. Zdendys 2026-11-09: no material is
--   mined by hand once a drill of it can be had -- with a coal drill of her force
--   within SOURCE_RADIUS mining now (working, at low power, its output full) into a
--   plain chest that is a store of it (commands/supply_stores.lua can_be_had), and no
--   store, she mines nothing: the shortage is logged
--   ([SUPPLY_SHORT], once per SUPPLY_LOG_TICKS) and kept for the status (supply_short,
--   the next search SHORT_HOLD_TICKS later -- Python plans more coal drills with
--   chests). Only while no such drill can be had (before the first, every one dry or
--   without power, none with a chest) she mines it by hand -- the status names that
--   shortage too (mining = true) for SUPPLY_LOG_TICKS (an
--   ensure_item step, the nearest patch: no_pull -- no chest near her is emptied
--   first -- and raw -- the target counts all the coal she holds, so reservations made
--   while she mines do not move it). A walk of 150 tiles takes ~20 s, mining 100 coal
--   by hand ~200 s. Belts are left alone: they carry coal to the production.
-- - She fetches up to STOCK coal (the fuel range: two stacks), at least S, capped by her
--   inventory room -- from a store; mining, at most max(min(the most urgent need's
--   coal, MINE_CHUNK) + what keeps her coal floor, MINE_CHUNK) at a time (the burners'
--   tasks wait while she mines). No new fetch while one of her open upkeep tasks holds
--   coal reserved and the scheduler would pick it before the fetch (its effective
--   priority from where she stands at least the fetch's p): that delivery comes first.
-- - One fetch task per companion (kind "upkeep"); its priority kept up to date while
--   she is short; withdrawn (unless being acted on) once she is not. A failed take
--   leaves its store out BAD_STORE_TICKS (the next fetch goes to another store); a
--   failed mining holds fetching off FAIL_BACKOFF_TICKS.
local u = require("commands.init")
local ledger = require("commands.task_pool_ledger")
local priority = require("commands.priority")
local F = require("commands.upkeep_feeds")
local Stores = require("commands.supply_stores")

local M = {}

M.STOCK = 100              -- coal she fetches up to (the fuel range's two stacks)
-- coal she mines by hand in one fetch at most (unless more is short): ~50 s of hand
-- mining -- the burners' tasks wait while she mines (a smoke: 80-100 coal, ~200 s, the
-- tasks waiting); a next fetch follows while she is still short
M.MINE_CHUNK = 25
-- a store whose share is less than min(S, this) is passed over while a need is urgent
-- (under half the target: a starving burner takes what a drill's chest has); else less
-- than min(the amount fetched, CALM_TAKE) (review: trips for 6 coal at 229 s left)
M.MIN_TAKE = 5
M.CALM_TAKE = 25
-- (the drills' chests are her only source once a drill stands: a far one too -- a walk
-- of 300 tiles ~40 s; whether a drill can be had: commands/supply_stores.lua)
M.SOURCE_RADIUS = Stores.RADIUS
-- the [SUPPLY_SHORT] log at most this often (its book pruned by commands/upkeep.lua)
local SUPPLY_LOG_TICKS = 18000
M.LOG_BOOKS = {supply = SUPPLY_LOG_TICKS}
-- after a search found no store, the next search this many ticks later
M.SHORT_HOLD_TICKS = 600
local FAIL_BACKOFF_TICKS = 3600
local BAD_STORE_TICKS = 18000
local STORE_TYPES = {"container"}   -- plain chests (logistic chests are the robots')

local function key_of(e)
  return string.format("%.1f,%.1f", e.position.x, e.position.y)
end

-- storage.upkeep.fetch = {[cid] = {task_id = id or nil, off_until = tick or nil,
--   bad = {[store key] = tick until it is left out}, supply_short = {item, short,
--   tick} or nil: the last search found no store and mined nothing, short_until = the
--   tick of the next search after it, mined = {item, short, tick}: her last mining
--   fetch} (a `drill` book of 0.16.177's first form is left unread)
local function book(cid)
  storage.upkeep.fetch = storage.upkeep.fetch or {}
  storage.upkeep.fetch[cid] = storage.upkeep.fetch[cid] or {}
  local b = storage.upkeep.fetch[cid]
  b.bad = b.bad or {}
  b.drill = nil
  return b
end

-- The coal store within SOURCE_RADIUS of her to fetch from (`fills`: the keys of the
-- fuel chests the upkeep fills, `bad`: stores a take failed at -- never a source): the
-- nearest whose store share covers `full`, else the one with the largest share of at
-- least `least` (review: the nearest with a few coal its drill had just refilled made
-- a trip every few seconds); the chest and its share, or nil and whether a chest
-- holding enough is only left out now (a failed take -- no shortage then: review).
local function nearest_store(c, item, least, full, fills, bad)
  local pos = c.entity.position
  local cands, left_out = {}, false
  for _, chest in pairs(c.entity.surface.find_entities_filtered{
      position = pos, radius = M.SOURCE_RADIUS, type = STORE_TYPES, force = c.entity.force}) do
    local key = chest.valid and key_of(chest)
    if key and chest.get_item_count(item) >= least and not fills[key] then
      if bad[key] and game.tick < bad[key] then
        -- (by its store share -- review: a drill's chest at its keep is no store either)
        left_out = left_out or F.store_share(chest, item) >= least
      else
        cands[#cands + 1] = {chest = chest, d = u.distance(pos, chest.position)}
      end
    end
  end
  -- (nearest first; the store share -- area searches -- read only until one covers it)
  table.sort(cands, function(a, b2) return a.d < b2.d end)
  local best, best_share = nil, least - 1
  for _, cand in ipairs(cands) do
    local share = F.store_share(cand.chest, item)
    if share >= full then return cand.chest, share end
    if share > best_share then best, best_share = cand.chest, share end
  end
  if best then return best, best_share end
  return nil, nil, left_out
end

-- The fetch task's steps for `amount` of `item` (she holds `have`): a take at the
-- store nearest_store picks (`need`: the shortage a store should cover; at most its
-- share), else -- only while no drill of it stands
-- (`mine_ok`) -- mining to hold `have + mined`, `mined` = min(amount,
-- max(least_mined, MINE_CHUNK)); and how ("take at x,y" / "mine"), and the amount
-- fetched; nil when there is no store and no mining ("left out" second when a store
-- holding enough is only left out now).
local function fetch_steps(c, item, amount, least_mined, least, need, have, fills, bad,
                           mine_ok)
  local store, share, left_out = nearest_store(c, item, least, need, fills, bad)
  if store then
    local n = math.min(amount, share)
    return {{type = "take", x = store.position.x, y = store.position.y, store = true,
             entity = store.name, item = item, count = n}}, "take at " .. key_of(store), n
  end
  if not mine_ok then return nil, left_out and "left out" or nil end
  local mined = math.min(amount, math.max(least_mined, M.MINE_CHUNK))
  return {{type = "ensure_item", item = item, count = have + mined, no_pull = true,
           raw = true}}, "mine", mined
end

-- Whether one of her open upkeep tasks still holds `item` reserved (she carries it for
-- that task) AND would be picked before a fetch of priority p (the scheduler's
-- effective priority from where she stands; a fetch's step has no position: its full
-- p) -- that delivery comes first. (review: a block on any coal-holding task let a far
-- one, outranked by every near build step, hold the fetch off while near burners died)
local function delivers_first(cid, c, item, p)
  local pos = c.entity.position
  for _, task_id in pairs(storage.upkeep.tasks and storage.upkeep.tasks[cid] or {}) do
    local t = storage.tasks[task_id]
    local s = t and t.steps and t.steps[1]
    if t and t.status == "active" and t.reserved and s and s.x and s.y
       and (t.reserved[item] or 0) - ((t.consumed or {})[item] or 0) > 0
       and priority.effective(t.priority or 1, u.distance(pos, {x = s.x, y = s.y})) >= p then
      return true
    end
  end
  return false
end

-- The expired left-out stores dropped; the ended fetch task forgotten -- a failed take
-- leaves its store out, a failed mining (its gather attempts ran out) or a take that
-- found no room in her inventory holds fetching off.
local function forget_ended(b, item)
  for key, until_tick in pairs(b.bad) do
    if game.tick >= until_tick then b.bad[key] = nil end
  end
  local t = b.task_id and storage.tasks[b.task_id]
  if not b.task_id or (t and t.status == "active") then return end
  if t and t.status == "failed" then
    local s = t.steps and t.steps[1]
    -- (a take that failed for want of room in her inventory says nothing of the store:
    -- held off like a failed mining -- review)
    if s and s.type == "take" and not tostring(t.error):find("no room", 1, true) then
      -- (one holding only its keep now -- its partner's inserter or another task came
      -- first -- is left out SHORT_HOLD_TICKS only: its drill refills it -- review: a
      -- drill's chest, the only store, was left out 5 minutes)
      local ticks = tostring(t.error):find("is no store", 1, true) and M.SHORT_HOLD_TICKS
                    or BAD_STORE_TICKS
      b.bad[string.format("%.1f,%.1f", s.x, s.y)] = game.tick + ticks
      log(string.format("[ai-companion] upkeep: taking %s at %.1f,%.1f failed (%s) -- "
                        .. "that store is left out %d ticks", item, s.x, s.y,
                        tostring(t.error), ticks))
    else
      b.off_until = game.tick + FAIL_BACKOFF_TICKS
      log("[ai-companion] upkeep: fetching " .. item .. " failed (" .. tostring(t.error) ..
          ") -- held off " .. FAIL_BACKOFF_TICKS .. " ticks")
    end
  end
  storage.tasks[b.task_id] = nil
  b.task_id = nil
end

-- One scan's getting material for companion cid.
-- short: the needs she had no free coal for ({want = coal wanted, t = seconds left,
-- target = its own target in seconds -- min(T, what its full slot / chest lasts):
-- review, a hand-fed boiler's ~111 s made every one of them urgent against T}); free:
-- her free coal above the floor (may be negative); fills: the keys of the fuel chests
-- among the needs; acting(task_id): whether that task's step is being acted on;
-- log_once: the upkeep's logger; target_s: the upkeep's target stock in seconds (T,
-- for a need without its own). Returns nothing.
function M.update(cid, c, item, short, free, fills, acting, log_once, target_s)
  local b = book(cid)
  forget_ended(b, item)
  local t = b.task_id and storage.tasks[b.task_id]
  if #short == 0 or t then b.supply_short, b.short_until = nil, nil end
  if #short == 0 then
    if t and not acting(b.task_id) then           -- not short any more
      ledger.cancel_task(b.task_id, "upkeep: no longer short of " .. item)
      storage.tasks[b.task_id] = nil
      b.task_id = nil
    end
    return
  end
  -- (the most urgent need: the least time left against its own target)
  local want, t_min, urgent, target, worst = 0, math.huge, 0, target_s, math.huge
  for _, n in ipairs(short) do
    want = want + n.want
    local nt = n.target or target_s
    local rel = n.t / math.max(1, nt)
    if rel < worst then worst, t_min, urgent, target = rel, n.t, n.want, nt end
  end
  -- (her coal under the floor counts too -- review: a take of 7 left her short again at
  -- once, a trip every few seconds)
  local S = math.max(1, want - free)
  local p = math.log(S, 2) + math.log(target / math.max(1, t_min), 2)
  if t then
    t.priority = p
    return
  end
  -- (after a search found no store: none again before SHORT_HOLD_TICKS -- a search of
  -- the containers within 300 tiles; the shortage stands meanwhile)
  if b.short_until and game.tick < b.short_until then return end
  -- (the shortage is set by this scan's search alone -- review: an early return kept a
  -- stale one)
  b.supply_short, b.short_until = nil, nil
  if b.off_until and game.tick < b.off_until then return end
  -- what she carries for an open upkeep task the scheduler would pick first is delivered
  -- first (review: a fetch has no position, its full priority beat every far fuel task
  -- -- chunk after chunk mined while the burners waited)
  if delivers_first(cid, c, item, p) then return end
  local inv = c.entity.get_main_inventory()
  local have = inv.get_item_count(item)
  local amount = math.min(math.max(S, M.STOCK - have), inv.get_insertable_count(item))
  if amount < 1 then
    log_once("noroom", cid, "fetch", 18000, "upkeep: short of " .. item ..
             " but no room in her inventory to fetch it")
    return
  end
  -- mining: the most urgent need's coal (a chunk of it at most -- an upkeep task takes a
  -- part too; review: a boiler's whole slot room was ~50) and what keeps her coal floor
  -- (free below 0), at least MINE_CHUNK (review: the whole shortage of several boilers
  -- was ~100 again)
  local least_mined = math.min(urgent, M.MINE_CHUNK) + math.max(0, -free)
  local least = (t_min < target / 2) and math.min(S, M.MIN_TAKE)
                or math.min(amount, M.CALM_TAKE)
  local steps, how, got = fetch_steps(c, item, amount, least_mined, least,
                                      math.max(S, least), have, fills, b.bad,
                                      not Stores.can_be_had(cid, c, item))
  if not steps then
    b.short_until = game.tick + M.SHORT_HOLD_TICKS
    -- (a store holding enough is only left out after a failed take: no shortage --
    -- review: Python built pairs while coal stood there)
    if how == "left out" then return end
    -- (a drill of it stands, no store holds enough: no hand mining -- Zdendys
    -- 2026-11-09; more drills with chests are Python's to plan)
    b.supply_short = {item = item, short = S, tick = game.tick}
    log_once("supply", cid, item, SUPPLY_LOG_TICKS,
             string.format("[SUPPLY_SHORT] upkeep: short of %d %s (%.0f s left) and no "
                           .. "store within %d holds %d -- a drill of it stands, so no "
                           .. "hand mining: more drills with supply chests are needed",
                           S, item, t_min, M.SOURCE_RADIUS, least))
    return
  end
  local r = ledger.submit_task(cid, steps, "upkeep", p)
  if r.task_id then
    b.task_id, b.got = r.task_id, got
    -- (mining by hand -- no drill of it to be had: a shortage Python is told of too)
    if how == "mine" then b.mined = {item = item, short = S, tick = game.tick} end
    -- (every one logged: one at a time, a failed one held off -- rare)
    log(string.format("[ai-companion] upkeep: fetching %d %s (task %d, %s; short %d, "
                      .. "%.0f s left, p %.2f)", got, item, r.task_id, how, S, t_min, p))
  else
    u.log_error("upkeep: the fetch submit failed: " .. tostring(r.error), "upkeep")
  end
end

-- The material cid is supply short of, for the status (Python plans more drills with
-- chests): {item, short, tick} -- her fetch found no store while a drill of it can be
-- had (no hand mining) -- or {item, short, tick, mining = true} -- she mined it by hand
-- within SUPPLY_LOG_TICKS (no drill of it to be had); or nil.
function M.supply_short(cid)
  local b = storage.upkeep and storage.upkeep.fetch and storage.upkeep.fetch[cid]
  if not b then return nil end
  if b.supply_short then return b.supply_short end
  local m = b.mined
  if m and game.tick - m.tick < SUPPLY_LOG_TICKS then
    return {item = m.item, short = m.short, tick = m.tick, mining = true}
  end
  return nil
end

-- The shortage of cid dropped (the fuel upkeep's scan skipped the fetch: another task
-- waits for coal -- review: the last shortage stayed meanwhile).
function M.clear_short(cid)
  local b = storage.upkeep and storage.upkeep.fetch and storage.upkeep.fetch[cid]
  if b then b.supply_short, b.short_until = nil, nil end
end

-- The fetch task of cid for the status: {task_id, priority, how, count = the amount
-- fetched} or nil.
function M.status(cid)
  local b = storage.upkeep and storage.upkeep.fetch and storage.upkeep.fetch[cid]
  local t = b and b.task_id and storage.tasks[b.task_id]
  if not t or t.status ~= "active" then return nil end
  local s = t.steps[1]
  return {task_id = b.task_id, priority = t.priority, how = s and s.type, count = b.got}
end

-- Withdraw cid's fetch task (upkeep switched off), unless it is being acted on; an
-- ended one forgotten (also called for a companion whose upkeep is off -- review: its
-- ended task stayed until upkeep came on again).
function M.cancel(cid, acting)
  local b = storage.upkeep and storage.upkeep.fetch and storage.upkeep.fetch[cid]
  if not b or not b.task_id then return end
  local t = storage.tasks[b.task_id]
  if t and t.status == "active" and not acting(b.task_id) then
    ledger.cancel_task(b.task_id, "upkeep switched off")
    storage.tasks[b.task_id] = nil
    b.task_id = nil
  elseif not t or t.status ~= "active" then
    storage.tasks[b.task_id] = nil
    b.task_id = nil
  end
end

return M
