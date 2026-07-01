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

  -- NATIVE mining, the SAME mechanic a player's pickaxe uses: entity.mine{inventory=...} extracts
  -- exactly ONE unit into the companion's inventory and decrements the tile's amount by 1; when the
  -- tile runs out the GAME itself removes it. The character MINES, it never "destroys" -- every unit
  -- ends up in the inventory, nothing is wasted. (The old code did entity.destroy per unit, which
  -- nuked whole 6500-unit deposits to take a single lump = a cheat + massive waste.)
  -- Verified live: mine{inventory=inv} on coal -> amount 261->260, +1 coal.
  while #q.entities > 0 do
    local entity = q.entities[1]
    if not (entity and entity.valid and entity.type == "resource") then
      table.remove(q.entities, 1)   -- invalid / non-resource -> skip to next tile
    else
      local inv = c.entity.get_main_inventory()
      local before = inv.get_item_count()
      entity.mine{inventory = inv}
      local gained = inv.get_item_count() - before
      q.harvested = q.harvested + gained
      if not entity.valid then table.remove(q.entities, 1) end   -- depleted -> game removed it
      q.current = {entity = entity.valid and entity or nil, done = false}
      return gained > 0   -- mined a unit this call (false only if inventory is full -> yield)
    end
  end
  return false
end

function M.tick_harvest_queues()
  process_queue("harvest_queues", function(cid, q, c)
    -- Target reached
    if q.harvested >= q.target then
      return true
    end

    -- Too far from mining area
    if u.distance(c.entity.position, q.position) > MINING_RANGE then
      return true
    end

    -- Mine next entity every TICK_INTERVAL ticks for pacing
    if not q.last_mine_tick then q.last_mine_tick = 0 end
    if game.tick - q.last_mine_tick < MIN_ACTION_TICKS then return false end
    q.last_mine_tick = game.tick

    if not M.start_mining_next(cid) then
      return true
    end

    q.current = nil
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
-- companion within reach, mines it ONE unit per MIN_ACTION_TICKS (native mine{} -> 1 unit, amount--,
-- game removes depleted tile), and moves to the next patch until the inventory holds `count` of the
-- mined product (or no reachable patch remains). Replaces the Python go_to + start_harvest + poll glue.
local function find_reachable_resource(surf, from, resource)
  local ores = surf.find_entities_filtered{name = resource, position = from, radius = 400}
  table.sort(ores, function(a, b) return u.distance(a.position, from) < u.distance(b.position, from) end)
  for _, e in ipairs(ores) do
    if e.valid and (e.amount or 0) > 0
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
      local e = find_reachable_resource(surf, c.entity.position, q.resource)
      if not e then return true end   -- no reachable patch -> done, return what we have
      q.entity_pos = {x = e.position.x, y = e.position.y}
      q.product = e.prototype.mineable_properties.products[1].name
      if not q.start_count then q.start_count = inv.get_item_count(q.product) end
      storage.walking_queues[cid] = {target = surf.find_non_colliding_position("character", e.position, 3, 0.5) or e.position}
      q.state = "approach"
      return false
    end

    if q.state == "approach" then
      if u.distance(c.entity.position, q.entity_pos) <= (c.entity.reach_distance or 10) then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "mine"
      end
      return false
    end

    if q.state == "mine" then
      if inv.get_item_count(q.product) - (q.start_count or 0) >= q.target then return true end   -- target met
      if game.tick - (q.last_mine_tick or 0) < MIN_ACTION_TICKS then return false end
      q.last_mine_tick = game.tick
      local res = surf.find_entities_filtered{name = q.resource, position = q.entity_pos, radius = 1}[1]
      if not (res and res.valid) then q.state = "find"; return false end   -- depleted -> next patch
      if u.distance(c.entity.position, res.position) > (c.entity.reach_distance or 10) then q.state = "find"; return false end
      res.mine{inventory = inv}   -- native 1-unit mine (no cheat)
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
        return true
      end

      -- Re-check the item is STILL in inventory right before placing (it may have been consumed
      -- during the walk -- crafted away / dropped). Never create a building for free.
      if c.entity.get_main_inventory().get_item_count(q.entity) < 1 then
        q.failed = "No " .. q.entity .. " in inventory"
        return true
      end
      local placed = surf.create_entity{
        name = q.entity,
        position = q.position,
        direction = q.direction,
        force = c.entity.force
      }
      -- Only keep the building if a real item was actually consumed; else remove it (no free build).
      if placed and c.entity.remove_item{name = q.entity, count = 1} < 1 then placed.destroy() end
      return true
    end

    return true
  end)
end

function M.get_build_status(cid)
  local q = storage.build_queues[cid]
  if not q then return {active = false} end
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
