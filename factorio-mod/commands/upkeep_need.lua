-- The fuel upkeep's need measures (commands/upkeep.lua): how long a burner's fuel lasts,
-- how full its output is, and the priority of a burner's or a fuel chest's need --
-- p = log2(target / max(1, t)), lowered by the output's fill: p' = 1 + (p - 1) x
-- (1 - 0.9 x fill) (Zdendys: a production's shortage in TIME left, by its reciprocal;
-- products piling up need the supply less, a full output still leaves a little).
local F = require("commands.upkeep_feeds")

local M = {}

-- (shared by the fuel upkeep and the feed upkeep, commands/upkeep_feed.lua)
-- the fuel upkeep scans the burners within this many tiles of her
M.SCAN_RADIUS = 150
-- a machine on a supply line delivering nothing is hers only under this many seconds of
-- fuel or input (a sparse belt's inserter waits now and then; a dead line's machine
-- drops below it, and a scan plus a walk fit in it while she is free)
M.LINE_DRY_S = 60
-- below this share of a stack her stock of an item is short (the stock upkeep's
-- trigger)
M.STOCK_LOW_SHARE = 0.5
-- what her stock of an item is filled up to (Zdendys: 70 % of a stack)
M.STOCK_TARGET_SHARE = 0.7
-- an underfed machine (its line delivering nothing) is logged at most once this long
M.UNDERFED_LOG_TICKS = 18000

-- statuses in which a burner needs no fuel now (a mined-out drill, nothing to smelt)
M.NO_NEED = {[defines.entity_status.no_minable_resources] = true,
             [defines.entity_status.no_ingredients] = true}

-- (seconds its fuel lasts, seconds its slots filled would last -- each slot with the
-- fuel it holds, an empty one with `fuel` --, joules per tick, the joules it holds) at
-- full consumption; nil when not measurable. (review: a slot holding wood has no room
-- for coal -- measured by coal alone, its full slot was what it held, and it never
-- showed a need until the slot ran empty)
function M.fuel_seconds(e, fuel)
  local burner = e.burner
  if not burner or not burner.inventory then return nil end
  local usage = e.prototype.get_max_energy_usage(e.quality)   -- joules per tick
  if not usage or usage <= 0 then return nil end
  local inv = burner.inventory
  local energy = (burner.remaining_burning_fuel or 0) + F.inventory_fuel(inv)
  local full = energy
  for i = 1, #inv do
    local stack = inv[i]
    local held = stack.valid_for_read
    local proto = held and stack.prototype or prototypes.item[fuel]
    if proto then
      full = full + math.max(0, proto.stack_size - (held and stack.count or 0))
                    * (proto.fuel_value or 0)
    end
  end
  return energy / (usage * 60), full / (usage * 60), usage, energy
end

-- Its output's fill, 0 .. 1 (products piling up -- nothing takes them off).
function M.output_fill(e)
  local s = e.status
  if s == defines.entity_status.full_output
     or s == defines.entity_status.waiting_for_space_in_destination then
    return 1
  end
  if e.type == "furnace" then
    local out = e.get_inventory(defines.inventory.crafter_output)
    if out and #out > 0 then
      local fill = 0
      for _, item in pairs(out.get_contents()) do
        local proto = prototypes.item[item.name]
        local stack = proto and proto.stack_size or 50
        fill = math.max(fill, item.count / stack)
      end
      return math.min(1, fill)
    end
  end
  return 0
end

-- The priority of a need from its time left and target, lowered by an output's fill
-- (nil: not short).
function M.priority_of(t, target, fill)
  if target <= 1 then return nil end
  local p = math.log(target / math.max(1, t), 2)
  if p <= 1 then return nil end
  return 1 + (p - 1) * (1 - 0.9 * fill)
end

-- A burner's upkeep need -- its own slot filled with `fuel`, target min(target_s, a full
-- slot): {p, t, target, usage, fill}, or nil (no task: not measurable, needing no fuel
-- now, or not short).
function M.burner_need(e, target_s, fuel)
  if M.NO_NEED[e.status] then return nil end
  local t, full, usage = M.fuel_seconds(e, fuel)
  if not t then return nil end
  local target = math.min(target_s, full)
  local fill = M.output_fill(e)
  local p = M.priority_of(t, target, fill)
  if not p then return nil end
  return {p = p, t = t, target = target, usage = usage, fill = fill}
end

-- A fuel chest's need for the burners it feeds (group: {chest, usage = their joules per
-- tick together, energy = the joules they hold, fill = the least output fill among
-- them}) -- the chest's fuel and theirs over their consumption together (review: each
-- burner counting the whole chest as its own overrated it N times), target target_s,
-- no slot cap (the chest is filled): {p, t, target, usage, fill, into = the chest}, or
-- nil.
function M.chest_need(group, target_s)
  local chest = group.chest
  local energy = group.energy + F.inventory_fuel(chest.get_inventory(defines.inventory.chest))
  local t = energy / (group.usage * 60)
  local p = M.priority_of(t, target_s, group.fill)
  if not p then return nil end
  return {p = p, t = t, target = target_s, usage = group.usage, fill = group.fill,
          into = chest}
end

return M
