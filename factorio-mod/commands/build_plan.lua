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
--   4. the fill items ensured, optional (best effort, as the fills themselves: a fill
--      item she cannot get leaves the build standing -- the inserts put in what she
--      has; the task's step_errors say so);
--   5. one place step per piece, in the plan's order (role -> which: the task's ctx
--      records the placed position; a run of belt pieces is one lay step instead --
--      belt_runs.lua, task_pool_lay.lua), a piece with a recipe followed by its
--      set_recipe step (0.16.174: an assembler, a chemical plant, a refinery); an
--      inserter with a filter gets it as it is placed (0.16.186: a line's burner
--      inserter takes only coal -- unfiltered, an empty furnace takes iron plates
--      for steel);
--   6. one insert step per fill, optional (a fill that fails leaves the build
--      standing; the task's step_errors say so) -- the fuel goes in only once the
--      whole chain stands.
-- The steps run one at a time, each competing in her queue by its priority; the next
-- exists for her only once the one before it is done (task_pool.lua: the cursor).
--
-- Plan JSON: {"name": "...", "resource": "iron-ore" | nil,
--   "pieces": [{"entity": NAME, "x": X, "y": Y, "dir": 0-3, "role": "primary" |
--               "secondary" | nil, "mirror": true | nil, "recipe": NAME | nil,
--               "filter": ITEM | nil, "ug": "input" | "output" | nil,
--               "chest_role": "store" | "buffer" | "surplus" | "central" | nil,
--               "chest_item": ITEM (with chest_role),
--               "replaces": OLD | nil}, ...],
--   ("replaces": an upgrade in place -- the OLD building standing there is
--    fast-replaced by the piece, a replace step instead of a place step:
--    task_pool_replace.lua; the OLD one comes back to her, its recipe stays)
--   ("ug": an underground belt's side -- the entrance or the exit; create_entity's
--    type, which can_place_entity does not take)
--   "fills": [{"entity": NAME, "x": X, "y": Y, "item": NAME, "count": N}, ...],
--   "removals": [{"entity": NAME, "x": X, "y": Y}, ...] | nil}

local belt_runs = require("commands.belt_runs")
local chest_roles = require("commands.chest_roles")
local replace_check = require("commands.replace_check")

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

-- A piece's recipe checked (0.16.174 review): the recipe known, the piece an assembling
-- machine (a furnace picks its recipe from its input, a silo's is fixed: set_recipe
-- exists only for assembling machines), a crafting category of the machine one of the
-- recipe's (2.1: recipe.categories, an array; crafting_categories, a dictionary), and
-- -- with her force -- unlocked. nil, or the reason and whether it is only locked (a
-- locked recipe is no fault of the plan's site: LOCKED_PREFIX).
local function recipe_problem(p, force)
  local r = prototypes.recipe[p.recipe]
  if not r then return "unknown recipe " .. tostring(p.recipe) end
  local e = prototypes.entity[p.entity]
  if e.type ~= "assembling-machine" then
    return p.entity .. " takes no recipe (not an assembling machine)"
  end
  local cats, fits = e.crafting_categories or {}, false
  for _, cat in ipairs(r.categories or {}) do
    if cats[cat] then fits = true end
  end
  if not fits then return p.entity .. " cannot make " .. p.recipe end
  if force and not (force.recipes[p.recipe] and force.recipes[p.recipe].enabled) then
    return p.recipe .. " not unlocked yet", true
  end
  return nil
end

-- the prefix of a plan refused for a recipe not unlocked yet -- not "build plan:" (a
-- refusal the controller blames on the build's site: factorio-ai layout_plan_ops)
M.LOCKED_PREFIX = "build plan recipe locked:"

-- The plan checked; nil or the reason it is refused, and whether it is only a locked
-- recipe. `force`: her force (recipes checked unlocked; nil: not checked).
local function check(plan, force)
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
    if p.ug ~= nil then
      if p.ug ~= "input" and p.ug ~= "output" then
        return "piece " .. i .. ": ug must be input or output"
      end
      if prototypes.entity[p.entity].type ~= "underground-belt" then
        return "piece " .. i .. ": " .. p.entity .. " is no underground belt (ug)"
      end
    end
    if p.replaces ~= nil then
      if type(p.replaces) ~= "string" then
        return "piece " .. i .. ": replaces must be an entity name"
      end
      local why = replace_check.problem(p.entity, p.replaces)
      if why then return "piece " .. i .. ": " .. why end
      if p.role ~= nil or p.ug ~= nil or p.mirror ~= nil then
        return "piece " .. i .. ": a replaced piece takes no role, ug or mirror"
      end
    end
    if p.filter ~= nil then
      if type(p.filter) ~= "string" or not prototypes.item[p.filter] then
        return "piece " .. i .. ": filter must be a known item"
      end
      local e = prototypes.entity[p.entity]
      if e.type ~= "inserter" or (e.filter_count or 0) < 1 then
        return "piece " .. i .. ": " .. p.entity .. " takes no filter"
      end
    end
    -- a chest's role, registered as it is placed (commands/chest_roles.lua); a replace
    -- step carries none (review)
    if p.chest_role ~= nil and p.replaces ~= nil then
      return "piece " .. i .. ": a replaced piece takes no chest_role"
    end
    if p.chest_role ~= nil then
      if not chest_roles.ROLES[p.chest_role] then
        return "piece " .. i .. ": unknown chest_role " .. tostring(p.chest_role)
      end
      if type(p.chest_item) ~= "string" or not prototypes.item[p.chest_item] then
        return "piece " .. i .. ": chest_role needs a known chest_item"
      end
      local e = prototypes.entity[p.entity]
      if e.type ~= "container" and e.type ~= "logistic-container" then
        return "piece " .. i .. ": " .. p.entity .. " is no chest"
      end
    end
    if p.recipe ~= nil then
      if type(p.recipe) ~= "string" then return "piece " .. i .. ": recipe must be a name" end
      local why, locked = recipe_problem(p, force)
      if why then return "piece " .. i .. ": " .. why, locked end
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

-- The task's steps of `plan` (this file's header), or nil plus the reason it is refused
-- ("build plan: ...", or LOCKED_PREFIX for a recipe not unlocked yet). `force`: her
-- force (a piece's recipe checked unlocked).
function M.expand(plan, force)
  if type(plan) ~= "table" then return nil, "a plan must be an object" end
  local err, locked = check(plan, force)
  if err then return nil, (locked and M.LOCKED_PREFIX or "build plan:") .. " " .. err end
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
  -- (optional: a fill item that cannot be had must not fail the whole build before
  -- anything is placed -- the fills are best effort)
  for _, item in ipairs(fill_order) do
    steps[#steps + 1] = {type = "ensure_item", item = item, count = fill_counts[item],
                         optional = true}
  end
  -- (a run of two or more belt pieces, each following the last, is one lay step: laid
  -- as she walks along, no build wait per piece -- belt_runs.lua, task_pool_lay.lua)
  for _, g in ipairs(belt_runs.group(plan.pieces)) do
    if g.lay then
      local pieces = {}
      for i, p in ipairs(g.lay) do
        pieces[i] = {entity = p.entity, x = p.x, y = p.y, dir = p.dir or 0, ug = p.ug}
      end
      steps[#steps + 1] = {type = "lay", pieces = pieces}
    elseif g.piece.replaces then
      local p = g.piece
      steps[#steps + 1] = {type = "replace", entity = p.entity, old = p.replaces,
                           x = p.x, y = p.y}
      if p.recipe then
        steps[#steps + 1] = {type = "set_recipe", x = p.x, y = p.y, entity = p.entity,
                             recipe = p.recipe}
      end
    else
      local p = g.piece
      steps[#steps + 1] = {type = "place", entity = p.entity, x = p.x, y = p.y,
                           dir = p.dir or 0, which = p.role, mirror = p.mirror or nil,
                           filter = p.filter, ug = p.ug,
                           chest = p.chest_role and {role = p.chest_role, item = p.chest_item}}
      -- (an assembler's recipe right after it stands -- 0.16.174)
      if p.recipe then
        steps[#steps + 1] = {type = "set_recipe", x = p.x, y = p.y, entity = p.entity,
                             recipe = p.recipe}
      end
    end
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
