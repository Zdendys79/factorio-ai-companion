-- AI Companion - nearest-entity / nearest-tile search shared by fac_world_nearest and
-- fac_resource_nearest. WHY: a single capped find_entities_filtered returns an arbitrary
-- subset, so "nearest of the first N found" is not the nearest; here the search grows
-- ring by ring and the answer is the true minimum distance within the first ring that
-- holds a match. WHAT: no result cap is ever applied before the minimum is taken.
local u = require("commands.init")

local M = {}

-- Circle radii tried in order; past the last one the whole MAX_HALF square is searched.
local RINGS = {32, 96, 200}
M.MAX_HALF = 200

-- A circle of radius r holds every candidate nearer than r, so the minimum within the
-- first non-empty circle is the global minimum; the square is the final catch-all.
local function search_areas(center)
  local areas = {}
  for _, r in ipairs(RINGS) do areas[#areas + 1] = {position = center, radius = r} end
  local h = M.MAX_HALF
  areas[#areas + 1] = {area = {{center.x - h, center.y - h}, {center.x + h, center.y + h}}}
  return areas
end

local function with_area(filter, area)
  local f = {}
  for k, v in pairs(filter) do f[k] = v end
  for k, v in pairs(area) do f[k] = v end
  return f
end

-- The entity of `filter` (find_entities_filtered keys, no area/limit) nearest to `center`
-- on `surf`, with its distance; nil when none exists within MAX_HALF.
function M.nearest_entity(surf, center, filter)
  for _, area in ipairs(search_areas(center)) do
    local es = surf.find_entities_filtered(with_area(filter, area))
    if #es > 0 then
      local best = surf.get_closest(center, es)
      if best and best.valid then return best, u.distance(best.position, center) end
      u.log_error("surface.get_closest returned no entity for " .. #es .. " candidates", "nearest_entity")
      local min
      for _, e in ipairs(es) do
        local d = u.distance(e.position, center)
        if not min or d < min then min, best = d, e end
      end
      return best, min
    end
  end
  return nil
end

-- Tile membership in a circle is judged by the tile centre while distances use the tile
-- position (its corner), so a closer tile may sit just outside the circle that found
-- the first one; this much margin on the re-search covers it.
local TILE_MARGIN = 1.5

local function min_tile(tiles, center)
  local best, min
  for _, t in ipairs(tiles) do
    local d = u.distance(t.position, center)
    if not min or d < min then min, best = d, t.position end
  end
  return best, min
end

-- The position of the tile of `names` nearest to `center` and its distance; nil when
-- none exists within MAX_HALF.
function M.nearest_tile(surf, center, names)
  for _, area in ipairs(search_areas(center)) do
    local tiles = surf.find_tiles_filtered(with_area({name = names}, area))
    if #tiles > 0 then
      local best, min = min_tile(tiles, center)
      if area.radius then
        local again = surf.find_tiles_filtered{name = names, position = center, radius = min + TILE_MARGIN}
        best, min = min_tile(again, center)
      end
      return best, min
    end
  end
  return nil
end

return M
