-- Getting material for the fuel upkeep (Zdendys: when she lacks the material to supply
-- a production or a chest no belt with it reaches yet, getting it is an action of its
-- own; its priority grows with the shortage in her inventory and in the production and
-- falls with the distance to the source that covers it). Called by commands/upkeep.lua's
-- scan with the needs she had no free coal for.
--
-- - p = log2(S) + log2(T / max(1, t)), T the upkeep's TARGET_S: S = the coal those
--   needs want beyond her free coal (at least 1 -- "missing" is never zero), t = the
--   least time left among them; the task pool's scheduler then raises it by nearness to
--   the source (p ^ (1 / (distance + 1))).
-- - The source: the nearest coal store within SOURCE_RADIUS of her -- a plain chest
--   holding coal that no inserter picks from (a chest that feeds a machine is the
--   machine's) and that is not one of the fuel chests the upkeep fills -- holding at
--   least min(S, MIN_TAKE), taken by a "take" step; else she mines it by hand (an
--   ensure_item step, the nearest patch: no_pull -- no chest near her is emptied
--   first -- and raw -- the target counts all the coal she holds, so reservations made
--   while she mines do not move it). A store, even a far one, comes before mining: a
--   walk of 150 tiles takes ~20 s, mining 100 coal by hand ~200 s. Belts are left
--   alone: they carry coal to the production.
-- - She fetches up to STOCK coal (the fuel range: two stacks), at least S, capped by her
--   inventory room -- from a store; mining, at most max(min(the most urgent need's
--   coal, MINE_CHUNK) + what keeps her coal floor, MINE_CHUNK) at a time (the burners'
--   tasks wait while she mines). No new fetch while one of her open upkeep tasks holds
--   coal reserved and the scheduler would pick it before the fetch (its effective
--   priority from where she stands at least the fetch's p): that delivery comes first.
-- - One fetch task per companion (kind "upkeep"); its priority kept up to date while
--   she is short; withdrawn (unless being acted on) once she is not. A failed take
--   leaves its store out BAD_STORE_TICKS (the next fetch goes to another store or to
--   mining); a failed mining holds fetching off FAIL_BACKOFF_TICKS.
local u = require("commands.init")
local ledger = require("commands.task_pool_ledger")
local priority = require("commands.priority")
local F = require("commands.upkeep_feeds")

local M = {}

M.STOCK = 100              -- coal she fetches up to (the fuel range's two stacks)
-- coal she mines by hand in one fetch at most (unless more is short): ~50 s of hand
-- mining -- the burners' tasks wait while she mines (a smoke: 80-100 coal, ~200 s, the
-- tasks waiting); a next fetch follows while she is still short
M.MINE_CHUNK = 25
M.MIN_TAKE = 5             -- a store holding less than min(S, this) is passed over
M.SOURCE_RADIUS = 150
local FAIL_BACKOFF_TICKS = 3600
local BAD_STORE_TICKS = 18000
local STORE_TYPES = {"container"}   -- plain chests (logistic chests are the robots')

local function key_of(e)
  return string.format("%.1f,%.1f", e.position.x, e.position.y)
end

-- storage.upkeep.fetch = {[cid] = {task_id = id or nil, off_until = tick or nil,
--   bad = {[store key] = tick until it is left out}}}
local function book(cid)
  storage.upkeep.fetch = storage.upkeep.fetch or {}
  storage.upkeep.fetch[cid] = storage.upkeep.fetch[cid] or {}
  local b = storage.upkeep.fetch[cid]
  b.bad = b.bad or {}
  return b
end

-- The nearest coal store within SOURCE_RADIUS of her holding at least `least` coal
-- (`fills`: the keys of the fuel chests the upkeep fills, `bad`: stores a take failed
-- at -- never a source), or nil.
local function nearest_store(c, item, least, fills, bad)
  local pos = c.entity.position
  local best, bd = nil, math.huge
  for _, chest in pairs(c.entity.surface.find_entities_filtered{
      position = pos, radius = M.SOURCE_RADIUS, type = STORE_TYPES, force = c.entity.force}) do
    if chest.valid and chest.get_item_count(item) >= least then
      local key = key_of(chest)
      local d = u.distance(pos, chest.position)
      if d < bd and not fills[key] and not (bad[key] and game.tick < bad[key])
         and not F.picked_from(chest) then
        best, bd = chest, d
      end
    end
  end
  return best
end

-- The fetch task's steps for `amount` of `item` (she holds `have`): a take at the
-- nearest store, else mining to hold `have + mined` -- `mined` = min(amount,
-- max(least_mined, MINE_CHUNK)); and how ("take at x,y" / "mine"), and the amount
-- fetched.
local function fetch_steps(c, item, amount, least_mined, least, have, fills, bad)
  local store = nearest_store(c, item, least, fills, bad)
  if store then
    return {{type = "take", x = store.position.x, y = store.position.y, store = true,
             entity = store.name, item = item, count = amount}}, "take at " .. key_of(store),
           amount
  end
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
      b.bad[string.format("%.1f,%.1f", s.x, s.y)] = game.tick + BAD_STORE_TICKS
      log(string.format("[ai-companion] upkeep: taking %s at %.1f,%.1f failed (%s) -- "
                        .. "that store is left out %d ticks", item, s.x, s.y,
                        tostring(t.error), BAD_STORE_TICKS))
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
-- short: the needs she had no free coal for ({want = coal wanted, t = seconds left});
-- free: her free coal above the floor (may be negative); fills: the keys of the fuel
-- chests among the needs; acting(task_id): whether that task's step is being acted on;
-- log_once: the upkeep's logger; target_s: the upkeep's target stock in seconds (T).
-- Returns nothing.
function M.update(cid, c, item, short, free, fills, acting, log_once, target_s)
  local b = book(cid)
  forget_ended(b, item)
  local t = b.task_id and storage.tasks[b.task_id]
  if #short == 0 then
    if t and not acting(b.task_id) then           -- not short any more
      ledger.cancel_task(b.task_id, "upkeep: no longer short of " .. item)
      storage.tasks[b.task_id] = nil
      b.task_id = nil
    end
    return
  end
  local want, t_min, urgent = 0, math.huge, 0
  for _, n in ipairs(short) do
    want = want + n.want
    if n.t < t_min then t_min, urgent = n.t, n.want end
  end
  local S = math.max(1, want - math.max(0, free))
  local p = math.log(S, 2) + math.log(target_s / math.max(1, t_min), 2)
  if t then
    t.priority = p
    return
  end
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
  local steps, how, got = fetch_steps(c, item, amount, least_mined, math.min(S, M.MIN_TAKE),
                                      have, fills, b.bad)
  local r = ledger.submit_task(cid, steps, "upkeep", p)
  if r.task_id then
    b.task_id, b.got = r.task_id, got
    -- (every one logged: one at a time, a failed one held off -- rare)
    log(string.format("[ai-companion] upkeep: fetching %d %s (task %d, %s; short %d, "
                      .. "%.0f s left, p %.2f)", got, item, r.task_id, how, S, t_min, p))
  else
    u.log_error("upkeep: the fetch submit failed: " .. tostring(r.error), "upkeep")
  end
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
