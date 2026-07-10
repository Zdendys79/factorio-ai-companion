-- AI Companion v0.9.0 - Belt-connection pathfinding (Stage 0.2, 2026-07-04)
-- A* over the tile grid between two points, avoiding resource-entity tiles (a belt
-- corridor must route AROUND an un-mined ore/coal/stone patch, never over it -- Zdendys:
-- "mělo by se vyhýbat všem nalezištím i vodě") and anything else that blocks a
-- transport-belt (water, cliffs, existing buildings/trees/rocks -- delegated to the
-- ENGINE's own surf.can_place_entity check rather than re-implementing collision rules,
-- so it stays correct as the game's placement logic evolves), with a small turn-penalty
-- so the result is a reasonably direct corridor, not a serpentine walk ("ne jen nějaký
-- klikatý had"). Bounded search area + node cap so a genuinely blocked/far target fails
-- fast instead of burning the RCON command's time budget.
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
-- room to route around, not just underground-belt's 5-tile max span (see UNDERGROUND_MAX_
-- DISTANCE below); 40 already got raised once for the same reason (see history above) and
-- live-caught tonight (bc_0708night1) still hit "no path" on a ~93-tile route.
local MAX_NODES = 4000           -- hard cap on A* expansions (bounded, no infinite loop) -- raised
-- 2500->4000 alongside the margin increase so the larger search area doesn't just make the
-- SAME "no path" failure happen after burning more of the budget with no detour room to show
-- for it -- both numbers need to move together.

-- Shore buffer (2026-07-08, Zdendys: "vodu obcházet alespon ve vzdalenosti 5-10 od brehu"):
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
-- (cubic dev ai bot, 2026-07-04: worked example with a wall forcing an extra turn). tile_key
-- (position only) is still used for the FINAL path reconstruction lookup, which is fine --
-- that only needs a unique per-node identity, not de-duplication across directions.
local function state_key(x, y, dir) return x .. ":" .. y .. ":" .. tostring(dir) end

-- Per-run cache: the same neighbor tile is checked from multiple expanded nodes, and
-- surf.can_place_entity is a real engine call (not a cheap table lookup) -- memoizing
-- avoids redundant checks within one search.
local function make_is_blocked(surf, force)
  local cache = {}
  return function(x, y)
    local key = tile_key(x, y)
    local cached = cache[key]
    if cached ~= nil then return cached end
    local blocked
    if surf.count_entities_filtered{position = {x, y}, radius = 0.3, type = "resource"} > 0 then
      blocked = true
    else
      blocked = not surf.can_place_entity{
        name = "transport-belt", position = {x, y},
        direction = defines.direction.north, force = force
      }
    end
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

-- 4-directional A* (belts are axis-aligned). Returns an ordered list of
-- {x, y, dir} (dir = the direction of travel INTO that tile, nil for the start tile),
-- or nil if no route was found within the search budget. On nil, a second string
-- return value distinguishes WHY (2026-07-10, task #43 diagnostic follow-up):
-- "start-blocked" / "dest-blocked" / "budget-exhausted" -- callers that only capture
-- one return value (`local path = pathfind.find_path(...)`) are unaffected, per Lua's
-- own multi-return semantics (extra return values are simply discarded).
function M.find_path(surf, from, to, force)
  local fx, fy = math.floor(from.x), math.floor(from.y)
  local tx, ty = math.floor(to.x), math.floor(to.y)
  local minx = math.min(fx, tx) - MAX_SEARCH_MARGIN
  local maxx = math.max(fx, tx) + MAX_SEARCH_MARGIN
  local miny = math.min(fy, ty) - MAX_SEARCH_MARGIN
  local maxy = math.max(fy, ty) + MAX_SEARCH_MARGIN
  local is_blocked = make_is_blocked(surf, force)
  local near_water = make_near_water(surf)
  -- The start tile is seeded directly into `open` (never evaluated as a "neighbor"),
  -- so it needs its own explicit check for the same reason the destination tile does.
  if is_blocked(fx, fy) then return nil, "start-blocked" end
  -- Destination-blocked check (2026-07-10, task #43 diagnostic follow-up): without this,
  -- a destination sitting on water/a resource/anything is_blocked rejects can NEVER be
  -- added to `open` (it's only ever validated as a side effect of neighbor-expansion
  -- below), so the search silently exhausts the whole budget before returning nil --
  -- indistinguishable from a genuine "too far/obstacle-heavy" failure. Checking it here
  -- fails fast AND tags the result with a distinguishable reason. `is_blocked` is a
  -- memoized per-call closure (see make_is_blocked above), so this extra call just
  -- seeds the (tx,ty) cache entry early -- no different from it being queried later
  -- during normal expansion, no stale-cache risk.
  if is_blocked(tx, ty) then return nil, "dest-blocked" end

  local function h(x, y) return math.abs(tx - x) + math.abs(ty - y) end

  local open = {{x = fx, y = fy, dir = nil, g = 0, f = h(fx, fy)}}
  local came_from = {}                    -- state_key -> predecessor node
  local gscore = {[state_key(fx, fy, nil)] = 0}
  local visited = {}
  local expansions = 0

  while #open > 0 and expansions < MAX_NODES do
    -- Pop lowest-f (linear scan -- MAX_NODES bounds worst case; a real priority queue
    -- isn't worth the complexity for the short corridors this command targets), tie-
    -- breaking toward the LARGER g (2026-07-05, Zdendys live-caught: a 134-tile route
    -- reported "no path" despite there being no water/cliffs in the way -- root cause:
    -- with a Manhattan heuristic and 4-directional movement, every tile inside the
    -- from/to bounding rectangle has the SAME f = g+h (the whole rectangle is one tied
    -- plateau), and the old tie-break ("keep whichever equal-f node was found first")
    -- made the search fan out breadth-first across nearly the ENTIRE rectangle before
    -- ever reaching the goal corner -- for a 121x58 box that's ~7000 tiles against a
    -- 2500-node cap, guaranteeing a false "no path" on a fully open field. Preferring
    -- the larger-g (equivalently smaller-h, i.e. closer to the goal) node among ties
    -- biases expansion to march toward the target instead of radiating outward evenly,
    -- without changing A*'s optimality guarantee at all (ties by definition share the
    -- same f, so picking a different one among them cannot produce a worse-than-optimal
    -- final path -- see the state_key/goal-test comments below, unaffected by this).
    local bi, bf, bg = 1, open[1].f, open[1].g
    for i = 2, #open do
      local o = open[i]
      if o.f < bf or (o.f == bf and o.g > bg) then bi, bf, bg = i, o.f, o.g end
    end
    local cur = table.remove(open, bi)
    local ck = state_key(cur.x, cur.y, cur.dir)
    if not visited[ck] then
      visited[ck] = true
      expansions = expansions + 1
      if cur.x == tx and cur.y == ty then
        -- Any (goal-tile, *) state popped here is guaranteed minimum-cost for the goal
        -- POSITION (not just for this particular direction): h() doesn't depend on dir, so
        -- among all direction-variants of the goal tile the lowest-g one always has the
        -- lowest f and is popped first (edge costs are non-negative, so g only grows along
        -- a path) -- position-only goal test is correct even though the state space isn't.
        local path, node = {}, cur
        while node do
          table.insert(path, 1, {x = node.x, y = node.y, dir = node.dir})
          node = came_from[state_key(node.x, node.y, node.dir)]
        end
        return path
      end
      for _, d in ipairs(DIRS) do
        local nx, ny = cur.x + d.dx, cur.y + d.dy
        if nx >= minx and nx <= maxx and ny >= miny and ny <= maxy then
          -- No endpoint exemption: the destination tile must be a genuinely valid belt
          -- spot too (not ore/water/occupied), same as every other tile on the route --
          -- otherwise a caller-requested endpoint sitting on a resource tile would let
          -- the corridor terminate ON ore, contradicting the avoid-resource-tiles rule.
          if not is_blocked(nx, ny) then
            local turn_penalty = (cur.dir and cur.dir ~= d.dir) and 0.5 or 0
            local shore_penalty = near_water(nx, ny) and SHORE_PENALTY or 0
            local ng = cur.g + 1 + turn_penalty + shore_penalty
            local nk = state_key(nx, ny, d.dir)
            if ng < (gscore[nk] or math.huge) then
              gscore[nk] = ng
              came_from[nk] = cur
              open[#open + 1] = {x = nx, y = ny, dir = d.dir, g = ng, f = ng + h(nx, ny)}
            end
          end
        end
      end
    end
  end
  return nil, "budget-exhausted"   -- no path found within the search budget
end

return M
