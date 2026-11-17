-- AI Companion -- pole routes planned by the mod (factorio-ai docs/power_lines.md, design
-- 1-2 and 5; Zdendys's decision 9: the mod connects a new production itself, never
-- where a planned building stands).
--
-- A route search is not tied to a companion: a queue of its own (storage.pole_routes by
-- id), worked in turn on the mod's nth tick -- each search its share of
-- EXPAND_PER_PASS expansions a pass --, its whole state (open heap, labels, the
-- placeability cache) in storage, so a save during a search loads with it. It plans,
-- it lays nothing: Python lays the route as a plan of small poles.
--
-- A* over pole spots (tile centres): the fewest poles (each tile keeps its labels of
-- cost and pole count that no other beats in both, so max_poles never loses a route);
-- a hop within the wire reach of both poles (prototype get_max_wire_distance, less
-- HOP_MARGIN); a spot where the pole can be placed (can_place_entity), never an
-- avoided, reserved (commands/reserved_tiles.lua) or kept-off tile; a resource tile
-- costs RESOURCE_COST more (line mining sweeps the deposits). Starts: every pole on a
-- generator's network with room for a wire (fewer than the prototype's
-- auto_connect_up_to_n_wires copper connections; a full one may still cover a supply
-- goal itself), or one named pole. Done when a pole spot is within `reach` of the goal
-- (a wire to the goal pole, or a supply reach).
--
-- /fac_pole_route_start <json> -- {goal = {pole = {x, y}} (its spot never taken) |
--   {supply = {x, y}, reach = r > 0}, from = {pole = {x, y}} | {plant = true} (the
--   default: the plant's poles), avoid = {{x, y}, ...}, max_poles >= 1,
--   pole = name (a 1x1 pole; default small-electric-pole), resource_cost = c >= 0
--   (default RESOURCE_COST; 0 to plan as if no deposit lay there), units_max >= 1 (a
--   shorter deadline, at most DEADLINE_UNITS)} -> {id} or {error}
-- /fac_pole_route_status <id> -> {id, status = "running"|"done", worked (passes),
--   units (budget units got: starts seeded, nodes expanded, dead labels popped), expanded,
--   route = {{x, y}, ...} (an empty route comes as the JSON {}), start = {x, y},
--   reason = "ok"|"no_route"|"node_cap"|
--   "deadline"|"no_start" (the named pole missing or full, no plant pole with room)|
--   "error" (the mod failed, logged)|"cancelled"} or {error = "unknown id"}
-- /fac_pole_route_cancel <id>|all -- ends a search ("cancelled") or drops every one
-- /fac_keep_off <owner> add x1 y1 x2 y2 | remove | list; /fac_keep_off clear
--   rectangles no pole route may take (planned expansions), by owner (not "clear"; an
--   identical rectangle is added once)
local u = require("commands.init")
local reserved = require("commands.reserved_tiles")

local M = {}

local EXPAND_PER_PASS = 24     -- expansions a pass, shared in turn by the searches
local NODE_CAP = 40000         -- expansions of one search at most ("node_cap")
local DEADLINE_UNITS = 80000   -- budget units a search itself got at most ("deadline";
                               -- a start seeded, a node expanded or a dead label popped)
local MAX_POLES = 120          -- poles of a route at most unless the caller says
local HOP_MARGIN = 0.1         -- a hop stays this far inside the wire reach
local RESOURCE_COST = 0.5      -- added poles' worth for a spot on a resource tile
local REPLY_TTL = 36000        -- ticks a search waits unasked / a reply after its last read
local PROFILE_EVERY = 200      -- every Nth pass is timed and logged
local KB, KW = 1048576, 2097152  -- a tile's numeric key: (x + KB) * KW + (y + KB)

local function key(x, y) return (x + KB) * KW + (y + KB) end

-- heap order: the lowest f, then the lowest h (nearer the goal)
local function less(a, b) return a.f < b.f or (a.f == b.f and a.h < b.h) end

local function heap_push(h, n)
  h[#h + 1] = n
  local i = #h
  while i > 1 do
    local p = math.floor(i / 2)
    if not less(n, h[p]) then break end
    h[i], h[p] = h[p], h[i]
    i = p
  end
end

local function heap_pop(h)
  local top = h[1]
  local last = table.remove(h)
  local n = #h
  if n > 0 then
    h[1] = last
    local i = 1
    while true do
      local l, r, m = 2 * i, 2 * i + 1, i
      if l <= n and less(h[l], h[m]) then m = l end
      if r <= n and less(h[r], h[m]) then m = r end
      if m == i then break end
      h[i], h[m] = h[m], h[i]
      i = m
    end
  end
  return top
end

-- The tile offsets of one hop (within `hop`), computed once per reach (not in storage:
-- the same on every peer).
local HOPS = {}
local function hops_of(hop)
  local out = HOPS[hop]
  if out then return out end
  out = {}
  local r = math.ceil(hop)
  for dx = -r, r do
    for dy = -r, r do
      if (dx ~= 0 or dy ~= 0) and dx * dx + dy * dy <= hop * hop then
        out[#out + 1] = {dx, dy}
      end
    end
  end
  HOPS[hop] = out
  return out
end

local function dist(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

-- Whether a pole has room for one more copper wire (the prototype's limit, read).
local function room(p)
  local c = p.get_wire_connector(defines.wire_connector_id.pole_copper, false)
  return (c and c.connection_count or 0) < (p.prototype.auto_connect_up_to_n_wires or 5)
end

local function start_of(e)
  return {e.position.x, e.position.y, e.prototype.get_max_wire_distance(),
          e.prototype.get_supply_area_distance() or 0, room(e), e.electric_network_id}
end

-- The poles a route may start from: one named pole (the nearest at that spot), or every
-- pole on a generator's network. [{x, y, wire, supply, room}] -- one without room for
-- a wire may still cover a supply goal itself, it starts no route.
local function starts_of(surf, s)
  local out = {}
  if s.from then
    local fx, fy = s.from[1], s.from[2]
    local best, bd = nil, math.huge
    for _, e in pairs(surf.find_entities_filtered{position = {fx, fy}, radius = 0.6,
                                                  type = "electric-pole", force = "player"}) do
      local d = (e.position.x - fx) ^ 2 + (e.position.y - fy) ^ 2
      if d < bd then best, bd = e, d end
    end
    if best then out[1] = start_of(best) end
    return out
  end
  local nets = {}
  for _, g in pairs(surf.find_entities_filtered{type = "generator", force = "player"}) do
    if g.electric_network_id then nets[g.electric_network_id] = true end
  end
  for _, p in pairs(surf.find_entities_filtered{type = "electric-pole", force = "player"}) do
    if p.electric_network_id and nets[p.electric_network_id] then
      out[#out + 1] = start_of(p)
    end
  end
  return out
end

-- A number of a parameter: nil when absent, false when not a number in [lo, inf).
local function num_param(v, lo)
  if v == nil then return nil end
  local n = tonumber(v)
  return n and n >= lo and n or false
end

-- A position {x, y} on the map (within the tile keys' range), or nil.
local function xy(t)
  if type(t) ~= "table" then return nil end
  local x, y = tonumber(t[1]), tonumber(t[2])
  if x and y and math.abs(x) < 1000000 and math.abs(y) < 1000000 then return x, y end
end

-- A new search's state from its parameters, or nil and an error.
local function new_search(p)
  if type(p) ~= "table" or type(p.goal) ~= "table" then return nil, "no goal" end
  local kind = p.goal.pole ~= nil and "pole" or "supply"
  local gx, gy = xy(p.goal[kind])
  if not gx then return nil, "goal needs pole = {x, y} or supply = {x, y}" end
  local name = p.pole or "small-electric-pole"
  local proto = type(name) == "string" and prototypes.entity[name]
  if not proto or proto.type ~= "electric-pole" then
    return nil, "not a pole: " .. tostring(name)
  end
  -- a route's spots are single tiles (centres, each checked alone)
  if proto.tile_width ~= 1 or proto.tile_height ~= 1 then
    return nil, "not a 1x1 pole: " .. name
  end
  local wire = proto.get_max_wire_distance()
  local reach = wire - HOP_MARGIN
  if kind == "supply" then
    reach = tonumber(p.goal.reach)
    if not reach or reach <= 0 then return nil, "a supply goal needs reach > 0" end
  end
  local from
  if p.from ~= nil then
    if type(p.from) ~= "table" then return nil, "from: {pole = {x, y}} or {plant = true}" end
    if p.from.pole ~= nil then
      local fx, fy = xy(p.from.pole)
      if not fx then return nil, "from.pole needs {x, y}" end
      from = {fx, fy}
    elseif p.from.plant ~= true then
      return nil, "from: {pole = {x, y}} or {plant = true}"
    end
  end
  local max_poles, rcost = num_param(p.max_poles, 1), num_param(p.resource_cost, 0)
  if max_poles == false then return nil, "max_poles must be a number >= 1" end
  if rcost == false then return nil, "resource_cost must be a number >= 0" end
  local units_max = num_param(p.units_max, 1)
  if units_max == false then return nil, "units_max must be a number >= 1" end
  local s = {goal = {gx, gy}, kind = kind, name = name, wire = wire, hop = wire - HOP_MARGIN,
             reach = reach, from = from, max_poles = math.floor(max_poles or MAX_POLES),
             rcost = rcost or RESOURCE_COST, avoid = {}, heap = {}, nodes = {}, labels = {},
             dead = {}, free = {}, seeded = 0, worked = 0, units = 0, expanded = 0,
             units_max = units_max and math.min(math.floor(units_max), DEADLINE_UNITS),
             status = "running", seen_tick = game.tick}
  if p.avoid ~= nil and type(p.avoid) ~= "table" then return nil, "avoid: {{x, y}, ...}" end
  for _, t in pairs(p.avoid or {}) do
    local ax, ay = xy(t)
    if not ax then return nil, "avoid: {{x, y}, ...}, each on the map" end
    s.avoid[key(math.floor(ax), math.floor(ay))] = true
  end
  -- the goal pole's own spot (a pole planned there) is never a route's
  if kind == "pole" then s.avoid[key(math.floor(gx), math.floor(gy))] = true end
  return s
end

-- Whether a new pole may stand on tile (tx, ty): false, 1, or 2 (a resource tile, at an
-- added cost). Cached for the search: a tile reserved or kept off after it was first
-- seen is not noticed by this search (the lay's next search sees it).
local function placeable(surf, s, tx, ty, ctx)
  local k = key(tx, ty)
  local v = s.free[k]
  if v ~= nil then return v end
  v = not s.avoid[k] and not reserved.reserved_at(tx, ty)
  local cx, cy = tx + 0.5, ty + 0.5
  if v then
    for _, r in ipairs(ctx.keep_off) do
      if cx >= r[1] and cx <= r[3] and cy >= r[2] and cy <= r[4] then v = false break end
    end
  end
  if v then
    v = surf.can_place_entity{name = s.name, position = {cx, cy}, force = "player"}
  end
  if v then
    v = surf.count_entities_filtered{type = "resource", position = {cx, cy},
                                     radius = 0.5} > 0 and 2 or 1
  end
  s.free[k] = v
  return v
end

local function finish(s, reason, route, start)
  s.status, s.reason, s.route, s.start = "done", reason, route or {}, start
  s.heap, s.nodes, s.labels, s.dead, s.free = nil, nil, nil, nil, nil
  s.avoid, s.starts = nil, nil
  s.done_tick = game.tick
end

-- A label (cost g, poles p) for tile (tx, ty) reached from `par` (a node index, or -i
-- for start i), unless a label there is as good in both; the labels it beats are
-- dropped. Both are kept because a pole limit with a resource cost needs them: the
-- cheaper way to a tile may use more poles than a dearer one.
local function add_label(s, tx, ty, g, p, par)
  -- h: the whole poles still needed at least (every hop costs >= 1 and covers <= hop):
  -- admissible and consistent; whole, so every node within one pole of the best has
  -- the same f and the tie goes to the one nearest the goal (n.h, the distance left)
  -- -- a fractional h opened a band ~80 tiles wide round a 424-tile line (21864
  -- expansions, live)
  local hn = math.max(0, dist(tx + 0.5, ty + 0.5, s.goal[1], s.goal[2]) - s.reach)
  local need = math.ceil(hn / s.hop - 1e-9)
  -- a label that cannot reach the goal within max_poles is never kept (live: a pole
  -- limit at the shortest count expanded 7763 nodes against 1265 without it)
  if p + need > s.max_poles then return end
  local k = key(tx, ty)
  local ls = s.labels[k]
  if ls then
    for _, i in ipairs(ls) do
      local o = s.nodes[i]
      if o.g <= g and o.p <= p then return end
    end
  end
  local kept = {}
  for _, i in ipairs(ls or {}) do
    local o = s.nodes[i]
    if g <= o.g and p <= o.p then s.dead[i] = true else kept[#kept + 1] = i end
  end
  local i = #s.nodes + 1
  local n = {f = g + need, h = hn, g = g, p = p, x = tx, y = ty,
             par = par, i = i}
  s.nodes[i] = n
  kept[#kept + 1] = i
  s.labels[k] = kept
  heap_push(s.heap, n)
end

-- Start i's first hops: every spot within the wire of both poles.
local function seed(surf, s, i, ctx)
  local st = s.starts[i]
  local r = math.min(st[3], s.wire) - HOP_MARGIN
  for dx = -math.ceil(r), math.ceil(r) do
    for dy = -math.ceil(r), math.ceil(r) do
      local tx, ty = math.floor(st[1] + dx), math.floor(st[2] + dy)
      if dist(tx + 0.5, ty + 0.5, st[1], st[2]) <= r then
        local v = placeable(surf, s, tx, ty, ctx)
        if v then add_label(s, tx, ty, v == 2 and 1 + s.rcost or 1, 1, -i) end
      end
    end
  end
end

-- Whether a start pole itself reaches the goal (a wire to the goal pole, or its own
-- supply area over the supply point).
-- For a {pole} goal whose pole stands (`goal_net`, its network id): only a start on
-- that same network -- a pole within wire reach is not wired to it when one of the two
-- was full as the other was placed (a pole wires itself only when it is placed: live
-- review, line mining's re-chain); a goal not standing yet (the count search): by
-- distance and room.
local function start_reaches(s, st, goal_net)
  local d = dist(st[1], st[2], s.goal[1], s.goal[2])
  if s.kind == "pole" then
    if goal_net ~= nil then return goal_net == st[6] end
    return st[5] and d <= math.min(s.reach, st[3] - HOP_MARGIN)
  end
  return d <= math.min(s.reach, st[4])
end

-- The network id of the pole standing on the goal spot of a {pole} goal (the nearest
-- within 0.6; -1 when it has none: no start is on it), false when none stands, nil for
-- a supply goal.
local function goal_network(surf, s)
  if s.kind ~= "pole" then return nil end
  local best, bd = nil, math.huge
  for _, e in pairs(surf.find_entities_filtered{position = {s.goal[1], s.goal[2]},
                                                radius = 0.6, type = "electric-pole",
                                                force = "player"}) do
    local d = (e.position.x - s.goal[1]) ^ 2 + (e.position.y - s.goal[2]) ^ 2
    if d < bd then best, bd = e, d end
  end
  if not best then return false end
  return best.electric_network_id or -1
end

-- One search's share of a pass: `budget` units -- a start seeded, a node expanded or a
-- dead label popped. The deadline counts the units the search itself got (in passes,
-- many searches sharing a pass would leave each too few to reach the node cap).
local function work(surf, s, budget, ctx)
  s.worked = s.worked + 1
  if not s.starts then
    -- a start pole that reaches the goal itself: the nearest (an empty route)
    local all, best, bd = starts_of(surf, s), nil, math.huge
    local net = goal_network(surf, s)
    if net == false then net = nil end
    for _, st in ipairs(all) do
      local d = dist(st[1], st[2], s.goal[1], s.goal[2])
      if d < bd and start_reaches(s, st, net) then best, bd = st, d end
    end
    if best then finish(s, "ok", {}, {best[1], best[2]}) return end
    s.starts = {}
    for _, st in ipairs(all) do
      if st[5] then s.starts[#s.starts + 1] = st end
    end
    if #s.starts == 0 then finish(s, "no_start") return end
  end
  local hops = hops_of(s.hop)
  for _ = 1, budget do
    s.units = (s.units or 0) + 1
    if s.units > (s.units_max or DEADLINE_UNITS) then finish(s, "deadline") return end
    if s.seeded < #s.starts then
      s.seeded = s.seeded + 1
      seed(surf, s, s.seeded, ctx)
    else
      if #s.heap == 0 then finish(s, "no_route") return end
      if s.expanded >= NODE_CAP then finish(s, "node_cap") return end
      local n = heap_pop(s.heap)
      if not s.dead[n.i] then
        if n.h == 0 then
          local route, i = {}, n.i
          while i > 0 do
            local m = s.nodes[i]
            table.insert(route, 1, {m.x + 0.5, m.y + 0.5})
            i = m.par
          end
          local st = s.starts[-i]
          finish(s, "ok", route, {st[1], st[2]})
          return
        end
        s.expanded = s.expanded + 1
        if n.p < s.max_poles then
          for _, o in ipairs(hops) do
            local tx, ty = n.x + o[1], n.y + o[2]
            local v = placeable(surf, s, tx, ty, ctx)
            if v then add_label(s, tx, ty, n.g + (v == 2 and 1 + s.rcost or 1), n.p + 1, n.i) end
          end
        end
      end
    end
  end
end

local function keep_off_list()
  local out = {}
  for _, rects in pairs(storage.keep_off or {}) do
    for _, r in ipairs(rects) do out[#out + 1] = r end
  end
  return out
end

-- The nth-tick pass: the running searches get their shares in turn (at most
-- EXPAND_PER_PASS searches a pass, the rest the next passes); a search nobody asked
-- about and a reply not read for REPLY_TTL ticks are dropped. A search that fails is
-- ended with "error" and logged -- the others go on.
function M.tick()
  local book = storage.pole_routes
  if not book or next(book) == nil then return end
  local tick, running, stale = game.tick, {}, {}
  for id, s in pairs(book) do
    s.seen_tick = s.seen_tick or tick
    local since = s.seen_tick
    if s.status ~= "running" then since = math.max(since, s.done_tick or tick) end
    if tick - since > REPLY_TTL then
      stale[#stale + 1] = id
    elseif s.status == "running" then
      running[#running + 1] = id
    end
  end
  for _, id in ipairs(stale) do
    log("[pole_route] search " .. id .. " dropped: nobody asked for it in " .. REPLY_TTL
        .. " ticks")
    book[id] = nil
  end
  if #running == 0 then return end
  table.sort(running)
  local n = math.min(#running, EXPAND_PER_PASS)
  local share = math.floor(EXPAND_PER_PASS / n)
  local first = (storage.pole_route_turn or 0) % #running
  storage.pole_route_turn = first + n
  storage.pole_route_passes = (storage.pole_route_passes or 0) + 1
  local prof = storage.pole_route_passes % PROFILE_EVERY == 0 and helpers.create_profiler()
  local surf = game.surfaces[1]
  local ctx = {keep_off = keep_off_list()}
  for j = 0, n - 1 do
    local id = running[(first + j) % #running + 1]
    local s = book[id]
    local ok, err = pcall(work, surf, s, share, ctx)
    if not ok then
      log("[pole_route] search " .. id .. " failed: " .. tostring(err))
      u.log_error("search " .. id .. ": " .. tostring(err), "pole_route")
      finish(s, "error")
    end
  end
  if prof then
    prof.stop()
    log({"", "[pole_route] pass of ", n, " searches x ", share, " expansions: ", prof})
  end
end

local function words_of(param)
  local w = {}
  for x in (param or ""):gmatch("%S+") do w[#w + 1] = x end
  return w
end

commands.add_command("fac_pole_route_start", nil, function(cmd)
  u.safe_command(function()
    local ok, p = pcall(helpers.json_to_table, cmd.parameter or "")
    if not ok or type(p) ~= "table" then
      u.json_response({error = "bad json: " .. tostring(p)}) return
    end
    local s, err = new_search(p)
    if not s then u.json_response({error = err}) return end
    storage.pole_routes = storage.pole_routes or {}
    storage.pole_route_next = (storage.pole_route_next or 0) + 1
    local id = storage.pole_route_next
    storage.pole_routes[id] = s
    u.json_response({id = id})
  end)
end)

commands.add_command("fac_pole_route_status", nil, function(cmd)
  u.safe_command(function()
    local id = tonumber(words_of(cmd.parameter)[1])
    local s = id and storage.pole_routes and storage.pole_routes[id]
    if not s then u.json_response({error = "unknown id"}) return end
    s.seen_tick = game.tick
    u.json_response({id = id, status = s.status, worked = s.worked, units = s.units,
                     expanded = s.expanded,
                     route = s.route, start = s.start, reason = s.reason})
  end)
end)

commands.add_command("fac_pole_route_cancel", nil, function(cmd)
  u.safe_command(function()
    local w = words_of(cmd.parameter)[1]
    storage.pole_routes = storage.pole_routes or {}
    if w == "all" then
      local n = 0
      for _ in pairs(storage.pole_routes) do n = n + 1 end
      storage.pole_routes = {}
      u.json_response({dropped = n}) return
    end
    local s = tonumber(w) and storage.pole_routes[tonumber(w)]
    if not s then u.json_response({error = "unknown id"}) return end
    if s.status == "running" then finish(s, "cancelled") end
    u.json_response({id = tonumber(w), status = s.status, reason = s.reason})
  end)
end)

commands.add_command("fac_keep_off", nil, function(cmd)
  u.safe_command(function()
    local w = words_of(cmd.parameter)
    storage.keep_off = storage.keep_off or {}
    if w[1] == "clear" and w[2] == nil then
      storage.keep_off = {}
      u.json_response({cleared = true}) return
    end
    local owner, op = w[1], w[2]
    if not owner or owner == "clear" or not (op == "add" or op == "remove" or op == "list") then
      u.json_response({error = "usage: <owner> add x1 y1 x2 y2 | remove | list; clear"})
      return
    end
    if op == "add" then
      local r = {tonumber(w[3]), tonumber(w[4]), tonumber(w[5]), tonumber(w[6])}
      if not (r[1] and r[2] and r[3] and r[4]) then
        u.json_response({error = "add needs x1 y1 x2 y2"}) return
      end
      r = {math.min(r[1], r[3]), math.min(r[2], r[4]), math.max(r[1], r[3]),
           math.max(r[2], r[4])}
      storage.keep_off[owner] = storage.keep_off[owner] or {}
      local have = false
      for _, o in ipairs(storage.keep_off[owner]) do
        if o[1] == r[1] and o[2] == r[2] and o[3] == r[3] and o[4] == r[4] then have = true end
      end
      if not have then table.insert(storage.keep_off[owner], r) end
    elseif op == "remove" then
      storage.keep_off[owner] = nil
    end
    u.json_response({owner = owner, rects = storage.keep_off[owner] or {}})
  end)
end)

return M
