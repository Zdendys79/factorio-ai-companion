-- AI Companion -- the task pool's "replace" step: a building upgraded in place to its
-- next tier (factorio-ai docs/science_scaling.md, the pack assemblers' tier upgrade;
-- milestones_design.md "Upgrades": Zdendys -- a milestone is replaced by its better
-- variant).
--
-- {type="replace", x=, y=, entity=NEW, old=OLD}: the OLD building of her force nearest
-- (x, y) within REPLACE_RADIUS is fast-replaced by NEW from her inventory, as a player
-- would -- LuaSurface.create_entity{fast_replace=true, character=her}. Live probe
-- (factorio-ai scripts/probe_fast_replace_2026_11_17.py, 2.1): the recipe and the
-- machine's contents stay, the OLD building comes back into her inventory -- and the NEW
-- item is NOT taken from it by the engine, so the step takes it (never a free build).
-- The NEW building must share OLD's fast-replaceable group (checked).

local u = require("commands.init")
local targeting = require("commands.task_pool_targeting")
local ledger = require("commands.task_pool_ledger")
local replace_check = require("commands.replace_check")

local M = {}

-- the OLD building's search radius round the step's position
local REPLACE_RADIUS = 1

-- @return boolean ok, string|nil err
function M.run_replace(c, t, step)
  local pos = targeting.step_target_pos(t, step)
  if not pos then return false, "replace: no target position resolved" end
  local why = replace_check.problem(step.entity, step.old)
  if why then return false, "replace: " .. why end
  local surf, force = c.entity.surface, c.entity.force
  -- (the nearest one: never the first match -- two machines may stand within reach)
  local old, best = nil, math.huge
  for _, e in pairs(surf.find_entities_filtered{name = step.old, position = pos,
                                                radius = REPLACE_RADIUS, force = force}) do
    local d = u.distance(e.position, pos)
    if e.valid and d < best then old, best = e, d end
  end
  if not old then
    return false, "replace: no " .. step.old .. " at the target"
  end
  local inv = c.entity.get_main_inventory()
  if inv.get_item_count(step.entity) < 1 then
    return false, "replace: no " .. step.entity .. " in her inventory"
  end
  local at, dir, mirror = old.position, old.direction, old.mirroring
  -- (what comes back to her: the OLD building -- one that does not fit her inventory
  -- is spilled by the engine, logged below)
  local back_before = inv.get_item_count(step.old)
  if not surf.can_fast_replace{name = step.entity, position = at, direction = dir,
                               force = force} then
    return false, "replace: " .. step.entity .. " cannot replace the " .. step.old
                  .. " there"
  end
  local ok, new = pcall(surf.create_entity, {name = step.entity, position = at,
                                             direction = dir, force = force,
                                             mirror = mirror, fast_replace = true,
                                             character = c.entity})
  if not ok or not (new and new.valid) then
    u.log_error("replace: create_entity " .. step.entity .. " failed: " .. tostring(new),
                "task_pool")
    return false, "replace: the " .. step.entity .. " was not built"
  end
  -- never a free build: the NEW item taken (counted above, the same tick)
  if c.entity.remove_item{name = step.entity, count = 1} < 1 then
    u.log_error("replace: the " .. step.entity .. " item was gone after the build",
                "task_pool")
    return false, "replace: the " .. step.entity .. " item vanished"
  end
  if inv.get_item_count(step.old) <= back_before then
    u.log_error("replace: the old " .. step.old .. " did not come back into her inventory"
                .. " (full? spilled at the spot)", "task_pool")
  end
  ledger.consume(t, step.entity, 1)
  t.placed = t.placed or {}
  t.placed[#t.placed + 1] = {entity = step.entity, x = new.position.x, y = new.position.y}
  return true, nil
end

return M
