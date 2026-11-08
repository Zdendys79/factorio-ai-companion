-- Taking items out of a machine or a chest into the companion's inventory -- shared by
-- building.lua's fac_building_empty and the task pool's "take_out" step (the mod walks to
-- it; factorio-ai CompanionAPI.collect / collect_many).
local M = {}

-- the target: the entity nearest the requested position within this radius
local EMPTY_RADIUS = 5

-- Take up to `count` of `item` out of the entity CLOSEST to `pos` (not any in the
-- radius: in a tight furnace row, collecting from the wrong furnace mismatches the fed
-- one) -- from its chest, its crafter output (a furnace's or an assembler's result) and
-- its fuel inventory (the surplus of a self-fuelling burner: the caller asks less than
-- the whole so it keeps a running buffer). Resource tiles are skipped: one can be
-- exactly as close to `pos` as the real target (a chest by its own ore patch) and would
-- win the tie with nothing to give. What does not fit her inventory stays in the target.
-- The caller has checked her reach.
-- @return table {extracted = n, item = item}
function M.empty(c, pos, item, count)
  local es = c.entity.surface.find_entities_filtered{position = pos, radius = EMPTY_RADIUS}
  local target, bd = nil, 1e18
  for _, e in ipairs(es) do
    if e.valid and e ~= c.entity and e.type ~= "resource" then
      local dx, dy = e.position.x - pos.x, e.position.y - pos.y
      local d = dx * dx + dy * dy
      if d < bd then bd, target = d, e end
    end
  end
  local ext = 0
  if target then
    -- (crafter_output covers a furnace's result too in 2.x; the 1.x furnace_result /
    -- furnace_source names are gone -- indexing them throws)
    for _, it in ipairs({defines.inventory.chest, defines.inventory.crafter_output,
                         defines.inventory.fuel}) do
      local inv = target.get_inventory(it)
      if inv then
        local av = inv.get_item_count(item)
        if av > 0 then
          local rm = inv.remove{name = item, count = math.min(count - ext, av)}
          if rm > 0 then
            -- (insert's own return: a full inventory takes less -- the rest goes back)
            local ins = c.entity.insert{name = item, count = rm}
            if ins < rm then inv.insert{name = item, count = rm - ins} end
            ext = ext + ins
          end
        end
      end
      if ext >= count then break end
    end
  end
  return {extracted = ext, item = item}
end

return M
