-- AI Companion -- the task pool's machine steps: loading a machine or a chest ("fill")
-- and taking out of one ("take_out"), the mod walking there (task_pool.lua's acting
-- state, a hand step within her reach). Their result is the step's result
-- (fac_task_status step_results). factorio-ai: CompanionAPI.fill / fill_many /
-- collect / collect_many.

local targeting = require("commands.task_pool_targeting")
local machine_fill = require("commands.machine_fill")
local machine_empty = require("commands.machine_empty")

local M = {}

-- The step's position, item and whole count >= 1 -- or the reason it has none.
-- @return table|nil pos, string|nil item, number|nil count, string|nil err
local function resolve(t, step)
  local pos = targeting.step_target_pos(t, step)
  if not pos then return nil, nil, nil, step.type .. ": no target position resolved" end
  if type(step.item) ~= "string" or not prototypes.item[step.item] then
    return nil, nil, nil, step.type .. ": unknown item " .. tostring(step.item)
  end
  local count = tonumber(step.count) or 1
  if count < 1 or count ~= math.floor(count) then
    return nil, nil, nil, step.type .. ": count must be a whole number >= 1, got "
                          .. tostring(step.count)
  end
  return pos, step.item, count, nil
end

-- {type="fill", x=, y=, item=NAME, count=N}: up to N of the item from her inventory
-- into the entity closest to (x, y) -- fac_building_fill's load (machine_fill.fill).
-- Not a need of the task (derive_needs): like the command, it loads what she has, up to
-- N. Result {inserted, item, into}.
-- @return boolean ok, string|nil err, table|nil result
function M.run_fill(c, t, step)
  local pos, item, count, err = resolve(t, step)
  if err then return false, err end
  local r = machine_fill.fill(c, pos, item, count)
  if r.error then return false, r.error end
  return true, nil, r
end

-- {type="take_out", x=, y=, item=NAME, count=N}: up to N of the item out of the entity
-- closest to (x, y) -- its chest, crafter output or fuel inventory -- into her inventory:
-- fac_building_empty's take (machine_empty.empty). Taking none is no failure (as the
-- command: the caller reads extracted). Result {extracted, item}.
-- @return boolean ok, string|nil err, table|nil result
function M.run_take_out(c, t, step)
  local pos, item, count, err = resolve(t, step)
  if err then return false, err end
  return true, nil, machine_empty.empty(c, pos, item, count)
end

return M
