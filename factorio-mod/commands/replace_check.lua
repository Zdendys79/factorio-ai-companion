-- AI Companion -- whether one building may fast-replace another (the "replace" step,
-- task_pool_replace.lua; a plan's "replaces" piece, build_plan.lua). No requires: both
-- load it (task_pool_replace -> task_pool_ledger -> build_plan would be a require loop).

local M = {}

-- Whether NEW may fast-replace OLD (both known, the same fast-replaceable group, no belt
-- -- a belt run is laid, not placed). nil, or the reason.
function M.problem(new, old)
  local pn, po = prototypes.entity[new or ""], prototypes.entity[old or ""]
  if not pn then return "unknown entity " .. tostring(new) end
  if not po then return "unknown entity to replace " .. tostring(old) end
  if new == old then return new .. " replaces itself" end
  if pn.type == "transport-belt" or pn.type == "underground-belt" then
    return "a belt is laid, not replaced"
  end
  local g = pn.fast_replaceable_group
  if not g or g == "" or g ~= po.fast_replaceable_group then
    return new .. " cannot fast-replace " .. old
  end
  return nil
end

return M
