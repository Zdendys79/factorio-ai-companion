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
-- - an inserter dropping into it (a belt / chest + inserter supply), or a mining drill
--   (a coal pair's drills feed each other), means it is not hers to serve by hand --
--   unless it runs dry all the same (t under FED_DRY_S): then
--   it is served and named underfed (its supply line is short), logged once per
--   UNDERFED_LOG_TICKS;
-- - p' > 1 makes an upkeep task: one fuel step at it, the coal to its target (raised to
--   MIN_BATCH, capped by the slot's room and her free coal above COAL_FLOOR; none when
--   the free coal does not reach min(MIN_BATCH, the room) -- "short"), priority p' (kept
--   up to date each scan; the task pool's scheduler
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

local M = {}

M.SCAN_TICKS = 120
M.SCAN_RADIUS = 150
M.TARGET_S = 300            -- the target stock, in seconds of a burner's consumption
M.MAX_TASKS = 3
M.FUEL = "coal"
M.MIN_BATCH = 5             -- coal per upkeep task at least (unless the room is less)
M.COAL_FLOOR = 10           -- free coal she keeps for the other tasks
-- a fed burner under this many seconds of fuel is served (a scan plus a walk to a far
-- burner take that long -- review: 10 s let it run dry before she arrived)
M.FED_DRY_S = 30
M.REPLACE_MARGIN = 0.5      -- a kept task is replaced only by a need this much higher
local UNDERFED_LOG_TICKS = 18000
local SHORT_LOG_TICKS = 18000
-- a burner whose upkeep task failed is left out this long, doubled while it repeats
local FAIL_BACKOFF_TICKS = 3600
-- an inserter / a drill whose drop position lies within this many tiles of a burner's
-- box counts as feeding it
local FEED_MARGIN = 0.3
local BURNER_TYPES = {"furnace", "mining-drill", "boiler"}

function M.init()
  -- storage.upkeep = {enabled = {[cid] = true}, tasks = {[cid] = {[key] = task_id}},
  --   last_scan = {[cid] = tick}, underfed = {[cid] = {[key] = tick logged}},
  --   short = {[cid] = {[key] = tick logged}},
  --   backoff = {[cid] = {[key] = {until_tick, n failures in a row}}},
  --   blocked = {[cid] = {coal = tick logged: another task waited for coal}}}
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

-- Whether a mining drill mines a fuel (its resource's product has a fuel value): a coal
-- drill dropping into a burner feeds its fuel, an iron drill dropping into a furnace
-- only its ore.
local function mines_fuel(drill)
  local res = drill.mining_target
  local mineable = res and res.valid and res.prototype.mineable_properties
  for _, product in pairs((mineable and mineable.products) or {}) do
    local proto = product.type == "item" and prototypes.item[product.name]
    if proto and (proto.fuel_value or 0) > 0 then return true end
  end
  return false
end

-- Whether something drops fuel into the entity: an inserter (its supply by belt or
-- chest -- what it carries is not known here; one that leaves it dry all the same is
-- caught by FED_DRY_S) or a mining drill mining a fuel (live: a coal pair's drills
-- feed each other -- an emptied one had its fuel back from its partner before any
-- task; an iron drill's ore into a furnace is no fuel).
local function fed(e)
  local box = e.bounding_box
  local area = {{box.left_top.x - 3, box.left_top.y - 3},
                {box.right_bottom.x + 3, box.right_bottom.y + 3}}
  for _, src in pairs(e.surface.find_entities_filtered{area = area,
                                                       type = {"inserter", "mining-drill"}}) do
    if src ~= e and (src.type == "inserter" or mines_fuel(src)) then
      local d = src.drop_position
      if d and d.x >= box.left_top.x - FEED_MARGIN and d.x <= box.right_bottom.x + FEED_MARGIN
         and d.y >= box.left_top.y - FEED_MARGIN
         and d.y <= box.right_bottom.y + FEED_MARGIN then
        return true
      end
    end
  end
  return false
end

-- (seconds the fuel lasts, seconds a full slot would last, joules per tick) at full
-- consumption; nil when not measurable.
local function fuel_seconds(e)
  local burner = e.burner
  if not burner or not burner.inventory then return nil end
  local usage = e.prototype.get_max_energy_usage(e.quality)   -- joules per tick
  if not usage or usage <= 0 then return nil end
  local energy = burner.remaining_burning_fuel or 0
  for _, item in pairs(burner.inventory.get_contents()) do
    local proto = prototypes.item[item.name]
    energy = energy + (proto and proto.fuel_value or 0) * item.count
  end
  local coal = prototypes.item[M.FUEL]
  local room = burner.inventory.get_insertable_count(M.FUEL)
  local full = energy + room * ((coal and coal.fuel_value) or 0)
  return energy / (usage * 60), full / (usage * 60), usage
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

-- A burner's upkeep need: {p, t, target, usage, fill}, or nil (no task: not
-- measurable, needing no fuel now, or not short).
function M.burner_need(e)
  if NO_NEED[e.status] then return nil end
  local t, full, usage = fuel_seconds(e)
  if not t then return nil end
  local target = math.min(M.TARGET_S, full)
  if target <= 1 then return nil end
  local p = math.log(target / math.max(1, t), 2)
  if p <= 1 then return nil end
  local fill = output_fill(e)
  return {p = 1 + (p - 1) * (1 - 0.9 * fill), t = t, target = target, usage = usage,
          fill = fill}
end

-- Coal to the burner's target, capped by its slot's room.
local function coal_wanted(e, need)
  local proto = prototypes.item[M.FUEL]
  if not proto or not proto.fuel_value or proto.fuel_value <= 0 then return 0, 0 end
  local missing_j = math.max(0, (need.target - need.t) * need.usage * 60)
  local room = e.burner.inventory.get_insertable_count(M.FUEL)
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

-- The coal an upkeep task for need n would take: the amount wanted raised to MIN_BATCH,
-- capped by the slot's room and the free coal (`extra`: coal a task about to be
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
  local off = storage.upkeep.backoff[cid]
  local pos = c.entity.position
  local needs = {}
  for _, e in pairs(c.entity.surface.find_entities_filtered{
      position = pos, radius = M.SCAN_RADIUS, force = c.entity.force, type = BURNER_TYPES}) do
    local held_off = e.valid and off[key_of(e)] and game.tick < off[key_of(e)].until_tick
    if e.valid and e.burner and not held_off then
      local need = M.burner_need(e)
      if need then
        local is_fed = fed(e)
        if is_fed and need.t >= M.FED_DRY_S then
          need = nil                         -- its supply line feeds it
        elseif is_fed then
          log_once("underfed", cid, key_of(e), UNDERFED_LOG_TICKS,
                   string.format("[UNDERFED] %s at %s: fed by an inserter / a drill yet "
                                 .. "%.0f s of fuel left -- its supply is short", e.name,
                                 key_of(e), need.t))
        end
      end
      if need then
        need.e, need.key = e, key_of(e)
        need.dist = u.distance(pos, e.position)
        needs[#needs + 1] = need
      end
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
    local r = ledger.submit_task(cid, {{type = "fuel", x = n.e.position.x,
                                        y = n.e.position.y, item = M.FUEL,
                                        count = amount}}, "upkeep", n.p)
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
      out.tasks[#out.tasks + 1] = {key = key, task_id = task_id, status = t.status,
                                   priority = t.priority}
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
