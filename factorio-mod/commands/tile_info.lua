-- /fac_chunk_info <x0> <y0> -- read-only: everything the dashboard's map shows about the
-- tiles of one square of CHUNK tiles (the browser keeps the squares in view and reads them
-- again: the tile under the cursor is shown from that memory)
-- (factorio-ai docs/dashboard.md, "Tile details"; Zdendys: at the closest zoom every detail
-- of the tile under the cursor -- its coordinates, what stands there, the resource, a
-- building's consumption, what it makes and how fast, its input and output inventories).
--
-- -> {x0, y0, side, resources = [[x, y, name, amount]], entities = [{name, type, x, y, box,
--     dir, status, health, recipe, rate,
--     crafting_speed, progress, finished, energy_kw, burning, fuel_left_mj, mining, amount,
--     inventories = {<name> = [{name, count}]}, lanes = [[{name, count}], ...], burner, errors}]}
-- Each part is read under its own pcall: a part the entity does not have is left out, a
-- read that failed is named in the entity's `errors` (never silent).
-- /fac_area_info <x0> <y0> <x1> <y1> -- read-only: an area's sums (M.area_info; the map's
-- areas: a line, a block, a corridor -- docs/dashboard.md, "Areas").
local u = require("commands.init")

local M = {}

-- the entity types described by name, type, position and box only
local PLAIN = {tree = true, ["simple-entity"] = true, fish = true, cliff = true,
               ["item-entity"] = true, corpse = true}

local STATUS = {}
for name, v in pairs(defines.entity_status) do STATUS[v] = name end

-- [{name, count}] of a LuaInventory or a transport line (2.x get_contents: an array of
-- {name, count, quality}).
local function contents(src)
  local out = {}
  for _, it in pairs(src.get_contents()) do
    out[#out + 1] = {name = it.name, count = it.count}
  end
  return out
end

-- `fn(e, r)` under a pcall; a failure goes into r.errors as `what: message`.
local function part(e, r, what, fn)
  local ok, err = pcall(fn, e, r)
  if not ok then
    r.errors = r.errors or {}
    r.errors[#r.errors + 1] = what .. ": " .. tostring(err)
  end
end

-- The items a minute a recipe makes at `speed` (productivity left out).
local function rate_of(recipe, speed)
  local out = {}
  if not (recipe and speed and recipe.energy and recipe.energy > 0) then return out end
  for _, p in pairs(recipe.products) do
    local amount = p.amount or ((p.amount_min or 0) + (p.amount_max or 0)) / 2
    out[#out + 1] = {name = p.name, per_min = amount * (p.probability or 1) * speed
                                                * 60 / recipe.energy}
  end
  return out
end

-- The electric network of a pole (Zdendys: the poles of one network share their numbers):
-- what it draws and makes now (its flow statistics over the last 5 seconds, in kW) and
-- the most its generators can make -- read once a network per command (`memo`).
local GENERATORS = {"generator", "solar-panel", "burner-generator", "fusion-generator"}
local NET_KEEP_TICKS = 60          -- a network's numbers kept this long across commands
local nets = {}                    -- id -> {tick, net} (not saved: a cache)
local function network_of(en, memo)
  local id = en.electric_network_id
  if not id then return nil end
  if memo[id] then return memo[id] end
  local kept = nets[id]
  if kept and game.tick - kept.tick < NET_KEEP_TICKS then
    memo[id] = kept.net
    return kept.net
  end
  local net = {id = id}
  local st = en.electric_network_statistics
  local function flow(counts, category)
    local sum = 0
    for name in pairs(counts) do
      sum = sum + st.get_flow_count{name = name, category = category,
                                     precision_index = defines.flow_precision_index.five_seconds}
    end
    return math.floor(sum * 60 / 1000 + 0.5)
  end
  -- (the electric statistics' input side is what the network's machines take, the output
  -- side what its generators give -- live check: the steam engines on the output side)
  net.draw_kw = flow(st.input_counts, "input")
  net.make_kw = flow(st.output_counts, "output")
  local max = 0
  for _, g in pairs(en.surface.find_entities_filtered{type = GENERATORS, force = en.force}) do
    if g.electric_network_id == id then
      local ok, w = pcall(function() return g.prototype.get_max_energy_production() end)
      if ok and w then max = max + w end
    end
  end
  net.max_kw = math.floor(max * 60 / 1000 + 0.5)
  memo[id] = net
  nets[id] = {tick = game.tick, net = net}
  return net
end

local function describe(e, memo)
  local r = {name = e.name, type = e.type, x = e.position.x, y = e.position.y}
  part(e, r, "box", function(en, t)
    local b = en.bounding_box
    t.box = {b.left_top.x, b.left_top.y, b.right_bottom.x, b.right_bottom.y}
  end)
  part(e, r, "direction", function(en, t) t.dir = en.direction end)
  part(e, r, "status", function(en, t) if en.status then t.status = STATUS[en.status] end end)
  part(e, r, "health", function(en, t)
    if en.health and en.max_health and en.max_health > 0 then
      t.health = math.floor(100 * en.health / en.max_health + 0.5)
    end
  end)
  if e.type == "resource" then
    part(e, r, "amount", function(en, t) t.amount = en.amount end)
    return r
  end
  if PLAIN[e.type] then return r end       -- (a tree, a rock, a fish: what and where only)
  if e.type == "electric-pole" then
    part(e, r, "network", function(en, t) t.network = network_of(en, memo or {}) end)
    return r
  end
  if e.type == "assembling-machine" or e.type == "furnace" then
    part(e, r, "recipe", function(en, t)
      local recipe = en.get_recipe()
      if not recipe and en.type == "furnace" and en.previous_recipe then
        local n = en.previous_recipe.name      -- (2.x: a recipe prototype, or its name)
        recipe = type(n) == "string" and prototypes.recipe[n] or n
      end
      if recipe then
        t.recipe = recipe.name
        t.crafting_speed = en.crafting_speed
        t.rate = rate_of(recipe, en.crafting_speed)
      end
      t.progress = math.floor(100 * (en.crafting_progress or 0) + 0.5)
      t.finished = en.products_finished
    end)
  end
  if e.type == "mining-drill" then
    part(e, r, "mining", function(en, t)
      local target = en.mining_target
      t.mining = target and target.name or nil
      local speed = en.prototype.mining_speed
      if target and speed and not target.prototype.infinite_resource then
        local mt = target.prototype.mineable_properties.mining_time or 1
        t.rate = {{name = target.name, per_min = speed * 60 / mt}}
      end
    end)
  end
  if e.type == "lab" then
    part(e, r, "research", function(en, t)
      local res = en.force.current_research
      t.recipe = res and ("research " .. res.name) or nil
    end)
  end
  part(e, r, "energy", function(en, t)
    local usage = en.prototype.get_max_energy_usage()
    if usage and usage > 0 then t.energy_kw = math.floor(usage * 60 / 1000 + 0.5) end
  end)
  part(e, r, "burner", function(en, t)
    local b = en.burner
    if b then
      t.burner = true
      local cb = b.currently_burning
      if cb then
        local n = cb.name          -- (2.x: an item prototype, or its name)
        t.burning = type(n) == "string" and n or n.name
      end
      t.fuel_left_mj = math.floor((b.remaining_burning_fuel or 0) / 1e5 + 0.5) / 10
    end
  end)
  part(e, r, "inventories", function(en, t)
    local max = en.get_max_inventory_index()
    for i = 1, max do
      local inv = en.get_inventory(i)
      if inv and not inv.is_empty() then
        t.inventories = t.inventories or {}
        local name = en.get_inventory_name(i) or tostring(i)
        t.inventories[name] = contents(inv)
      end
    end
  end)
  if e.type == "transport-belt" or e.type == "underground-belt" or e.type == "splitter" then
    part(e, r, "lanes", function(en, t)
      t.lanes = {}
      for i = 1, en.get_max_transport_line_index() do
        t.lanes[i] = contents(en.get_transport_line(i))
      end
    end)
  end
  return r
end

-- The side of the square /fac_chunk_info reads (the dashboard keeps its squares in the
-- browser and reads each again while it is in view).
M.CHUNK = 32

-- Every entity of the square of CHUNK tiles from (x0, y0): the player's and the neutral
-- ones described (describe; trees, rocks and the like by name and place only), the
-- resources only as [x, y, name, amount] (many, small).
function M.chunk_info(x0, y0)
  local s = game.surfaces[1]
  local out = {x0 = x0, y0 = y0, side = M.CHUNK, entities = {}, resources = {}}
  local memo = {}
  for _, e in pairs(s.find_entities_filtered{area = {{x0, y0}, {x0 + M.CHUNK, y0 + M.CHUNK}}}) do
    if e.valid and e.type ~= "character-corpse" then
      if e.type == "resource" then
        out.resources[#out.resources + 1] = {math.floor(e.position.x), math.floor(e.position.y),
                                             e.name, e.amount}
      elseif e.type ~= "character" then
        out.entities[#out.entities + 1] = describe(e, memo)
      end
    end
  end
  return out
end

-- The most tiles a side of an area read takes (a bounded command: RCON times out).
M.AREA_MAX_SIDE = 256

-- An area's sums (x0, y0 .. x1, y1, whole tiles): its machines by name with their status
-- counts, what its working machines make a minute (their recipes' rates, drills' mining),
-- the power its working electric machines draw now (their prototypes' maximum), and the
-- items in its output inventories.
function M.area_info(x0, y0, x1, y1)
  local s = game.surfaces[1]
  local out = {x0 = x0, y0 = y0, x1 = x1, y1 = y1, machines = {}, makes = {}, power_kw = 0,
               power_max_kw = 0, outputs = {}, errors = {}}
  local makes, outputs, memo = {}, {}, {}
  for _, e in pairs(s.find_entities_filtered{area = {{x0, y0}, {x1 + 1, y1 + 1}},
                                             force = "player"}) do
    if e.valid and e.type ~= "character" then
      local d = describe(e, memo)
      local m = out.machines[e.name] or {count = 0, status = {}}
      out.machines[e.name] = m
      m.count = m.count + 1
      if d.status then m.status[d.status] = (m.status[d.status] or 0) + 1 end
      local working = d.status == "working" or d.status == "normal"
      if d.energy_kw and not d.burner then
        out.power_max_kw = out.power_max_kw + d.energy_kw
        if working then out.power_kw = out.power_kw + d.energy_kw end
      end
      if working then
        for _, r in pairs(d.rate or {}) do makes[r.name] = (makes[r.name] or 0) + r.per_min end
      end
      for inv, items in pairs(d.inventories or {}) do
        if inv:find("output") or (inv:find("result") and not inv:find("burnt"))
           or inv == "chest" then
          for _, it in pairs(items) do outputs[it.name] = (outputs[it.name] or 0) + it.count end
        end
      end
      for _, err in pairs(d.errors or {}) do
        if #out.errors < 20 then out.errors[#out.errors + 1] = e.name .. ": " .. err end
      end
    end
  end
  for name, per_min in pairs(makes) do out.makes[#out.makes + 1] = {name = name, per_min = per_min} end
  table.sort(out.makes, function(a, b) return a.per_min > b.per_min end)
  for name, n in pairs(outputs) do out.outputs[#out.outputs + 1] = {name = name, count = n} end
  table.sort(out.outputs, function(a, b) return a.count > b.count end)
  return out
end

commands.add_command("fac_area_info", nil, function(cmd)
  u.safe_command(function()
    local a = {}
    for w in string.gmatch(cmd.parameter or "", "%S+") do a[#a + 1] = tonumber(w) end
    if #a ~= 4 or not (a[1] and a[2] and a[3] and a[4]) then
      u.json_response({error = "usage: /fac_area_info <x0> <y0> <x1> <y1>"})
      return
    end
    local x0, y0 = math.floor(math.min(a[1], a[3])), math.floor(math.min(a[2], a[4]))
    local x1, y1 = math.floor(math.max(a[1], a[3])), math.floor(math.max(a[2], a[4]))
    if x1 - x0 >= M.AREA_MAX_SIDE or y1 - y0 >= M.AREA_MAX_SIDE then
      u.json_response({error = "area larger than " .. M.AREA_MAX_SIDE .. " tiles a side"})
      return
    end
    u.json_response(M.area_info(x0, y0, x1, y1))
  end)
end)

commands.add_command("fac_chunk_info", nil, function(cmd)
  u.safe_command(function()
    local args = {}
    for w in string.gmatch(cmd.parameter or "", "%S+") do args[#args + 1] = w end
    local x, y = tonumber(args[1]), tonumber(args[2])
    if not (x and y) then
      u.json_response({error = "usage: /fac_chunk_info <x0> <y0>"})
      return
    end
    u.json_response(M.chunk_info(math.floor(x), math.floor(y)))
  end)
end)

return M
