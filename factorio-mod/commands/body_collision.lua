-- Whether her own body stands in a build's way: the character's collision box overlaps the
-- entity's collision box and their collision masks share a layer. A pure read of the
-- prototypes -- nothing is moved to find out (she steps aside only when this says so).
local M = {}

local function share_layer(a, b)
  for layer in pairs(a.layers or {}) do
    if b.layers and b.layers[layer] then return true end
  end
  return false
end

-- The entity's collision box on `position`, turned by the build direction.
local function box_at(proto, position, direction)
  local bb = proto.collision_box
  local x1, y1, x2, y2 = bb.left_top.x, bb.left_top.y, bb.right_bottom.x, bb.right_bottom.y
  for _ = 1, math.floor((direction or 0) / 4 + 0.5) % 4 do
    x1, y1, x2, y2 = -y1, x1, -y2, x2
  end
  return position.x + math.min(x1, x2), position.y + math.min(y1, y2),
         position.x + math.max(x1, x2), position.y + math.max(y1, y2)
end

-- @param character LuaEntity her body
-- @return boolean true when an `entity_name` built at `position` would overlap it
function M.blocks(character, entity_name, position, direction)
  local proto = prototypes.entity[entity_name]
  if not proto or not proto.collision_box then return false end
  if not share_layer(proto.collision_mask, character.prototype.collision_mask) then
    return false
  end
  local ax1, ay1, ax2, ay2 = box_at(proto, position, direction)
  local bb = character.bounding_box
  return ax1 < bb.right_bottom.x and bb.left_top.x < ax2
     and ay1 < bb.right_bottom.y and bb.left_top.y < ay2
end

return M
