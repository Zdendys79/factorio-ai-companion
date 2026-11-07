-- What feeds a burner its fuel (the mod's fuel upkeep, commands/upkeep.lua): whether it
-- has a supply line of its own, or a fuel chest that is hers to fill (Zdendys: she
-- supplies a production or a chest no belt with that material reaches yet).
local u = require("commands.init")

local M = {}

-- a source whose drop position lies within this many tiles of a box drops into it
local FEED_MARGIN = 0.3
-- the chests she fills: plain containers (logistic chests are the robots' to supply)
local CHEST_TYPES = {container = true}
-- the other chests an inserter may pick from: judged by what they hold, never hers
-- (review: a logistic plate buffer counted as a fuel line)
local OTHER_STORES = {["logistic-container"] = true, ["infinity-container"] = true,
                      ["linked-container"] = true}
-- a source's pickup entity is searched within this radius of its pickup position
local PICKUP_RADIUS = 0.6
-- what is never a pickup source (review: a ghost or a corpse at the spot made the
-- inserter count as a supply line)
local NOT_SOURCES = {resource = true, ["entity-ghost"] = true, ["tile-ghost"] = true,
                     character = true, corpse = true, ["character-corpse"] = true,
                     ["item-request-proxy"] = true}
-- the belts whose lanes tell what an inserter picking from them carries
local BELT_TYPES = {["transport-belt"] = true, ["underground-belt"] = true,
                    splitter = true, ["lane-splitter"] = true, ["linked-belt"] = true,
                    loader = true, ["loader-1x1"] = true}
-- a supply line keeps a burner at 5 fuel items (live); under this many it falls behind
M.LINE_MIN_ITEMS = 4

-- Whether an item is a fuel (its prototype has a fuel value).
local function is_fuel(name)
  local proto = prototypes.item[name]
  return proto ~= nil and (proto.fuel_value or 0) > 0
end

-- Whether a mining drill mines a fuel (its resource's product has a fuel value): a coal
-- drill dropping into a burner feeds its fuel, an iron drill dropping into a furnace
-- only its ore.
function M.mines_fuel(drill)
  local res = drill.mining_target
  local mineable = res and res.valid and res.prototype.mineable_properties
  for _, product in pairs((mineable and mineable.products) or {}) do
    if product.type == "item" and is_fuel(product.name) then return true end
  end
  return false
end

-- Whether a crafting machine's recipe makes a fuel (a furnace / assembler an inserter
-- takes from feeds fuel only then -- review: plates from a furnace are no fuel).
local function makes_fuel(machine)
  local ok, recipe = pcall(machine.get_recipe)
  if not ok or not recipe then return false end
  for _, product in pairs(recipe.products or {}) do
    if product.type == "item" and is_fuel(product.name) then return true end
  end
  return false
end

-- Whether `src` drops into `box` (its drop position within FEED_MARGIN of the box).
local function drops_into(src, box)
  local d = src.drop_position
  return d ~= nil and d.x >= box.left_top.x - FEED_MARGIN
     and d.x <= box.right_bottom.x + FEED_MARGIN
     and d.y >= box.left_top.y - FEED_MARGIN and d.y <= box.right_bottom.y + FEED_MARGIN
end

-- The inserters and drills around a box (3 tiles out).
local function sources_around(entity)
  local box = entity.bounding_box
  local area = {{box.left_top.x - 3, box.left_top.y - 3},
                {box.right_bottom.x + 3, box.right_bottom.y + 3}}
  return entity.surface.find_entities_filtered{area = area,
                                               type = {"inserter", "mining-drill"}}, box
end

-- The entity an inserter picks up from: the nearest at its pickup position, or nil.
local function pickup_source(ins)
  local p = ins.pickup_position
  local best, bd = nil, math.huge
  for _, s in pairs(ins.surface.find_entities_filtered{position = p, radius = PICKUP_RADIUS}) do
    if s.valid and s ~= ins and not NOT_SOURCES[s.type] then
      local d = u.distance(s.position, p)
      if d < bd then best, bd = s, d end
    end
  end
  return best
end

-- What fills the chest: "fuel" (an inserter or a fuel-mining drill drops into it -- a
-- supply of its own: a belt line, a coal pair v2's drill; live: an emptied fuel chest
-- had coal back before any task), "ore" (only drills mining no fuel -- an ore buffer,
-- review: no fuel chest, coal is not to go into it), or nil (nothing: hers to fill).
local function chest_filled_by(chest)
  local sources, box = sources_around(chest)
  local ore = false
  for _, src in pairs(sources) do
    if drops_into(src, box) then
      if src.type == "inserter" or M.mines_fuel(src) then return "fuel" end
      ore = true
    end
  end
  return ore and "ore" or nil
end

-- What a list of contents ({name, count} entries) holds: "fuel" (a fuel among them),
-- "other" (only items that are no fuel) or "empty".
local function contents_kind(contents)
  local kind = "empty"
  for _, item in pairs(contents) do
    if is_fuel(item.name) then return "fuel" end
    kind = "other"
  end
  return kind
end

-- What the belt an inserter picks from carries, all its lanes: contents_kind.
local function belt_kind(belt)
  local kind = "empty"
  for i = 1, belt.get_max_transport_line_index() do
    local k = contents_kind(belt.get_transport_line(i).get_contents())
    if k == "fuel" then return "fuel" end
    if k == "other" then kind = "other" end
  end
  return kind
end

-- What a chest holds: contents_kind.
local function chest_kind(chest)
  local inv = chest.get_inventory(defines.inventory.chest)
  return inv and contents_kind(inv.get_contents()) or "empty"
end

-- Whether a chest is a fuel chest: empty, or holding only fuels (review: an ore chest
-- feeding a furnace by an inserter is no fuel feed -- coal is not to go into it, and a
-- full mixed one left a starving burner to nobody; an empty one that once held ore
-- gets coal, which its inserter then hands the burner as fuel -- harmless).
local function fuel_chest(chest)
  local inv = chest.get_inventory(defines.inventory.chest)
  if not inv then return false end
  for _, item in pairs(inv.get_contents()) do
    if not is_fuel(item.name) then return false end
  end
  return true
end

-- Whether an inserter holds an item that is no fuel (an ore inserter from a belt with
-- a gap at its pickup -- review: an "empty" belt then counted as a coal line).
local function holds_no_fuel(ins)
  local held = ins.held_stack
  return held ~= nil and held.valid_for_read and not is_fuel(held.name)
end

-- A source's status name ("?" when unknown) -- for the logs.
local status_names
local function status_name(s)
  if not status_names then
    status_names = {}
    for k, v in pairs(defines.entity_status) do status_names[v] = k end
  end
  return status_names[s.status] or "?"
end

-- Whether a source feeding a burner supplies it: working (low power too -- slower, it
-- still delivers; review), or waiting for room in the burner (live: an inserter keeps
-- a burner at 5 fuel items -- a boiler's ~12 s, a drill's ~140 s -- and waits for
-- space; one from an emptied belt waits for source items, a coal pair's partner drill
-- mined out or without fuel stands).
local function supplying(src)
  local s = src.status
  return s == defines.entity_status.working
      or s == defines.entity_status.low_power
      or s == defines.entity_status.waiting_for_space_in_destination
end

-- What feeds the burner its fuel: {other, other_ok, why, chests, chest_ok, chest_why}.
-- - other: a supply line of its own -- an inserter from a belt or a chest an inserter
--   / a fuel-mining drill fills (unless it carries only items that are no fuel: an ore
--   belt, a plate buffer -- review: an idle ore inserter's status looked like a fuel
--   supply), from the ground, or from a machine making a fuel; a drill mining a fuel (a
--   coal pair's drills feed each other);
-- - other_ok: one of those sources supplies it (supplying) and its fuel slot holds at
--   least LINE_MIN_ITEMS (review: an inserter at the insertion limit keeps 5 items in
--   it, so fewer means the fuel does not keep up -- whatever the line's status); why:
--   what does not supply, for the log;
-- - chests: the fuel chests (plain containers, empty or holding only fuels, filled by
--   nothing) inserters feed it from -- hers to fill -- nearest first;
-- - chest_ok: one of the inserters from them supplies it and its fuel slot holds at
--   least LINE_MIN_ITEMS; chest_why: what does not supply.
-- An iron drill's ore, an inserter from an ore belt, an ore chest, an ore buffer or a
-- furnace making plates is no fuel feed: such a burner counts as having none.
function M.feeds(e)
  local sources, box = sources_around(e)
  local f = {other = false, other_ok = false, why = nil, chests = {}, chest_ok = false}
  local seen = {}
  local function line(src)
    f.other = true
    if supplying(src) then f.other_ok = true else f.why = src.name .. " " .. status_name(src) end
  end
  for _, src in pairs(sources) do
    if src ~= e and drops_into(src, box) then
      if src.type == "mining-drill" then
        if M.mines_fuel(src) then line(src) end
      else
        local from = pickup_source(src)
        local chest = from and CHEST_TYPES[from.type]
        -- (a chest a drill mining no fuel fills is an ore buffer: no fuel feed)
        local filled = chest and chest_filled_by(from)
        local store = filled == "fuel" or (from and OTHER_STORES[from.type])
        if store or (from and BELT_TYPES[from.type]) then
          -- a belt, a chest a line fills, or a logistic chest: a fuel line unless it
          -- carries only what is no fuel; an empty one is a coal line run dry (its
          -- inserter's status tells) -- unless its inserter holds what is no fuel (a
          -- gap on an ore belt)
          local kind = store and chest_kind(from) or belt_kind(from)
          if kind == "fuel" or (kind == "empty" and not holds_no_fuel(src)) then
            line(src)
          end
        elseif chest then
          if not filled and fuel_chest(from) then
            if supplying(src) then
              f.chest_ok = true
            else
              f.chest_why = src.name .. " " .. status_name(src)
            end
            if not seen[from.unit_number or from] then
              seen[from.unit_number or from] = true
              f.chests[#f.chests + 1] = from
            end
          end
        elseif from and (from.type == "furnace" or from.type == "assembling-machine") then
          if makes_fuel(from) then line(src) end
        else
          line(src)                        -- the ground, anything else
        end
      end
    end
  end
  local n = e.burner.inventory.get_item_count()
  if f.other_ok and n < M.LINE_MIN_ITEMS then
    f.other_ok, f.why = false, "only " .. n .. " fuel items in it"
  end
  if f.chest_ok and n < M.LINE_MIN_ITEMS then
    f.chest_ok, f.chest_why = false, "only " .. n .. " fuel items in it"
  end
  table.sort(f.chests, function(a, b)
    return u.distance(a.position, e.position) < u.distance(b.position, e.position)
  end)
  return f
end

-- The burners (furnace, mining drill, boiler) the inserters picking up from the chest
-- drop into -- all that the chest feeds (review: a group of only the burners under the
-- scan's cheap check overrated its time left), each once.
local FED_TYPES = {furnace = true, ["mining-drill"] = true, boiler = true}
function M.chest_burners(chest)
  local out, seen = {}, {}
  local sources = sources_around(chest)
  for _, ins in pairs(sources) do
    if ins.type == "inserter" and pickup_source(ins) == chest then
      local d = ins.drop_position
      local best, bd = nil, math.huge
      for _, b in pairs(ins.surface.find_entities_filtered{
          area = {{d.x - 0.1, d.y - 0.1}, {d.x + 0.1, d.y + 0.1}}, force = ins.force}) do
        if b.valid and FED_TYPES[b.type] and b.burner then
          local dist = u.distance(b.position, d)
          if dist < bd then best, bd = b, dist end
        end
      end
      if best and not seen[best.unit_number or best] then
        seen[best.unit_number or best] = true
        out[#out + 1] = best
      end
    end
  end
  return out
end

-- Whether an inserter picks up from the chest (it feeds a machine or a line -- its coal
-- is that machine's, not a store she may take from).
function M.picked_from(chest)
  for _, ins in pairs(sources_around(chest)) do
    if ins.type == "inserter" and pickup_source(ins) == chest then return true end
  end
  return false
end

-- The fuel energy (joules) an inventory holds.
function M.inventory_fuel(inv)
  local energy = 0
  for _, item in pairs((inv and inv.get_contents()) or {}) do
    local proto = prototypes.item[item.name]
    energy = energy + (proto and proto.fuel_value or 0) * item.count
  end
  return energy
end

return M
