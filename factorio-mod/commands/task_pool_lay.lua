-- AI Companion -- the task pool's "lay" step: a run of belt pieces laid as she walks
-- along (factorio-ai docs/belt_planning.md step 1b). A build plan's pieces each wait
-- BUILD_TICKS after their approach (queues_build.lua); a belt route of 200 pieces would
-- cost 12000 ticks of waits alone. A lay places each piece as soon as its tile is in
-- her build reach, at the task pool's rate (one piece per pass of the pool,
-- on_nth_tick(5)), while she keeps walking along the run (walk_ahead). The pieces, their
-- positions, directions and underground sides are the plan's (Python's); the mod only
-- lays them.
--
-- Step: {type = "lay", pieces = {{entity, x, y, dir = 0-3, ug = "input"|"output"|nil},
--        ...}, laid = N (pieces laid so far; nil = 0, set by this module)}.
-- The task's active step carries the lay's walk: state "laying", walking (a walk of
-- its own runs), approach_deadline, approach_tries, and the no-progress sample
-- (lay_since, lay_pos, lay_inv, lay_laid).

local u = require("commands.init")
local queues = require("commands.queues")
local ledger = require("commands.task_pool_ledger")
local clearing = require("commands.clearing")

-- place()'s answer while she is still clearing the piece's tile herself (not a failure)
local CLEARING = {}

local M = {}

M.APPROACH_RETRIES = 2       -- fresh walks to a piece before the step fails (as the belt queue)
M.STALL_TICKS = 600          -- no progress this long fails the step (queues_core's backstop)
M.STALL_MOVE = 5             -- tiles she must move to count as progress (bypass shuffles)
M.LOOKAHEAD = 8              -- pieces ahead she walks toward while laying (walk_ahead)

-- Stop a walk of the lay's own (the step ends or is cancelled, a deadline ran out).
function M.stop_walk(cid, c, active)
  if c and active.clear_state then clearing.release(cid, c) end   -- (mid-clearing)
  if active.walking then
    storage.walking_queues[cid] = nil
    if c then c.entity.walking_state = {walking = false} end
    active.walking = false
  end
end

-- Start a walk of the lay's own toward `aim` (a free spot for her near it).
local function start_walk(cid, c, active, aim)
  storage.walking_queues[cid] = {
    target = c.entity.surface.find_non_colliding_position("character", aim, 3, 0.5) or aim}
  active.walking = true
end

-- Walk toward the piece `p` out of her reach. Returns nil while walking, or the
-- step's failure reason. Its deadline counts from the first walk to this piece (a walk
-- the walker ended short of reach is started again under the same deadline); at the
-- deadline a fresh try, APPROACH_RETRIES times, aims at a spot between her and the
-- tile, reach - 2 short of it (as the belt queue), then the step fails.
local function approach(cid, c, active, p, reach, done, total)
  if active.approach_deadline and game.tick >= active.approach_deadline then
    M.stop_walk(cid, c, active)
    active.approach_deadline = nil
    if (active.approach_tries or 0) >= M.APPROACH_RETRIES then
      return string.format("cannot reach belt tile (%s,%s) -- %d/%d laid before giving up",
                           p.x, p.y, done, total)
    end
    active.approach_tries = (active.approach_tries or 0) + 1
  end
  if not active.approach_deadline then
    active.approach_deadline = u.approach_deadline(c.entity.position, {x = p.x, y = p.y})
  end
  if not active.walking then
    local aim = {x = p.x, y = p.y}
    if (active.approach_tries or 0) > 0 then
      local pos = c.entity.position
      local d = u.distance(pos, aim)
      local back = math.min(d, math.max(0, reach - 2))
      if d > 0 then
        aim = {x = aim.x + (pos.x - aim.x) / d * back, y = aim.y + (pos.y - aim.y) / d * back}
      end
    end
    start_walk(cid, c, active, aim)
  end
  return nil
end

-- Keep her walking along the run while she lays (no stop at each piece: a stop and a
-- fresh walk per piece made a lay slower than the belt queue, live): with no walk of
-- its own running, one toward the piece LOOKAHEAD ahead, once that piece is farther
-- than reach - 2. No deadline of its own -- the no-progress check covers it, and a
-- piece out of reach gets approach's.
local function walk_ahead(cid, c, active, step, done)
  if active.walking then return end
  local q = step.pieces[math.min(#step.pieces, done + M.LOOKAHEAD)]
  local reach = c.entity.build_distance or 10
  if q and u.distance(c.entity.position, {x = q.x, y = q.y}) > reach - 2 then
    start_walk(cid, c, active, {x = q.x, y = q.y})
  end
end

-- Place the piece `p` where she stands within reach. Returns nil when it stands (its
-- item used, its reservation consumed, recorded in t.placed), or the failure reason.
local function place(cid, c, t, p, done, total, st)
  local surf = c.entity.surface
  local inv = c.entity.get_main_inventory()
  local pos = {x = p.x, y = p.y}
  local dir = u.dir_map[p.dir or 0] or defines.direction.north
  -- (the tile cleared by her, in real time: commands/clearing.lua -- not from afar)
  if clearing.step(cid, c, st, p.entity, pos, dir) == "busy" then return CLEARING end
  if inv.get_item_count(p.entity) < 1 then
    return string.format("Out of %s mid-build (%d/%d placed)", p.entity, done, total)
  end
  -- (create_entity's type -- the underground side -- is not a can_place_entity field)
  if not surf.can_place_entity{name = p.entity, position = pos, direction = dir,
                               force = c.entity.force} then
    return string.format("Cannot place %s at (%s,%s)", p.entity, p.x, p.y)
  end
  local placed = surf.create_entity{name = p.entity, position = pos, direction = dir,
                                    force = c.entity.force, type = p.ug}
  if not placed then return "create_entity returned nil" end
  if p.ug and placed.belt_to_ground_type ~= p.ug then
    local got = placed.belt_to_ground_type
    placed.destroy()
    return "underground belt stood as " .. tostring(got) .. ", not " .. p.ug
  end
  -- never a free build: the real item used, undone if it is gone
  if c.entity.remove_item{name = p.entity, count = 1} < 1 then
    placed.destroy()
    return "item vanished before consuming"
  end
  ledger.consume(t, p.entity, 1)
  t.placed = t.placed or {}
  t.placed[#t.placed + 1] = {entity = p.entity, x = placed.position.x, y = placed.position.y}
  return nil
end

-- Whether the lay made no progress for STALL_TICKS: her inventory total unchanged, she
-- within STALL_MOVE tiles of the sample's spot and no piece laid (queues_core's
-- backstop rule -- the move threshold because the walker's bypass shuffles reset an
-- exact compare, the inventory because a walk through a forest brings wood).
local function stalled(c, active, laid)
  local inv = c.entity.get_main_inventory().get_item_count()
  local pos = c.entity.position
  if not active.lay_since or active.lay_laid ~= laid or active.lay_inv ~= inv
      or u.distance(pos, active.lay_pos) > M.STALL_MOVE then
    active.lay_since, active.lay_laid, active.lay_inv = game.tick, laid, inv
    active.lay_pos = {x = pos.x, y = pos.y}
    return false
  end
  return game.tick - active.lay_since >= M.STALL_TICKS
end

-- One pass of a lay step (task_pool.lua M.tick, state "laying"). Returns "running",
-- "done", or nil and the failure reason.
function M.tick(cid, c, t, step, active)
  -- (a raw /fac_task_submit lay without pieces: refused, not an error in the tick)
  if type(step.pieces) ~= "table" or #step.pieces == 0 then
    M.stop_walk(cid, c, active)
    return nil, "lay step without pieces"
  end
  local total = #step.pieces
  local done = step.laid or 0
  local p = step.pieces[done + 1]
  if not p then
    M.stop_walk(cid, c, active)
    return "done"
  end
  if stalled(c, active, done) then
    M.stop_walk(cid, c, active)
    return nil, string.format("lay made no progress for %d ticks (%d/%d laid)",
                              M.STALL_TICKS, done, total)
  end
  -- (a walk the walker ended -- arrived or given up -- is no walk of hers any more)
  if active.walking and not storage.walking_queues[cid] then active.walking = false end
  local reach = c.entity.build_distance or 10
  if u.distance(c.entity.position, {x = p.x, y = p.y}) > reach then
    local why = approach(cid, c, active, p, reach, done, total)
    if why then return nil, why end
    return "running"
  end
  active.clear_state = active.clear_state or {}
  local why = place(cid, c, t, p, done, total, active.clear_state)
  if why == CLEARING then
    active.lay_since = nil            -- (mining a tree is progress: no stall meanwhile)
    return "running"
  end
  if why then
    M.stop_walk(cid, c, active)
    return nil, why
  end
  active.clear_state = nil
  step.laid = done + 1
  active.approach_tries, active.approach_deadline = nil, nil
  if step.laid >= total then
    M.stop_walk(cid, c, active)
    return "done"
  end
  walk_ahead(cid, c, active, step, step.laid)
  return "running"
end

return M
