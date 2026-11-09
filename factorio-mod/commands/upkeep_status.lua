-- A companion's upkeep state for the /fac_upkeep reply (commands/task.lua): the fuel
-- upkeep's (commands/upkeep.lua) open tasks, the burners she had no free coal for, the
-- coal fetch, the feed upkeep and the stock upkeep.
local upkeep = require("commands.upkeep")
local Fetch = require("commands.upkeep_fetch")
local Feed = require("commands.upkeep_feed")
local Stock = require("commands.upkeep_stock")

local M = {}

-- The state: enabled, its open fuel-upkeep tasks, short (burners she had no free coal
-- for lately), blocked_by_coal_wait, fetch, feed and stock.
function M.status(cid)
  local up = storage.upkeep or {}
  local recent = upkeep.SHORT_LOG_TICKS
  local out = {enabled = (up.enabled and up.enabled[cid]) or false, tasks = {}, short = {}}
  for key, task_id in pairs((up.tasks and up.tasks[cid]) or {}) do
    local t = storage.tasks[task_id]
    if t and t.status == "active" then
      -- fills: what the task fills -- the burner's slot ("fuel") or a fuel chest
      -- ("insert"), at "x,y"
      local s = t.steps and t.steps[1]
      out.tasks[#out.tasks + 1] = {key = key, task_id = task_id, status = t.status,
                                   priority = t.priority, fills = s and s.type,
                                   at = s and string.format("%.1f,%.1f", s.x, s.y)}
    end
  end
  local logs = up.logs or {}
  for key, tick in pairs((logs.short and logs.short[cid]) or {}) do
    if game.tick - tick < recent then out.short[#out.short + 1] = key end
  end
  -- another task waited for coal lately (no new upkeep task then)
  local blocked = logs.blocked and logs.blocked[cid] and logs.blocked[cid].coal
  out.blocked_by_coal_wait = blocked ~= nil and game.tick - blocked < recent
  -- getting the coal she lacks: {task_id, priority, how = "take" / "ensure_item"}
  out.fetch = Fetch.status(cid)
  -- feeding: {tasks, hand_fed (rule 6: what she feeds by hand, each with the tick of its
  -- last feed), unknown (furnaces whose input it cannot tell), held_off (after
  -- failures)} -- commands/upkeep_feed.lua
  out.feed = Feed.status(cid)
  -- keeping her stock: [{item, task_id, priority, at}] -- commands/upkeep_stock.lua
  out.stock = Stock.status(cid)
  return out
end

return M
