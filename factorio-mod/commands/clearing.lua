-- Clearing a build footprint the way a player does (Zdendys: "Nyara stood on the north
-- side, trees stood where the generator was to go -- farther than 5 tiles -- and were
-- removed without her moving and clearing the area herself" -- the mod's instant
-- obs.mine{} from any distance was cheating, no mining time, no walking):
-- she WALKS to each tree / rock / loose item of the footprint until it is within REACH
-- tiles, STANDS there and mines it with the engine's own mining (mining_state: the
-- real mining time, her own mining speed), one after another, nearest first.
--
-- The caller keeps one state table per footprint (`st`, a fresh {} for each) and calls
-- M.step every cycle while it answers "busy"; "done" means nothing is left that can be
-- cleared (an obstacle she cannot reach or cannot mine -- a full inventory -- is
-- skipped after a bound, so the build then fails its collision check as before).
local u = require("commands.init")
local inv_watch = require("commands.inventory_watch")
local Surplus = require("commands.upkeep_surplus")

local M = {}

M.REACH = 2.5               -- she mines / picks an obstacle from this near (the engine's own mining reach is ~2.7: a tree 3.3 off never came down)
-- the walker stops within 2 tiles of its target (control.lua): aimed this near the
-- obstacle she ends at most 2.3 tiles from it, inside REACH
local AIM_NEAR = 0.3
M.STEER_FROM = 6.0          -- nearer than this she steers straight at the obstacle
M.MINE_TICKS = 900          -- the longest she mines one obstacle before she leaves it
M.WALK_TICKS = 1200         -- the longest she walks toward one obstacle
M.STUCK_TICKS = 90          -- steering straight at it without moving this long: the pathfinder takes her
M.STUCK_REACH = 3.1        -- a tree she cannot get nearer to is mined from this far (its selection box is ~0.4 round it)
M.STUCK_MINE_TICKS = 150   -- the longest she mines from the stuck spot (a tree ~66 ticks): the ladder must end before the 600-tick backstop
M.PATH_STUCK_TICKS = 200   -- a path walk that moves her less than STUCK_MOVE this long: she tries from here, then leaves the obstacle
M.STUCK_MOVE = 0.3          -- (moved less than this many tiles in STUCK_TICKS = stuck)
local OBSTACLE_TYPES = {"tree", "simple-entity"}

local function key(e)
  return e.unit_number or string.format("%.2f,%.2f", e.position.x, e.position.y)
end

-- The entity's collision box on the build's direction, padded by half a tile (the area
-- queues_build.clear_build_area always used).
local function footprint(entity_name, position, direction)
  local proto = prototypes.entity[entity_name]
  if not proto or not proto.collision_box then return nil end
  local bb = proto.collision_box
  local x1, y1, x2, y2 = bb.left_top.x, bb.left_top.y, bb.right_bottom.x, bb.right_bottom.y
  for _ = 1, math.floor((direction or 0) / 4 + 0.5) % 4 do
    x1, y1, x2, y2 = -y1, x1, -y2, x2
  end
  return {
    {x = position.x + math.min(x1, x2) - 0.5, y = position.y + math.min(y1, y2) - 0.5},
    {x = position.x + math.max(x1, x2) + 0.5, y = position.y + math.max(y1, y2) + 0.5}}
end

-- Items she may put away to make room (never what a build or a craft needs: plates,
-- parts, tools stay) -- raw material and surplus only.
local RELIEF_ITEMS = {"wood", "stone", "iron-ore", "copper-ore", "coal", "stone-brick"}
M.ROOM_TICKS = 3600        -- the longest she waits for a chest or a walk to one

-- Whether her inventory takes what mining `o` yields (also the walk's clearing, control.lua):
-- each item product's amount (its most) fits -- the room left in its part stacks first,
-- the rest in empty slots counted across all the products (a huge rock's stone and coal
-- do not both fit in one slot). can_insert would answer whether SOME fit: a stack of 99
-- wood takes 1 of a tree's 4, and the tree then never comes down.
local function room_for(inv, o)
  local empty, slots = inv.count_empty_stacks(), 0
  for _, p in ipairs(o.prototype.mineable_properties.products or {}) do
    if p.type == "item" then
      local n = p.amount or p.amount_max or 1
      local stack = prototypes.item[p.name].stack_size
      local in_parts = math.max(0, inv.get_insertable_count(p.name) - empty * stack)
      if n > in_parts then slots = slots + math.ceil((n - in_parts) / stack) end
    end
  end
  return slots <= empty
end
M.room_for = room_for

-- Her inventory is full: she frees it herself, the mod's own business (Zdendys: Python
-- is only told she has nowhere to put things). The item she holds most of (of
-- RELIEF_ITEMS) goes, all but half a stack, into the nearest role chest of it
-- (upkeep_surplus: the item's store, else a surplus chest) -- inserted from where she
-- stands within her reach, else she walks to it; with no such chest within
-- upkeep_surplus.RADIUS Python is asked for a surplus chest (the "surplus" event) and she
-- waits, bounded by ROOM_TICKS.
-- @return string "done" (room made), "busy" (walking / waiting), "none" (gave up)
local function make_room(cid, c, st)
  local e = c.entity
  local inv = e.get_main_inventory()
  st.room_since = st.room_since or game.tick
  if game.tick - st.room_since >= M.ROOM_TICKS then
    u.log_error("clearing: her inventory is full and nothing took her surplus in "
                .. M.ROOM_TICKS .. " ticks -- the obstacle is left", "clearing")
    return "none"
  end
  local best, best_n = nil, 0
  for _, name in ipairs(RELIEF_ITEMS) do
    local n = inv.get_item_count(name)
    if n > best_n then best, best_n = name, n end
  end
  if not best then return "none" end
  local half = math.floor((prototypes.item[best].stack_size or 50) / 2)
  -- (all but half a stack; half a stack or less goes whole, so a slot comes free)
  local move = best_n > half and best_n - half or best_n
  local chest = Surplus.relief_chest(cid, c, best, move)
  if not chest then return "busy" end              -- (Python asked: she waits)
  if u.distance(e.position, chest.position) > 8 then
    -- walks to it (the walker ends within 2 tiles of the target)
    storage.walking_queues[cid] = storage.walking_queues[cid]
      or {target = {x = chest.position.x, y = chest.position.y + 1.5}}
    st.walking = true
    return "busy"
  end
  if st.walking then
    storage.walking_queues[cid] = nil
    e.walking_state = {walking = false}
    st.walking = false
  end
  local put = chest.insert{name = best, count = move}
  if put > 0 then e.remove_item{name = best, count = put} end
  inv_watch.gained(e)
  u.log_error(string.format("clearing: her inventory was full -- %d %s put into the chest at "
                            .. "(%.1f,%.1f)", put, best, chest.position.x, chest.position.y),
              "clearing")
  if put > 0 then st.room_since = nil end   -- (a full chest keeps the ROOM_TICKS clock running)
  return put > 0 and "done" or "busy"
end

-- Stand down: her mining and the walk toward an obstacle stop.
local function stand_down(cid, c, st)
  if st.mining or c.entity.mining_state.mining then
    c.entity.mining_state = {mining = false}
    st.mining = nil
  end
  if st.walking then
    storage.walking_queues[cid] = nil
    c.entity.walking_state = {walking = false}
    st.walking = false
  end
end

-- The relief and the came-down bookkeeping every cycle starts with.
-- @return boolean true when this cycle is spent (her inventory is being relieved)
local function prelude(cid, c, st)
  st.skip = st.skip or {}
  if st.relief then
    -- her inventory is being relieved (a walk to a chest, or a wait for one): nothing
    -- else runs meanwhile
    local r = make_room(cid, c, st)
    if r == "busy" then return true end
    if r == "none" then
      st.skip[st.relief] = true
      st.room_failed = true         -- (no room could be made: a pick-up reads "inventory full")
    end
    st.relief, st.room_since = nil, nil
    return true
  end
  if st.target and not st.target.valid then
    -- (it came down: its wood or stone is in her inventory)
    inv_watch.gained(c.entity)
    st.target = nil
  end
  return false
end

-- A target wider than this (half its box side; a tree's box is under it) is reached from its
-- edge, not from its centre (a crash-site wreck's centre lies inside its own collision box:
-- nobody can stand there).
local BIG_HALF = 1.4

-- The point of `best` she reaches from: its centre for a small target; for a big one the
-- point of its box nearest to her.
local function reach_point(best, p)
  local bb = best.selection_box
  if not bb then return best.position end
  local hx = (bb.right_bottom.x - bb.left_top.x) / 2
  local hy = (bb.right_bottom.y - bb.left_top.y) / 2
  if hx <= BIG_HALF and hy <= BIG_HALF then return best.position end
  return {x = math.min(math.max(p.x, bb.left_top.x), bb.right_bottom.x),
          y = math.min(math.max(p.y, bb.left_top.y), bb.right_bottom.y)}
end

-- One cycle of work on `best`: the walk to it, then its mining (or the pick-up of a loose
-- item).
-- @return string "busy"
local function work(cid, c, st, best, best_d, kind)
  local e = c.entity
  if st.target ~= best then
    st.target, st.mining, st.mine_started = best, nil, nil
    st.steer_pos, st.steer_tick, st.path_mode = nil, nil, nil
    st.path_pos, st.path_tick, st.reach_ext = nil, nil, nil
    st.started = game.tick
  end
  local waited = game.tick - (st.started or game.tick)
  local reach = st.reach_ext and M.STUCK_REACH or M.REACH
  local spot = reach_point(best, e.position)
  best_d = u.distance(e.position, spot)
  if best_d > reach then
    -- walk closer: to a point AIM_NEAR from it, on her side
    if waited >= M.WALK_TICKS then
      st.skip[key(best)] = true
      stand_down(cid, c, st)
      u.log_error(string.format("clearing: %s at (%.1f,%.1f) not reached in %d ticks -- left",
                                best.name, best.position.x, best.position.y, waited), "clearing")
      return "busy"
    end
    if best_d > M.STEER_FROM then
      -- far: the walker's pathfinding brings her near
      if not storage.walking_queues[cid] then
        local p = e.position
        storage.walking_queues[cid] = {
          target = {x = spot.x + (p.x - spot.x) / best_d * AIM_NEAR,
                    y = spot.y + (p.y - spot.y) / best_d * AIM_NEAR}}
      end
    else
      -- near: her last steps straight at it (the walker ends a walk within 2 tiles of its
      -- target -- too coarse: she stood 3 tiles off a tree, out of mining reach)
      local p = e.position
      local function path_to()
        if not storage.walking_queues[cid] then
          storage.walking_queues[cid] = {
            target = {x = spot.x + (p.x - spot.x) / best_d * AIM_NEAR,
                      y = spot.y + (p.y - spot.y) / best_d * AIM_NEAR}}
        end
      end
      if st.path_mode then
        -- (a path walk that gets her no nearer is left after PATH_STUCK_TICKS -- sooner than the
        -- task pool's no-progress backstop (600 ticks), which would otherwise fail the whole
        -- build: smoke 2026-11-21, a tree 2.7 tiles off, her reach 2.5, "state clearing, path=true")
        if not st.path_pos or u.distance(st.path_pos, p) >= M.STUCK_MOVE then
          st.path_pos, st.path_tick = {x = p.x, y = p.y}, game.tick
        elseif game.tick - st.path_tick >= M.PATH_STUCK_TICKS then
          st.path_pos, st.path_tick = nil, nil
          stand_down(cid, c, st)
          if best_d <= M.STUCK_REACH and not st.reach_ext then
            -- (she cannot get nearer: the engine mines a tree from its selection box, a little
            -- farther than REACH -- try from here before leaving it)
            st.reach_ext = true
            return "busy"
          end
          st.skip[key(best)] = true
          u.log_error(string.format("clearing: %s at (%.1f,%.1f) %.1f tiles off, the path walk "
                                    .. "got her no nearer in %d ticks -- left", best.name,
                                    best.position.x, best.position.y, best_d,
                                    M.PATH_STUCK_TICKS), "clearing")
          return "busy"
        end
        path_to()                 -- (kept going: the walker's pathfinding is taking her round)
      elseif st.steer_pos and u.distance(st.steer_pos, p) < M.STUCK_MOVE
             and game.tick - st.steer_tick >= M.STUCK_TICKS then
        -- straight at it she does not get nearer (a boiler, a belt, a chest in the way --
        -- smoke: 605 ticks standing 4 tiles off a build): the walker's pathfinding takes
        -- her round, aimed AIM_NEAR from the obstacle, until it is within reach
        st.path_mode = true
        path_to()
      else
        if not st.steer_pos or u.distance(st.steer_pos, p) >= M.STUCK_MOVE then
          st.steer_pos, st.steer_tick = {x = p.x, y = p.y}, game.tick
        end
        storage.walking_queues[cid] = nil
        e.walking_state = {walking = true, direction = u.get_direction(p, best.position)}
      end
    end
    st.walking = true
    return "busy"
  end
  if st.walking then
    storage.walking_queues[cid] = nil
    e.walking_state = {walking = false}
    st.walking = false
  end
  if kind == "item" then
    -- a loose item within reach: picked up (instant in the game too)
    local moved = e.get_main_inventory().insert(best.stack)
    if moved >= best.stack.count then
      best.destroy()
      inv_watch.gained(e)
    else
      if moved > 0 then best.stack.count = best.stack.count - moved end
      st.skip[key(best)] = true          -- (her inventory is full)
    end
    return "busy"
  end
  if not room_for(e.get_main_inventory(), best) then
    -- the inventory is full: she makes room (a relief chest) and goes on -- a build
    -- planned right does not fail for want of a slot (Zdendys)
    stand_down(cid, c, st)
    st.relief = key(best)
    return "busy"
  end
  st.mine_started = st.mine_started or game.tick       -- (the mining time counts from here)
  -- (from the stuck spot she tries only a while: the task pool's no-progress backstop is 600 ticks)
  if game.tick - st.mine_started >= (st.reach_ext and M.STUCK_MINE_TICKS or M.MINE_TICKS) then
    -- it does not come down (a full inventory): left, the build fails its check
    st.skip[key(best)] = true
    stand_down(cid, c, st)
    u.log_error(string.format("clearing: %s at (%.1f,%.1f) not down after %d ticks -- left",
                              best.name, best.position.x, best.position.y,
                              game.tick - st.mine_started), "clearing")
    return "busy"
  end
  -- (stamped every cycle she mines here: the orphan-mining backstop of queues_harvest
  -- leaves a clearing's mining alone)
  storage.clearing_mining = storage.clearing_mining or {}
  storage.clearing_mining[cid] = game.tick
  if not st.mining then
    e.selected = best
    e.mining_state = {mining = true, position = spot}
    st.mining = true
  elseif not e.mining_state.mining then
    e.selected = best
    e.mining_state = {mining = true, position = spot}
  end
  return "busy"
end

-- One cycle of the clearing of the footprint of `entity_name` at `position`.
-- @param cid number the companion's id
-- @param c table the companion record
-- @param st table the caller's state for this footprint
-- @return string "busy" (call again next cycle) or "done"
function M.step(cid, c, st, entity_name, position, direction)
  local e = c.entity
  local surf = e.surface
  local area = footprint(entity_name, position, direction)
  if not area then return "done" end
  if prelude(cid, c, st) then return "busy" end
  local best, best_d, kind = nil, math.huge, nil
  for _, o in ipairs(surf.find_entities_filtered{area = area, type = OBSTACLE_TYPES}) do
    if o.valid and not st.skip[key(o)] then
      local d = u.distance(e.position, o.position)
      if d < best_d then best, best_d, kind = o, d, "obstacle" end
    end
  end
  for _, it in ipairs(surf.find_entities_filtered{area = area, type = "item-entity"}) do
    if it.valid and it.stack and it.stack.valid_for_read and not st.skip[key(it)] then
      local d = u.distance(e.position, it.position)
      if d < best_d then best, best_d, kind = it, d, "item" end
    end
  end
  if not best then
    stand_down(cid, c, st)
    return "done"
  end
  return work(cid, c, st, best, best_d, kind)
end

-- One cycle of felling the one tree `target`: she walks to it and mines it with the
-- engine's mining, her own mining speed (the wood chop of the task pool's ensure_item).
-- @param st table the caller's state for this tree (a fresh {} per tree)
-- @return string "busy" (call again next cycle) or "done": the tree is down -- or left
--   standing (not reached, not mined in time): the caller reads target.valid
function M.step_target(cid, c, st, target)
  if prelude(cid, c, st) then return "busy" end
  if not target.valid or st.skip[key(target)] then
    stand_down(cid, c, st)
    return "done"
  end
  return work(cid, c, st, target, u.distance(c.entity.position, target.position), "obstacle")
end

-- Her mining and her walk stop at once (a task, a build or a lay that ends or is
-- cancelled mid-clearing: nothing else resets them).
function M.release(cid, c)
  if c.entity.mining_state.mining then c.entity.mining_state = {mining = false} end
  c.entity.walking_state = {walking = false}
  storage.walking_queues[cid] = nil
end

return M
