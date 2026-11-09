-- The fuel upkeep's batches (commands/upkeep.lua): which fuel and how much of it an
-- upkeep task for a need takes. `cfg` is the upkeep's constants (FUEL = coal, MIN_BATCH,
-- WOOD, WOOD_KEEP); a need n is
-- {e = the burner, into = its fuel chest or nil, t, target, usage, full = true for a
-- burner filled to full, missing_j = the joules a fuel chest lacks} (upkeep_need).
local M = {}

-- The inventory an upkeep task fills: the fuel chest (need.into) or the burner's slot.
function M.target_inventory(e, need)
  if need.into then return need.into.get_inventory(defines.inventory.chest) end
  return e.burner.inventory
end

-- The fuel `item` a need takes, capped by the room of what is filled for it: a burner
-- (need.full) to full -- all the room (Zdendys 2026-11-09); a fuel chest up to its
-- CHEST_STACKS (need.missing_j, upkeep_need.chest_need). (amount, room)
function M.wanted(e, need, item)
  local proto = prototypes.item[item]
  if not proto or not proto.fuel_value or proto.fuel_value <= 0 then return 0, 0 end
  local inv = M.target_inventory(e, need)
  local room = inv and inv.get_insertable_count(item) or 0
  if need.full then return room, room end
  local missing_j = math.max(0, need.missing_j or 0)
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

-- The coal once the burner's other fuels are swapped out into her inventory -- to full,
-- all the room (a swap is only ever a burner's, filled to full -- Zdendys 2026-11-09):
-- (amount, room, the coal worth the energy taken out).
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
  return room, room, math.ceil(out_j / coal.fuel_value)
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

-- A need she has no free coal for, as an entry of the fetch's short list
-- (commands/upkeep_fetch.lua): {want = the coal it wants, t, target}, or nil -- only a
-- need whose fuel lasts under its target (min(TARGET_S, what its full slot / chest
-- lasts)) sends her to get coal, ranked against that target (reviews of 0.16.177: a
-- half slot of a stone furnace, ~1100 s, made a fetch that outranked every build; a
-- boiler's full slot, ~111 s, was always urgent against TARGET_S; it waits for her coal
-- meanwhile). It wants only what keeps it its target -- a slot's full room, a chest's 4
-- stacks are filled from what she carries (live: 4 stacks of several chests made a
-- shortage of 1072 coal, a fetch at p 11.4, and full slots of ~12 burners one of ~230 at
-- p ~9.5 -- each outranked every feed) -- at least MIN_BATCH, for a burner held by
-- another fuel what its swap needs (review: a fetch of less never let the swap happen).
function M.short_entry(cfg, n)
  if n.t >= n.target then return nil end
  local want, room = M.wanted(n.e, n, cfg.FUEL)
  local least = cfg.MIN_BATCH
  if room < 1 and not n.into then
    local out
    want, room, out = M.wanted_after_swap(cfg, n)
    least = out + cfg.MIN_BATCH
  end
  local coal = prototypes.item[cfg.FUEL]
  want = math.min(want, math.ceil(math.max(0, n.target - n.t) * n.usage * 60
                                  / coal.fuel_value))
  return {want = math.min(math.max(want, least), room), t = n.t, target = n.target}
end

-- What she may give of a fuel other than coal (`inv` her main inventory): wood above
-- cfg.WOOD_KEEP (`keep` false: the keep too), any other all she holds unreserved;
-- `extra` as in choose.
local function free_other(cfg, inv, item, extra, keep)
  local free = inv.get_item_count(item) - (storage.reserved[item] or 0) + (extra[item] or 0)
  if item == cfg.WOOD and keep then free = free - cfg.WOOD_KEEP end
  return free
end

-- The fuel an upkeep task for need n takes (`extra`: what a task about to be replaced
-- would release, by item; `inv` her main inventory; `blocked`: another task waits for
-- coal; `free_coal` her free coal above the floor). A slot already holding another fuel
-- (only that fits it -- review: wood left to run dry): topped up with it from her
-- surplus; else, at a burner, coal swapped in (the fuel step moves the other fuel into
-- her inventory -- review: topping it up from the keep drained the wood the builds
-- keep, the slot never going back to coal); else with it from all she holds unreserved,
-- the keep too (no coal to swap in -- too little coal for what comes out, no room for it
-- in her inventory --, or another task waits for coal -- a running burner before her
-- wood stock). Else her wood surplus where it covers the need (Zdendys: wood is never
-- kept in stock beyond what the builds need) -- also in part (review of 0.16.177: a
-- slot's whole room of wood, 100, was more than her surplus mostly, so it was never
-- burned; the fill goes on); else coal, unless another task waits for it.
-- (item, amount, whether free coal is what limits it, swap)
function M.choose(cfg, n, extra, inv, blocked, free_coal)
  local held = M.held_fuel(cfg, n)
  if held then
    local amount = M.other(cfg, n, held, free_other(cfg, inv, held, extra, true), true)
    if amount >= 1 or n.into then return held, amount, false, false end
    -- (a swap only when her inventory has room for what comes out -- review: else the
    -- step failed at every scan)
    local coal_n, coal_short = 0, false
    if not blocked and M.swap_fits(n, cfg.FUEL, inv) then
      coal_n, coal_short = M.coal(cfg, n, free_coal, extra[cfg.FUEL], true)
    end
    if coal_n >= 1 then return cfg.FUEL, coal_n, false, true end
    amount = M.other(cfg, n, held, free_other(cfg, inv, held, extra, false), true)
    return held, amount, amount < 1 and coal_short, false
  end
  local wood_n = M.other(cfg, n, cfg.WOOD, free_other(cfg, inv, cfg.WOOD, extra, true), true)
  if wood_n >= 1 or blocked then return cfg.WOOD, wood_n, false, false end
  local amount, coal_short = M.coal(cfg, n, free_coal, extra[cfg.FUEL])
  return cfg.FUEL, amount, coal_short, false
end

return M
