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

local MAX_SEARCH_MARGIN = 15     -- tiles of slack around the from/to bounding box
local MAX_NODES = 2500           -- hard cap on A* expansions (bounded, no infinite loop)

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

-- 4-directional A* (belts are axis-aligned). Returns an ordered list of
-- {x, y, dir} (dir = the direction of travel INTO that tile, nil for the start tile),
-- or nil if no route was found within the search budget.
function M.find_path(surf, from, to, force)
  local fx, fy = math.floor(from.x), math.floor(from.y)
  local tx, ty = math.floor(to.x), math.floor(to.y)
  local minx = math.min(fx, tx) - MAX_SEARCH_MARGIN
  local maxx = math.max(fx, tx) + MAX_SEARCH_MARGIN
  local miny = math.min(fy, ty) - MAX_SEARCH_MARGIN
  local maxy = math.max(fy, ty) + MAX_SEARCH_MARGIN
  local is_blocked = make_is_blocked(surf, force)
  -- The start tile is seeded directly into `open` (never evaluated as a "neighbor"),
  -- so it needs its own explicit check for the same reason the destination tile does.
  if is_blocked(fx, fy) then return nil end

  local function h(x, y) return math.abs(tx - x) + math.abs(ty - y) end

  local open = {{x = fx, y = fy, dir = nil, g = 0, f = h(fx, fy)}}
  local came_from = {}                    -- state_key -> predecessor node
  local gscore = {[state_key(fx, fy, nil)] = 0}
  local visited = {}
  local expansions = 0

  while #open > 0 and expansions < MAX_NODES do
    -- pop lowest-f (linear scan -- MAX_NODES bounds worst case; a real priority queue
    -- isn't worth the complexity for the short corridors this command targets)
    local bi, bf = 1, open[1].f
    for i = 2, #open do if open[i].f < bf then bi, bf = i, open[i].f end end
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
            local ng = cur.g + 1 + turn_penalty
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
  return nil   -- no path found within the search budget
end

return M
