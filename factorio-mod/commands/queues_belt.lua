-- AI Companion -- the route queue (Stage 0.2, 2026-07-04; 2026-07-19 size-refactor
-- split out of queues.lua): a fluid pipeline of pipes and pipe-to-ground pairs between
-- two points (pathfind.lua pipe mode), laid by the companion walking along it, one tile
-- per queue tick, with the real items. Owns storage.belt_queues (its name kept from the
-- belt days) exclusively; calls queues_core.lua and queues_build.lua (clear_build_area:
-- each piece's tile cleared before it is placed).
--
-- Belt routes are no longer the mod's (0.16.193, factorio-ai docs/belt_planning.md step
-- 5, Zdendys): Python plans them (src/rl/belt_route.py) and the mod lays them as a build
-- plan's "lay" step (task_pool_lay.lua). This queue's belt mode -- the pure / partial /
-- underground options, the partial prefix, the straight underground-pair fallback -- is
-- gone; a belt record of an older version found in storage is dropped as failed.

local u = require("commands.init")
local pathfind = require("commands.pathfind")
local core = require("commands.queues_core")
local requests = require("commands.controller_requests")
local build = require("commands.queues_build")
local events = require("commands.events")

local M = {}

local function step_dir(a, b)
  if b.x > a.x then return defines.direction.east end
  if b.x < a.x then return defines.direction.west end
  if b.y > a.y then return defines.direction.south end
  return defines.direction.north
end

-- the items a route is built of
local ITEMS = {plain = "pipe", underground = "pipe-to-ground"}

local function opposite(dir) return (dir + 8) % 16 end

-- ticks a companion gets to step off a pipe tile she stands on, below the queues'
-- universal no-progress backstop (600); she aims STEP_OFF_DISTANCE tiles sideways
local STEP_OFF_TICKS = 300
local STEP_OFF_DISTANCE = 3
-- fresh walks to a route tile after its approach deadline ran out, before the route
-- fails (each one with a new path request, a new deadline and a stand spot reach - 2
-- short of the tile, on her side)
local APPROACH_RETRIES = 2
-- opts: {pipe = true} (blue science B1', required -- belts are Python's, see the header)
-- lays a fluid pipeline of pipes and pipe-to-ground pairs (pathfind.lua pipe mode); with
-- {plan = true} only its need is returned. A pipe-to-ground's surface connection is on
-- its facing side, so an entrance faces back toward the source and an exit toward the
-- sink.
function M.start_belt_connect(cid, from_pos, to_pos, opts)
  if not (opts and opts.pipe) then
    return {error = "belt routes are planned in Python (a build plan's lay step) -- "
                    .. "only option 'pipe' is routed here"}
  end
  local c = core.valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  -- Task-pool ownership (2026-07-08, task #42; task_pool.lua never calls this): while a
  -- step holds her the route is queued (controller_requests.lua: never refused, started
  -- by the scheduler); a plan only searches -- it needs no body and runs at once
  if not opts.plan then
    local queued = requests.gate(cid, "belt", {from = from_pos, to = to_pos, opts = opts},
                                 from_pos)
    if queued then return queued end
  end
  local surf = c.entity.surface
  local force = c.entity.force
  local path, reason = pathfind.find_path(surf, from_pos, to_pos, force, opts)
  if not path then
    -- (the search already hops as far as a pipe-to-ground reaches)
    return {error = "no path", reason = reason, expansions = pathfind.last_expansions}
  end
  -- Each tile's direction as OUTGOING (toward the next tile), not the A* search's "arrived
  -- from" bookkeeping; the last tile has no next -- it continues straight. An entrance's
  -- outgoing direction points at its exit; a pipe-to-ground entrance must face the other
  -- way (its surface side toward the source).
  for i = 1, #path do
    if path[i + 1] then
      path[i].dir = step_dir(path[i], path[i + 1])
    else
      path[i].dir = (path[i - 1] and path[i - 1].dir) or defines.direction.north
    end
  end
  for _, node in ipairs(path) do
    if node.underground == "entrance" then node.dir = opposite(node.dir) end
  end

  local need_belt, need_underground = 0, 0
  for _, node in ipairs(path) do
    if node.underground then need_underground = need_underground + 1
    else need_belt = need_belt + 1 end
  end
  -- "plan" (0.16.145): the route and its item need only -- nothing is started, no items
  -- are checked (a caller checks a route exists before building what it connects)
  if opts.plan then
    -- extent: the route's bounding box, its longer side in tiles. A fluid segment longer
    -- than the engine's pipeline extent (utility-constants default_pipeline_extent 320)
    -- does not flow into or out of machines (live 2026-11-06: 330 straight pipes, the
    -- refinery at the end got 0 crude; 300 pipes, 400)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, node in ipairs(path) do
      x0, y0 = math.min(x0, node.x), math.min(y0, node.y)
      x1, y1 = math.max(x1, node.x), math.max(y1, node.y)
    end
    return {planned = true, tiles = #path, need_belt = need_belt,
            need_underground = need_underground, expansions = pathfind.last_expansions,
            extent = math.max(x1 - x0, y1 - y0) + 1}
  end

  local inv = c.entity.get_main_inventory()
  local have_belt = inv.get_item_count(ITEMS.plain)
  local have_underground = inv.get_item_count(ITEMS.underground)
  if have_belt < need_belt or have_underground < need_underground then
    -- the field names stay "belt" (one status shape for the callers)
    return {
      error = "Insufficient pipe items",
      need_belt = need_belt, need_underground = need_underground,
      have_belt = have_belt, have_underground = have_underground
    }
  end

  storage.belt_queues[cid] = {path = path, idx = 1, tiles_placed = 0, state = "placing",
    pipe = true,
    -- run_start_tick/run_end_tick (2026-07-28, action-timing instrumentation,
    -- batch 2): this domain already has a "done"/"failed" freeze grace period
    -- (get_belt_connect_status consumes it exactly once before deleting), so
    -- run_end_tick (set at each terminal transition in tick_belt_queues) is
    -- reliably readable by the next poll.
    run_start_tick = game.tick}
  return {started = true, tiles = #path, need_belt = need_belt, need_underground = need_underground}
end

function M.tick_belt_queues()
  core.process_queue("belt_queues", function(cid, q, c)
    -- TERMINAL: sit here until get_belt_connect_status consumes+clears this entry (same
    -- fix as tick_build_queues -- otherwise a poll a moment after completion just sees
    -- plain "active:false", indistinguishable from success).
    if q.state == "done" or q.state == "failed" then
      -- its end once as a job-end event (commands/events.lua: kind "pipe", the
      -- companion's id -- one route at a time each)
      if not q.event_sent then
        q.event_sent = true
        events.emit({kind = "pipe", id = cid, cid = cid, status = q.state,
                     error = q.failed, tiles = q.tiles_placed})
      end
      return false
    end
    -- a belt route of an older version (q.pipe nil: before 0.16.193 a record without it
    -- was a belt) -- the belt mode is gone (header): dropped as failed, its caller told
    if not q.pipe then
      if q.walking then                      -- (her walk to its tile stops with it)
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
      end
      q.failed = "a belt route of an older mod version -- belt routes are planned in Python"
      u.log_error(q.failed .. " (dropped)", "belt_queue")
      q.run_end_tick = game.tick
      q.state = "failed"
      return false
    end

    local surf = c.entity.surface
    local reach = c.entity.build_distance or 10
    local node = q.path[q.idx]
    if not node then q.run_end_tick = game.tick; q.state = "done"; return false end

    if u.distance(c.entity.position, {x = node.x, y = node.y}) > reach then
      -- APPROACH DEADLINE (cubic dev ai bot, 2026-07-04): unlike tick_gather_queues/
      -- tick_fuel_queues, this had NO elapsed-time guard at all -- a permanently blocked
      -- tile (water/cliff/train in the way) left q.walking=true and this branch returning
      -- `false` (still active) forever, hanging get_belt_connect_status indefinitely with
      -- no way for a caller to ever learn it failed. Same distance-scaled deadline formula
      -- as tick_gather_queues (25 ticks/tile, floor 1800) so a legitimately long walk isn't
      -- cut short but a genuinely stuck one bails instead of hanging.
      -- Also (re)seed the deadline if it's simply MISSING, not just on the first tick of
      -- walking: `storage` is Factorio's persistent save-game state, so a belt_queues entry
      -- written by an OLDER mod version (before approach_deadline existed) could still have
      -- q.walking=true with no deadline after a save/reload -- `(q.approach_deadline or 0)`
      -- would then make `game.tick >= 0` true on the very next tick and kill a build that's
      -- still genuinely walking (cubic dev ai bot, 2026-07-04). Healing it here (instead of
      -- just nil-guarding the comparison) gives that legacy entry a fresh, bounded deadline
      -- rather than either failing it instantly OR leaving it to hang forever again.
      if not q.walking or not q.approach_deadline then
        q.approach_deadline = u.approach_deadline(c.entity.position, {x = node.x, y = node.y})
        if not q.walking then
          -- a retry aims at a spot between her and the tile, reach - 2 short of it (any
          -- spot within reach will do): a different, shorter walk than the first one
          local aim = {x = node.x, y = node.y}
          if (q.approach_tries or 0) > 0 then
            local p = c.entity.position
            local d = u.distance(p, aim)
            local back = math.min(d, math.max(0, reach - 2))
            if d > 0 then
              aim = {x = aim.x + (p.x - aim.x) / d * back, y = aim.y + (p.y - aim.y) / d * back}
            end
          end
          storage.walking_queues[cid] = {
            target = surf.find_non_colliding_position("character", aim, 3, 0.5) or aim
          }
          q.walking = true
        end
      elseif game.tick >= q.approach_deadline + u.clearing_grace(cid)
             and (q.approach_tries or 0) < APPROACH_RETRIES then
        -- live 2026-11-06: a 118-piece pipeline through dense forest (65 trees within 8
        -- tiles) failed at piece 24 with the deadline run out while she was still
        -- clearing her way (another run passed the same tile). A fresh walk -- a new
        -- path request, a new deadline, a nearer stand spot -- before giving up. Only
        -- reachable while she keeps making progress (wood from the trees): standing
        -- still for 600 ticks, the universal backstop in queues_core drops the queue.
        -- q.approach_tries is nil on older records (none tried yet) and resets with
        -- every placed tile.
        q.approach_tries = (q.approach_tries or 0) + 1
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.walking = false
        q.approach_deadline = nil
      elseif game.tick >= q.approach_deadline + u.clearing_grace(cid) then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.failed = "cannot reach route tile (" .. node.x .. "," .. node.y .. ") -- " ..
                   q.tiles_placed .. "/" .. #q.path .. " placed before giving up"
        q.run_end_tick = game.tick
        q.state = "failed"
      end
      return false
    end
    if q.walking then
      storage.walking_queues[cid] = nil
      c.entity.walking_state = {walking = false}
      q.walking = false
    end

    local item = node.underground and ITEMS.underground or ITEMS.plain
    local pos = {x = node.x, y = node.y}

    -- A pipe collides with characters (a belt and a pipe-to-ground do not -- live
    -- 2026-11-06: "Cannot place pipe" with the companion standing on the start tile;
    -- core/lualib/collision-mask-defaults.lua: pipe = building() with the player layer,
    -- pipe-to-ground = building_walkable() without it). She steps off the tile first,
    -- sideways to the route, by walking; bounded. (Another character -- the player --
    -- on a route tile still fails the route as "Cannot place pipe"; planning tests a
    -- belt, which characters do not block.)
    if not node.underground then
      local p, cx, cy = c.entity.position, node.x + 0.5, node.y + 0.5
      if math.abs(p.x - cx) < 0.5 and math.abs(p.y - cy) < 0.5 then
        if not q.step_off_deadline then
          local sx, sy = 0, 1                   -- sideways to an east/west route
          if node.dir == defines.direction.north or node.dir == defines.direction.south then
            sx, sy = 1, 0
          end
          -- the walker stops within 2 tiles of its target (control.lua), so the aim is
          -- STEP_OFF_DISTANCE away: she then ends at least 1 tile off the centre
          -- (verification review: an aim 2 away read as arrived at once). A free spot
          -- found too near the tile is not used -- the other side is tried.
          local target = nil
          for _, side in ipairs({1, -1}) do
            local aim = {x = cx + side * STEP_OFF_DISTANCE * sx, y = cy + side * STEP_OFF_DISTANCE * sy}
            local spot = surf.find_non_colliding_position("character", aim, 2, 0.5)
            if spot and u.distance(spot, {x = cx, y = cy}) >= STEP_OFF_DISTANCE - 0.5 then
              target = spot
              break
            end
          end
          storage.walking_queues[cid] = {
            target = target or {x = cx + STEP_OFF_DISTANCE * sx, y = cy + STEP_OFF_DISTANCE * sy}}
          q.step_off_deadline = game.tick + STEP_OFF_TICKS
        elseif game.tick >= q.step_off_deadline then
          storage.walking_queues[cid] = nil
          c.entity.walking_state = {walking = false}
          q.failed = "could not step off pipe tile (" .. node.x .. "," .. node.y .. ")"
          q.run_end_tick = game.tick
          q.state = "failed"
        end
        return false
      end
      if q.step_off_deadline then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.step_off_deadline = nil
      end
    end
    if c.entity.get_main_inventory().get_item_count(item) < 1 then
      q.failed = "Out of " .. item .. " mid-build (" .. q.idx .. "/" .. #q.path .. " placed)"
      q.run_end_tick = game.tick
      q.state = "failed"; return false
    end
    -- what lies on the tile is cleared into her inventory first, as a belt run's lay
    -- does (queues_build.clear_build_area: items on the ground, trees, rocks) -- the
    -- route planner counts them passable (live: an item on the ground failed a planned
    -- crude pipeline "Cannot place pipe-to-ground" 47 pieces in)
    -- (the tile's centre: node x / y is its corner -- the padded area then stays on it)
    build.clear_build_area(surf, item, {x = node.x + 0.5, y = node.y + 0.5},
                           c.entity.get_main_inventory(), node.dir)
    -- `type` (input/output) is a create_entity-only field for underground belts, not a
    -- valid can_place_entity param -- keep the collision check's args separate so an
    -- unrecognized key can't make the check itself error or behave unexpectedly.
    if not surf.can_place_entity{name = item, position = pos, direction = node.dir, force = c.entity.force} then
      q.failed = "Cannot place " .. item .. " at (" .. node.x .. "," .. node.y .. ")"
      q.run_end_tick = game.tick
      q.state = "failed"; return false
    end
    local create_args = {name = item, position = pos, direction = node.dir, force = c.entity.force}
    local placed = surf.create_entity(create_args)
    if not placed then
      q.failed = "create_entity returned nil"
      q.run_end_tick = game.tick
      q.state = "failed"; return false
    end
    -- Never a free build: consume the real item, undo if it somehow isn't there anymore.
    if c.entity.remove_item{name = item, count = 1} < 1 then
      placed.destroy()
      q.failed = "item vanished before consuming"
      q.run_end_tick = game.tick
      q.state = "failed"; return false
    end
    q.tiles_placed = q.tiles_placed + 1
    q.idx = q.idx + 1
    q.approach_tries = nil
    if q.idx > #q.path then
      q.run_end_tick = game.tick
      q.state = "done"
    end
    return false
  end)
end

function M.get_belt_connect_status(cid)
  local q = storage.belt_queues[cid]
  if not q then return {active = false} end
  if q.state == "done" then
    storage.belt_queues[cid] = nil
    return {active = false, connected = true, tiles = q.tiles_placed,
      run_start_tick = q.run_start_tick, run_end_tick = q.run_end_tick}
  end
  if q.state == "failed" then
    storage.belt_queues[cid] = nil
    return {active = false, connected = false, error = q.failed, tiles = q.tiles_placed,
      run_start_tick = q.run_start_tick, run_end_tick = q.run_end_tick}
  end
  return {active = true, tiles_placed = q.tiles_placed, tiles_total = #q.path}
end

-- the controller's queued route, started by the scheduler (controller_requests.lua)
requests.register("belt", function(cid, a)
  return M.start_belt_connect(cid, a.from, a.to, a.opts)
end)

return M
