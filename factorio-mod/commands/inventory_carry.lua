-- Everything a companion carries goes with her or lands on the ground -- never destroyed.
-- Her body is replaced (respawn) or removed (kill, disappear): this module moves every one
-- of her inventories (main, guns, ammo, armor, trash), the cursor stack and the refund of
-- a cancelled hand-craft queue to the new body, or spills them at her position.
--
-- The hand-craft queue cannot be carried to another body: it is cancelled and the engine
-- returns the ingredients to her main inventory, which is carried like the rest.
local u = require("commands.init")

local M = {}

-- (name, defines.inventory) of every inventory a character body owns, in carry order
local KINDS = {
  {"main",  defines.inventory.character_main},
  {"guns",  defines.inventory.character_guns},
  {"ammo",  defines.inventory.character_ammo},
  {"armor", defines.inventory.character_armor},
  {"trash", defines.inventory.character_trash},
}
local MAX_CANCELS = 64      -- the queue is cancelled one entry per round, bounded

local function inventories(entity)
  local list = {}
  for _, k in ipairs(KINDS) do
    local inv = entity.get_inventory(k[2])
    if inv and inv.valid then list[#list + 1] = {name = k[1], kind = k[2], inv = inv} end
  end
  return list
end

-- Cancels her whole hand-craft queue (the ingredients return to her inventory).
-- @return number entries cancelled
local function cancel_crafting(entity, cid)
  local cancelled = 0
  while entity.crafting_queue_size > 0 and cancelled < MAX_CANCELS do
    local queue = entity.crafting_queue
    local last = queue and queue[#queue]
    if not last then break end
    entity.cancel_crafting{index = last.index, count = last.count}
    cancelled = cancelled + 1
  end
  if entity.crafting_queue_size > 0 then
    u.log_error(string.format("inventory_carry: companion %s's craft queue still holds %d "
      .. "entries after %d cancels", tostring(cid), entity.crafting_queue_size, cancelled),
      "inventory_carry")
  end
  return cancelled
end

-- Takes everything she carries into a scratch inventory, slot for slot (a stack keeps its
-- ammo, durability and equipment grid), so the old body may be destroyed.
-- @param entity LuaEntity her character body (still valid)
-- @return table a hold for release() / spill_hold(); must be given to one of them
function M.hold(entity, cid)
  local cancelled = cancel_crafting(entity, cid)
  local invs, layout, total = inventories(entity), {}, 0
  for _, k in ipairs(invs) do
    k.offset = total
    layout[#layout + 1] = {kind = k.kind, offset = total, size = #k.inv}
    total = total + #k.inv
  end
  local scratch = game.create_inventory(total + 1)
  local held = {scratch = scratch, layout = layout, cursor_slot = total + 1,
                cancelled = cancelled, kept = 0}
  for _, k in ipairs(invs) do
    for i = 1, #k.inv do
      if k.inv[i].valid_for_read then
        if scratch[k.offset + i].set_stack(k.inv[i]) then
          held.kept = held.kept + 1
        else
          u.log_error(string.format("inventory_carry: %s slot %d of companion %s did not "
            .. "go into the hold", k.name, i, tostring(cid)), "inventory_carry")
        end
      end
    end
  end
  local cursor = entity.cursor_stack
  if cursor and cursor.valid and cursor.valid_for_read then
    if scratch[held.cursor_slot].set_stack(cursor) then
      held.kept = held.kept + 1
    else
      u.log_error("inventory_carry: the cursor stack of companion " .. tostring(cid)
        .. " did not go into the hold", "inventory_carry")
    end
  end
  return held
end

-- Puts the hold into the new body: each stack to its own slot, else into the main
-- inventory, what fits nowhere on the ground at her feet. The hold ends.
-- @return table {placed = stacks, spilled = stacks}
function M.release(held, entity, cid)
  local placed, spilled = 0, 0
  local main = entity.get_inventory(defines.inventory.character_main)
  local function put_anywhere(stack)
    local put = main and main.valid and main.insert(stack) or 0
    if put >= stack.count then return true end
    if put > 0 then stack.count = stack.count - put end
    entity.surface.spill_item_stack{position = entity.position, stack = stack,
                                    enable_looted = true, allow_belts = false}
    return false
  end
  for _, l in ipairs(held.layout) do
    local dst = entity.get_inventory(l.kind)
    for i = 1, l.size do
      local src = held.scratch[l.offset + i]
      if src.valid_for_read then
        local slot = dst and dst.valid and i <= #dst and dst[i] or nil
        if slot and not slot.valid_for_read and slot.set_stack(src) then
          placed = placed + 1
        elseif put_anywhere(src) then
          placed = placed + 1
        else
          spilled = spilled + 1
        end
      end
    end
  end
  local cur = held.scratch[held.cursor_slot]
  if cur.valid_for_read then
    local hand = entity.cursor_stack
    if hand and hand.valid and not hand.valid_for_read and hand.set_stack(cur) then
      placed = placed + 1
    elseif put_anywhere(cur) then
      placed = placed + 1
    else
      spilled = spilled + 1
    end
  end
  held.scratch.destroy()
  if spilled > 0 then
    u.log_error(string.format("inventory_carry: companion %s's new body had no room for %d "
      .. "stack(s): spilled at her feet", tostring(cid), spilled), "inventory_carry")
  end
  return {placed = placed, spilled = spilled}
end

-- Puts the hold on the ground at `position` (no new body came). The hold ends.
-- @return number stacks spilled
function M.spill_hold(held, surface, position)
  local n = held.kept
  surface.spill_inventory{position = position, inventory = held.scratch,
                          enable_looted = true, allow_belts = false,
                          use_start_position_on_failure = true}
  held.scratch.destroy()
  return n
end

-- Everything she carries onto the ground at her position (kill, disappear): the craft
-- queue is cancelled first, then every inventory and the cursor stack are spilled.
-- @return table list of {name=, count=} of what was spilled (summed per item name)
function M.spill_all(entity, cid)
  cancel_crafting(entity, cid)
  local surface, pos = entity.surface, entity.position
  local totals, order = {}, {}
  local function count(inv_or_stack)
    for _, item in pairs(inv_or_stack.get_contents()) do
      if not totals[item.name] then order[#order + 1] = item.name; totals[item.name] = 0 end
      totals[item.name] = totals[item.name] + item.count
    end
  end
  for _, k in ipairs(inventories(entity)) do
    if not k.inv.is_empty() then
      count(k.inv)
      surface.spill_inventory{position = pos, inventory = k.inv, enable_looted = true,
                              allow_belts = false, use_start_position_on_failure = true}
      k.inv.clear()
    end
  end
  local cursor = entity.cursor_stack
  if cursor and cursor.valid and cursor.valid_for_read then
    if not totals[cursor.name] then order[#order + 1] = cursor.name; totals[cursor.name] = 0 end
    totals[cursor.name] = totals[cursor.name] + cursor.count
    surface.spill_item_stack{position = pos, stack = cursor, enable_looted = true,
                             allow_belts = false, use_start_position_on_failure = true}
    cursor.clear()
  end
  local spilled = {}
  for _, name in ipairs(order) do spilled[#spilled + 1] = {name = name, count = totals[name]} end
  return spilled
end

return M
