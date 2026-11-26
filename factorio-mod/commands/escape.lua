-- Keep the way out free while building (factorio-ai docs/game_rules.md rule 93): a piece
-- must not close her in the build.
--
-- Before a piece that stands in a character's way is placed, a flood over the tiles round
-- her (a tile is free when a character could stand at its centre -- the engine's own
-- can_place_entity for "character": buildings, water, cliffs) asks whether she reaches the
-- ground outside the build's bounds (the whole plan's boxes, a ring of one tile round
-- them) now and whether she still does with the piece's box standing. Only a piece that
-- takes her way out away traps her. Then a spot within her build reach of the piece is
-- looked for from which, with the piece standing, she still reaches outside -- she walks
-- there first. Read-only.
local body = require("commands.body_collision")
local u = require("commands.init")

local M = {}

local function key(x, y) return x .. "," .. y end
local DIRS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

-- The bounds {x1, y1, x2, y2} (whole tiles) of the build: every place / lay piece's box of
-- `steps` (a task's), else `fallback_box` -- a ring of one tile added.
function M.bounds(steps, fallback_box)
  local x1, y1, x2, y2
  local function add(bx1, by1, bx2, by2)
    x1 = x1 and math.min(x1, bx1) or bx1
    y1 = y1 and math.min(y1, by1) or by1
    x2 = x2 and math.max(x2, bx2) or bx2
    y2 = y2 and math.max(y2, by2) or by2
  end
  local function piece(name, x, y, dir)
    local proto = prototypes.entity[name]
    if proto and proto.collision_box and x and y then
      add(body.box_at(proto, {x = x, y = y}, dir))
    end
  end
  for _, st in ipairs(steps or {}) do
    if st.type == "place" then
      piece(st.entity, st.x, st.y, u.dir_map[st.dir or 0] or 0)
    elseif st.type == "lay" then
      for _, p in ipairs(st.pieces or {}) do piece(p.entity, p.x, p.y, u.dir_map[p.dir or 0] or 0) end
    end
  end
  if not x1 and fallback_box then add(table.unpack(fallback_box)) end
  if not x1 then return nil end
  return {math.floor(x1) - 1, math.floor(y1) - 1, math.ceil(x2), math.ceil(y2)}
end

-- A flood from tile (sx, sy) within the bounds' ring: (whether a tile outside the bounds
-- was reached, the reached tiles {key -> {x, y}}). `free(x, y)` decides a tile.
local function flood(sx, sy, b, free)
  local seen, list = {[key(sx, sy)] = true}, {{sx, sy}}
  local reached = {[key(sx, sy)] = {sx, sy}}
  local i = 1
  while i <= #list do
    local x, y = list[i][1], list[i][2]
    i = i + 1
    if x < b[1] or x > b[3] or y < b[2] or y > b[4] then return true, reached end
    for _, d in ipairs(DIRS) do
      local nx, ny = x + d[1], y + d[2]
      local k = key(nx, ny)
      if not seen[k] and nx >= b[1] - 1 and nx <= b[3] + 1 and ny >= b[2] - 1
         and ny <= b[4] + 1 then
        seen[k] = true
        if free(nx, ny) then
          list[#list + 1] = {nx, ny}
          reached[k] = {nx, ny}
        end
      end
    end
  end
  return false, reached
end

-- The tile test: a character could stand at the tile's centre (memoized for one check) and,
-- with `box` given, the centre lies outside it.
local function tile_test(surf, box)
  local memo = {}
  local function base(x, y)
    local k = key(x, y)
    if memo[k] == nil then
      memo[k] = surf.can_place_entity{name = "character", position = {x + 0.5, y + 0.5}}
    end
    return memo[k]
  end
  local function with_box(x, y)
    local cx, cy = x + 0.5, y + 0.5
    if box and cx > box[1] and cx < box[3] and cy > box[2] and cy < box[4] then return false end
    return base(x, y)
  end
  return base, with_box
end

-- Whether placing `entity_name` at `position` (`direction`) would close the character in
-- the build's bounds `b` (module header); false for a piece that does not stand in a
-- character's way.
function M.traps(character, entity_name, position, direction, b)
  if not b or not body.blocks_characters(character, entity_name) then return false end
  local proto = prototypes.entity[entity_name]
  local box = {body.box_at(proto, position, direction)}
  local base, with_box = tile_test(character.surface, box)
  local p = character.position
  local sx, sy = math.floor(p.x), math.floor(p.y)
  -- (only a piece that takes her way out away: closed in already -- a forest's ring of
  -- trees she mines her way through, another character -- is no trap of this piece)
  return flood(sx, sy, b, base) and not flood(sx, sy, b, with_box)
end

-- A spot within `reach` of `position` she reaches now and from which, with the piece
-- standing, she still reaches outside the bounds -- the nearest to her -- or nil.
function M.safe_spot(character, entity_name, position, direction, b, reach)
  M.last_miss = nil
  local proto = prototypes.entity[entity_name]
  if not proto or not b then return nil end
  local box = {body.box_at(proto, position, direction)}
  local base, with_box = tile_test(character.surface, box)
  local p = character.position
  local _, now = flood(math.floor(p.x), math.floor(p.y), b, base)
  local cands = {}
  local surf = character.surface
  for _, t in pairs(now) do
    local cx, cy = t[1] + 0.5, t[2] + 0.5
    local inside = (cx > box[1] and cx < box[3] and cy > box[2] and cy < box[4])
      -- (not a belt: on a belt she is carried, the build's approach would walk her back)
      or surf.count_entities_filtered{position = {cx, cy}, radius = 0.4,
                                      type = {"transport-belt", "underground-belt",
                                              "splitter"}} > 0
    local d = math.sqrt((cx - position.x) ^ 2 + (cy - position.y) ^ 2)
    if not inside and d <= reach - 1 then
      cands[#cands + 1] = {t = t, dist = (cx - p.x) ^ 2 + (cy - p.y) ^ 2}
    end
  end
  table.sort(cands, function(a, c) return a.dist < c.dist end)
  local failed = {}
  for _, c in ipairs(cands) do
    if not failed[key(c.t[1], c.t[2])] then
      local out, reached = flood(c.t[1], c.t[2], b, with_box)
      if out then return {x = c.t[1] + 0.5, y = c.t[2] + 0.5} end
      -- (every tile of a pocket that does not escape fails alike: not flooded again)
      for k in pairs(reached) do failed[k] = true end
    end
  end
  local n = 0
  for _ in pairs(now) do n = n + 1 end
  M.last_miss = string.format("she at (%.1f,%.1f), bounds %d,%d..%d,%d, %d tile(s) reached, "
    .. "%d candidate(s) in reach", p.x, p.y, b[1], b[2], b[3], b[4], n, #cands)
  return nil
end

return M
