-- Nyara's own fuel upkeep (Zdendys's architecture, factorio-ai docs/architecture_roles.md):
-- the routine upkeep is the mod's, never the controller's. Python never says "this
-- furnace is hungry, put coal in" -- the mod knows it, and such a task rises in her
-- queue the less fuel the burner has left.
--
-- Every SCAN_TICKS, for each companion with upkeep on (/fac_upkeep <id> on), every
-- player burner (furnace, mining drill, boiler, burner inserter) within SCAN_RADIUS of
-- her:
-- - a burner inserter: one that picks up a fuel feeds itself (live: it keeps ~1 item)
--   and is left alone until it stands without fuel at two scans in a row (a drained
--   one never restarts by itself) -- then served by hand, named underfed; any other one
--   is served by its fuel time like an unfed burner (the rules below are the others');
-- - t = the seconds its fuel lasts at its full consumption (the burning fuel's energy
--   left + its fuel slot's); its target = min(TARGET_S, what a full slot lasts) (a
--   boiler's full slot lasts ~111 s); p = log2(target / max(1, t)) -- a production's
--   shortage in TIME left, the priority by its reciprocal (Zdendys);
-- - its output's fill lowers the part above 1: p' = 1 + (p - 1) x (1 - 0.9 x fill)
--   (products piling up need the supply less; a full output still leaves a little);
-- - a mined-out drill or a furnace with nothing to smelt needs no fuel now -- skipped;
-- - what feeds it (commands/upkeep_feeds.lua): a supply line of its own (an inserter
--   from a belt or a chest a fuel line fills, a fuel-mining drill -- a coal pair's
--   drills feed each other; an inserter from an ore belt or a plate buffer is none)
--   means it is not hers to serve by hand while one of its sources supplies it
--   (working, at low power too, or waiting for room in it -- an inserter keeps a
--   burner at 5 fuel items, a boiler's ~12 s, so its seconds left tell nothing) and its
--   fuel slot holds at least LINE_MIN_ITEMS (4); a supply line delivering nothing at
--   two scans in a row (an empty belt, a partner drill without fuel, a slot under 4)
--   makes it hers like an unfed one once its fuel lasts under LINE_DRY_S (a sparse
--   belt is slow, not dead), named underfed, logged once per UNDERFED_LOG_TICKS;
-- - a fuel chest an inserter feeds it from, supplied by nothing (Zdendys: she supplies
--   a production or a chest no belt with that material reaches yet), is what she fills:
--   once one of its burners runs down (it is that burner's nearest fuel chest), one need
--   for all the burners inserters from it feed: t = (the chest's fuel + theirs) over
--   their consumption together, target TARGET_S, the least output fill among them; a
--   burner of it under FED_DRY_S with no inserter from its chest supplying it at two
--   scans in a row is served by hand too (underfed when the chest has fuel: its
--   inserter does not deliver; one waiting only for the slot to empty -- the chest's
--   wood does not fit the slot's coal -- counts as supplying); a
--   chest with no room for coal or wood is full of fuel -- no need;
-- - p' > 1 makes an upkeep task: one fuel step at the burner (an insert step at a fuel
--   chest) -- a slot already holding another fuel (wood: no coal fits) topped up with
--   it from her surplus, else at a burner coal swapped in (the step moves the other
--   fuel into her inventory), else with it from all she holds unreserved; else with her
--   wood surplus (above WOOD_KEEP) wood where wood fits, the whole amount from her free
--   wood; else coal --, the coal to its
--   target (raised to MIN_BATCH, capped by the room and her free
--   coal above COAL_FLOOR; none when the free coal does not reach min(MIN_BATCH, the
--   room) -- "short"), priority p' (kept up to date each scan; the task pool's scheduler
--   ranks it with every other task's step by p' ^ (1 / (distance + 1)) -- it may come
--   between a build's steps).
-- At most MAX_TASKS upkeep tasks per companion, the highest p' (nearer first on a tie;
-- one is replaced only by a need REPLACE_MARGIN higher, so ties do not churn); none
-- with coal submitted while another task waits for coal (its need comes first). A task
-- no longer needed (and not being acted on) is cancelled quietly; ended upkeep tasks are removed
-- from storage.tasks (nothing polls them). Coal comes from her inventory (the
-- stopgap); burners she has no free coal for are listed as "short" in the status and
-- logged, and getting the coal is an action of its own (commands/upkeep_fetch.lua: a
-- coal store or mining, priority log2(short) + log2(T / t)).
local u = require("commands.init")
local ledger = require("commands.task_pool_ledger")
local F = require("commands.upkeep_feeds")
local Fetch = require("commands.upkeep_fetch")
local N = require("commands.upkeep_need")
local B = require("commands.upkeep_batch")
local Feed = require("commands.upkeep_feed")
local Stock = require("commands.upkeep_stock")
local Regs = require("commands.upkeep_feed_regs")

local M = {}

M.SCAN_TICKS = 120
M.SCAN_RADIUS = N.SCAN_RADIUS
M.TARGET_S = 300            -- the target stock, in seconds of a burner's consumption
M.MAX_TASKS = 3
M.FUEL = "coal"
M.MIN_BATCH = 5             -- coal per upkeep task at least (unless the room is less)
M.COAL_FLOOR = 10           -- free coal she keeps for the other tasks
M.WOOD = "wood"
-- wood she keeps for the builds (small poles); above it her wood is burned first -- the
-- controller's own wood stock cap (factorio-ai opening_targets RAW_MATERIAL_STOCK_CAPS)
M.WOOD_KEEP = 200
-- a chest-fed burner under this many seconds of fuel, no inserter from its chest
-- supplying it, is served by hand (a scan plus a walk to a far burner take that long --
-- review: 10 s let it run dry before she arrived)
M.FED_DRY_S = 30
-- a burner on a supply line delivering nothing is hers only under this many seconds of
-- fuel (upkeep_need.lua; a near build's steps still outrank a far upkeep task)
M.LINE_DRY_S = N.LINE_DRY_S
M.REPLACE_MARGIN = 0.5      -- a kept task is replaced only by a need this much higher
local UNDERFED_LOG_TICKS = N.UNDERFED_LOG_TICKS
-- (also how long upkeep_status.lua lists a burner as short)
M.SHORT_LOG_TICKS = 18000
local SHORT_LOG_TICKS = M.SHORT_LOG_TICKS
-- a burner whose upkeep task failed is left out this long, doubled while it repeats
local FAIL_BACKOFF_TICKS = 3600
-- (an inserter only with a burner: a burner inserter -- electric ones have none)
local BURNER_TYPES = {"furnace", "mining-drill", "boiler", "inserter"}

function M.init()
  -- storage.upkeep = {enabled = {[cid] = true}, tasks = {[cid] = {[key] = task_id}},
  --   last_scan = {[cid] = tick},
  --   backoff = {[cid] = {[key] = {until_tick, n failures in a row}}},
  --   down = {[cid] = {[key] = {first, last, path}: scan ticks its supply delivered
  --   nothing}} (made by the scan), fetch (commands/upkeep_fetch.lua),
  --   logs = {[book] = {[cid] = {[key] = tick logged}}} -- the books underfed, short,
  --   blocked (key "coal": another task waited for coal), noroom; under one table so a
  --   book's name can never be a state field's (review: a "fetch" book's pruning
  --   deleted the fetch task's id)}
  storage.upkeep = storage.upkeep or {}
  storage.upkeep.enabled = storage.upkeep.enabled or {}
  storage.upkeep.tasks = storage.upkeep.tasks or {}
  storage.upkeep.last_scan = storage.upkeep.last_scan or {}
  storage.upkeep.backoff = storage.upkeep.backoff or {}
  storage.upkeep.logs = storage.upkeep.logs or {}
  -- (the books of 0.16.154 and before, at the top level: dropped)
  storage.upkeep.underfed, storage.upkeep.short, storage.upkeep.blocked = nil, nil, nil
  -- (the feed's and the stock's books set up -- and migrated -- with it, before any
  -- status read: review)
  Feed.init()
  Stock.init()
  Regs.init()
end

local function key_of(e)
  return string.format("%.1f,%.1f", e.position.x, e.position.y)
end

-- (the need measures live in commands/upkeep_need.lua)
local NO_NEED = N.NO_NEED
local output_fill = N.output_fill

local function fuel_seconds(e)
  return N.fuel_seconds(e, M.FUEL)
end

-- A burner's upkeep need -- its own slot filled (upkeep_need.burner_need).
function M.burner_need(e)
  return N.burner_need(e, M.TARGET_S, M.FUEL)
end

local function chest_need(group)
  return N.chest_need(group, M.TARGET_S)
end

-- Whether another active task of the companion still waits for coal.
local function coal_wanted_elsewhere(cid)
  for _, t in pairs(storage.tasks) do
    if t.cid == cid and t.status == "active" and t.kind ~= "upkeep"
       and t.needs and (t.needs[M.FUEL] or 0) > 0 then
      return true
    end
  end
  return false
end

-- Log at most once per `every` ticks per burner key (book: storage.upkeep.logs[name][cid]).
local function log_once(name, cid, key, every, msg)
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

-- The log books' entries older than their interval dropped (review: one entry per key
-- ever logged stayed for the whole game).
-- (the feed's and the stock's books too: feed.LOG_BOOKS, stock.LOG_BOOKS -- review: they
-- were never pruned)
local LOG_BOOKS = {underfed = UNDERFED_LOG_TICKS, short = SHORT_LOG_TICKS,
                   blocked = SHORT_LOG_TICKS, noroom = SHORT_LOG_TICKS}
for _, part in pairs({Feed, Stock}) do
  for name, every in pairs(part.LOG_BOOKS) do LOG_BOOKS[name] = every end
end
local function prune_log_books(cid)
  local logs = storage.upkeep.logs or {}
  for name, every in pairs(LOG_BOOKS) do
    local book = logs[name] and logs[name][cid]
    for key, tick in pairs(book or {}) do
      if game.tick - tick >= every then book[key] = nil end
    end
  end
end

-- the error of a task that failed because she could not get to its burner
local UNREACHABLE = "could not reach"

-- Forget the ended tasks: their keys freed, removed from the pool (nothing polls
-- them); one that failed because she could not reach its burner holds that burner off
-- FAIL_BACKOFF_TICKS, doubled while it repeats -- review: otherwise the next scan sent
-- her straight back to it (another failure -- her coal taken meanwhile, the slot
-- filled by someone else -- holds nothing off: the next scan judges it afresh).
local function prune(cid, mine)
  storage.upkeep.backoff = storage.upkeep.backoff or {}
  storage.upkeep.backoff[cid] = storage.upkeep.backoff[cid] or {}
  local off = storage.upkeep.backoff[cid]
  for key, task_id in pairs(mine) do
    local t = storage.tasks[task_id]
    if not t or t.status ~= "active" then
      if t and t.status == "failed" and tostring(t.error):find(UNREACHABLE, 1, true) then
        local prev = off[key]
        local n = (prev and prev.n or 0) + 1
        local ticks = FAIL_BACKOFF_TICKS * 2 ^ math.min(n - 1, 4)
        off[key] = {until_tick = game.tick + ticks, n = n}
        -- (where she stands now: a walk that timed out is diagnosed from it -- the
        -- slow-line smoke's 28 timeouts at two furnaces could not be replayed)
        local c = u.get_companion(cid)
        local at = (c and c.entity and c.entity.valid)
                   and string.format("; she is at %.1f,%.1f", c.entity.position.x,
                                     c.entity.position.y) or ""
        log("[ai-companion] upkeep: the task at " .. key .. " failed (" ..
            tostring(t.error) .. ") -- held off " .. ticks .. " ticks" .. at)
      elseif t and t.status == "done" and off[key] then
        off[key] = nil                       -- served again: the back-off ends
      end
      mine[key] = nil
      storage.tasks[task_id] = nil
    end
  end
end

-- One companion's scan: the needs ranked, tasks kept / created / cancelled.
local function scan(cid, c)
  storage.upkeep.tasks[cid] = storage.upkeep.tasks[cid] or {}
  local mine = storage.upkeep.tasks[cid]
  prune(cid, mine)
  prune_log_books(cid)
  local off = storage.upkeep.backoff[cid]
  local pos = c.entity.position
  local needs = {}
  local function add(need, e)
    if need then
      need.e, need.key = e, key_of(e)
      need.dist = u.distance(pos, e.position)
      needs[#needs + 1] = need
    end
  end
  local function is_off(e)
    return off[key_of(e)] ~= nil and game.tick < off[key_of(e)].until_tick
  end
  -- a burner whose supply line delivers nothing: {[key] = {first, last scan ticks,
  -- path: "line" / "chest"}}
  storage.upkeep.down = storage.upkeep.down or {}
  storage.upkeep.down[cid] = storage.upkeep.down[cid] or {}
  local down = storage.upkeep.down[cid]
  for k, d in pairs(down) do
    if game.tick - d.last > M.SCAN_TICKS * 3 then down[k] = nil end   -- left the scan
  end
  -- Whether the burner's supply (path: its "line" or its fuel "chest") was down at this
  -- scan and the one before (a record older than the scan before, or of the other
  -- path, starts afresh -- review: a burner flipping between paths).
  local function down_twice(key, path)
    local d = down[key]
    if not d or d.path ~= path or game.tick - d.last > M.SCAN_TICKS * 3 / 2 then
      down[key] = {first = game.tick, last = game.tick, path = path}
      return false
    end
    d.last = game.tick
    return game.tick - d.first >= M.SCAN_TICKS
  end
  -- A burner inserter's need (live: one that picks up a fuel feeds itself from what it
  -- carries and keeps ~1 item -- the 4-item rule of the other burners would flag it
  -- forever; a fully drained one never restarts by itself, even with coal at its
  -- pickup): a self-fed one is left alone until it stands without fuel at two scans in
  -- a row, then served by hand (named underfed); any other one (it moves ore, plates or
  -- nothing) has no fuel feed -- served by its fuel time like an unfed burner.
  local function inserter_need(e)
    local key = key_of(e)
    if not F.inserter_self_fed(e) then
      if not is_off(e) then add(M.burner_need(e), e) end
    elseif e.status ~= defines.entity_status.no_fuel then
      down[key] = nil
    elseif not is_off(e) and down_twice(key, "self") then
      local need = M.burner_need(e)
      if need then
        log_once("underfed", cid, key, UNDERFED_LOG_TICKS,
                 string.format("[UNDERFED] %s at %s: it carries fuel yet stands without "
                               .. "fuel (drained -- it never restarts by itself) -- served "
                               .. "by hand", e.name, key))
      end
      add(need, e)
    end
  end
  -- the fuel chests to judge: {[chest key] = chest} (a burner's nearest fuel chest)
  local groups = {}
  for _, e in pairs(c.entity.surface.find_entities_filtered{
      position = pos, radius = M.SCAN_RADIUS, force = c.entity.force, type = BURNER_TYPES}) do
    -- (cheap first: a burner whose own fuel lasts TARGET_S / 2 needs nothing either way;
    -- one fed from a chest that still holds fuel keeps its slot topped up, so its chest
    -- is judged once its own fuel runs down)
    local own_t = e.valid and e.burner and not NO_NEED[e.status] and fuel_seconds(e)
    if own_t and own_t < M.TARGET_S / 2 and e.type == "inserter" then
      inserter_need(e)
    elseif own_t and own_t < M.TARGET_S / 2 then
      local f = F.feeds(e)
      if f.other then
        -- its supply line feeds it while one of its sources supplies (the insertion
        -- limit keeps only a few items in it -- a boiler's ~12 s); down at two scans in
        -- a row (a sparse belt's inserter waits now and then), it is hers like an
        -- unfed one, named underfed
        -- (a line delivering nothing while the burner still has LINE_DRY_S of fuel is a
        -- slow line, not a dead one -- the wood smoke: a sparse coal belt sent her to
        -- burners with 130 s of fuel 120 times; it is hers once its fuel runs low)
        if f.other_ok or own_t >= M.LINE_DRY_S then
          down[key_of(e)] = nil
        elseif not is_off(e) and down_twice(key_of(e), "line") then
          local need = M.burner_need(e)
          if need then
            log_once("underfed", cid, key_of(e), UNDERFED_LOG_TICKS,
                     string.format("[UNDERFED] %s at %s: its supply line delivers nothing "
                                   .. "(%s), %.0f s of fuel left -- served by hand",
                                   e.name, key_of(e), tostring(f.why), need.t))
          end
          add(need, e)
        end
      elseif #f.chests > 0 then
        local chest = f.chests[1]
        local ck = key_of(chest)
        groups[ck] = groups[ck] or chest
        -- running dry with no inserter from its chest supplying it at two scans in a row
        -- (review: one scan's blip made a task the next one cancelled): served by hand
        -- (review: the chest's need alone left it dry), named underfed when its chest
        -- has fuel to give (an inserter from a chest with fuel waits for room in it at
        -- the insertion limit -- a boiler's ~12 s: no rescue then)
        if f.chest_ok or own_t >= M.FED_DRY_S then
          down[key_of(e)] = nil
        elseif not is_off(e) and down_twice(key_of(e), "chest") then
          if F.inventory_fuel(chest.get_inventory(defines.inventory.chest)) > 0 then
            log_once("underfed", cid, key_of(e), UNDERFED_LOG_TICKS,
                     string.format("[UNDERFED] %s at %s: %.0f s of fuel left though its "
                                   .. "fuel chest at %s holds fuel -- its chest's inserter "
                                   .. "does not deliver (%s)", e.name, key_of(e), own_t, ck,
                                   tostring(f.chest_why)))
          end
          add(M.burner_need(e), e)
        end
      elseif not is_off(e) then
        add(M.burner_need(e), e)
      end
    end
  end
  -- each fuel chest one of whose burners ran down: one need for all the burners it
  -- feeds (review: the whole chest's burners, not only those under the cheap check);
  -- a chest with no room for coal or wood is full of fuel -- no need (review: serving
  -- its burners by hand then went to burners whose chest supplies them)
  for _, chest in pairs(groups) do
    local inv = chest.get_inventory(defines.inventory.chest)
    if inv and (inv.get_insertable_count(M.FUEL) > 0 or inv.get_insertable_count(M.WOOD) > 0)
       and not is_off(chest) then
      local g = {chest = chest, usage = 0, energy = 0, fill = 1}
      for _, b in ipairs(F.chest_burners(chest)) do
        local _, _, usage, energy = fuel_seconds(b)
        if usage and not NO_NEED[b.status] then
          g.usage, g.energy = g.usage + usage, g.energy + energy
          g.fill = math.min(g.fill, output_fill(b))
        end
      end
      if g.usage > 0 then add(chest_need(g), chest) end
    end
  end
  table.sort(needs, function(a, b)
    if a.p ~= b.p then return a.p > b.p end
    return a.dist < b.dist
  end)
  local by_key = {}
  for _, n in ipairs(needs) do by_key[n.key] = n end
  local active = storage.active_step and storage.active_step[cid]
  local function acting(task_id) return active and active.task_id == task_id end
  local inv = c.entity.get_main_inventory()
  local function free_coal()
    return inv.get_item_count(M.FUEL) - (storage.reserved[M.FUEL] or 0) - M.COAL_FLOOR
  end
  -- another task waiting for coal comes first: no new upkeep task with coal (logged
  -- once; review: wood takes it no coal)
  local blocked = coal_wanted_elsewhere(cid)
  if blocked and #needs > 0 then
    log_once("blocked", cid, "coal", SHORT_LOG_TICKS,
             "upkeep: another task waits for coal -- no new upkeep task with coal meanwhile")
  end
  -- What she may give of a fuel other than coal: wood above WOOD_KEEP (`keep` false:
  -- the keep too), any other all she holds unreserved; `extra` as in choose.
  local function free_other(item, extra, keep)
    local free = inv.get_item_count(item) - (storage.reserved[item] or 0) + (extra[item] or 0)
    if item == M.WOOD and keep then free = free - M.WOOD_KEEP end
    return free
  end
  -- The fuel an upkeep task for need n takes (`extra`: what a task about to be replaced
  -- would release, by item). A slot already holding another fuel (only that fits it --
  -- review: wood left to run dry): topped up with it from her surplus; else, at a burner,
  -- coal swapped in (the fuel step moves the other fuel into her inventory -- review:
  -- topping it up from the keep drained the wood the builds keep, the slot never going
  -- back to coal); else with it from all she holds unreserved, the keep too (no coal to
  -- swap in -- too little coal for what comes out, no room for it in her inventory --,
  -- or another task waits for coal -- a running burner before her wood stock).
  -- Else her wood surplus where it covers the need (Zdendys: wood is never kept in stock
  -- beyond what the builds need); else coal, unless another task waits for it.
  -- (item, amount, whether free coal is what limits it, swap)
  local function choose(n, extra)
    extra = extra or {}
    local held = B.held_fuel(M, n)
    if held then
      local amount = B.other(M, n, held, free_other(held, extra, true), true)
      if amount >= 1 or n.into then return held, amount, false, false end
      -- (a swap only when her inventory has room for what comes out -- review: else the
      -- step failed at every scan)
      local coal_n, coal_short = 0, false
      if not blocked and B.swap_fits(n, M.FUEL, inv) then
        coal_n, coal_short = B.coal(M, n, free_coal(), extra[M.FUEL], true)
      end
      if coal_n >= 1 then return M.FUEL, coal_n, false, true end
      amount = B.other(M, n, held, free_other(held, extra, false), true)
      return held, amount, amount < 1 and coal_short, false
    end
    local wood_n = B.other(M, n, M.WOOD, free_other(M.WOOD, extra, true), false)
    if wood_n >= 1 or blocked then return M.WOOD, wood_n, false, false end
    local amount, coal_short = B.coal(M, n, free_coal(), extra[M.FUEL])
    return M.FUEL, amount, coal_short, false
  end
  local function open_count()
    local k = 0
    for _ in pairs(mine) do k = k + 1 end
    return k
  end
  -- The weakest open task that may be replaced (not being acted on): key, its p.
  local function weakest()
    local wk, wp = nil, math.huge
    for key, task_id in pairs(mine) do
      local np = by_key[key] and by_key[key].p or 0
      if not acting(task_id) and np < wp then wk, wp = key, np end
    end
    return wk, wp
  end
  local function submit(n, amount, item, swap)
    -- a fuel chest is filled by an "insert" step, a burner by a "fuel" step (swap: its
    -- other fuel into her inventory first)
    local step = n.into and {type = "insert", x = n.into.position.x, y = n.into.position.y,
                             entity = n.into.name, item = item, count = amount}
                 or {type = "fuel", x = n.e.position.x, y = n.e.position.y, item = item,
                     count = amount, swap = swap or nil}
    local r = ledger.submit_task(cid, {step}, "upkeep", n.p)
    if r.task_id then
      mine[n.key] = r.task_id
    else
      u.log_error("upkeep: submit for " .. n.e.name .. " at " .. n.key .. " failed: "
                  .. tostring(r.error), "upkeep")
    end
  end
  -- the needs in rank order: a free slot takes the next one; with all MAX_TASKS slots
  -- open, a need replaces the weakest open task only when it is REPLACE_MARGIN higher
  -- AND can be submitted (its fuel, counting what the replaced task releases) --
  -- decided before anything is cancelled (review)
  -- the needs she has no free coal for (getting material, commands/upkeep_fetch.lua)
  local short = {}
  for _, n in ipairs(needs) do
    if not mine[n.key] then
      if open_count() < M.MAX_TASKS then
        local item, amount, coal_short, swap = choose(n)
        if amount >= 1 then
          submit(n, amount, item, swap)
        elseif coal_short then
          -- (a burner held by another fuel: what its swap needs -- review: a fetch of
          -- less never let the swap happen)
          local want, room = B.wanted(n.e, n, M.FUEL)
          local least = M.MIN_BATCH
          if room < 1 and not n.into then
            local out
            want, room, out = B.wanted_after_swap(M, n)
            least = out + M.MIN_BATCH
          end
          short[#short + 1] = {want = math.min(math.max(want, least), room), t = n.t}
          log_once("short", cid, n.key, SHORT_LOG_TICKS,
                   string.format("upkeep: no free coal for %s at %s (%.0f s of fuel "
                                 .. "left; %d free above the floor)", n.e.name, n.key,
                                 n.t, math.max(0, free_coal())))
        end
      else
        local wk, wp = weakest()
        if wk and n.p > wp + M.REPLACE_MARGIN then
          local old = storage.tasks[mine[wk]]
          local _, amount = choose(n, old and old.reserved)
          if amount >= 1 then
            ledger.cancel_task(mine[wk], "upkeep: replaced by a bigger need")
            storage.tasks[mine[wk]] = nil
            mine[wk] = nil
            local item, now, _, swap = choose(n)   -- (what it released now free)
            if now >= 1 then submit(n, now, item, swap) end
          end
        end
      end
    end
  end
  -- the open tasks: their priority kept up to date, those no longer needed cancelled
  for key, task_id in pairs(mine) do
    local t = storage.tasks[task_id]
    if by_key[key] and t then
      t.priority = by_key[key].p
    elseif not acting(task_id) then
      ledger.cancel_task(task_id, "upkeep: no longer needed")
      storage.tasks[task_id] = nil
      mine[key] = nil
    end
  end
  -- getting the coal she lacks (not while another task waits for coal: its own
  -- ensure_item gets it, and a fetch under way is not withdrawn meanwhile)
  if not blocked then
    local fills = {}
    for _, n in ipairs(needs) do
      if n.into then fills[n.key] = true end
    end
    Fetch.update(cid, c, M.FUEL, short, free_coal(), fills, acting, log_once, M.TARGET_S)
  end
  -- feeding the productions no belt feeds, keeping her stock (commands/upkeep_feed.lua,
  -- upkeep_stock.lua)
  Feed.scan(cid, c, acting, log_once)
  Stock.scan(cid, c, acting, log_once)
end

-- the upkeep's parts with task records of their own, by their storage.upkeep book
local PARTS = {feed = Feed, stock = Stock}

-- The tick handler (control.lua's on_nth_tick(5), after the task pool's own tick so
-- its reservations come first): each enabled companion's scan every SCAN_TICKS.
-- Reads game.tick itself (guard_tick calls it with no argument).
function M.tick()
  if not storage.upkeep then return end
  local now = game.tick
  -- switched off while one of its tasks was being acted on: that task's record is
  -- cleared once it ended (review: it stayed until upkeep came on again)
  for cid, mine in pairs(storage.upkeep.tasks) do
    if not storage.upkeep.enabled[cid] and next(mine) then prune(cid, mine) end
  end
  -- (the feed's and the stock's records likewise -- review)
  for name, part in pairs(PARTS) do
    local book = storage.upkeep[name]
    for cid in pairs((book and book.tasks) or {}) do
      if not storage.upkeep.enabled[cid] and part.has_tasks(cid) then
        local active = storage.active_step and storage.active_step[cid]
        part.stop(cid, function(task_id) return active and active.task_id == task_id end)
      end
    end
  end
  for cid, b in pairs(storage.upkeep.fetch or {}) do
    if not storage.upkeep.enabled[cid] and b.task_id then
      local active = storage.active_step and storage.active_step[cid]
      Fetch.cancel(cid, function(task_id) return active and active.task_id == task_id end)
    end
  end
  for cid, on in pairs(storage.upkeep.enabled) do
    if on then
      local c = u.get_companion(cid)
      if c and c.entity and c.entity.valid then
        local last = storage.upkeep.last_scan[cid] or -M.SCAN_TICKS
        if now - last >= M.SCAN_TICKS then
          storage.upkeep.last_scan[cid] = now
          scan(cid, c)
        end
      end
    end
  end
end

-- Switch a companion's upkeep on or off (off cancels its open upkeep tasks not being
-- acted on and forgets the ended ones).
function M.set_enabled(cid, on)
  M.init()
  storage.upkeep.enabled[cid] = on or nil
  -- (a loop of the controller's that loaded furnaces itself never outlives a run --
  -- upkeep_feed_regs.lua "loading", hers only)
  Regs.drop_loading(cid)
  if not on then
    -- (its books are not left to grow while it is off -- review)
    if storage.upkeep.down then storage.upkeep.down[cid] = nil end
    prune_log_books(cid)
    local active = storage.active_step and storage.active_step[cid]
    Fetch.cancel(cid, function(task_id) return active and active.task_id == task_id end)
    Feed.stop(cid, function(task_id) return active and active.task_id == task_id end)
    Stock.stop(cid, function(task_id) return active and active.task_id == task_id end)
    for key, task_id in pairs(storage.upkeep.tasks[cid] or {}) do
      local t = storage.tasks[task_id]
      if t and t.status == "active" and not (active and active.task_id == task_id) then
        ledger.cancel_task(task_id, "upkeep switched off")
        storage.tasks[task_id] = nil
        storage.upkeep.tasks[cid][key] = nil
      elseif not t or t.status ~= "active" then
        storage.tasks[task_id] = nil
        storage.upkeep.tasks[cid][key] = nil
      end
    end
  end
end

-- (its state for a reply: commands/upkeep_status.lua)
return M
