-- AI Companion v0.9.0 - Tick-based queue system
local u = require("commands.init")

local M = {}

-- Constants
local TICK_INTERVAL = 5
local MIN_ACTION_TICKS = 30
local BUILD_TICKS = 60
local ATTACK_COOLDOWN = 15
local ATTACK_RANGE = 6
local MINING_RANGE = 5
-- Real mining requires standing basically ON/adjacent to the resource -- confirmed live
-- 2026-07-03 (Zdendys, watching: "Stojí postava přímo na uhlí! nic nejde dolovat na dálku"):
-- unlike build/reach_distance (~10) or MINING_RANGE (5, used elsewhere as a generous "still
-- close enough to keep going" bound), native mining_state silently does nothing at a genuine
-- multi-tile distance even with `selected` correctly set -- it only actually starts once the
-- companion is essentially touching the resource tile.
local MINE_ADJACENT_RANGE = 2

-- Validate companion exists and is valid
local function valid_companion(id)
  local c = u.get_companion(id)
  return c and c.entity and c.entity.valid and c
end

-- Generic queue processor - eliminates repetition across all tick functions
local function process_queue(queue_name, processor)
  local queues = storage[queue_name]
  if not queues then return end

  local to_remove = {}
  for cid, q in pairs(queues) do
    local c = valid_companion(cid)
    if not c then
      to_remove[#to_remove + 1] = cid
    else
      local should_remove = processor(cid, q, c)
      if should_remove then to_remove[#to_remove + 1] = cid end
    end
  end

  for _, cid in ipairs(to_remove) do queues[cid] = nil end
end

function M.init()
  storage.harvest_queues = storage.harvest_queues or {}
  storage.gather_queues = storage.gather_queues or {}
  storage.fuel_queues = storage.fuel_queues or {}
  storage.craft_queues = storage.craft_queues or {}
  storage.build_queues = storage.build_queues or {}
  storage.combat_queues = storage.combat_queues or {}
end

-- ============ HARVEST ============

function M.start_harvest(cid, position, target_count, resource_name)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end

  -- Filter by resource name if specified, otherwise get all resources
  local filter = {position = position, radius = 3, type = "resource"}
  if resource_name then filter.name = resource_name end

  local entities = c.entity.surface.find_entities_filtered(filter)
  if #entities == 0 then return {error = "No resource"} end

  table.sort(entities, function(a, b)
    return u.distance(a.position, c.entity.position) < u.distance(b.position, c.entity.position)
  end)

  storage.harvest_queues[cid] = {
    entities = entities,
    position = position,
    target = target_count,
    harvested = 0,
    current = nil,
    resource_name = resource_name
  }

  M.start_mining_next(cid)
  -- Set inv_snapshot immediately after starting mining
  storage.harvest_queues[cid].inv_snapshot = c.entity.get_main_inventory().get_contents()
  return {started = true, entities = #entities, target = target_count, resource = resource_name}
end

function M.start_mining_next(cid)
  local q = storage.harvest_queues[cid]
  if not q then return false end

  local c = valid_companion(cid)
  if not c then
    storage.harvest_queues[cid] = nil
    return false
  end

  -- NATIVE mining, the SAME mechanic a real player uses: setting mining_state lets the GAME
  -- ENGINE run the whole mining cycle itself (real per-resource mining_time, real swinging
  -- animation, real extraction into the inventory) -- we do NOT call entity.mine{} ourselves
  -- at all (Zdendys 2026-07-03: "pouzit proste nativni schopnosti postavy", same as
  -- character.mining_state a player's client sets while holding the mine button). The engine
  -- keeps mining the SAME target automatically, one unit per completed swing, for as long as
  -- mining_state stays true and the target is valid+in range -- tick_harvest_queues just
  -- watches inventory deltas and moves mining_state to the next tile once one depletes.
  --
  -- mining_state.position is ONLY consulted for TILE mining (e.g. landfill/cliffs); per the
  -- Factorio API docs, "when the player isn't mining tiles the player will mine whatever
  -- entity is currently selected" -- so an ore/resource ENTITY must be set via `selected`
  -- first, or mining_state silently does nothing (0 extraction forever, no error) even
  -- though mining=true and the position looks correct. Live-caught 2026-07-03: harvest
  -- queues stuck at "0/N harvested" indefinitely until this was added.
  while #q.entities > 0 do
    local entity = q.entities[1]
    if not (entity and entity.valid and entity.type == "resource") then
      table.remove(q.entities, 1)   -- invalid / non-resource -> skip to next tile
    else
      c.entity.selected = entity
      c.entity.mining_state = {mining = true, position = entity.position}
      q.current = {entity = entity, done = false}
      return true
    end
  end
  return false
end

function M.tick_harvest_queues()
  process_queue("harvest_queues", function(cid, q, c)
    -- Target reached
    if q.harvested >= q.target then
      c.entity.mining_state = {mining = false}
      return true
    end

    -- Too far from mining area
    if u.distance(c.entity.position, q.position) > MINING_RANGE then
      c.entity.mining_state = {mining = false}
      return true
    end

    -- NATIVE mining (Zdendys 2026-07-03: "pouzit proste nativni schopnosti postavy"): the
    -- engine itself runs the mining cycle once mining_state is set in start_mining_next --
    -- same speed, same animation, same extraction as a real player holding the mine button.
    -- We just watch the inventory for what the engine actually produced.
    --
    -- Track the SPECIFIC mined item (q.resource_name), not the whole-inventory total (cubic-dev-ai
    -- review, 2026-07-03): a plain get_item_count() total is thrown off by ANY concurrent queue on
    -- the same companion (fuel top-up removing coal, a craft consuming ingredients, a build
    -- consuming a placed item) -- completely unrelated inventory changes get misread as mined
    -- progress or lost progress. When start_harvest was called without a resource filter (mines
    -- whatever resource is nearby, name unknown up front) there's no single item to track, so this
    -- falls back to the old whole-inventory delta -- same limitation there, but at least the
    -- baseline-staleness bug below is fixed in both cases.
    local inv = c.entity.get_main_inventory()
    local now_count = q.resource_name and inv.get_item_count(q.resource_name) or inv.get_item_count()
    if q.last_inv_count == nil then q.last_inv_count = now_count end
    local gained = now_count - q.last_inv_count
    if gained > 0 then
      q.harvested = q.harvested + gained
    end
    -- ALWAYS refresh the baseline (not just when gained > 0): otherwise any net inventory
    -- DECREASE (a concurrent queue consuming items) leaves last_inv_count stale/too-high, and
    -- every subsequent tick's mined units get silently swallowed by the still-negative delta
    -- until the total climbs back above the old stale baseline (cubic-dev-ai review).
    q.last_inv_count = now_count

    -- Current target depleted (engine removed it) or never set -> advance to the next tile.
    local cur = q.current and q.current.entity
    if not (cur and cur.valid) then
      if #q.entities > 0 and q.entities[1] == cur then table.remove(q.entities, 1) end
      if not M.start_mining_next(cid) then
        c.entity.mining_state = {mining = false}
        -- A depleted tile normally means its full amount was MINED (game inserts or, if the
        -- inventory is full, spills the item on the ground -- either way the tile empties).
        -- If harvested is still short of target here, every listed entity ran out while
        -- items were spilling instead of landing in inventory -- silently reporting this as
        -- plain "queue done" would hide a real inventory-full condition from the caller.
        if q.harvested < q.target then
          u.log_error(string.format(
            "harvest queue for companion %d ended short (%d/%d %s): entities exhausted, " ..
            "possible full inventory (mined items spilled to ground)",
            cid, q.harvested, q.target, q.resource_name or "?"), "harvest_queue")
        end
        return true
      end
    end

    return q.harvested >= q.target
  end)
end

function M.get_harvest_status(cid)
  local q = storage.harvest_queues[cid]
  if not q then return {active = false} end
  return {
    active = true,
    harvested = q.harvested,
    target = q.target,
    remaining = #q.entities,
    mining = q.current ~= nil
  }
end

function M.stop_harvest(cid)
  local q = storage.harvest_queues[cid]
  if not q then return {stopped = false} end

  local c = valid_companion(cid)
  if c then c.entity.mining_state = {mining = false} end

  local harvested = q.harvested
  storage.harvest_queues[cid] = nil
  return {stopped = true, harvested = harvested}
end

-- ============ GATHER (autonomous: find reachable patch -> walk -> mine to target) ============
-- Self-contained composite: the mod finds the nearest REACHABLE + SAFE patch of `resource`, walks the
-- companion within reach, and mines it NATIVELY via character.mining_state (same speed/animation/
-- extraction as a real player holding the mine button; amount--, game removes depleted tile), moving
-- to the next patch until the inventory holds `count` of the mined product (or no reachable patch
-- remains). Replaces the Python go_to + start_harvest + poll glue.
-- shared tile-key helper (gather blacklist of unreachable patches + fuel-group visited set)
local function _tile_key(pos) return math.floor(pos.x) .. "," .. math.floor(pos.y) end

local function find_reachable_resource(surf, from, resource, blacklist)
  local ores = surf.find_entities_filtered{name = resource, position = from, radius = 400}
  table.sort(ores, function(a, b) return u.distance(a.position, from) < u.distance(b.position, from) end)
  for _, e in ipairs(ores) do
    if e.valid and (e.amount or 0) > 0
       and not (blacklist and blacklist[_tile_key(e.position)])
       and surf.count_entities_filtered{type = "unit-spawner", position = e.position, radius = 20} == 0
       and surf.find_non_colliding_position("character", e.position, 2.5, 0.5) then
      return e
    end
  end
  return nil
end

function M.start_gather(cid, resource, count)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  storage.gather_queues[cid] = {resource = resource, target = count, state = "find", last_mine_tick = 0}
  return {started = true, resource = resource, target = count}
end

function M.tick_gather_queues()
  process_queue("gather_queues", function(cid, q, c)
    local surf = c.entity.surface
    local inv = c.entity.get_main_inventory()

    if q.state == "find" then
      local e = find_reachable_resource(surf, c.entity.position, q.resource, q.blacklist)
      if not e then return true end   -- no reachable patch left -> done, return what we have
      local mp = e.prototype.mineable_properties
      if not (mp and mp.products and mp.products[1]) then
        -- Non-standard resource (no item product, e.g. a fluid-only patch) -- blacklist this
        -- tile and retry next tick instead of crashing on a nil index.
        q.blacklist = q.blacklist or {}
        q.blacklist[_tile_key(e.position)] = true
        u.log_error("gather queue: resource '" .. q.resource .. "' at (" ..
          math.floor(e.position.x) .. "," .. math.floor(e.position.y) ..
          ") has no minable item product, skipping", "gather_queue")
        return false
      end
      q.entity_pos = {x = e.position.x, y = e.position.y}
      q.product = mp.products[1].name
      if not q.start_count then q.start_count = inv.get_item_count(q.product) end
      -- distance-scaled deadline: 25 ticks/tile (~3.7x the expected walk) so a legit long walk is
      -- never aborted, but a companion STUCK on an obstacle (standable != path-reachable) bails fast
      -- instead of hanging the whole 180s (the "3 min and 0 coal" bug).
      q.approach_deadline = game.tick + math.max(1800, math.floor(u.distance(c.entity.position, e.position) * 25))
      -- radius=1 (not 3): walk essentially ONTO the resource tile, not just "in the
      -- neighborhood" -- see MINE_ADJACENT_RANGE comment above (native mining needs real
      -- adjacency, confirmed live 2026-07-03).
      storage.walking_queues[cid] = {target = surf.find_non_colliding_position("character", e.position, 1, 0.5) or e.position}
      q.state = "approach"
      return false
    end

    if q.state == "approach" then
      if u.distance(c.entity.position, q.entity_pos) <= MINE_ADJACENT_RANGE then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "mine"
      elseif game.tick >= (q.approach_deadline or 0) then   -- cannot reach this patch -> blacklist + try next
        q.blacklist = q.blacklist or {}
        q.blacklist[_tile_key(q.entity_pos)] = true
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "find"
      end
      return false
    end

    if q.state == "mine" then
      if inv.get_item_count(q.product) - (q.start_count or 0) >= q.target then
        c.entity.mining_state = {mining = false}
        return true   -- target met
      end
      -- Pick the NEAREST resource entity to the companion's ACTUAL position, not just any
      -- entity within radius=1 of the originally-recorded q.entity_pos: a resource patch is
      -- many individually-tiled entities ~1 tile apart, so a radius=1 query around q.entity_pos
      -- can catch 2+ neighboring tiles, and an unsorted [1] pick can be the WRONG (slightly
      -- farther) one -- close enough to have satisfied the "approach" exit check against
      -- q.entity_pos, yet just over MINE_ADJACENT_RANGE from where the companion is actually
      -- standing. Live-caught 2026-07-03: state flipped mine->find within one tick, mining_state
      -- never even attempted (selected stayed nil), even though the companion visibly reached
      -- and stopped right next to the coal.
      local candidates = surf.find_entities_filtered{name = q.resource, position = q.entity_pos, radius = 2}
      local res, best_d = nil, 1e18
      for _, e in ipairs(candidates) do
        if e.valid then
          local d = u.distance(c.entity.position, e.position)
          if d < best_d then best_d, res = d, e end
        end
      end
      if not res then
        c.entity.mining_state = {mining = false}
        q.state = "find"; return false   -- depleted -> next patch
      end
      if best_d > MINE_ADJACENT_RANGE then
        c.entity.mining_state = {mining = false}
        q.state = "find"; return false
      end
      -- NATIVE mining (Zdendys 2026-07-03: "pouzit proste nativni schopnosti postavy"):
      -- setting mining_state lets the GAME ENGINE run the whole cycle -- same speed,
      -- animation, and extraction as a real player holding the mine button. No more manual
      -- res.mine{} timer call; just let the engine run its own mining_time countdown.
      -- `selected` must be set too: mining_state.position only applies to TILE mining
      -- (landfill/cliffs) -- an ore ENTITY is only mined via the currently `selected` entity,
      -- else mining_state=true silently mines nothing (live-caught 2026-07-03: "0/N harvested"
      -- forever, no error).
      --
      -- CRITICAL: do NOT reassign mining_state every tick once it's already active. Live-caught
      -- 2026-07-03 (test_gather_diag.py): re-setting mining_state = {mining=true,...} on EVERY
      -- tick (as the old comment here claimed was "harmless") restarts the engine's per-resource
      -- mining_time countdown each time, so the swing NEVER completes -- state sat at "mine" with
      -- gathered=0 for 36s+ straight, companion stationary the whole time. A real player only
      -- sends the mine-button-down event ONCE and holds it; we now do the same -- only assign
      -- when the engine reports it isn't already mining (a fresh read of mining_state.mining
      -- each tick, not a cached value, so this correctly resumes if the engine ever stops it,
      -- e.g. after the target changes).
      if c.entity.selected ~= res then
        c.entity.selected = res
      end
      if not c.entity.mining_state.mining then
        c.entity.mining_state = {mining = true, position = res.position}
      end
      return false
    end
    return true
  end)
end

function M.get_gather_status(cid)
  local q = storage.gather_queues[cid]
  if not q then return {active = false} end
  local c = valid_companion(cid)
  local have = (c and q.product) and c.entity.get_main_inventory().get_item_count(q.product) - (q.start_count or 0) or 0
  return {active = true, resource = q.resource, target = q.target, gathered = have, state = q.state}
end

-- ============ FUEL GROUP (autonomous: walk to each burner in range -> top up fuel) ============
-- Self-contained composite: the mod finds every burner machine (one with a fuel inventory) of the
-- FUEL_TYPES within `radius` of the companion, walks to each (nearest-first), and tops it up FROM
-- THE COMPANION'S OWN INVENTORY (native insert -> consumes real coal, no cheat). Replaces the Python
-- go_to + fuel + poll loop over a hardcoded machine list.
-- ROUND-ROBIN, not greedy: with scarce coal, filling burner #1 to `per` in one visit can exhaust the
-- WHOLE supply before burner #2 is ever tried (the top-of-tick "out of coal -> done" check fires
-- first) -- observed live as "only the first furnace gets fed". Each burner is visited AT MOST ONCE
-- per round (tracked in `served`, reset when a round completes); a burner still short after being
-- served waits for the NEXT round, so every reachable burner gets a turn before any one is topped off
-- twice, spreading a limited supply evenly instead of draining it on whichever is nearest.
-- Valid entity TYPES (not names): burner-inserter's type is "inserter"; electric inserters/drills
-- return nil get_fuel_inventory() and are skipped, so filtering by type + fuel-inv is exact.
local FUEL_TYPES = {"furnace", "boiler", "inserter", "mining-drill"}
local APPROACH_TIMEOUT = 900   -- ticks (~15s@60ups): give up on an unreachable burner, skip it
-- _tile_key is defined once above (shared with the gather blacklist).

local function find_next_burner(surf, from, radius, per, blacklist, served)
  local es = surf.find_entities_filtered{position = from, radius = radius, type = FUEL_TYPES}
  table.sort(es, function(a, b) return u.distance(a.position, from) < u.distance(b.position, from) end)
  for _, e in ipairs(es) do
    local key = _tile_key(e.position)
    if e.valid and not blacklist[key] and not served[key] then
      local fi = e.get_fuel_inventory()
      if fi and fi.get_item_count("coal") < per then return e end   -- burner (electric = nil fi) that needs topping up
    end
  end
  return nil
end

function M.start_fuel_group(cid, per, radius)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  storage.fuel_queues[cid] = {per = per or 20, radius = radius or 200, state = "find",
                              blacklist = {}, served = {}, fueled = 0, machines = 0}
  return {started = true, per = per or 20, radius = radius or 200}
end

function M.tick_fuel_queues()
  process_queue("fuel_queues", function(cid, q, c)
    local surf = c.entity.surface
    local inv = c.entity.get_main_inventory()

    -- TERMINAL: freeze here until get_fuel_status consumes+clears this entry -- same fix as the
    -- build queue: deleting the entry the instant it's done meant a Python poll a moment later saw
    -- plain "active:false" with NO fueled/machines counts (observed live: real coal WAS split across
    -- both furnaces, but the reported result said "fueled:0, machines:0" because the run finished
    -- inside the first 2s poll interval, before Python ever saw an in-progress snapshot).
    if q.state == "done" then return false end

    if inv.get_item_count("coal") <= 0 then q.state = "done"; return false end   -- out of coal -> done

    if q.state == "find" then
      local e = find_next_burner(surf, c.entity.position, q.radius, q.per, q.blacklist, q.served)
      if not e then
        if next(q.served) then q.served = {}; return false end   -- round complete, some still need more -> new round
        q.state = "done"; return false                           -- truly nothing left to fuel -> done
      end
      q.target_pos = {x = e.position.x, y = e.position.y}
      q.target_key = _tile_key(e.position)
      q.approach_deadline = game.tick + APPROACH_TIMEOUT
      storage.walking_queues[cid] = {target = surf.find_non_colliding_position("character", e.position, 2, 0.5) or e.position}
      q.state = "approach"
      return false
    end

    if q.state == "approach" then
      if u.distance(c.entity.position, q.target_pos) <= (c.entity.reach_distance or 10) then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "fuel"
      elseif game.tick >= (q.approach_deadline or 0) then    -- unreachable -> skip PERMANENTLY (every round)
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.blacklist[q.target_key] = true
        q.state = "find"
      end
      return false
    end

    if q.state == "fuel" then
      q.served[q.target_key] = true                           -- mark BEFORE fueling: at-most-once per ROUND
      local e = surf.find_entities_filtered{position = q.target_pos, radius = 1, type = FUEL_TYPES}[1]
      if e and e.valid then
        local fi = e.get_fuel_inventory()
        local have = inv.get_item_count("coal")
        if fi and have > 0 then
          local want = q.per - fi.get_item_count("coal")
          if want > 0 then
            local r = fi.insert{name = "coal", count = math.min(want, have)}
            if r > 0 then inv.remove{name = "coal", count = r}; q.fueled = q.fueled + r; q.machines = q.machines + 1 end
          end
        end
      end
      q.state = "find"
      return false
    end
    q.state = "done"
    return false
  end)
end

function M.get_fuel_status(cid)
  local q = storage.fuel_queues[cid]
  if not q then return {active = false} end
  if q.state == "done" then
    storage.fuel_queues[cid] = nil
    return {active = false, fueled = q.fueled, machines = q.machines}
  end
  return {active = true, state = q.state, fueled = q.fueled, machines = q.machines}
end

-- ============ CRAFT ============

function M.start_craft(cid, recipe, count)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end

  local proto = prototypes.recipe[recipe]
  if not proto then return {error = "Unknown recipe: " .. recipe} end

  local craftable = c.entity.get_craftable_count(recipe)
  if craftable < 1 then return {error = "Missing ingredients"} end

  local actual = math.min(count, craftable)
  local ticks = math.max(MIN_ACTION_TICKS, (proto.energy or 0.5) * 60)

  storage.craft_queues[cid] = {
    recipe = recipe,
    target = actual,
    crafted = 0,
    ticks_per = ticks,
    tick_start = game.tick
  }

  return {started = true, recipe = recipe, target = actual, ticks_per = ticks}
end

function M.tick_craft_queues()
  process_queue("craft_queues", function(cid, q, c)
    local elapsed = game.tick - q.tick_start
    if elapsed < q.ticks_per then return false end

    local crafted = c.entity.begin_crafting{recipe = q.recipe, count = 1}
    if crafted < 1 then return true end
    -- headless: fire craft-item research triggers the scripted craft would otherwise miss
    u.fire_craft_triggers(c.entity.force, q.recipe, crafted)

    q.crafted = q.crafted + 1
    q.tick_start = game.tick
    return q.crafted >= q.target
  end)
end

function M.get_craft_status(cid)
  local q = storage.craft_queues[cid]
  if not q then return {active = false} end
  return {
    active = true,
    recipe = q.recipe,
    crafted = q.crafted,
    target = q.target,
    progress = math.floor((game.tick - q.tick_start) / q.ticks_per * 100)
  }
end

function M.stop_craft(cid)
  local q = storage.craft_queues[cid]
  if not q then return {stopped = false} end
  local crafted = q.crafted
  storage.craft_queues[cid] = nil
  return {stopped = true, crafted = crafted}
end

-- ============ BUILD ============

-- Entity types that block character movement (used for approach-position search).
-- These MUST be valid Factorio 2.0 prototype TYPE names, not entity names — a
-- single invalid string makes find_entities_filtered{type=...} raise and (without
-- the pcall in control.lua) would crash the whole tick scheduler. Notably:
-- steam-engine's type is "generator"; chests are "container"/"logistic-container".
local SOLID_TYPES = {
  "offshore-pump", "boiler", "generator", "pipe", "pipe-to-ground",
  "mining-drill", "furnace", "assembling-machine", "inserter",
  "transport-belt", "splitter", "underground-belt",
  "lab", "wall", "gate", "electric-pole", "container", "logistic-container",
  "storage-tank", "beacon", "radar", "solar-panel", "accumulator",
  "roboport", "pump", "cliff"
}

-- Find a walkable tile near build_pos from which the character can reach it
local function find_approach_pos(surf, char_pos, build_pos)
  local candidates = {}
  for _, dist in ipairs({5, 4, 6, 3, 7}) do
    for _, angle in ipairs({0, 45, 90, 135, 180, 225, 270, 315}) do
      local rad = math.rad(angle)
      local p = {
        x = math.floor(build_pos.x + dist * math.sin(rad) + 0.5),
        y = math.floor(build_pos.y - dist * math.cos(rad) + 0.5)
      }
      local blocked = surf.find_entities_filtered{position = p, radius = 0.5, type = SOLID_TYPES}
      if #blocked == 0 then
        candidates[#candidates + 1] = {pos = p, dist = u.distance(char_pos, p)}
      end
    end
  end
  if #candidates > 0 then
    table.sort(candidates, function(a, b) return a.dist < b.dist end)
    return candidates[1].pos
  end
  return {x = build_pos.x, y = build_pos.y - 5}
end

-- Remove trees and small rocks from the entity's collision footprint
local function clear_build_area(surf, entity_name, position, inv)
  local proto = prototypes.entity[entity_name]
  if not proto or not proto.collision_box then return end
  local bb = proto.collision_box
  local area = {
    {x = position.x + bb.left_top.x - 0.5, y = position.y + bb.left_top.y - 0.5},
    {x = position.x + bb.right_bottom.x + 0.5, y = position.y + bb.right_bottom.y + 0.5}
  }
  local obstacles = surf.find_entities_filtered{area = area, type = {"tree", "simple-entity"}}
  for _, obs in ipairs(obstacles) do
    if obs.valid then obs.mine{inventory = inv} end   -- MINE (wood/stone into inventory), not free-destroy
  end
end

-- Start a smart build: auto-approach + auto-clear + place
-- State machine: approaching -> clearing -> building -> done
function M.start_build(cid, entity_name, position, direction)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end

  local dir = direction or defines.direction.north
  local inv = c.entity.get_main_inventory()
  if inv.get_item_count(entity_name) < 1 then
    return {error = "No " .. entity_name .. " in inventory"}
  end

  -- Find safe approach position and start walking there
  local approach = find_approach_pos(c.entity.surface, c.entity.position, position)
  storage.walking_queues[cid] = {target = approach}

  storage.build_queues[cid] = {
    entity = entity_name,
    position = position,
    direction = dir,
    approach = approach,
    state = "approaching",
    tick_start = game.tick
  }

  return {started = true, entity = entity_name, position = position, state = "approaching"}
end

function M.tick_build_queues()
  process_queue("build_queues", function(cid, q, c)
    local surf = c.entity.surface
    local reach = c.entity.build_distance or 10

    -- TERMINAL: sit here (do nothing more) until get_build_status consumes+clears this entry.
    -- Returning true immediately on failure used to delete the queue in the SAME tick it was set,
    -- so a Python poll a moment later saw plain "active:false" -- indistinguishable from success
    -- (place_smart then reported {"placed": true} for a build that never happened; the entity was
    -- never created, e.g. collision or item consumed mid-walk). Now the failure reason survives
    -- until it is actually read.
    if q.state == "done" or q.state == "failed" then return false end

    -- APPROACHING: wait until character is within build reach of target
    if q.state == "approaching" then
      if u.distance(c.entity.position, q.position) <= reach then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "clearing"
      end
      return false
    end

    -- CLEARING: remove trees/rocks from build footprint
    if q.state == "clearing" then
      clear_build_area(surf, q.entity, q.position, c.entity.get_main_inventory())
      q.state = "building"
      q.tick_start = game.tick
      return false
    end

    -- BUILDING: wait BUILD_TICKS then place
    if q.state == "building" then
      if game.tick - q.tick_start < BUILD_TICKS then return false end

      -- Re-check reach (companion may have drifted)
      if u.distance(c.entity.position, q.position) > reach then
        local approach = find_approach_pos(surf, c.entity.position, q.position)
        storage.walking_queues[cid] = {target = approach}
        q.approach = approach
        q.state = "approaching"
        return false
      end

      -- COLLISION CHECK (same guard the game applies to a player): create_entity does
      -- NOT reject overlaps, so without this the async build could stack a building on
      -- top of another (observed: output furnace overlapping the drill by one row).
      -- Refuse instead of force-overlapping; the caller verifies via entity presence.
      if not surf.can_place_entity{name = q.entity, position = q.position,
                                   direction = q.direction, force = c.entity.force} then
        q.failed = "Cannot place (collision)"
        q.state = "failed"
        return false
      end

      -- Re-check the item is STILL in inventory right before placing (it may have been consumed
      -- during the walk -- crafted away / dropped). Never create a building for free.
      if c.entity.get_main_inventory().get_item_count(q.entity) < 1 then
        q.failed = "No " .. q.entity .. " in inventory"
        q.state = "failed"
        return false
      end
      local placed = surf.create_entity{
        name = q.entity,
        position = q.position,
        direction = q.direction,
        force = c.entity.force
      }
      -- Only keep the building if a real item was actually consumed; else remove it (no free build).
      if placed and c.entity.remove_item{name = q.entity, count = 1} < 1 then placed.destroy() end
      if not placed then q.failed = "create_entity returned nil"; q.state = "failed"; return false end
      q.state = "done"
      return false
    end

    return true
  end)
end

function M.get_build_status(cid)
  local q = storage.build_queues[cid]
  if not q then return {active = false} end
  -- Terminal states are consumed HERE (not by tick_build_queues) so the result -- success OR the
  -- failure reason -- survives long enough for a Python poll to actually read it. Previously the
  -- queue was deleted the same tick a failure was detected, so the NEXT poll just saw plain
  -- "active:false" (indistinguishable from success) and place_smart reported a build that never
  -- happened as {"placed": true}.
  if q.state == "done" then
    storage.build_queues[cid] = nil
    return {active = false, placed = true}
  end
  if q.state == "failed" then
    storage.build_queues[cid] = nil
    return {active = false, placed = false, error = q.failed}
  end
  local progress = 0
  if q.state == "approaching" then progress = 10
  elseif q.state == "clearing" then progress = 50
  elseif q.state == "building" then
    progress = 60 + math.floor((game.tick - q.tick_start) / BUILD_TICKS * 40)
  end
  return {
    active = true,
    entity = q.entity,
    position = q.position,
    state = q.state,
    progress = progress
  }
end

function M.stop_build(cid)
  if not storage.build_queues[cid] then return {stopped = false} end
  storage.walking_queues[cid] = nil
  storage.build_queues[cid] = nil
  return {stopped = true}
end

-- ============ COMBAT ============

function M.start_combat(cid, target_pos)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end

  local enemies = c.entity.surface.find_entities_filtered{
    position = target_pos,
    radius = 10,
    force = "enemy",
    type = {"unit", "unit-spawner"}
  }
  if #enemies == 0 then return {error = "No enemies"} end

  table.sort(enemies, function(a, b)
    return u.distance(a.position, c.entity.position) < u.distance(b.position, c.entity.position)
  end)

  storage.combat_queues[cid] = {
    targets = enemies,
    current = enemies[1],
    cooldown = 0,
    kills = 0
  }

  return {started = true, targets = #enemies}
end

function M.tick_combat_queues()
  process_queue("combat_queues", function(cid, q, c)
    if q.cooldown > 0 then
      q.cooldown = q.cooldown - TICK_INTERVAL
      return false
    end

    if not q.current or not q.current.valid then
      -- Find next valid target (build new list to avoid mutation during iteration)
      local valid_targets = {}
      for _, t in ipairs(q.targets) do
        if t.valid then valid_targets[#valid_targets + 1] = t end
      end
      q.targets = valid_targets

      if #q.targets == 0 then
        c.entity.shooting_state = {state = defines.shooting.not_shooting}
        return true
      end
      q.current = table.remove(q.targets, 1)
    end

    local dist = u.distance(c.entity.position, q.current.position)

    if dist <= ATTACK_RANGE then
      c.entity.shooting_state = {
        state = defines.shooting.shooting_enemies,
        position = q.current.position
      }
      q.cooldown = ATTACK_COOLDOWN
    else
      c.entity.shooting_state = {state = defines.shooting.not_shooting}
      local dir = u.get_direction(c.entity.position, q.current.position)
      if dir then c.entity.walking_state = {walking = true, direction = dir} end
    end
    return false
  end)
end

function M.get_combat_status(cid)
  local q = storage.combat_queues[cid]
  if not q then return {active = false} end

  local remaining = #q.targets
  if q.current and q.current.valid then remaining = remaining + 1 end

  return {
    active = true,
    targets_remaining = remaining,
    current_target = q.current and q.current.valid and q.current.name or nil
  }
end

function M.stop_combat(cid)
  local q = storage.combat_queues[cid]
  if not q then return {stopped = false} end

  local c = valid_companion(cid)
  if c then
    c.entity.shooting_state = {state = defines.shooting.not_shooting}
    c.entity.walking_state = {walking = false}
  end

  storage.combat_queues[cid] = nil
  return {stopped = true}
end

return M
