-- Nyara's own fuel upkeep (Zdendys's architecture, factorio-ai docs/architecture_roles.md):
-- the routine upkeep is the mod's, never the controller's. Python never says "this
-- furnace is hungry, put coal in" -- the mod knows it, and such a task rises in her
-- queue the less fuel the burner has left.
--
-- Every SCAN_TICKS, for each companion with upkeep on (/fac_upkeep <id> on), every
-- player burner (furnace, mining drill, boiler) within SCAN_RADIUS of her:
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
--   makes it hers like an unfed one, named underfed, logged once per
--   UNDERFED_LOG_TICKS;
-- - a fuel chest an inserter feeds it from, supplied by nothing (Zdendys: she supplies
--   a production or a chest no belt with that material reaches yet), is what she fills:
--   once one of its burners runs down (it is that burner's nearest fuel chest), one need
--   for all the burners inserters from it feed: t = (the chest's fuel + theirs) over
--   their consumption together, target TARGET_S, the least output fill among them; a
--   burner of it under FED_DRY_S with no inserter from its chest supplying it at two
--   scans in a row is served by hand too (underfed when the chest has fuel: its
--   inserter does not deliver); a
--   chest with no room for coal is full of fuel -- no need;
-- - p' > 1 makes an upkeep task: one fuel step at the burner (an insert step at a fuel
--   chest), the coal to its target (raised to MIN_BATCH, capped by the room and her free
--   coal above COAL_FLOOR; none when the free coal does not reach min(MIN_BATCH, the
--   room) -- "short"), priority p' (kept up to date each scan; the task pool's scheduler
--   ranks it with every other task's step by p' ^ (1 / (distance + 1)) -- it may come
--   between a build's steps).
-- At most MAX_TASKS upkeep tasks per companion, the highest p' (nearer first on a tie;
-- one is replaced only by a need REPLACE_MARGIN higher, so ties do not churn); none
-- submitted while another task waits for coal (its need comes first). A task no longer
-- needed (and not being acted on) is cancelled quietly; ended upkeep tasks are removed
-- from storage.tasks (nothing polls them). Coal comes from her inventory only (the
-- stopgap; getting material is a later action of its own) -- burners she has no coal
-- for are listed as "short" in the status and logged.
local u = require("commands.init")
local ledger = require("commands.task_pool_ledger")
local F = require("commands.upkeep_feeds")

local M = {}

M.SCAN_TICKS = 120
M.SCAN_RADIUS = 150
M.TARGET_S = 300            -- the target stock, in seconds of a burner's consumption
M.MAX_TASKS = 3
M.FUEL = "coal"
M.MIN_BATCH = 5             -- coal per upkeep task at least (unless the room is less)
M.COAL_FLOOR = 10           -- free coal she keeps for the other tasks
-- a chest-fed burner under this many seconds of fuel, no inserter from its chest
-- supplying it, is served by hand (a scan plus a walk to a far burner take that long --
-- review: 10 s let it run dry before she arrived)
M.FED_DRY_S = 30
M.REPLACE_MARGIN = 0.5      -- a kept task is replaced only by a need this much higher
local UNDERFED_LOG_TICKS = 18000
local SHORT_LOG_TICKS = 18000
-- a burner whose upkeep task failed is left out this long, doubled while it repeats
local FAIL_BACKOFF_TICKS = 3600
local BURNER_TYPES = {"furnace", "mining-drill", "boiler"}

function M.init()
  -- storage.upkeep = {enabled = {[cid] = true}, tasks = {[cid] = {[key] = task_id}},
  --   last_scan = {[cid] = tick}, underfed = {[cid] = {[key] = tick logged}},
  --   short = {[cid] = {[key] = tick logged}},
  --   backoff = {[cid] = {[key] = {until_tick, n failures in a row}}},
  --   blocked = {[cid] = {coal = tick logged: another task waited for coal}},
  --   down = {[cid] = {[key] = {first, last}: scan ticks its supply line delivered
  --   nothing}} (made by the scan)}
  storage.upkeep = storage.upkeep or {}
  storage.upkeep.enabled = storage.upkeep.enabled or {}
  storage.upkeep.tasks = storage.upkeep.tasks or {}
  storage.upkeep.last_scan = storage.upkeep.last_scan or {}
  storage.upkeep.underfed = storage.upkeep.underfed or {}
  storage.upkeep.short = storage.upkeep.short or {}
  storage.upkeep.backoff = storage.upkeep.backoff or {}
  storage.upkeep.blocked = storage.upkeep.blocked or {}
end

local function key_of(e)
  return string.format("%.1f,%.1f", e.position.x, e.position.y)
end

-- (seconds its fuel lasts, seconds a full slot would last, joules per tick, the joules
-- it holds) at full consumption; nil when not measurable.
local function fuel_seconds(e)
  local burner = e.burner
  if not burner or not burner.inventory then return nil end
  local usage = e.prototype.get_max_energy_usage(e.quality)   -- joules per tick
  if not usage or usage <= 0 then return nil end
  local energy = (burner.remaining_burning_fuel or 0) + F.inventory_fuel(burner.inventory)
  local coal = prototypes.item[M.FUEL]
  local room = burner.inventory.get_insertable_count(M.FUEL)
  local full = energy + room * ((coal and coal.fuel_value) or 0)
  return energy / (usage * 60), full / (usage * 60), usage, energy
end

-- Its output's fill, 0 .. 1 (products piling up -- nothing takes them off).
local function output_fill(e)
  local s = e.status
  if s == defines.entity_status.full_output
     or s == defines.entity_status.waiting_for_space_in_destination then
    return 1
  end
  if e.type == "furnace" then
    local out = e.get_inventory(defines.inventory.crafter_output)
    if out and #out > 0 then
      local fill = 0
      for _, item in pairs(out.get_contents()) do
        local proto = prototypes.item[item.name]
        local stack = proto and proto.stack_size or 50
        fill = math.max(fill, item.count / stack)
      end
      return math.min(1, fill)
    end
  end
  return 0
end

-- statuses in which a burner needs no fuel now (a mined-out drill, nothing to smelt)
local NO_NEED = {[defines.entity_status.no_minable_resources] = true,
                 [defines.entity_status.no_ingredients] = true}

-- The priority of a need from its time left and target, lowered by an output's fill
-- (nil: not short).
local function priority_of(t, target, fill)
  if target <= 1 then return nil end
  local p = math.log(target / math.max(1, t), 2)
  if p <= 1 then return nil end
  return 1 + (p - 1) * (1 - 0.9 * fill)
end

-- A burner's upkeep need -- its own slot filled: {p, t, target, usage, fill}, or nil
-- (no task: not measurable, needing no fuel now, or not short).
function M.burner_need(e)
  if NO_NEED[e.status] then return nil end
  local t, full, usage = fuel_seconds(e)
  if not t then return nil end
  local target = math.min(M.TARGET_S, full)
  local fill = output_fill(e)
  local p = priority_of(t, target, fill)
  if not p then return nil end
  return {p = p, t = t, target = target, usage = usage, fill = fill}
end

-- A fuel chest's need for the burners it feeds (group: {chest, usage = their joules per
-- tick together, energy = the joules they hold, fill = the least output fill among
-- them}) -- the chest's fuel and theirs over their consumption together (review: each
-- burner counting the whole chest as its own overrated it N times), no slot cap (the
-- chest is filled): {p, t, target, usage, fill, into = the chest}, or nil.
local function chest_need(group)
  local chest = group.chest
  local energy = group.energy + F.inventory_fuel(chest.get_inventory(defines.inventory.chest))
  local t = energy / (group.usage * 60)
  local p = priority_of(t, M.TARGET_S, group.fill)
  if not p then return nil end
  return {p = p, t = t, target = M.TARGET_S, usage = group.usage, fill = group.fill,
          into = chest}
end

-- The inventory an upkeep task fills: the fuel chest (need.into) or the burner's slot.
local function target_inventory(e, need)
  if need.into then return need.into.get_inventory(defines.inventory.chest) end
  return e.burner.inventory
end

-- Coal to the target, capped by the room of what is filled.
local function coal_wanted(e, need)
  local proto = prototypes.item[M.FUEL]
  if not proto or not proto.fuel_value or proto.fuel_value <= 0 then return 0, 0 end
  local missing_j = math.max(0, (need.target - need.t) * need.usage * 60)
  local inv = target_inventory(e, need)
  local room = inv and inv.get_insertable_count(M.FUEL) or 0
  return math.min(math.ceil(missing_j / proto.fuel_value), room), room
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

-- Log at most once per `every` ticks per burner key (book: storage.upkeep[name][cid]).
local function log_once(name, cid, key, every, msg)
  storage.upkeep[name] = storage.upkeep[name] or {}
  local book = storage.upkeep[name]
  book[cid] = book[cid] or {}
  local last = book[cid][key]
  if not last or game.tick - last >= every then
    book[cid][key] = game.tick
    log("[ai-companion] " .. msg)
  end
end

-- The log books' entries older than their interval dropped (review: one entry per key
-- ever logged stayed for the whole game).
local LOG_BOOKS = {underfed = UNDERFED_LOG_TICKS, short = SHORT_LOG_TICKS,
                   blocked = SHORT_LOG_TICKS}
local function prune_log_books(cid)
  for name, every in pairs(LOG_BOOKS) do
    local book = storage.upkeep[name] and storage.upkeep[name][cid]
    for key, tick in pairs(book or {}) do
      if game.tick - tick >= every then book[key] = nil end
    end
  end
end

-- The coal an upkeep task for need n would take: the amount wanted raised to MIN_BATCH,
-- capped by the room of what is filled and the free coal (`extra`: coal a task about to be
-- replaced would release) -- 0 when the free coal does not reach min(MIN_BATCH, the
-- room) (review: she walked far to hand over 1 coal). (amount, whether free coal is
-- what limits it)
local function batch(n, free, extra)
  local want, room = coal_wanted(n.e, n)
  local amount = math.min(math.max(want, M.MIN_BATCH), room)
  local avail = math.max(0, free + (extra or 0))
  local take = math.min(amount, avail)
  if take < math.min(M.MIN_BATCH, room) then return 0, avail < amount end
  return take, avail < amount
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
        log("[ai-companion] upkeep: the task at " .. key .. " failed (" ..
            tostring(t.error) .. ") -- held off " .. ticks .. " ticks")
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
  -- the fuel chests to judge: {[chest key] = chest} (a burner's nearest fuel chest)
  local groups = {}
  for _, e in pairs(c.entity.surface.find_entities_filtered{
      position = pos, radius = M.SCAN_RADIUS, force = c.entity.force, type = BURNER_TYPES}) do
    -- (cheap first: a burner whose own fuel lasts TARGET_S / 2 needs nothing either way;
    -- one fed from a chest that still holds fuel keeps its slot topped up, so its chest
    -- is judged once its own fuel runs down)
    local own_t = e.valid and e.burner and not NO_NEED[e.status] and fuel_seconds(e)
    if own_t and own_t < M.TARGET_S / 2 then
      local f = F.feeds(e)
      if f.other then
        -- its supply line feeds it while one of its sources supplies (the insertion
        -- limit keeps only a few items in it -- a boiler's ~12 s); down at two scans in
        -- a row (a sparse belt's inserter waits now and then), it is hers like an
        -- unfed one, named underfed
        if f.other_ok then
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
  -- a chest with no room for coal is full of fuel -- no need (review: serving its
  -- burners by hand then went to burners whose chest supplies them)
  for _, chest in pairs(groups) do
    local inv = chest.get_inventory(defines.inventory.chest)
    if inv and inv.get_insertable_count(M.FUEL) > 0 and not is_off(chest) then
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
  -- another task waiting for coal comes first: no new upkeep task (logged once)
  local blocked = coal_wanted_elsewhere(cid)
  if blocked and #needs > 0 then
    log_once("blocked", cid, "coal", SHORT_LOG_TICKS,
             "upkeep: another task waits for coal -- no new upkeep task meanwhile")
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
  local function submit(n, amount)
    -- a fuel chest is filled by an "insert" step, a burner by a "fuel" step
    local step = n.into and {type = "insert", x = n.into.position.x, y = n.into.position.y,
                             entity = n.into.name, item = M.FUEL, count = amount}
                 or {type = "fuel", x = n.e.position.x, y = n.e.position.y, item = M.FUEL,
                     count = amount}
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
  -- AND can be submitted (its coal, counting what the replaced task releases) --
  -- decided before anything is cancelled (review)
  if not blocked then
    for _, n in ipairs(needs) do
      if not mine[n.key] then
        if open_count() < M.MAX_TASKS then
          local amount, coal_short = batch(n, free_coal())
          if amount >= 1 then
            submit(n, amount)
          elseif coal_short then
            log_once("short", cid, n.key, SHORT_LOG_TICKS,
                     string.format("upkeep: no free coal for %s at %s (%.0f s of fuel "
                                   .. "left; %d free above the floor)", n.e.name, n.key,
                                   n.t, math.max(0, free_coal())))
          end
        else
          local wk, wp = weakest()
          if wk and n.p > wp + M.REPLACE_MARGIN then
            local old = storage.tasks[mine[wk]]
            local releases = old and old.reserved and old.reserved[M.FUEL] or 0
            local amount = batch(n, free_coal(), releases)
            if amount >= 1 then
              ledger.cancel_task(mine[wk], "upkeep: replaced by a bigger need")
              storage.tasks[mine[wk]] = nil
              mine[wk] = nil
              local now_free = batch(n, free_coal())   -- (its first value only)
              if now_free >= 1 then submit(n, math.min(amount, now_free)) end
            end
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
end

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
  if not on then
    -- (its books are not left to grow while it is off -- review)
    if storage.upkeep.down then storage.upkeep.down[cid] = nil end
    prune_log_books(cid)
    local active = storage.active_step and storage.active_step[cid]
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

-- A companion's upkeep state for a reply: enabled, its open upkeep tasks, and the
-- burners she had no free coal for (logged ticks).
function M.status(cid)
  local up = storage.upkeep or {}
  local out = {enabled = (up.enabled and up.enabled[cid]) or false, tasks = {}, short = {}}
  for key, task_id in pairs((up.tasks and up.tasks[cid]) or {}) do
    local t = storage.tasks[task_id]
    if t and t.status == "active" then
      -- fills: what the task fills -- the burner's slot ("fuel") or a fuel chest
      -- ("insert"), at "x,y"
      local s = t.steps and t.steps[1]
      out.tasks[#out.tasks + 1] = {key = key, task_id = task_id, status = t.status,
                                   priority = t.priority, fills = s and s.type,
                                   at = s and string.format("%.1f,%.1f", s.x, s.y)}
    end
  end
  for key, tick in pairs((up.short and up.short[cid]) or {}) do
    if game.tick - tick < SHORT_LOG_TICKS then out.short[#out.short + 1] = key end
  end
  -- another task waited for coal lately (no new upkeep task then)
  local blocked = up.blocked and up.blocked[cid] and up.blocked[cid].coal
  out.blocked_by_coal_wait = blocked ~= nil and game.tick - blocked < SHORT_LOG_TICKS
  return out
end

return M
