-- AI Companion -- generic task pool (2026-07-07, Zdendys's redesign)
--
-- Replaces Python-orchestrated monolithic macros (which block on ONE goal's whole
-- step sequence at a time, and restart every step from scratch after any failure)
-- with a mod-side pool: Python submits an ORDERED list of generic atomic STEPS
-- under a task_id. The mod derives item NEEDS from those steps, reserves whatever
-- is already on hand, and works through the remaining steps of ALL currently-
-- submitted tasks together -- each time the companion goes idle, the NEXT step
-- executed is whichever ready task's next step is CLOSEST to the companion right
-- now (task_id order as the tiebreak), not necessarily the same task as last time.
-- This is what lets an unrelated-but-nearby task's step get done WHILE a slow/
-- distant task is still working out its own next move, instead of the whole
-- companion sitting idle-but-blocked on one goal (Zdendys: "coal_pair @259k je
-- naprosto nepredstavitelne pomalu").
--
-- Procurement (mining raw ore, crafting intermediate items) is NOT reimplemented
-- here -- a task with unmet needs just stays blocked until enough of the needed
-- item exists in the main inventory; something ELSE (the existing gather_queues/
-- craft_queues macros, or a future task that supplies coal/plates as a side
-- effect) is expected to top that up. This keeps this first version's scope to
-- the mechanism Zdendys actually described tonight (pool/reservation/priority),
-- not a from-scratch reimplementation of every existing procurement macro.
--
-- Step vocabulary (v1 -- exactly what iron_drill/stone_drill need, not yet a
-- fully general DSL):
--   {type="find_patch", resource=NAME}                 -> ctx.px, ctx.py
--   {type="verify_tile", resource=NAME}                -> aborts task if patch gone
--   {type="pick_orientation", primary=ENTITY, secondary=ENTITY, offsets={{dx,dy},...}}
--                                                       -> ctx.sx, ctx.sy, ctx.dir
--   {type="place", which="primary"|"secondary", entity=NAME}
--   {type="fuel", which="primary"|"secondary", item=NAME, count=N}
--
-- "which" addresses WHERE a place/fuel step acts: "primary" = ctx.px/py (the
-- patch position itself, i.e. the drill), "secondary" = ctx.sx/sy (the paired
-- furnace/chest position found by pick_orientation).

local u = require("commands.init")
local queues = require("commands.queues")

local M = {}

local FUEL_REACH = 3      -- mirrors fac_building_fuel's own radius (building.lua)
local WALK_REACH = 2      -- mirrors MINE_ADJACENT_RANGE-class "close enough" used elsewhere

function M.init()
  storage.tasks = storage.tasks or {}
  storage.next_task_id = storage.next_task_id or 1
  storage.reserved = storage.reserved or {}
  -- storage.active_step[cid] = {task_id=, state="walking"|"acting"} -- at most ONE step
  -- in flight per companion at a time (single physical entity, can only do one thing).
  storage.active_step = storage.active_step or {}
end

-- ---- needs derivation + reservation ledger ----

local function derive_needs(steps)
  local needs = {}
  for _, s in ipairs(steps) do
    if s.type == "place" then
      needs[s.entity] = (needs[s.entity] or 0) + 1
    elseif s.type == "fuel" then
      needs[s.item] = (needs[s.item] or 0) + (s.count or 1)
    end
  end
  return needs
end

local function release_reservations(t)
  for item, count in pairs(t.reserved or {}) do
    storage.reserved[item] = math.max(0, (storage.reserved[item] or 0) - count)
  end
  t.reserved = {}
end

local function fail_task(task_id, reason)
  local t = storage.tasks[task_id]
  if not t or t.status ~= "active" then return end
  release_reservations(t)
  t.status = "failed"
  t.error = reason
  u.log_error(string.format("task %d failed: %s", task_id, tostring(reason)), "task_pool")
end

local function complete_task(task_id)
  local t = storage.tasks[task_id]
  if not t or t.status ~= "active" then return end
  release_reservations(t)
  t.status = "done"
end

-- Submit a new task_list under a fresh task_id (2026-07-07 design). `steps` is a
-- plain Lua array (already decoded from the caller's JSON via helpers.json_to_table).
function M.submit_task(cid, steps)
  local c = u.get_companion(cid)
  if not c then return {error = "Invalid companion"} end
  if not steps or #steps == 0 then return {error = "Empty step list"} end

  local needs = derive_needs(steps)
  local inv = c.entity.get_main_inventory()
  local task_reserved = {}
  local remaining_needs = {}
  for item, count in pairs(needs) do
    local have = inv.get_item_count(item)
    local already_reserved = storage.reserved[item] or 0
    -- Only what's genuinely UNCLAIMED by another active task can be reserved here
    -- (Zdendys: "spocita si co potrebuje... nesmi pocitat jiz rezervovane pocty").
    local available = math.max(0, have - already_reserved)
    local take = math.min(available, count)
    if take > 0 then
      storage.reserved[item] = already_reserved + take
      task_reserved[item] = take
    end
    if take < count then
      remaining_needs[item] = count - take
    end
  end

  local task_id = storage.next_task_id
  storage.next_task_id = task_id + 1
  storage.tasks[task_id] = {
    cid = cid,
    steps = steps,
    cursor = 1,
    ctx = {},
    reserved = task_reserved,
    needs = remaining_needs,
    status = "active",
    created_tick = game.tick,
  }
  return {task_id = task_id, needs = remaining_needs}
end

function M.get_task_status(task_id)
  local t = storage.tasks[task_id]
  if not t then return {active = false} end
  return {
    active = t.status == "active",
    status = t.status,
    error = t.error,
    cursor = t.cursor,
    total_steps = #t.steps,
    needs = t.needs,
    ctx = t.ctx,  -- px/py/sx/sy/dir: useful for diagnosing placement failures externally
  }
end

-- ---- step readiness + target position (for distance-priority scheduling) ----

-- Returns the world position a given step will act at (nil if the step doesn't
-- need a specific position -- e.g. find_patch/verify_tile/pick_orientation run
-- instantly wherever the companion currently stands).
local function step_target_pos(t, step)
  if step.type == "place" or step.type == "fuel" then
    if step.which == "primary" and t.ctx.px then return {x = t.ctx.px, y = t.ctx.py} end
    if step.which == "secondary" and t.ctx.sx then return {x = t.ctx.sx, y = t.ctx.sy} end
  end
  return nil
end

-- A task's CURRENT step is ready to run if every item it will consume is fully
-- reserved for THIS task already (needs table only tracks the deficit -- once a
-- deficit item arrives in inventory, a later tick's reservation top-up, done in
-- M.tick(), clears it from `needs`).
local function task_ready(t)
  return next(t.needs) == nil
end

-- ---- synchronous (non-walking) step execution ----

local function run_find_patch(c, t, step)
  local surf = c.entity.surface
  local es = surf.find_entities_filtered{name = step.resource, position = c.entity.position, radius = 400}
  table.sort(es, function(a, b)
    return u.distance(a.position, c.entity.position) < u.distance(b.position, c.entity.position)
  end)
  for _, e in ipairs(es) do
    if e.valid and (e.amount or 1) > 0
       and surf.find_non_colliding_position("character", e.position, WALK_REACH, 0.5) then
      t.ctx.px, t.ctx.py = e.position.x, e.position.y
      return true
    end
  end
  return false, "no reachable " .. step.resource .. " patch found"
end

local function run_verify_tile(c, t, step)
  local surf = c.entity.surface
  local es = surf.find_entities_filtered{name = step.resource, position = {x = t.ctx.px, y = t.ctx.py}, radius = 1}
  if #es == 0 then return false, "patch tile no longer present" end
  return true
end

local function run_pick_orientation(c, t, step)
  local surf = c.entity.surface
  for _, off in ipairs(step.offsets) do
    local sx, sy = t.ctx.px + off[1], t.ctx.py + off[2]
    -- Compute the REAL defines.direction value BEFORE checking can_place_entity
    -- (2026-07-07, live-caught collision bug): this mod uses TWO different
    -- direction numbering systems -- u.dir_map's "simple" 0-3 (matches the MCP
    -- tools API convention) vs. Factorio's own raw defines.direction enum
    -- (north=0, east=4, south=8, west=12, 16-direction system). The check here
    -- was using NO direction (defaulting to north's footprint), while the actual
    -- placement later passed the SIMPLE 0-3 value straight into queues.start_build
    -- (which expects a raw defines.direction value) -- e.g. simple "2" (meant as
    -- south) was literally interpreted as raw direction 2 (northeast), a
    -- completely different rotation than what was just verified as fitting.
    -- Checking and placing with the SAME correctly-translated direction fixes
    -- both the wrong rotation AND the check/placement mismatch in one go.
    local simple_dir
    if off[1] == 0 and off[2] > 0 then simple_dir = 2
    elseif off[1] == 0 and off[2] < 0 then simple_dir = 0
    elseif off[1] > 0 then simple_dir = 1
    else simple_dir = 3 end
    local real_dir = u.dir_map[simple_dir]
    -- opposite_direction (2026-07-07, coal_pair): two SAME-type entities (e.g. two
    -- burner-mining-drills) facing EACH OTHER so each one's mined output auto-feeds
    -- the other's fuel inventory (real vanilla mechanic, no cheat -- matches the
    -- already-live-verified geometry in spatial_bc.py's _build_coal_drill_pair).
    -- Without this the secondary would default to facing north regardless of which
    -- side it's on, which is wrong for a drill (though harmless for a directionless
    -- chest/furnace) and would also make its OWN can_place_entity check below use
    -- the wrong footprint if that entity's collision box isn't rotation-symmetric.
    local secondary_dir = real_dir
    if step.opposite_direction then
      secondary_dir = u.dir_map[(simple_dir + 2) % 4]
    end
    if surf.can_place_entity{name = step.primary, position = {x = t.ctx.px, y = t.ctx.py}, direction = real_dir, force = c.entity.force}
       and surf.can_place_entity{name = step.secondary, position = {x = sx, y = sy}, direction = secondary_dir, force = c.entity.force} then
      t.ctx.sx, t.ctx.sy = sx, sy
      t.ctx.dir = real_dir
      t.ctx.dir2 = secondary_dir
      -- Kept alongside sx/sy so the primary's "place" step can RECOMPUTE the
      -- secondary's position once the primary's REAL (possibly snapped) placed
      -- position is known -- see the note where offset_dx/dy is consumed below.
      t.ctx.offset_dx, t.ctx.offset_dy = off[1], off[2]
      return true
    end
  end
  return false, "no free orientation (all sides blocked)"
end

-- ---- main scheduler tick ----

-- Picks the single best (task, step) to advance right now: among all ACTIVE, READY
-- tasks whose companion is currently IDLE, prefer the one whose current step's
-- target is CLOSEST to the companion; ties broken by task_id (older task wins --
-- Zdendys: "stari kroku odpovida cca poradi taskID").
local function pick_next(cid, c)
  local best_task_id, best_dist = nil, math.huge
  for task_id, t in pairs(storage.tasks) do
    if t.cid == cid and t.status == "active" and task_ready(t) and t.cursor <= #t.steps then
      local step = t.steps[t.cursor]
      local pos = step_target_pos(t, step)
      local dist = pos and u.distance(c.entity.position, pos) or 0  -- instant steps: distance 0, always win ties by task_id
      if dist < best_dist or (dist == best_dist and (not best_task_id or task_id < best_task_id)) then
        best_task_id, best_dist = task_id, dist
      end
    end
  end
  return best_task_id
end

-- Re-check every active task's outstanding `needs` against CURRENT inventory
-- (2026-07-07, live-caught in scripts/test_task_pool.py: a task submitted before
-- its coal arrived stayed stuck on cursor 1 forever -- `needs` was computed ONCE
-- at submit_task time and nothing ever refreshed it afterward, even though the
-- whole point of submitting ahead of having materials is that something else
-- -- gather_queues, another task's own by-product, a later delivery -- can supply
-- them in the meantime). Iterates tasks in task_id order (oldest first) so an
-- older task claims newly-available stock before a younger one, consistent with
-- the pool's own task_id tiebreak elsewhere.
--
-- ONLY does this work for companions whose inventory actually CHANGED since the
-- last tick (2026-07-07, Zdendys: "Ono neni jakym jinym zpusobem, bez zasahu
-- companiona samotneho, by doslo ke zmene stavu jeho inventare!" -- correct,
-- inventory only ever changes as a result of the companion's OWN actions
-- (mining/crafting/fueling/collecting), so polling get_item_count for every
-- outstanding need on EVERY tick regardless was wasted work on every tick where
-- nothing could possibly have changed. storage.inv_count_cache[cid] tracks the
-- last-seen total item count per companion; a plain sum is enough to detect ANY
-- change cheaply without needing to hook into every individual queue type's own
-- completion point (harvest/gather/craft/fuel/build each add or remove items in
-- their own way -- comparing the total sidesteps enumerating all of them).
local function refresh_needs()
  local ids = {}
  for task_id, t in pairs(storage.tasks) do
    if t.status == "active" and next(t.needs) ~= nil then ids[#ids + 1] = task_id end
  end
  if #ids == 0 then return end
  table.sort(ids)
  storage.inv_count_cache = storage.inv_count_cache or {}
  for _, task_id in ipairs(ids) do
    local t = storage.tasks[task_id]
    local c = u.get_companion(t.cid)
    if c then
      local inv = c.entity.get_main_inventory()
      local total = inv.get_item_count()
      if storage.inv_count_cache[t.cid] ~= total then
        storage.inv_count_cache[t.cid] = total
        for item, deficit in pairs(t.needs) do
          local have = inv.get_item_count(item)
          local already_reserved = storage.reserved[item] or 0
          local available = math.max(0, have - already_reserved)
          local take = math.min(available, deficit)
          if take > 0 then
            storage.reserved[item] = already_reserved + take
            t.reserved[item] = (t.reserved[item] or 0) + take
            if take >= deficit then
              t.needs[item] = nil
            else
              t.needs[item] = deficit - take
            end
          end
        end
      end
    end
  end
end

function M.tick()
  refresh_needs()
  for cid, active in pairs(storage.active_step) do
    local c = u.get_companion(cid)
    if not c then storage.active_step[cid] = nil; goto continue end
    local t = storage.tasks[active.task_id]
    if not t or t.status ~= "active" then storage.active_step[cid] = nil; goto continue end
    local step = t.steps[t.cursor]

    if active.state == "walking" then
      if not storage.walking_queues[cid] then
        -- Arrived (or walking_queue was never set for a non-walk step) -> act.
        active.state = "acting"
      else
        goto continue  -- still walking, check again next tick
      end
    end

    if active.state == "acting" then
      local ok, err = true, nil
      if step.type == "place" then
        -- Handled entirely inline (not via the generic ok/err fall-through below,
        -- see the bug note there): start_build's OWN failure is reported
        -- immediately (queues.start_build never queues anything in that case, so
        -- there is no later "building" state to catch it) -- fail_task here or the
        -- task would sit stuck in "acting" forever with active_step never cleared.
        local pos = step_target_pos(t, step)
        local place_dir = (step.which == "secondary" and t.ctx.dir2) or t.ctx.dir or 0
        local r = queues.start_build(cid, step.entity, pos, place_dir)
        if r.error then
          fail_task(active.task_id, r.error)
          storage.active_step[cid] = nil
        else
          -- Poll build_queues to completion via the SEPARATE "building" state
          -- below (own stale-progress backstop, same as every other queue type).
          active.state = "building"
        end
      elseif step.type == "fuel" then
        local pos = step_target_pos(t, step)
        local inv = c.entity.get_main_inventory()
        local have = inv.get_item_count(step.item)
        if have == 0 then
          ok, err = false, "no " .. step.item .. " in inventory"
        else
          local es = c.entity.surface.find_entities_filtered{
            position = pos, radius = FUEL_REACH,
            type = {"furnace", "boiler", "burner-inserter", "mining-drill"}}
          if #es == 0 then
            ok, err = false, "no burner near target"
          else
            local remaining = step.count or 1
            for _, e in ipairs(es) do
              if remaining <= 0 then break end
              local fi = e.get_fuel_inventory()
              if fi then
                local n = math.min(remaining, have)
                local inserted = fi.insert({name = step.item, count = n})
                if inserted > 0 then
                  c.entity.remove_item({name = step.item, count = inserted})
                  remaining = remaining - inserted
                  have = have - inserted
                end
              end
            end
          end
        end
      elseif step.type == "find_patch" then
        ok, err = run_find_patch(c, t, step)
      elseif step.type == "verify_tile" then
        ok, err = run_verify_tile(c, t, step)
      elseif step.type == "pick_orientation" then
        ok, err = run_pick_orientation(c, t, step)
      else
        ok, err = false, "unknown step type " .. tostring(step.type)
      end

      -- "place" is fully handled above (either failed inline, or transitioned to
      -- the separate "building" state) -- every OTHER step type completes
      -- synchronously within this same tick, so their ok/err is resolved here.
      if step.type ~= "place" then
        if ok then
          t.cursor = t.cursor + 1
          storage.active_step[cid] = nil
          if t.cursor > #t.steps then complete_task(active.task_id) end
        else
          fail_task(active.task_id, err)
          storage.active_step[cid] = nil
        end
      end
    end

    if active.state == "building" then
      local st = queues.get_build_status(cid)
      if st.active then
        goto continue  -- still building, check again next tick
      elseif st.placed then
        -- Sync ctx to the REAL placed position (2026-07-07, live-caught): create_entity
        -- can snap a 2x2 entity to a different grid alignment than the 1x1 ore tile
        -- position find_patch recorded (observed: requested (46.5,-185.5), actually
        -- landed at (47,-185)). If this was the PRIMARY and a secondary offset was
        -- already chosen (pick_orientation ran before this), recompute sx/sy from the
        -- REAL px/py so the secondary's own place step doesn't overlap the primary's
        -- true footprint -- fuel steps use step_target_pos too, so this must happen
        -- before either later step's target position is read.
        if step.which == "primary" and st.position then
          t.ctx.px, t.ctx.py = st.position.x, st.position.y
          if t.ctx.offset_dx then
            t.ctx.sx = t.ctx.px + t.ctx.offset_dx
            t.ctx.sy = t.ctx.py + t.ctx.offset_dy
          end
        elseif step.which == "secondary" and st.position then
          t.ctx.sx, t.ctx.sy = st.position.x, st.position.y
        end
        t.cursor = t.cursor + 1
        storage.active_step[cid] = nil
        if t.cursor > #t.steps then complete_task(active.task_id) end
      else
        fail_task(active.task_id, st.error or "build failed")
        storage.active_step[cid] = nil
      end
    end
    ::continue::
  end

  -- Companion(s) currently idle -> pick the next (task, step) to start.
  for cid, c in pairs(storage.companions or {}) do
    if c.entity and c.entity.valid and not storage.active_step[cid] then
      local task_id = pick_next(cid, c)
      if task_id then
        local t = storage.tasks[task_id]
        local step = t.steps[t.cursor]
        local pos = step_target_pos(t, step)
        if pos and u.distance(c.entity.position, pos) > WALK_REACH then
          storage.walking_queues[cid] = {target = pos}
          storage.active_step[cid] = {task_id = task_id, state = "walking"}
        else
          storage.active_step[cid] = {task_id = task_id, state = "acting"}
        end
      end
    end
  end
end

return M
