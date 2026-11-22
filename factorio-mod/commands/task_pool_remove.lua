-- The task pool's "remove" step: picking up one of her own buildings with real mining
-- time (the rule: nothing is mined or moved instantly). She stands within reach of it and
-- mines it with the engine's own mining (commands/clearing.lua step_target: the walk
-- closer, her mining speed, the full-inventory relief); the engine puts the item and a
-- chest's contents into her inventory. The step's active state is "removing"; this
-- module polls it.
local clearing = require("commands.clearing")
local inv_watch = require("commands.inventory_watch")

local M = {}

-- the longest one pick-up lasts in all (clearing's own bounds: a walk 1200, a mining 900,
-- a relief 3600 ticks)
M.DEADLINE_TICKS = 5700

-- Start the pick-up of `target` in the active step.
function M.begin(c, active, target)
  active.state = "removing"
  active.remove_target = target
  active.remove_st = {}
  active.remove_deadline = game.tick + M.DEADLINE_TICKS
end

-- One cycle of the pick-up.
-- @return boolean true while it goes on; else false and ok (boolean), err (string or nil)
function M.tick(cid, c, active)
  local target = active.remove_target
  local over = game.tick >= active.remove_deadline
  if target and target.valid and not over
     and clearing.step_target(cid, c, active.remove_st, target) == "busy" then
    return true
  end
  clearing.release(cid, c)
  inv_watch.gained(c.entity)
  local ok = not (target and target.valid)
  local st = active.remove_st
  active.remove_target, active.remove_st, active.remove_deadline = nil, nil, nil
  if ok then return false, true, nil end
  -- (still standing: her inventory could not take it, or she never got to it / it did not
  -- come down in time -- callers tell the two by the start of the reason)
  if over or not (st and st.room_failed) and st and next(st.skip or {}) then
    return false, false, "could not reach: not reached or not mined in time"
  end
  return false, false, "Cannot remove (inventory full?)"
end

return M
