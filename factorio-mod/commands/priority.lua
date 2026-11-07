-- Nyara's queue priorities (Zdendys's model; factorio-ai docs/architecture_roles.md and
-- docs/companion_task_queue.md).
--
-- A step's effective priority = p ^ (1 / (distance + 1)): standing next to it gives the
-- full p, a far one converges to 1. The scheduler runs the highest, the older task on a
-- tie. Base p by the kind of task (Zdendys: build < relocation < dismantling); the
-- mod's upkeep tasks compute their own p on the same scale (commands/upkeep.lua: log2
-- of the target time over the time a burner's fuel lasts, lowered by a full output).
local M = {}

-- a task's base priority by its kind
M.BASE = {build = 2, relocate = 3, dismantle = 4}
M.DEFAULT_KIND = "build"
-- the mod's own upkeep tasks (commands/upkeep.lua): their priority is computed (the
-- time a burner's fuel lasts, its output's fill) and kept up to date by the upkeep
M.UPKEEP_KIND = "upkeep"

-- The base priority of a task kind (nil for an unknown kind).
-- @param kind string|nil
-- @return number|nil
function M.base(kind)
  return M.BASE[kind or M.DEFAULT_KIND]
end

-- A priority raised by nearness.
-- @param p number the priority (>= 1; below 1 the formula inverts -- clamped)
-- @param distance number tiles to where the step acts (0 for an in-place step)
-- @return number
function M.effective(p, distance)
  return math.max(1, p) ^ (1 / ((distance or 0) + 1))
end

return M
