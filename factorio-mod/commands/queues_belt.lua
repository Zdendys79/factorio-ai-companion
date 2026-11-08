-- AI Companion -- BELT CONNECT queue (Stage 0.2, 2026-07-04; 2026-07-19 size-refactor
-- split out of queues.lua). Fully self-contained: owns storage.belt_queues exclusively,
-- no cross-section calls beyond queues_core.lua. Uses commands.pathfind, its only user
-- in the whole original queues.lua (confirmed by grep before this split).
--
-- Model=WHAT/mod=HOW split (belt/inserter automation plan): the model/Python side already
-- knows the exact relative geometry of what it just built (furnace, drill, assembler --
-- same proven pattern as _build_ore_drill_furnace) and places any INSERTERS itself via the
-- existing fac_building_place/_rotate/fac_inserter_set_filter primitives. This command
-- handles ONLY the one genuinely-new problem: routing a transport-belt corridor between two
-- already-chosen points, avoiding water/buildings (pathfind.lua's A*; ore patches are
-- ordinary ground, see pathfind.lua), with an
-- underground-belt straight-line fallback (entrance to exit at most 5 tiles, yellow tier)
-- for a gap no walkable route crosses -- not for a "pure" route (2026-11-06, see
-- start_belt_connect); "underground" routes cross obstacles inside the search instead
-- (pathfind.lua). No `material`/inserter-type param -- narrower than the original plan
-- sketch (which had this command also place+type both end inserters); simplified during
-- implementation per the plan's own flagged Open Question #3 ("exact algorithm needs its
-- own design pass"). Async like fac_building_place_start/_status: the companion really
-- walks the path (no teleporting) and consumes real transport-belt/underground-belt items,
-- one tile per queue tick.
-- Confirmed straight from the engine's own prototype data (not the ambiguous/contradictory
-- wiki wording -- cubic dev ai bot flagged this as an off-by-one, 2026-07-04):
-- /base/prototypes/entity/transport-belts.lua's "underground-belt" (yellow tier) entry has
-- max_distance = 5 -- entrance and exit tiles can be up to 5 tiles apart (4 tiles of actual
-- underground gap in between), NOT 4 tiles apart. Named to match the engine field exactly
-- so this stays unambiguous.

local u = require("commands.init")
local pathfind = require("commands.pathfind")
local core = require("commands.queues_core")
local requests = require("commands.controller_requests")

local M = {}

local UNDERGROUND_MAX_DISTANCE = 5   -- yellow-tier underground-belt (entrance-to-exit span)

local function step_dir(a, b)
  if b.x > a.x then return defines.direction.east end
  if b.x < a.x then return defines.direction.west end
  if b.y > a.y then return defines.direction.south end
  return defines.direction.north
end

-- the items a route is built of: belts, or (pipe mode) pipes
local ITEMS = {
  belt = {plain = "transport-belt", underground = "underground-belt"},
  pipe = {plain = "pipe", underground = "pipe-to-ground"},
}

local function opposite(dir) return (dir + 8) % 16 end

-- ticks a companion gets to step off a pipe tile she stands on, below the queues'
-- universal no-progress backstop (600); she aims STEP_OFF_DISTANCE tiles sideways
local STEP_OFF_TICKS = 300
local STEP_OFF_DISTANCE = 3
-- fresh walks to a route tile after its approach deadline ran out, before the route
-- fails (each one with a new path request, a new deadline and a stand spot reach - 2
-- short of the tile, on her side)
local APPROACH_RETRIES = 2

-- opts (optional, 2026-11-06): {pure = true} -- the route avoids every tile something
-- from outside would put items onto or take them from (pathfind.lua, fed_tiles): a plate
-- belt must carry only its own plates. {pipe = true} (blue science B1') lays a fluid
-- pipeline instead: pipes and pipe-to-ground pairs (pathfind.lua pipe mode), the same
-- queue, walk and item rules. A pipe-to-ground's surface connection is on its facing
-- side, so an entrance faces back toward the source and an exit toward the sink.
function M.start_belt_connect(cid, from_pos, to_pos, opts)
  local c = core.valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  -- Task-pool ownership (2026-07-08, task #42; task_pool.lua never calls this): while a
  -- step holds her the route is queued (controller_requests.lua: never refused, started
  -- by the scheduler); a plan only searches -- it needs no body and runs at once
  if not (opts and opts.plan) then
    local queued = requests.gate(cid, "belt", {from = from_pos, to = to_pos, opts = opts},
                                 from_pos)
    if queued then return queued end
  end
  local surf = c.entity.surface
  local force = c.entity.force

  local pipe = opts and opts.pipe and true or false
  local items = pipe and ITEMS.pipe or ITEMS.belt
  local path, reason = pathfind.find_path(surf, from_pos, to_pos, force, opts)
  if not path and (reason == "dest-fed" or (opts and opts.pure) or pipe or (opts and opts.plan)) then
    -- (pipe mode: the search already hops as far as a pipe-to-ground reaches; a plan
    -- reports the search's own result, not the straight-pair fallback)
    -- no underground fallback for a pure route (independent review 2026-11-06): the pair
    -- is placed without the fed-tile check (for dest-fed its exit would even stand on
    -- that fed tile), and an underground exit on the caller's join tile cannot be turned
    -- into the belt it must feed (turning an underground swaps its input/output sides)
    return {error = "no path", reason = reason, expansions = pathfind.last_expansions}
  end
  if not path then
    -- No walkable route at all within the search budget -- try a direct underground-belt
    -- pair across the gap (only when it's a straight axis-aligned hop within the yellow
    -- tier's max distance; A* already tried routing AROUND anything shorter/bypassable).
    local fx, fy = math.floor(from_pos.x), math.floor(from_pos.y)
    local tx, ty = math.floor(to_pos.x), math.floor(to_pos.y)
    local same_row = (fx == tx) or (fy == ty)
    local dist = math.abs(tx - fx) + math.abs(ty - fy)
    if same_row and dist >= 1 and dist <= UNDERGROUND_MAX_DISTANCE then
      path = {
        {x = fx, y = fy, dir = step_dir({x = fx, y = fy}, {x = tx, y = ty}), underground = "entrance"},
        {x = tx, y = ty, dir = step_dir({x = fx, y = fy}, {x = tx, y = ty}), underground = "exit"},
      }
    else
      -- `reason` distinguishes WHY find_path failed (task #43 diagnostic follow-up,
      -- 2026-07-10): "start-blocked" / "dest-blocked" / "unreachable" (2026-10-23) /
      -- "budget-exhausted". Additive
      -- only -- `error` stays exactly "no path" so every existing caller checking
      -- `.get("error")` for truthiness is unaffected.
      return {error = "no path", reason = reason or "budget-exhausted"}
    end
  else
    -- Recompute each tile's direction as OUTGOING (toward the next tile), not the A*
    -- search's internal "arrived from" bookkeeping -- a Factorio belt's direction is the
    -- way it moves items (matches the tile-to-tile step it feeds INTO), so tile i's belt
    -- must face tile i+1, not tile i-1. The last tile has no next -- continue straight.
    for i = 1, #path do
      if path[i + 1] then
        path[i].dir = step_dir(path[i], path[i + 1])
      else
        path[i].dir = (path[i - 1] and path[i - 1].dir) or defines.direction.north
      end
    end
    -- an entrance's outgoing direction points at its exit; a pipe-to-ground entrance must
    -- face the other way (its surface side toward the source)
    if pipe then
      for _, node in ipairs(path) do
        if node.underground == "entrance" then node.dir = opposite(node.dir) end
      end
    end
  end

  local need_belt, need_underground = 0, 0
  for _, node in ipairs(path) do
    if node.underground then need_underground = need_underground + 1
    else need_belt = need_belt + 1 end
  end
  -- "plan" (0.16.145): the route and its item need only -- nothing is started, no items
  -- are checked (a caller checks a route exists before building what it connects)
  if opts and opts.plan then
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
  local have_belt = inv.get_item_count(items.plain)
  local have_underground = inv.get_item_count(items.underground)
  if have_belt < need_belt or have_underground < need_underground then
    -- the field names stay "belt" for both kinds (one status shape for the callers)
    return {
      error = pipe and "Insufficient pipe items" or "Insufficient belt items",
      need_belt = need_belt, need_underground = need_underground,
      have_belt = have_belt, have_underground = have_underground
    }
  end

  storage.belt_queues[cid] = {path = path, idx = 1, tiles_placed = 0, state = "placing",
    pipe = pipe,
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
    if q.state == "done" or q.state == "failed" then return false end

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
      elseif game.tick >= q.approach_deadline and (q.approach_tries or 0) < APPROACH_RETRIES then
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
      elseif game.tick >= q.approach_deadline then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.failed = "cannot reach belt tile (" .. node.x .. "," .. node.y .. ") -- " ..
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

    -- q.pipe is nil on records from before pipe mode: those are belts
    local items = q.pipe and ITEMS.pipe or ITEMS.belt
    local item = node.underground and items.underground or items.plain
    local pos = {x = node.x, y = node.y}

    -- A pipe collides with characters (a belt and a pipe-to-ground do not -- live
    -- 2026-11-06: "Cannot place pipe" with the companion standing on the start tile;
    -- core/lualib/collision-mask-defaults.lua: pipe = building() with the player layer,
    -- pipe-to-ground = building_walkable() without it). She steps off the tile first,
    -- sideways to the route, by walking; bounded. (Another character -- the player --
    -- on a route tile still fails the route as "Cannot place pipe"; planning tests a
    -- belt, which characters do not block.)
    if q.pipe and not node.underground then
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
    -- `type` (input/output) is a create_entity-only field for underground belts, not a
    -- valid can_place_entity param -- keep the collision check's args separate so an
    -- unrecognized key can't make the check itself error or behave unexpectedly.
    if not surf.can_place_entity{name = item, position = pos, direction = node.dir, force = c.entity.force} then
      q.failed = "Cannot place " .. item .. " at (" .. node.x .. "," .. node.y .. ")"
      q.run_end_tick = game.tick
      q.state = "failed"; return false
    end
    local create_args = {name = item, position = pos, direction = node.dir, force = c.entity.force}
    if node.underground and not q.pipe then
      create_args.type = (node.underground == "entrance") and "input" or "output"
    end
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
