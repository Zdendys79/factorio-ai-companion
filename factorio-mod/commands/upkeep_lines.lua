-- What delivers an input item into a machine (the feed upkeep, commands/upkeep_feed.lua;
-- factorio-ai docs/mod_upkeep_supply.md A): a drill dropping into it the ore it mines,
-- or an inserter picking that item from a belt, a chest or another machine's output.
local F = require("commands.upkeep_feeds")

local M = {}

-- the machines an inserter takes from by their output (the rest: by their chest)
local MACHINE_TYPES = {furnace = true, ["assembling-machine"] = true}
-- a source that stands for want of energy delivers nothing, however stocked it is (the
-- fuel upkeep fuels a burner inserter; meanwhile the machine is hers when it runs low)
local STOPPED = {[defines.entity_status.no_fuel] = true,
                 [defines.entity_status.no_power] = true}

-- an empty pickup's last contents are remembered this long (memory below)
M.MEMORY_TICKS = 36000

-- The item names a list of contents ({name, count} entries) holds, added to `set`.
local function add_names(set, contents)
  for _, it in pairs(contents or {}) do
    if (it.count or 0) > 0 then set[it.name] = true end
  end
end

-- The item names the entity an inserter picks from holds now ({} when it is empty, or
-- holds nothing an inserter takes).
local function source_items(from)
  local set = {}
  if F.BELT_TYPES[from.type] then
    for i = 1, from.get_max_transport_line_index() do
      add_names(set, from.get_transport_line(i).get_contents())
    end
    return set
  end
  -- (by its type: inventory index 1 is a container's chest but a furnace's FUEL --
  -- independent review: an iron furnace feeding a steel furnace read as coal, no line)
  local which = MACHINE_TYPES[from.type] and defines.inventory.crafter_output
                or defines.inventory.chest
  local inv = from.get_inventory(which)
  if inv then add_names(set, inv.get_contents()) end
  return set
end

-- What the pickup `from` holds of `item`: true, false (only other items), "empty" (it
-- held the item when last seen holding something) or "unknown" (never seen holding
-- anything within MEMORY_TICKS: a source for any item -- but no proof of one, review: an
-- old empty coal belt beside a mined-out drill read as a dry ore line).
-- An empty one is judged by what it held when last seen holding something (memory:
-- {[unit number] = {tick, items}}, kept MEMORY_TICKS): a fuel inserter's empty coal
-- belt is no ore line that ran dry (review: it made a furnace without any ore line
-- "underfed", served only once its input lasted under LINE_DRY_S).
local function source_holds(from, item, memory)
  local set = source_items(from)
  local unit = from.unit_number
  if next(set) then
    if memory and unit then memory[unit] = {tick = game.tick, items = set} end
    return set[item] == true
  end
  local last = memory and unit and memory[unit]
  if last and game.tick - last.tick < M.MEMORY_TICKS then
    return last.items[item] and "empty" or false
  end
  return "unknown"
end

-- Whether a mining drill mines `item` (its resource's product).
local function mines(drill, item)
  local res = drill.mining_target
  local mineable = res and res.valid and res.prototype.mineable_properties
  for _, product in pairs((mineable and mineable.products) or {}) do
    if product.type == "item" and product.name == item then return true end
  end
  return false
end

-- What delivers `item` into `machine`: "line" (a source that has the item at hand and
-- is not stopped for want of energy, or supplies it now -- working, or waiting for room
-- in the machine), "dry" (a source for it delivering nothing: its pickup empty, a drill
-- standing, a source without fuel or power), "mined_out" (a drill dropping into it
-- whose resource is gone and no other source but pickups never seen holding anything:
-- the controller's to replace -- Zdendys 2026-11-09: no hand supply once drills exist;
-- it was fed by hand meanwhile) or nil (none: hers to feed); and the
-- status names of its sources for the item (for the log).
-- An inserter whose pickup holds only other items is no line for `item` (the fuel
-- inserter from a coal belt -- an empty pickup by what it last held, `memory`: see
-- source_holds); one holding `item` in its hand is a line.
function M.input_line(machine, item, memory)
  local sources, box = F.sources_around(machine)
  -- (known_dry: a "dry" source with proof it is one -- a drill of the item, a pickup
  -- seen holding it, a hand holding it; one only "unknown" does not outweigh a mined-out
  -- drill)
  local found, why, mined_out, known_dry = nil, {}, false, false
  for _, src in pairs(sources) do
    local into = src.valid and F.drops_into(src, box)
    if src.valid and not into then
      why[#why + 1] = src.name .. ":drops-elsewhere"
    end
    if into then
      -- its: a source for `item`; stocked: it has the item at hand (in its hand or at
      -- its pickup) -- a line whatever its status says (live: an inserter from a chest
      -- of 788 ore reported waiting_for_source_items at one scan)
      local its, stocked, unknown = nil, false, false
      if src.type == "mining-drill" then
        its = mines(src, item)
        if not its and src.status == defines.entity_status.no_minable_resources then
          mined_out = true
        end
      else
        local held = src.held_stack
        if held and held.valid_for_read then
          its = held.name == item
          stocked = its
        else
          local from = F.pickup_source(src)
          local h = from and source_holds(from, item, memory)
          its = h == true or h == "empty" or h == "unknown"
          stocked = h == true
          unknown = h == "unknown"
        end
      end
      if its then
        if (stocked and not STOPPED[src.status]) or F.supplying(src) then
          return "line", {F.status_name(src)}
        end
        found = "dry"
        if not unknown then known_dry = true end
        why[#why + 1] = src.name .. ":" .. F.status_name(src)
      elseif src.type == "mining-drill"
             and src.status == defines.entity_status.no_minable_resources then
        why[#why + 1] = src.name .. ":mined-out"
      else
        why[#why + 1] = src.name .. ":not-for-" .. item
      end
    end
  end
  if mined_out and not known_dry then return "mined_out", why end
  return found, why
end

return M
