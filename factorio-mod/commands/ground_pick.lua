-- Items on the ground picked up as she passes (Zdendys: "nothing may lie on the ground,
-- everything is stored in chests or inventories; tidying is like felling trees -- when
-- I walk past an item on the ground, I pick it up").
--
-- The game's own picking (picking_state) reaches only item_pickup_distance (1 tile) and
-- picked nothing 1 tile off her walk (factorio-ai probe_picking_state_2026_11_18), so
-- the walking queues' pass picks the item-entities within PICK_R of her itself, as the
-- build queue's obstacle clearing does (queues_build.lua): the stack into her main
-- inventory, the lying stack shrunk by what went in (a part that did not fit stays).
-- Only into stacks she already holds, or while more than KEEP_EMPTY slots stay empty:
-- the callers that count her free slots before a pick-up walk (a relocation, a retire)
-- must still find them (review); the rest stays on the ground for a later pass.
local M = {}

M.PICK_R = 2          -- tiles round her: the same reach as the walk's tree clearing
M.PICK_MAX = 8        -- item-entities picked per pass at most (a big spill: over passes)
M.KEEP_EMPTY = 3      -- empty slots kept (factorio-ai INVENTORY_OVERFLOW_EMPTY_STACKS_FLOOR)

-- Pick up to PICK_MAX item-entities within PICK_R of character `e`; returns how many
-- items went into her inventory.
function M.pick_near(e)
  local inv = e.get_main_inventory()
  if not inv then return 0 end
  local moved_total, seen = 0, 0
  local items = e.surface.find_entities_filtered{position = e.position, radius = M.PICK_R,
                                                 type = "item-entity"}
  for _, it in ipairs(items) do
    if seen >= M.PICK_MAX then break end
    if it.valid and it.stack and it.stack.valid_for_read then
      seen = seen + 1
      local name = it.stack.name
      local held = inv.get_item_count(name) > 0
      if held or inv.count_empty_stacks() > M.KEEP_EMPTY then
        local moved = inv.insert(it.stack)
        if moved >= it.stack.count then it.destroy()
        elseif moved > 0 then it.stack.count = it.stack.count - moved end
        moved_total = moved_total + moved
      end
    end
  end
  return moved_total
end

return M
