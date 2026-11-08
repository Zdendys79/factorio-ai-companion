-- The fuel upkeep's batches (commands/upkeep.lua): how much of a fuel an upkeep task for a
-- need takes. `cfg` is the upkeep's constants (FUEL = coal, MIN_BATCH, TARGET_S); a need n is
-- {e = the burner, into = its fuel chest or nil, t, target, usage} (upkeep_need).
local M = {}

-- The inventory an upkeep task fills: the fuel chest (need.into) or the burner's slot.
function M.target_inventory(e, need)
  if need.into then return need.into.get_inventory(defines.inventory.chest) end
  return e.burner.inventory
end

-- The fuel `item` to the need's target, capped by the room of what is filled for it:
-- (amount, room).
function M.wanted(e, need, item)
  local proto = prototypes.item[item]
  if not proto or not proto.fuel_value or proto.fuel_value <= 0 then return 0, 0 end
  local missing_j = math.max(0, (need.target - need.t) * need.usage * 60)
  local inv = M.target_inventory(e, need)
  local room = inv and inv.get_insertable_count(item) or 0
  return math.min(math.ceil(missing_j / proto.fuel_value), room), room
end

-- Whether an item prototype is a chemical fuel (2.1: an item's fuel_categories, an
-- array -- it has no fuel_category, live).
local function chemical(proto)
  for _, cat in ipairs(proto.fuel_categories or {}) do
    if cat == "chemical" then return true end
  end
  return false
end

-- The fuel other than coal that what need n fills holds where coal has no room (only
-- that fuel fits it then -- a burner slot holding wood), or nil. (a chemical fuel only
-- -- review: a chest's partial stack of nutrients or a fuel cell is no fuel to top up)
function M.held_fuel(cfg, n)
  local inv = M.target_inventory(n.e, n)
  if not inv or inv.get_insertable_count(cfg.FUEL) > 0 then return nil end
  for i = 1, #inv do
    local stack = inv[i]
    if stack.valid_for_read and stack.name ~= cfg.FUEL
       and chemical(stack.prototype) and (stack.prototype.fuel_value or 0) > 0
       and inv.get_insertable_count(stack.name) > 0 then
      return stack.name
    end
  end
  return nil
end

-- The amount of a fuel `item` other than coal an upkeep task for need n would take: the
-- amount wanted raised to a batch worth MIN_BATCH coal, capped by the room for it in
-- what is filled (a burner slot holding coal takes no wood) -- 0 unless `free` (what she
-- may give of it) covers it all; with `partial`, what she may give when that reaches
-- min(the batch, the room).
function M.other(cfg, n, item, free, partial)
  local coal, fuel = prototypes.item[cfg.FUEL], prototypes.item[item]
  if not (coal and fuel and (fuel.fuel_value or 0) > 0) then return 0 end
  local want, room = M.wanted(n.e, n, item)
  local least = math.ceil(cfg.MIN_BATCH * coal.fuel_value / fuel.fuel_value)
  local amount = math.min(math.max(want, least), room)
  if amount < 1 then return 0 end
  if free >= amount then return amount end
  if partial and free >= math.min(least, room) then return free end
  return 0
end

-- The coal to the target once the burner's other fuels are swapped out into her
-- inventory -- the target of a slot of coal, min(TARGET_S, what it lasts full: the
-- coal's own, not the fuel's taken out) -- and the room for it then: (amount, room, the
-- coal worth the energy taken out).
function M.wanted_after_swap(cfg, n)
  local coal = prototypes.item[cfg.FUEL]
  if not coal or (coal.fuel_value or 0) <= 0 then return 0, 0, 0 end
  local inv = n.e.burner.inventory
  local room, out_j = 0, 0
  for i = 1, #inv do
    local stack = inv[i]
    if stack.valid_for_read and stack.name == cfg.FUEL then
      room = room + math.max(0, coal.stack_size - stack.count)
    else
      room = room + coal.stack_size
      if stack.valid_for_read then
        out_j = out_j + stack.count * (stack.prototype.fuel_value or 0)
      end
    end
  end
  local per_s = n.usage * 60
  local energy = math.max(0, n.t * per_s - out_j)          -- what stays in it
  local target_j = math.min(cfg.TARGET_S * per_s, energy + room * coal.fuel_value)
  local want = math.ceil(math.max(0, target_j - energy) / coal.fuel_value)
  return math.min(want, room), room, math.ceil(out_j / coal.fuel_value)
end

-- Whether all the burner's fuel other than `item` a swap would move out fits `into`
-- (her main inventory; per entry -- the fuel slot of every burner the upkeep keeps is a
-- single one).
function M.swap_fits(n, item, into)
  for _, it in pairs(n.e.burner.inventory.get_contents()) do
    if it.name ~= item
       and into.get_insertable_count({name = it.name, quality = it.quality}) < it.count then
      return false
    end
  end
  return true
end

-- The coal an upkeep task for need n would take: the amount wanted raised to MIN_BATCH,
-- capped by the room of what is filled and the free coal (`extra`: coal a task about to
-- be replaced would release) -- 0 when the free coal does not reach min(MIN_BATCH, the
-- room) (review: she walked far to hand over 1 coal). (amount, whether free coal is what
-- limits it)
-- With `swap` (a burner slot holding another fuel -- the fuel step moves it into her
-- inventory first), the room and the amount wanted are those after the swap (wanted_
-- after_swap), and the least is the coal worth what is taken out plus MIN_BATCH (review:
-- 5 coal for 20 wood left a burner half the fuel it had).
function M.coal(cfg, n, free, extra, swap)
  local want, room, least
  if swap then
    local out
    want, room, out = M.wanted_after_swap(cfg, n)
    least = math.min(out + cfg.MIN_BATCH, room)
  else
    want, room = M.wanted(n.e, n, cfg.FUEL)
    least = math.min(cfg.MIN_BATCH, room)
  end
  local amount = math.min(math.max(want, least), room)
  local avail = math.max(0, free + (extra or 0))
  local take = math.min(amount, avail)
  if take < least then return 0, avail < amount end
  return take, avail < amount
end

return M
