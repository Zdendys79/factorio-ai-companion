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
-- Zdendys 2026-11-09 (factorio-ai docs/architecture_roles.md Decided 5): a burner is
-- fuelled by hand -- to full -- once its fuel slot holds this share of a stack or less,
-- or its fuel lasts under FUEL_LOW_S, whichever comes first (a stone furnace's half slot
-- lasts ~18 min, a burner drill's ~11 min)
M.FUEL_SKIP_SHARE = 0.5
M.FUEL_LOW_S = 300
-- a burner whose slot takes fewer items than this is not fuelled (review: a hand-fed
-- boiler's full slot lasts ~111 s, always under FUEL_LOW_S -- a task for 1 coal after
-- every coal it burned); the upkeep's MIN_BATCH
M.MIN_ROOM = 5
-- the least priority of a low burner's or chest's need (its fuel may still last far
-- longer than the target -- a stone furnace's half slot ~1100 s: a task still, the
-- lowest)
M.MIN_P = 1.01
-- Zdendys 2026-11-09 (Decided 5): a supply chest holds this many stacks of coal at
-- least -- filled up to it once it holds CHEST_LOW_STACKS or less (the half, as a
-- burner's slot) or its burners' fuel lasts under FUEL_LOW_S
M.CHEST_STACKS = 4
M.CHEST_LOW_STACKS = 2

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

-- The share of its fuel slots' stacks a burner holds, 0 .. 1 (each slot by the fuel it
-- holds; an empty one counts a stack of `fuel` -- review of 0.16.176: the slot rule
-- judges items, not seconds), and the items its slots still take.
function M.fuel_slot_share(e, fuel)
  local inv = e.burner and e.burner.inventory
  if not inv or #inv == 0 then return 1, 0 end
  local held, cap = 0, 0
  for i = 1, #inv do
    local stack = inv[i]
    local proto = stack.valid_for_read and stack.prototype or prototypes.item[fuel]
    if proto then
      cap = cap + proto.stack_size
      held = held + (stack.valid_for_read and stack.count or 0)
    end
  end
  if cap <= 0 then return 1, 0 end
  return held / cap, cap - held
end

-- Whether a burner's fuel is low (Zdendys 2026-11-09): its slot at FUEL_SKIP_SHARE of a
-- stack or less, or its fuel lasting under FUEL_LOW_S -- whichever comes first.
function M.fuel_low(share, t)
  return share <= M.FUEL_SKIP_SHARE or t < M.FUEL_LOW_S
end

-- A burner's upkeep need -- its fuel slot filled to full (Zdendys 2026-11-09) once its
-- fuel is low (fuel_low), or while `filling` (a fill that brought less than full goes
-- on): {p, t, target, usage, fill, full = true}, or nil (no task: not measurable,
-- needing no fuel now, not low, or its slot taking fewer than MIN_ROOM items). p from
-- its seconds left against min(target_s, a full slot), lowered by its output's fill,
-- at least MIN_P.
function M.burner_need(e, target_s, fuel, filling)
  if M.NO_NEED[e.status] then return nil end
  local share, room = M.fuel_slot_share(e, fuel)
  if share >= 1 or room < M.MIN_ROOM then return nil end
  local t, full, usage = M.fuel_seconds(e, fuel)
  if not t then return nil end
  if not (filling or M.fuel_low(share, t)) then return nil end
  local target = math.min(target_s, full)
  local fill = M.output_fill(e)
  local p = math.max(M.MIN_P, 1 + (math.log(target / math.max(1, t), 2) - 1)
                                  * (1 - 0.9 * fill))
  return {p = p, t = t, target = target, usage = usage, fill = fill, full = true}
end

-- A fuel chest's need for the burners it feeds (group: {chest, usage = their joules per
-- tick together, energy = the joules they hold, fill = the least output fill among
-- them}) -- Zdendys 2026-11-09 (Decided 5): a supply chest is kept at CHEST_STACKS
-- stacks of `fuel` at least, a task now and then: once its fuel is worth CHEST_LOW_STACKS
-- stacks or less, or the chest's fuel and theirs last under min(FUEL_LOW_S, half of
-- what a full chest and theirs last) over their consumption together (review: each
-- burner counting the whole chest as its own overrated it N times), or while `filling`
-- (a fill that brought less goes on), it is filled up to CHEST_STACKS (missing_j, the
-- joules missing): {p, t, target, usage, fill, into = the chest, missing_j}, or nil
-- (fewer than MIN_ROOM items short of CHEST_STACKS). p from t against target =
-- min(target_s, what a full chest and theirs last), at least MIN_P.
function M.chest_need(group, target_s, fuel, filling)
  local proto = prototypes.item[fuel]
  if not proto or (proto.fuel_value or 0) <= 0 then return nil end
  local chest = group.chest
  local held_j = F.inventory_fuel(chest.get_inventory(defines.inventory.chest))
  local stack_j = proto.stack_size * proto.fuel_value
  local t = (group.energy + held_j) / (group.usage * 60)
  -- (its target and the low mark: min(target_s, what a full chest and their fuel
  -- last), its half -- review: 4 stacks last two boilers ~222 s, always under
  -- FUEL_LOW_S, a 5-coal task at nearly every scan)
  local full_t = (group.energy + M.CHEST_STACKS * stack_j) / (group.usage * 60)
  local target = math.min(target_s, full_t)
  local low_t = math.min(M.FUEL_LOW_S, full_t / 2)
  if not filling and held_j > M.CHEST_LOW_STACKS * stack_j and t >= low_t then
    return nil
  end
  local missing_j = M.CHEST_STACKS * stack_j - held_j
  if missing_j < M.MIN_ROOM * proto.fuel_value then return nil end
  local p = M.priority_of(t, target, group.fill) or M.MIN_P
  return {p = p, t = t, target = target, usage = group.usage, fill = group.fill,
          into = chest, missing_j = missing_j}
end

return M
