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

-- A priority aged: p times log2 of the ticks since `since` (Zdendys: every command and
-- task ages, so one that keeps losing to other steps gains on them -- a far one only
-- slowly, effective()'s nearness root weakens it; a fresh
-- one -- under 2 ticks -- counts below p, at most the lowest priority, and is still
-- done when nothing else waits). A nil `since` (a task from an older save) counts as
-- fresh.
-- @param p number the base priority
-- @param since number|nil the tick the task or command was given
-- @return number
function M.aged(p, since)
  local age = math.max(1, game.tick - (since or game.tick))
  return p * math.log(age, 2)
end

-- A priority raised by nearness.
-- @param p number the priority (>= 1; below 1 the formula inverts -- clamped)
-- @param distance number tiles to where the step acts (0 for an in-place step)
-- @return number
function M.effective(p, distance)
  return math.max(1, p) ^ (1 / ((distance or 0) + 1))
end

return M
