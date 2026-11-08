-- Loading a machine or a chest from the companion's inventory -- shared by building.lua's
-- fac_building_fill and the task pool's "fill" step (the mod walks to it; factorio-ai
-- CompanionAPI.fill / fill_many).
local u = require("commands.init")

local M = {}

-- the target: the entity nearest the requested position within this radius
local FILL_RADIUS = 3

-- Insert up to `count` of `item` from her inventory into the entity CLOSEST to `pos`
-- (not the first in the radius: in a tight furnace row several furnaces are within it,
-- and feeding the wrong one breaks parallel smelting -- observed: copper-ore fed an iron
-- furnace). Resource tiles are skipped (one can be exactly as close to `pos` as the real
-- target and would win the tie). The caller has checked her reach.
-- @return table {inserted = n, item = item, into = name} or {error = reason}
function M.fill(c, pos, item, count)
  local inv = c.entity.get_inventory(defines.inventory.character_main)
  local have = inv.get_item_count(item)
  if have == 0 then return {error = "No " .. item} end
  local es = c.entity.surface.find_entities_filtered{position = pos, radius = FILL_RADIUS}
  local target, bd = nil, 1e18
  for _, e in ipairs(es) do
    if e.valid and e ~= c.entity and e.type ~= "resource" then
      local dx, dy = e.position.x - pos.x, e.position.y - pos.y
      local d = dx * dx + dy * dy
      if d < bd then bd, target = d, e end
    end
  end
  local ins = 0
  if target then
    -- (pcall: the nearest entity may be one with no inventory at all -- a pole, a tree
    -- -- and an error here would stall the task pool's tick, step after step; as the
    -- insert step does -- independent review)
    local ok, r = pcall(target.insert, {name = item, count = math.min(count, have)})
    if not ok then
      u.log_error("fill: " .. target.name .. ".insert failed: " .. tostring(r), "machine_fill")
      return {error = "Could not insert (" .. target.name .. " takes no " .. item .. ")"}
    end
    if r > 0 then
      local removed = inv.remove{name = item, count = r}
      if removed < r then
        -- (her inventory held less than it said: what is missing goes back out)
        target.remove_item{name = item, count = r - removed}
        u.log_error(string.format("fill: %d %s put in, only %d taken from her inventory",
                                  r, item, removed), "machine_fill")
      end
      ins = removed
    end
  end
  if ins > 0 then return {inserted = ins, item = item, into = target.name} end
  return {error = "Could not insert"}
end

return M
