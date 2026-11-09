-- AI Companion -- a build plan task (factorio-ai docs/build_plans.md, Zdendys): the
-- controller hands over the whole plan of a build at once, under one task name -- its
-- pieces (entity, exact position, direction) in placement order, back to front (a
-- consumer before the inserter that feeds it, the inserter before its chest), and the
-- fills (fuel, material), and what it takes down first (removals: an upgrade's old
-- buildings, their items reused) -- and the mod splits it into its own steps itself:
--   1. every part ensured (gathered, fetched or crafted) -- as many as the removals
--      will not give back, so the old buildings stand until the rest is in hand;
--      with a resource, the new primary piece's tile checked too (set_position,
--      verify_tile) -- both before anything old is taken down;
--   2. the removals, optional (one already gone is only noted; the next pass makes
--      up for it);
--   3. every part ensured again, the whole count: what a removal did not give, and a
--      part a later craft consumed (a burner drill's recipe takes a stone furnace);
--   4. the fill items ensured;
--   5. one place step per piece, in the plan's order (role -> which: the task's ctx
--      records the placed position);
--   6. one insert step per fill, optional (a fill that fails leaves the build
--      standing; the task's step_errors say so) -- the fuel goes in only once the
--      whole chain stands.
-- The steps run one at a time, each competing in her queue by its priority; the next
-- exists for her only once the one before it is done (task_pool.lua: the cursor).
--
-- Plan JSON: {"name": "...", "resource": "iron-ore" | nil,
--   "pieces": [{"entity": NAME, "x": X, "y": Y, "dir": 0-3, "role": "primary" |
--               "secondary" | nil, "mirror": true | nil}, ...],
--   "fills": [{"entity": NAME, "x": X, "y": Y, "item": NAME, "count": N}, ...],
--   "removals": [{"entity": NAME, "x": X, "y": Y}, ...] | nil}

local M = {}

local ROLES = {primary = true, secondary = true}

-- The item that places entity `name`, or nil plus the reason: plans place only entities
-- whose own item places them (derive_needs counts a place step's entity as its item).
local function placing_item(name)
  local proto = prototypes.entity[name]
  if not proto then return nil, "unknown entity " .. tostring(name) end
  local items = proto.items_to_place_this
  if not items or not items[1] then return nil, name .. " is placed by no item" end
  if items[1].name ~= name then
    return nil, name .. " is placed by " .. items[1].name .. ", not by its own item"
  end
  return name
end

-- The plan checked; nil or the reason it is refused.
local function check(plan)
  if type(plan.pieces) ~= "table" or #plan.pieces == 0 then return "a plan needs pieces" end
  for i, p in ipairs(plan.pieces) do
    if type(p) ~= "table" or type(p.x) ~= "number" or type(p.y) ~= "number" then
      return "piece " .. i .. ": x / y missing"
    end
    if type(p.entity) ~= "string" then return "piece " .. i .. ": entity missing" end
    local _, err = placing_item(p.entity)
    if err then return "piece " .. i .. ": " .. err end
    if p.dir ~= nil and not (p.dir == 0 or p.dir == 1 or p.dir == 2 or p.dir == 3) then
      return "piece " .. i .. ": dir must be 0-3"
    end
    if p.role ~= nil and not ROLES[p.role] then
      return "piece " .. i .. ": role must be primary or secondary"
    end
    if p.mirror ~= nil and type(p.mirror) ~= "boolean" then
      return "piece " .. i .. ": mirror must be true or false"
    end
  end
  for i, f in ipairs(plan.fills or {}) do
    if type(f) ~= "table" or type(f.x) ~= "number" or type(f.y) ~= "number"
        or type(f.entity) ~= "string" or not prototypes.item[f.item or ""]
        or type(f.count) ~= "number" or f.count < 1 or f.count ~= math.floor(f.count) then
      return "fill " .. i .. ": entity, x, y, a known item and a whole count >= 1 needed"
    end
  end
  for i, r in ipairs(plan.removals or {}) do
    if type(r) ~= "table" or type(r.x) ~= "number" or type(r.y) ~= "number"
        or type(r.entity) ~= "string" or not prototypes.entity[r.entity] then
      return "removal " .. i .. ": a known entity, x and y needed"
    end
  end
  if plan.resource ~= nil then
    if type(plan.resource) ~= "string" or not prototypes.entity[plan.resource] then
      return "unknown resource " .. tostring(plan.resource)
    end
    local has_primary = false
    for _, p in ipairs(plan.pieces) do
      if p.role == "primary" then has_primary = true end
    end
    if not has_primary then return "a resource check needs a primary piece" end
  end
  return nil
end

-- The task's steps of `plan` (this file's header), or nil plus the reason it is refused.
function M.expand(plan)
  if type(plan) ~= "table" then return nil, "a plan must be an object" end
  local err = check(plan)
  if err then return nil, "build plan: " .. err end
  local order, counts = {}, {}
  for _, p in ipairs(plan.pieces) do
    if not counts[p.entity] then order[#order + 1] = p.entity end
    counts[p.entity] = (counts[p.entity] or 0) + 1
  end
  local given = {}
  for _, r in ipairs(plan.removals or {}) do
    given[r.entity] = (given[r.entity] or 0) + 1
  end
  local steps = {}
  -- 1. the parts the removals will not give back (the old buildings stand meanwhile)
  for _, item in ipairs(order) do
    local short = counts[item] - (given[item] or 0)
    if short > 0 then
      steps[#steps + 1] = {type = "ensure_item", item = item, count = short}
    end
  end
  -- the new site's resource checked before anything old is taken down
  if plan.resource then
    for _, p in ipairs(plan.pieces) do
      if p.role == "primary" then
        steps[#steps + 1] = {type = "set_position", x = p.x, y = p.y}
        steps[#steps + 1] = {type = "verify_tile", resource = plan.resource}
        break
      end
    end
  end
  -- 2. the removals (optional: one already gone only noted, the next pass makes up)
  for _, r in ipairs(plan.removals or {}) do
    steps[#steps + 1] = {type = "remove", entity = r.entity, x = r.x, y = r.y,
                         optional = true}
  end
  -- 3. every part again, the whole count
  for _, item in ipairs(order) do
    steps[#steps + 1] = {type = "ensure_item", item = item, count = counts[item]}
  end
  -- 4. the fill items
  local fill_order, fill_counts = {}, {}
  for _, f in ipairs(plan.fills or {}) do
    if not fill_counts[f.item] then fill_order[#fill_order + 1] = f.item end
    fill_counts[f.item] = (fill_counts[f.item] or 0) + f.count
  end
  for _, item in ipairs(fill_order) do
    steps[#steps + 1] = {type = "ensure_item", item = item, count = fill_counts[item]}
  end
  for _, p in ipairs(plan.pieces) do
    steps[#steps + 1] = {type = "place", entity = p.entity, x = p.x, y = p.y,
                         dir = p.dir or 0, which = p.role, mirror = p.mirror or nil}
  end
  for _, f in ipairs(plan.fills or {}) do
    steps[#steps + 1] = {type = "insert", x = f.x, y = f.y, entity = f.entity,
                         item = f.item, count = f.count, optional = true}
  end
  return steps
end

-- The pieces a task put down, [{entity, x, y}] at their real positions -- recorded by
-- task_pool.lua when each place step finishes (t.placed), for any task. A task from an
-- older save has no record: nil, which the status leaves out (the controller then
-- picks up every planned piece).
function M.placed(t)
  return t.placed
end

return M
