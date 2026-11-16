-- An inserter's item filter set as it is placed (0.16.186, factorio-ai line mining: a
-- line's burner inserter takes only coal -- unfiltered, an empty furnace takes iron
-- plates for steel). Used by queues_build.lua right after create_entity, before the
-- inserter's first swing (a later tick).

local u = require("commands.init")

local M = {}

-- Set filter 1 of `placed` to `item` (2.1: a filter acts only with use_filters) and
-- read it back. nil when it holds; else the inserter is taken back -- its item returned
-- to `char` (spilled beside it when her inventory is full, never lost), logged -- and
-- the reason is returned, prefixed "filter <item> not set: " (factorio-ai
-- build_plan.failed_at_spot blames no site for it).
function M.apply(placed, item, char)
  local ok, err = pcall(function()
    placed.use_filters = true
    placed.set_filter(1, item)
    -- a filter the game ignored is a failure too
    local f = placed.get_filter(1)
    local n = f and f.name
    n = (type(n) == "string" and n) or (n and n.name)
    if not placed.use_filters or n ~= item then
      error("read back use_filters=" .. tostring(placed.use_filters) .. " filter="
            .. tostring(n))
    end
  end)
  if ok then return nil end
  -- an unfiltered inserter must not stay: it would feed plates into an empty furnace
  local name, surf = placed.name, placed.surface
  local at = {x = placed.position.x, y = placed.position.y}
  placed.destroy()
  local back = char.insert{name = name, count = 1}
  if back < 1 then
    surf.spill_item_stack{position = at, stack = {name = name, count = 1}}
  end
  u.log_error("build queue: filter " .. item .. " on " .. name .. " failed: "
              .. tostring(err) .. " -- taken back (item returned: " .. back .. ")",
              "build_queue")
  return "filter " .. item .. " not set: " .. tostring(err)
end

return M
