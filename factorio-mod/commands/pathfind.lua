-- AI Companion v0.9.0 - route pathfinding (Stage 0.2, 2026-07-04): since 0.16.193 a
-- fluid pipeline's only (pipe mode) -- belt routes are planned in Python (factorio-ai
-- src/rl/belt_route.py, docs/belt_planning.md step 5), their pure / underground options
-- here gone. A* over the tile grid between two points, avoiding anything that blocks a
-- transport-belt (water, cliffs, existing buildings/trees/rocks -- delegated to the
-- ENGINE's own surf.can_place_entity check rather than re-implementing collision rules,
-- so it stays correct as the game's placement logic evolves), with a small turn-penalty
-- so the result is a reasonably direct corridor, not a serpentine walk ("not just some
-- zigzagging snake"). Bounded search area + node cap so a genuinely blocked/far target fails
-- fast instead of burning the RCON command's time budget.
--
-- Resource tiles are ordinary ground: a belt may cross an ore/coal/stone patch (Zdendys
-- 2026-10-24: "why shouldn't belts go over a resource patch?"). Until 0.16.136 is_blocked
-- had a resource check meant to route around patches, but it queried the integer tile
-- CORNER with radius 0.3 while resource entities sit at tile CENTRES -- live 2026-10-24 it
-- matched 0 of 491 ore tiles, so it never blocked ore/coal/stone (only crude oil, whose
-- collision box is large, could have matched) and was removed.
local reserved = require("commands.reserved_tiles")

local M = {}

-- MAX_SEARCH_MARGIN raised 15->40 (2026-07-05, Zdendys live-caught: a diagnostic sweep of
-- 7 distances/shapes on ONE fresh map found a NON-monotonic success pattern by bounding-box
-- area -- e.g. a 2340-tile-area route failed "no path" while a LARGER 7018-tile-area route
-- on the SAME map succeeded -- inconsistent with a pure node-budget explanation (which would
-- predict smaller-area routes succeed more reliably than larger ones). This points to a real
-- obstacle (most likely a lake, since this mod's map-gen deliberately favors a nearby water
-- body for the power plant) that some specific routes need to detour around by MORE than the
-- old 15-tile margin, independent of how many nodes the search budget allows -- no margin
-- increase can be substituted for by a bigger MAX_NODES, since a blocked tile just outside
-- the bounding box is never even a candidate node regardless of budget. 40 gives real
-- clearance for a sizeable lake without exploding the search area unreasonably (the
-- companion's own tie-break fix, added the same day, already lets the search converge
-- toward the goal instead of fanning out across the whole box, so a wider margin shouldn't
-- by itself blow the existing MAX_NODES budget for the common case).
local MAX_SEARCH_MARGIN = 60     -- tiles of slack around the from/to bounding box (2026-07-08,
-- raised 40->60, Zdendys: "vetsina vody nelze podejit" -- a genuinely wide lake needs real
-- room to route around, not just an underground hop's short span; 40 already got raised
-- once for the same reason (see history above) and
-- live-caught tonight (bc_0708night1) still hit "no path" on a ~93-tile route.
-- (the belt search's MAX_NODES 128000 and its tuning history went with the belt mode,
-- 0.16.193 -- git history keeps them; the pipe search has its own PIPE_MAX_NODES)

-- Shore buffer (2026-07-08, Zdendys: "go around water at a distance of at least 5-10 from the shore"):
-- a SOFT cost, not a hard block, added to any tile within SHORE_BUFFER of a water tile, so
-- the route PREFERS to stay clear of the coast when a choice exists (leaves room for the
-- power plant's own shore-adjacent structures, and avoids a corridor that hugs the water's
-- edge for its whole length) without making an unavoidable coast-hugging stretch impossible.
local SHORE_BUFFER = 8
local SHORE_PENALTY = 3

local function tile_key(x, y) return x .. ":" .. y end
-- State key for the SEARCH bookkeeping (visited/gscore/came_from) MUST include the arrival
-- direction, not just (x,y): edge cost depends on it via turn_penalty below, so two paths
-- reaching the same tile with equal g but different incoming direction are genuinely
-- different states -- collapsing them onto one (x,y) key lets whichever is expanded FIRST
-- permanently block a later, better-oriented arrival at the same g (or even lower cost
-- overall once its own better-turn continuation is considered), breaking A*'s optimality
-- (cubic dev ai bot, 2026-07-04: worked example with a wall forcing an extra turn).
-- (Corrected 2026-07-10, adversarial verify: path reconstruction below also uses
-- state_key via came_from, not tile_key -- this comment previously claimed otherwise;
-- tile_key is only ever used by the make_is_blocked/make_near_water caches above.)
-- `ug` (2026-11-06): the node is a pipe-to-ground EXIT, which may only continue
-- straight -- its expansion differs from a plain belt's, so it is a separate state.
local function state_key(x, y, dir, ug)
  return x .. ":" .. y .. ":" .. tostring(dir) .. (ug and ":u" or "")
end

-- UNDERGROUND HOPS: besides the 4 neighbours, a node entered straight (not the start,
-- not an exit) may become a pipe-to-ground ENTRANCE whose EXIT is PIPE_UG_MAX_DISTANCE
-- or fewer tiles ahead in the same direction, hopping over whatever lies between. The
-- exit only continues straight. No hop where a pipe-to-ground of the same axis stands
-- within that distance of the hop on that line: the game would pair the new entrance
-- or exit with it.
local OWN_PATH_LOOKBACK = 16   -- path tiles a crossing route checks it does not step on
-- pipe mode (blue science B1'): pipe-to-ground links at a centre distance of up to 10
-- (prototype max_underground_distance 10; measured live 2026-11-05: 10 links, 11 not);
-- a surface pipe costs 1.5 per tile, a pair k + 1 -- the run stays underground
local PIPE_UG_MAX_DISTANCE = 10
local PIPE_STEP_COST = 1.5
local PIPE_HOP_PENALTY = 1
-- entity types whose prototypes can have fluid boxes (base + Space Age; a heat exchanger
-- is a "boiler"; checked against the 2.1.24 prototype data); an assembler or
-- an electric mining drill counts even when its box is unused -- a pipe beside it could
-- still join it, so the route keeps off (conservative)
local PIPE_FLUID_TYPES = {"pipe", "pipe-to-ground", "storage-tank", "pump", "offshore-pump",
  "boiler", "generator", "fluid-turret", "mining-drill", "assembling-machine", "furnace",
  "reactor", "infinity-pipe", "valve", "fusion-generator",
  "fusion-reactor", "thruster", "agricultural-tower", "rocket-silo", "fluid-wagon"}
-- pipe mode tries up to 9 hops from every expanded node (independent review: a search
-- with no route would otherwise have run the old belt search's budget, ~3x the heap
-- work, in one tick); weighted (PIPE_H_WEIGHT), a live 456-tile crude route took 21456 expansions
local PIPE_MAX_NODES = 64000
-- weighted A* for pipes (see find_path): routes at most 1.5x the cheapest cost
local PIPE_H_WEIGHT = 1.5

-- Per-run cache: the same neighbor tile is checked from multiple expanded nodes, and
-- surf.can_place_entity is a real engine call (not a cheap table lookup) -- memoizing
-- avoids redundant checks within one search.
local function make_is_blocked(surf, force)
  local cache = {}
  return function(x, y)
    local key = tile_key(x, y)
    local cached = cache[key]
    if cached ~= nil then return cached end
    local blocked = not surf.can_place_entity{
      name = "transport-belt", position = {x, y},
      direction = defines.direction.north, force = force
    }
    cache[key] = blocked
    return blocked
  end
end

local DIRS = {
  {dx = 1, dy = 0, dir = defines.direction.east}, {dx = -1, dy = 0, dir = defines.direction.west},
  {dx = 0, dy = 1, dir = defines.direction.south}, {dx = 0, dy = -1, dir = defines.direction.north},
}

-- Memoized "is there water within SHORE_BUFFER tiles" check, same caching pattern as
-- make_is_blocked above (count_tiles_filtered is a real engine call). A single area query
-- per newly-discovered tile, not a hard block -- see SHORE_PENALTY comment above.
local function make_near_water(surf)
  local cache = {}
  return function(x, y)
    local key = tile_key(x, y)
    local cached = cache[key]
    if cached ~= nil then return cached end
    -- Same water-tile name set used elsewhere in this mod (e.g. demonstrator.py's own
    -- terrain surveys) -- shallow-water/mud variants are still unwalkable-for-belts water,
    -- not just "water"/"deepwater".
    local near = surf.count_tiles_filtered{
      area = {{x - SHORE_BUFFER, y - SHORE_BUFFER}, {x + SHORE_BUFFER, y + SHORE_BUFFER}},
      name = {"water", "deepwater", "water-shallow", "water-mud"}
    } > 0
    cache[key] = near
    return near
  end
end

-- Binary min-heap for the A* open list (2026-07-10, task #43 perf follow-up).
-- The OLD code popped the lowest-f node via a LINEAR SCAN over the entire `open`
-- array on every iteration -- with MAX_NODES=4000 and up to 4 pushes per
-- expansion, `open` can grow into the thousands, making every pop O(|open|) and
-- the whole search roughly O(n^2) instead of the O(n log n) a proper priority
-- queue gives. Lua has no built-in decrease-key heap, so this uses the standard
-- "lazy deletion" pattern: a state can be pushed multiple times (once per
-- successful relaxation -- the OLD linear-scan code already relied on this too,
-- since it never removed a stale `open` entry on relaxation either, only ever
-- appended a fresh one), and the existing `visited[state_key]` check (unchanged,
-- right after `heap_pop` at the call site below) discards a stale duplicate the
-- first time it's popped after its state has already been expanded via a
-- fresher, cheaper entry. This is safe BECAUSE edge costs are non-negative: each
-- successive relaxation of the same state produces a STRICTLY smaller g (the
-- `ng < gscore[nk]` guard below enforces this), and since h() depends only on
-- position (not on which relaxation produced the entry), a strictly smaller g
-- means a strictly smaller f too -- so the freshest (cheapest) entry for any
-- given state ALWAYS has the smallest f among all of that state's own entries,
-- and is therefore ALWAYS popped before any of its own staler duplicates,
-- regardless of push order. This is the exact same property the old linear scan
-- already depended on (it too just picked the global-minimum f/g node each
-- iteration, oblivious to which entries were "stale") -- a pure performance
-- change, not a new correctness assumption.
--
-- Comparator: lowest f first; among equal f, prefer LARGER g (2026-07-05
-- tie-break, see the historical comment preserved at the call site below --
-- unchanged, still biases the search to march toward the goal instead of
-- fanning out on a plateau); among equal f AND equal g (a real tie between two
-- distinct nodes), prefer whichever was pushed FIRST (`seq`, a monotonically
-- increasing push counter) -- this exactly reproduces the old linear scan's own
-- de-facto tie-break (it iterated `open` in insertion order and only overwrote
-- its running-best on a STRICT `<`, so among full ties the earliest-inserted
-- entry always won), so the heap's pop order is IDENTICAL to the old scan's pop
-- order at every single step, not just "equally optimal" -- same algorithm
-- trace, same expansions count, same final path, for any given input.
local function heap_less(a, b)
  if a.f ~= b.f then return a.f < b.f end
  if a.g ~= b.g then return a.g > b.g end
  return a.seq < b.seq
end

local function heap_push(heap, node)
  heap[#heap + 1] = node
  local i = #heap
  while i > 1 do
    local parent = math.floor(i / 2)
    if heap_less(heap[i], heap[parent]) then
      heap[i], heap[parent] = heap[parent], heap[i]
      i = parent
    else
      break
    end
  end
end

-- Pops and returns the minimum element (per heap_less above). Caller must only
-- call this on a non-empty heap (the while loop at the call site below already
-- guards on `#open > 0` before calling, matching the old code's own guard).
local function heap_pop(heap)
  local n = #heap
  local top = heap[1]
  heap[1] = heap[n]
  heap[n] = nil
  n = n - 1
  local i = 1
  while true do
    local left, right = i * 2, i * 2 + 1
    local smallest = i
    if left <= n and heap_less(heap[left], heap[smallest]) then smallest = left end
    if right <= n and heap_less(heap[right], heap[smallest]) then smallest = right end
    if smallest == i then break end
    heap[i], heap[smallest] = heap[smallest], heap[i]
    i = smallest
  end
  return top
end

-- 4-directional A* (belts are axis-aligned). Returns an ordered list of
-- {x, y, dir} (dir = the direction of travel INTO that tile, nil for the start tile),
-- or nil if no route was found within the search budget. On nil, a second string
-- return value distinguishes WHY (2026-07-10, task #43 diagnostic follow-up):
-- "start-blocked" / "dest-blocked" / "unreachable" (2026-10-23: open list emptied) /
-- "budget-exhausted" (PIPE_MAX_NODES hit) -- callers that only capture
-- one return value (`local path = pathfind.find_path(...)`) are unaffected, per Lua's
-- own multi-return semantics (extra return values are simply discarded).
-- opts: {pipe = true} (required since 0.16.193 -- belts are Python's; anything else
-- answers nil, "pipe-only") plans a fluid pipeline: hops of up to PIPE_UG_MAX_DISTANCE
-- (pipe-to-ground pairs, preferred over surface pipe), and no surface step onto a tile
-- beside a foreign fluid entity (start and destination exempt: they touch the source
-- and the sink -- an end touching two fluid entities fails as "start-fluid-mixed" /
-- "dest-fluid-mixed"; an end with no usable neighbour as "start-enclosed" /
-- "dest-enclosed"; the node budget is PIPE_MAX_NODES). Entries carry the same
-- underground = "entrance" / "exit" marks.
function M.find_path(surf, from, to, force, opts)
  M.last_expansions = 0          -- diagnostic: the last search's expansions (plan replies)
  if not (opts and opts.pipe) then return nil, "pipe-only" end
  local fx, fy = math.floor(from.x), math.floor(from.y)
  local tx, ty = math.floor(to.x), math.floor(to.y)
  local minx = math.min(fx, tx) - MAX_SEARCH_MARGIN
  local maxx = math.max(fx, tx) + MAX_SEARCH_MARGIN
  local miny = math.min(fy, ty) - MAX_SEARCH_MARGIN
  local maxy = math.max(fy, ty) + MAX_SEARCH_MARGIN
  local is_blocked = make_is_blocked(surf, force)
  -- a reserved tile (commands/reserved_tiles.lua: a block's join tile a later route must
  -- reach) is no tile for this route -- unless it is the route's own start or end
  local res = reserved.lookup()
  if res then
    local placeable = is_blocked
    is_blocked = function(x, y)
      local col = res[x]
      if col and col[y] and not (x == fx and y == fy) and not (x == tx and y == ty) then
        return true
      end
      return placeable(x, y)
    end
  end
  local near_water = make_near_water(surf)
  -- The start tile is seeded directly into `open` (never evaluated as a "neighbor"),
  -- so it needs its own explicit check for the same reason the destination tile does.
  if is_blocked(fx, fy) then return nil, "start-blocked" end
  -- Destination-blocked check (2026-07-10, task #43 diagnostic follow-up): without this,
  -- a destination sitting on water/a building/anything is_blocked rejects can NEVER be
  -- added to `open` (it's only ever validated as a side effect of neighbor-expansion
  -- below), so the search silently exhausts the whole budget before returning nil --
  -- indistinguishable from a genuine "too far/obstacle-heavy" failure. Checking it here
  -- fails fast AND tags the result with a distinguishable reason. `is_blocked` is a
  -- memoized per-call closure (see make_is_blocked above), so this extra call just
  -- seeds the (tx,ty) cache entry early -- no different from it being queried later
  -- during normal expansion, no stale-cache risk.
  if is_blocked(tx, ty) then return nil, "dest-blocked" end

  -- PIPE mode (opts.pipe, 2026-11-06, blue science B1'): the same search lays a fluid
  -- pipeline -- plain steps are pipes, hops are pipe-to-ground pairs (up to
  -- PIPE_UG_MAX_DISTANCE). A surface pipe costs more than the tiles a pair covers, so the
  -- run stays underground (it does not block walking, and touches nothing on the way),
  -- and a hop needs no obstacle ahead.
  -- The cheapest tile in pipe mode is one of a longest hop, (max + penalty) / max = 1.1;
  -- scaling the heuristic by it keeps it admissible and consistent (a step costs 1.5, a
  -- hop of k costs k + 1 >= 1.1 k for k <= 10) while narrowing the search band of a long
  -- pipeline (with h = Manhattan alone every tile within ~0.14 x length of the line would
  -- tie with the best route).
  -- On top of that the pipe search is WEIGHTED (PIPE_H_WEIGHT; live 2026-11-06: a
  -- 456-tile crude route over a real map ran out of the node budget with the plain
  -- bound): the route found costs at most PIPE_H_WEIGHT x the cheapest one, which for a
  -- pipeline only means a few more pieces -- finding one at all is what matters.
  local h_scale = PIPE_H_WEIGHT * (PIPE_UG_MAX_DISTANCE + PIPE_HOP_PENALTY)
                  / PIPE_UG_MAX_DISTANCE
  local function h(x, y) return h_scale * (math.abs(tx - x) + math.abs(ty - y)) end

  local ug_max = PIPE_UG_MAX_DISTANCE
  local ug_type = "pipe-to-ground"
  local step_cost = PIPE_STEP_COST
  local hop_penalty = PIPE_HOP_PENALTY
  local DIR_OF = {}
  for _, d in ipairs(DIRS) do DIR_OF[d.dir] = d end
  -- whether an underground of the axis of `d` stands on the line through (x, y) within
  -- ug_max either way (memoized per tile and axis): the game would pair with it
  local ug_axis_cache = {}
  local function axis_underground_near(x, y, d)
    local key = tile_key(x, y) .. ":" .. (d.dir % 8)
    local v = ug_axis_cache[key]
    if v ~= nil then return v end
    local ax, bx = x - math.abs(d.dx) * ug_max, x + math.abs(d.dx) * ug_max
    local ay, by = y - math.abs(d.dy) * ug_max, y + math.abs(d.dy) * ug_max
    v = false
    for _, e in pairs(surf.find_entities_filtered{
        area = {{ax + 0.1, ay + 0.1}, {bx + 0.9, by + 0.9}}, type = ug_type}) do
      if (e.direction - d.dir) % 8 == 0 then v = true break end
    end
    ug_axis_cache[key] = v
    return v
  end
  -- PIPE mode: a plain pipe joins every adjacent fluid box, so it may not stand next to a
  -- FOREIGN fluid entity (crude must not mix with water or steam). The tiles touching any
  -- fluid entity's footprint are collected once (one area query); the start and goal
  -- tiles are exempt -- they are meant to touch their source and sink, and nothing else:
  -- an end tile touching TWO fluid entities is refused below (independent review). A
  -- pipe-to-ground connects only on its facing side (the route itself), so hop ends are
  -- exempt too. fluid_adj[tile] = the set of fluid entities touching it.
  local fluid_adj = {}
  local anon = 0                -- ids for fluid entities without a unit_number
  do
    -- the entity types that can carry a fluid box (a long pipeline's box holds many trees
    -- and rocks -- those are not queried); each is still checked for real fluid boxes
    for _, e in pairs(surf.find_entities_filtered{area = {{minx - 6, miny - 6}, {maxx + 7, maxy + 7}},
        type = PIPE_FLUID_TYPES}) do
      local ok, boxes = pcall(function() return e.prototype.fluidbox_prototypes end)
      if ok and boxes and #boxes > 0 then
        local b = e.bounding_box
        local x0, y0 = math.floor(b.left_top.x + 0.01), math.floor(b.left_top.y + 0.01)
        local x1, y1 = math.ceil(b.right_bottom.x - 0.01) - 1, math.ceil(b.right_bottom.y - 0.01) - 1
        anon = anon + 1
        local id = e.unit_number or ("anon" .. anon)
        local function mark(x, y)
          local k = tile_key(x, y)
          fluid_adj[k] = fluid_adj[k] or {}
          fluid_adj[k][id] = true
        end
        for x = x0, x1 do mark(x, y0 - 1) mark(x, y1 + 1) end
        for y = y0, y1 do mark(x0 - 1, y) mark(x1 + 1, y) end
      end
    end
  end
  local function fluid_touch(x, y)
    return fluid_adj[tile_key(x, y)] ~= nil and not (x == fx and y == fy)
           and not (x == tx and y == ty)
  end
  do
    -- an end pipe joins every fluid entity beside it: more than one = a foreign fluid
    -- would mix in at the very first (or last) tile
    for _, e in ipairs({{fx, fy, "start-fluid-mixed"}, {tx, ty, "dest-fluid-mixed"}}) do
      local n = 0
      for _ in pairs(fluid_adj[tile_key(e[1], e[2])] or {}) do n = n + 1 end
      if n > 1 then return nil, e[3] end
    end
    -- fail fast on an enclosed end (the search would otherwise expand the whole box):
    -- the start needs a free, clean neighbour (it cannot hop -- no direction yet); the
    -- goal needs a free neighbour (an exit may arrive there, exits touch nothing)
    local start_ok, goal_ok = false, false
    for _, d in ipairs(DIRS) do
      local sx, sy = fx + d.dx, fy + d.dy
      if not is_blocked(sx, sy) and not fluid_touch(sx, sy) then start_ok = true end
      if not is_blocked(tx + d.dx, ty + d.dy) then goal_ok = true end
    end
    if not start_ok and not (math.abs(tx - fx) + math.abs(ty - fy) <= 1) then
      return nil, "start-enclosed"
    end
    if not goal_ok then return nil, "dest-enclosed" end
  end
  local max_nodes = PIPE_MAX_NODES

  -- a route never steps onto its own start or a tile of its recent path: with
  -- crossings, looping back to enter a hop straight can look cheapest (live 2026-11-06:
  -- an underground entrance planned on the start tile's own belt). Each node carries its
  -- parent, so no state-key strings are built on this hot path (independent review).
  local function on_own_path(node, x, y)
    if x == fx and y == fy then return true end
    local n, steps = node, 0
    while n and steps < OWN_PATH_LOOKBACK do
      if n.x == x and n.y == y then return true end
      n = n.parent
      steps = steps + 1
    end
    return false
  end

  local open = {}
  local seq = 0                           -- monotonic push counter, see heap_less above
  seq = seq + 1
  heap_push(open, {x = fx, y = fy, dir = nil, g = 0, f = h(fx, fy), seq = seq})
  local came_from = {}                    -- state_key -> predecessor node
  local gscore = {[state_key(fx, fy, nil)] = 0}
  local visited = {}
  local expansions = 0

  while #open > 0 and expansions < max_nodes do
    -- Pop lowest-f via the binary min-heap above (O(log n), see heap_pop/heap_less
    -- for the full mechanism + why its pop order is provably identical to the OLD
    -- linear-scan's pop order at every step). Tie-break toward the LARGER g
    -- (2026-07-05, Zdendys live-caught: a 134-tile route reported "no path" despite
    -- there being no water/cliffs in the way -- root cause: with a Manhattan
    -- heuristic and 4-directional movement, every tile inside the from/to bounding
    -- rectangle has the SAME f = g+h (the whole rectangle is one tied plateau), and
    -- the old tie-break ("keep whichever equal-f node was found first") made the
    -- search fan out breadth-first across nearly the ENTIRE rectangle before ever
    -- reaching the goal corner -- for a 121x58 box that's ~7000 tiles against a
    -- 2500-node cap, guaranteeing a false "no path" on a fully open field. Preferring
    -- the larger-g (equivalently smaller-h, i.e. closer to the goal) node among ties
    -- biases expansion to march toward the target instead of radiating outward evenly,
    -- without changing A*'s optimality guarantee at all (ties by definition share the
    -- same f, so picking a different one among them cannot produce a worse-than-optimal
    -- final path -- see the state_key/goal-test comments below, unaffected by this).
    local cur = heap_pop(open)
    local ck = state_key(cur.x, cur.y, cur.dir, cur.ug)
    if not visited[ck] then
      visited[ck] = true
      expansions = expansions + 1
      if cur.x == tx and cur.y == ty then
        -- Any (goal-tile, *) state popped here is guaranteed minimum-cost for the goal
        -- POSITION (not just for this particular direction): h() doesn't depend on dir, so
        -- among all direction-variants of the goal tile the lowest-g one always has the
        -- lowest f and is popped first (edge costs are non-negative, so g only grows along
        -- a path) -- position-only goal test is correct even though the state space isn't.
        -- (Pipe mode is weighted -- PIPE_H_WEIGHT: there the route is within 1.5x of the
        -- cheapest, not minimum; the lowest-g goal variant still pops first, h = 0 there.)
        -- an exit's predecessor is its entrance (hops start only from non-exit nodes)
        local path, node, after_exit, seen = {}, cur, false, {}
        while node do
          local entry = {x = node.x, y = node.y, dir = node.dir}
          if node.ug then entry.underground = "exit"
          elseif after_exit then entry.underground = "entrance" end
          after_exit = node.ug == true
          -- a tile used twice cannot be built (live 2026-11-06: a crossing route looped
          -- back over its own start) -- the expansion below avoids it; this is the net
          local tk = tile_key(node.x, node.y)
          if seen[tk] then M.last_expansions = expansions return nil, "self-overlap" end
          seen[tk] = true
          table.insert(path, 1, entry)
          node = came_from[state_key(node.x, node.y, node.dir, node.ug)]
        end
        M.last_expansions = expansions
        return path
      end
      -- underground hops: from a node entered straight that is not itself an exit
      if cur.dir and not cur.ug then
        local d = DIR_OF[cur.dir]
        -- a hop from anywhere: a pair is cheaper than the surface pipes it replaces, so
        -- the run is meant to stay underground (the axis check, an engine call, runs
        -- only once a free exit tile exists -- independent review: worst-case tick time)
        local axis_ok = nil
        if d then
          for k = 2, ug_max do
            local nx, ny = cur.x + d.dx * k, cur.y + d.dy * k
            if nx < minx or nx > maxx or ny < miny or ny > maxy then break end
            if not (nx == tx and ny == ty) and not is_blocked(nx, ny)
                and not on_own_path(cur, nx, ny) then
              if axis_ok == nil then axis_ok = not axis_underground_near(cur.x, cur.y, d) end
              if not axis_ok then break end
              local ng = cur.g + k + hop_penalty + (near_water(nx, ny) and SHORE_PENALTY or 0)
              local nk = state_key(nx, ny, cur.dir, true)
              -- (no relaxing an expanded state: the weighted pipe heuristic is not
              -- consistent, and came_from must stay the chain on_own_path checked)
              if not visited[nk] and ng < (gscore[nk] or math.huge) then
                gscore[nk] = ng
                came_from[nk] = cur
                seq = seq + 1
                heap_push(open, {x = nx, y = ny, dir = cur.dir, g = ng, f = ng + h(nx, ny),
                                 seq = seq, ug = true, parent = cur})
              end
            end
          end
        end
      end
      for _, d in ipairs(DIRS) do
        local nx, ny = cur.x + d.dx, cur.y + d.dy
        -- an underground exit only continues straight
        if (not cur.ug or d.dir == cur.dir)
            and nx >= minx and nx <= maxx and ny >= miny and ny <= maxy then
          -- No endpoint exemption: the destination tile must be a genuinely valid belt
          -- spot too (not water/occupied), same as every other tile on the route.
          if not is_blocked(nx, ny) and not on_own_path(cur, nx, ny)
              and not fluid_touch(nx, ny) then
            local turn_penalty = (cur.dir and cur.dir ~= d.dir) and 0.5 or 0
            local shore_penalty = near_water(nx, ny) and SHORE_PENALTY or 0
            local ng = cur.g + step_cost + turn_penalty + shore_penalty
            local nk = state_key(nx, ny, d.dir)
            if not visited[nk] and ng < (gscore[nk] or math.huge) then
              gscore[nk] = ng
              came_from[nk] = cur
              seq = seq + 1
              heap_push(open, {x = nx, y = ny, dir = d.dir, g = ng, f = ng + h(nx, ny), seq = seq,
                               parent = cur})
            end
          end
        end
      end
    end
  end
  -- 2026-10-23: an EMPTY open list means every tile reachable from the start (inside the
  -- search box) was expanded without meeting the goal -- the start or the goal sits in an
  -- enclosed pocket, and more PIPE_MAX_NODES cannot help. It used to be reported as
  -- "budget-exhausted" too, which made enclosed starts (live: a coal-belt end boxed in by
  -- boiler fuel chests, failing in 2 ticks) indistinguishable from genuinely long searches.
  M.last_expansions = expansions
  if #open == 0 then return nil, "unreachable" end
  return nil, "budget-exhausted"   -- node budget ran out before the goal was reached
end

return M
