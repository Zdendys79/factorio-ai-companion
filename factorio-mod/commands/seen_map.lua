-- The seen map (factorio-ai game rule 82, Zdendys: what Python knows of the map is what the
-- companions walking on it and the radars discovered; every companion reveals the map in a circle
-- round her).
--
-- The game charts only for a force with a connected player, and a headless run has none: the
-- force's own chart stays empty. So the mod keeps the record a player's game would make
-- (storage.seen_chunks[surface index]["cx,cy"] = tick first seen), by the game's own rules:
--   * a companion sees the 5x5 chunks centred on her chunk (as a player's character), and the
--     chunks within GENERATE_RADIUS round her are generated (as round a player) so she can walk on;
--   * a working radar sees its 7x7 chunks (max_distance_of_nearby_sector_revealed 3) and scans one
--     further chunk out to 14 (max_distance_of_sector_revealed) every SECTOR_TICKS (10 MJ a sector
--     at 300 kW), nearest first.
-- A save made before the record gets the chunks of what the force built booked once.
-- Read by Python's map reads through the remote interface "fac_seen" (is_seen(surface, x, y)).
local M = {}

M.CHARACTER_R = 2          -- chunks round a companion's chunk (5x5)
M.GENERATE_RADIUS = 5      -- chunks round a companion generated (a player: 20, slowly)
M.RADAR_NEAR_R = 3         -- chunks round a radar's chunk (7x7)
M.RADAR_FAR_R = 14         -- chunks a radar's sector scan reaches
M.SECTOR_TICKS = 2000      -- ticks a sector scan takes (10 MJ / 300 kW)
M.EVERY = 60               -- ticks between two updates
M.RADAR_LIST_TICKS = 600   -- the radars looked up again this often

local function book(si)
  storage.seen_chunks = storage.seen_chunks or {}
  storage.seen_chunks[si] = storage.seen_chunks[si] or {}
  return storage.seen_chunks[si]
end

-- the chunks round (cx, cy) booked seen -- only those generated (an empty chunk not yet made is
-- no "nothing here"); returns whether all of them were
local function mark(surf, seen, cx, cy, r)
  local all = true
  for x = cx - r, cx + r do
    for y = cy - r, cy + r do
      local k = x .. "," .. y
      if not seen[k] then
        if surf.is_chunk_generated({x, y}) then seen[k] = game.tick else all = false end
      end
    end
  end
  return all
end

-- the far sector chunks of a radar, nearest first (relative chunk offsets)
local far_offsets = nil
local function offsets()
  if far_offsets then return far_offsets end
  far_offsets = {}
  for dx = -M.RADAR_FAR_R, M.RADAR_FAR_R do
    for dy = -M.RADAR_FAR_R, M.RADAR_FAR_R do
      if math.max(math.abs(dx), math.abs(dy)) > M.RADAR_NEAR_R then
        far_offsets[#far_offsets + 1] = {dx, dy, dx * dx + dy * dy}
      end
    end
  end
  table.sort(far_offsets, function(a, b) return a[3] < b[3] end)
  return far_offsets
end

local function radars()
  if storage.seen_radars and game.tick < (storage.seen_radars_next or 0) then
    return storage.seen_radars
  end
  local list = {}
  for _, s in pairs(game.surfaces) do
    for _, e in pairs(s.find_entities_filtered{type = "radar"}) do list[#list + 1] = e end
  end
  storage.seen_radars, storage.seen_radars_next = list, game.tick + M.RADAR_LIST_TICKS
  -- (the scan state of a radar gone is dropped)
  local keep = {}
  for _, e in pairs(list) do
    if e.valid and storage.radar_scan and storage.radar_scan[e.unit_number] then
      keep[e.unit_number] = storage.radar_scan[e.unit_number]
    end
  end
  storage.radar_scan = keep
  return list
end

-- a save made before the record: what the force built stands where it was seen (its chunks
-- booked once)
local function seed_from_buildings()
  storage.seen_seeded = true
  for _, s in pairs(game.surfaces) do
    local seen = book(s.index)
    for _, e in pairs(s.find_entities_filtered{force = "player"}) do
      local k = math.floor(e.position.x / 32) .. "," .. math.floor(e.position.y / 32)
      if not seen[k] then seen[k] = game.tick end
    end
  end
end

function M.tick()
  if game.tick % M.EVERY ~= 0 then return end
  if not storage.seen_seeded then seed_from_buildings() end
  for _, c in pairs(storage.companions or {}) do
    local e = c.entity
    if e and e.valid then
      local p = e.position
      local cx, cy = math.floor(p.x / 32), math.floor(p.y / 32)
      mark(e.surface, book(e.surface.index), cx, cy, M.CHARACTER_R)
      e.surface.request_to_generate_chunks(p, M.GENERATE_RADIUS)
    end
  end
  storage.radar_scan = storage.radar_scan or {}
  for _, r in pairs(radars()) do
    if r.valid and r.status == defines.entity_status.working then
      local seen = book(r.surface.index)
      local cx, cy = math.floor(r.position.x / 32), math.floor(r.position.y / 32)
      mark(r.surface, seen, cx, cy, M.RADAR_NEAR_R)
      local id = r.unit_number
      local st = storage.radar_scan[id] or {i = 0, next = game.tick + M.SECTOR_TICKS}
      storage.radar_scan[id] = st
      if game.tick >= st.next then
        -- (a sector already seen costs no scan; the next one is generated first, then booked:
        -- the scan moves on when it is)
        local offs = offsets()
        st.next = game.tick + M.SECTOR_TICKS     -- (every sector seen: looked at again then)
        for _ = 1, #offs do
          local o = offs[(st.i % #offs) + 1]
          local k = (cx + o[1]) .. "," .. (cy + o[2])
          if not seen[k] then
            if mark(r.surface, seen, cx + o[1], cy + o[2], 0) then
              st.i = (st.i % #offs) + 1
              st.next = game.tick + M.SECTOR_TICKS
            else
              r.surface.request_to_generate_chunks({(cx + o[1]) * 32 + 16, (cy + o[2]) * 32 + 16}, 0)
            end
            break
          end
          st.i = (st.i % #offs) + 1
        end
      end
    end
  end
end

-- whether the chunk of tile (x, y) on surface `si` was seen
function M.is_seen(si, x, y)
  local s = storage.seen_chunks and storage.seen_chunks[si]
  return s ~= nil and s[math.floor(x / 32) .. "," .. math.floor(y / 32)] ~= nil
end

remote.add_interface("fac_seen", {
  is_seen = function(si, x, y) return M.is_seen(si, x, y) end,
  -- the pieces (squares of `size` tiles from (x0, y0)) holding a seen chunk, as "i,j"
  -- (column, row) joined by ';' -- the dashboard reads only those
  pieces = function(si, x0, y0, size)
    local out, got = {}, {}
    for k in pairs((storage.seen_chunks or {})[si] or {}) do
      local cx, cy = k:match("^(%-?%d+),(%-?%d+)$")
      if cx then
        -- (a chunk across a piece's edge: both pieces)
        for _, dx in ipairs({0, 31}) do
          for _, dy in ipairs({0, 31}) do
            local i = math.floor((tonumber(cx) * 32 + dx - x0) / size)
            local j = math.floor((tonumber(cy) * 32 + dy - y0) / size)
            local key = i .. "," .. j
            if not got[key] then got[key] = true; out[#out + 1] = key end
          end
        end
      end
    end
    return table.concat(out, ";")
  end,
  count = function(si)
    local n = 0
    for _ in pairs((storage.seen_chunks or {})[si] or {}) do n = n + 1 end
    return n
  end,
})

return M
