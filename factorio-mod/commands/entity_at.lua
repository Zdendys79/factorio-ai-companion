-- The entity a command or a task step means at a position, and its pick-up (shared by
-- building.lua's fac_building_remove and the task pool's "remove" step).
local M = {}

-- how far off an entity's selection box a requested position may lie: callers pass a
-- position slightly off the entity's centre (a snapped pipe up to ~0.6 off); a
-- neighbouring 1x1 belt's box is 0.5 away from this tile's centre, so it never qualifies
local BOX_MARGIN = 0.25

-- The entity `name` of `force` that `pos` means: the nearest one within 1 tile (not
-- the first found -- radius 1 round a belt tile also matches its 4 neighbours, in no
-- particular order), and only if `pos` lies on it (within BOX_MARGIN of its selection
-- box): when nothing of that name is there, the nearest match is a neighbour, which a
-- pick-up must not mine. Returns the entity or nil.
function M.find(surface, name, pos, force)
  local es = surface.find_entities_filtered{name = name, position = pos, radius = 1,
                                            force = force}
  local t, td = nil, nil
  for _, e in ipairs(es) do
    local d = (e.position.x - pos.x) ^ 2 + (e.position.y - pos.y) ^ 2
    if not td or d < td then t, td = e, d end
  end
  if not t then return nil end
  local bb, m = t.selection_box, BOX_MARGIN
  if pos.x < bb.left_top.x - m or pos.x > bb.right_bottom.x + m
     or pos.y < bb.left_top.y - m or pos.y > bb.right_bottom.y + m then
    return nil
  end
  return t
end

-- MINE `t` (native) into the companion's inventory: its real item and its contents go
-- there and the game removes it -- never a fabricated item and a free destroy. With a
-- full inventory mine{} leaves it standing -- also when only its contents fitted (they
-- moved, the item count rose, the entity still stands: judged by the entity, not the
-- count -- independent review). Returns true, or false and the reason.
function M.mine_into(c, t)
  local mined = t.mine{inventory = c.entity.get_main_inventory()}
  if not mined or t.valid then
    return false, "Cannot remove (inventory full?)"
  end
  return true
end

return M
