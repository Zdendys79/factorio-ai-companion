-- Setting a crafting machine's recipe: the one place for the task pool's set_recipe
-- step and the /fac_building_recipe command. The machine is the assembling machine
-- (assembler, chemical plant, refinery) nearest the target; the recipe must be known
-- and unlocked; what the machine held for its old recipe comes back to her inventory
-- (what does not fit is spilled at the machine, logged). Fluids are not returned.
local u = require("commands.init")
local inv_watch = require("commands.inventory_watch")

local M = {}

M.RADIUS = 1   -- how far from the target the machine may stand (its centre)

-- The assembling machine nearest pos within M.RADIUS (of `name` when given), or nil.
local function nearest_machine(c, pos, name)
  local filter = {position = pos, radius = M.RADIUS, force = c.entity.force}
  if name then filter.name = name end
  local target, best = nil, math.huge
  for _, e in pairs(c.entity.surface.find_entities_filtered(filter)) do
    if e.valid and e.type == "assembling-machine" then
      local d = u.distance(e.position, pos)
      if d < best then target, best = e, d end
    end
  end
  return target
end

-- Hand the removed items to her; spill the rest at the machine (logged).
local function return_items(c, machine, removed, tag)
  for _, it in pairs(removed or {}) do
    local got = c.entity.insert(it)
    if got > 0 then inv_watch.gained(c.entity) end
    if got < it.count then
      -- (no force: spilled items marked for deconstruction would call robots)
      c.entity.surface.spill_item_stack{position = machine.position,
        stack = {name = it.name, count = it.count - got, quality = it.quality}}
      u.log_error(string.format("set_recipe: %d %s from the %s spilled (her inventory full)",
                                it.count - got, it.name, machine.name), tag)
    end
  end
end

-- Set the recipe of the machine at pos.
-- @param c table companion record (c.entity her character)
-- @param pos table {x, y}
-- @param recipe_name string
-- @param entity_name string|nil only a machine of this name
-- @param tag string log tag of the caller
-- @return boolean ok, string|nil err
function M.set(c, pos, recipe_name, entity_name, tag)
  if type(recipe_name) ~= "string" then return false, "set_recipe: recipe missing" end
  local recipe = c.entity.force.recipes[recipe_name]
  if not recipe then return false, "set_recipe: unknown recipe " .. recipe_name end
  if not recipe.enabled then
    return false, "set_recipe: " .. recipe_name .. " not unlocked yet"
  end
  local machine = nearest_machine(c, pos, entity_name)
  if not machine then
    return false, "set_recipe: no " .. tostring(entity_name or "machine")
                  .. " (an assembling machine) at the target"
  end
  local ok, removed = pcall(machine.set_recipe, recipe_name)
  if not ok then
    u.log_error("set_recipe: " .. machine.name .. ".set_recipe failed: " .. tostring(removed), tag)
    return false, "set_recipe: the " .. machine.name .. " refused " .. recipe_name
  end
  return_items(c, machine, removed, tag)
  local now = machine.get_recipe()
  if not now or now.name ~= recipe_name then
    return false, "set_recipe: the " .. machine.name .. " did not take " .. recipe_name
  end
  return true, nil
end

return M
