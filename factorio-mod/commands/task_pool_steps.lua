-- AI Companion -- task pool synchronous (non-walking) step handlers: the steps that act
-- at once (read_drop_position, find_existing, set_position, find_patch, verify_tile) and
-- their helpers. The scheduler (M.tick), which dispatches to these, is in task_pool.lua,
-- whose header comment block holds the step vocabulary.

local u = require("commands.init")
local targeting = require("commands.task_pool_targeting")
local ledger = require("commands.task_pool_ledger")
local feeds = require("commands.upkeep_feeds")
local inv_watch = require("commands.inventory_watch")
local machine_recipe = require("commands.machine_recipe")

local step_target_pos = targeting.step_target_pos
local WALK_REACH = targeting.WALK_REACH

local M = {}

-- an "insert" step's target: the entity of its name nearest its position within this
-- radius
local INSERT_RADIUS = 1

-- {type="insert", x=, y=, entity=NAME, item=NAME, count=N}: N of the item from her
-- inventory into the entity of that name nearest (x, y) within INSERT_RADIUS -- e.g.
-- the fuel chest an inserter feeds a burner from (commands/upkeep.lua: Zdendys -- she
-- supplies a production or a chest no belt with that material reaches yet). What went
-- in leaves the task's reservations (ledger.consume); what could not be taken from her
-- inventory is taken back out of the target.
-- @return boolean ok, string|nil err
function M.run_insert(c, t, step)
  local pos = step_target_pos(t, step)
  if not pos then return false, "insert: no target position resolved" end
  if type(step.item) ~= "string" or not prototypes.item[step.item] then
    return false, "insert: unknown item " .. tostring(step.item)
  end
  local count = tonumber(step.count) or 1
  if count < 1 or count ~= math.floor(count) then
    return false, "insert: count must be a whole number >= 1, got " .. tostring(step.count)
  end
  local inv = c.entity.get_main_inventory()
  local raw = inv.get_item_count(step.item)
  if raw == 0 then return false, "no " .. step.item .. " in inventory" end
  -- what she holds less what OTHER tasks reserved (ledger.free_count): an optional
  -- insert runs without its own full reservation since 0.16.173 and must not take
  -- another task's (review: an upkeep fuel task's coal went into a plan's fill)
  local have, others = ledger.free_count(t, step.item, raw)
  if have <= 0 then
    return false, string.format("no %s free in inventory (%d held, %d reserved by other "
                                .. "tasks)", step.item, raw, others)
  end
  local filter = {position = pos, radius = INSERT_RADIUS}
  if step.entity then filter.name = step.entity end
  local target, best = nil, math.huge
  for _, e in pairs(c.entity.surface.find_entities_filtered(filter)) do
    if e.valid and e ~= c.entity and e.type ~= "resource" then
      local d = u.distance(e.position, pos)
      if d < best then target, best = e, d end
    end
  end
  if not target then
    return false, "insert: no " .. tostring(step.entity or "entity") .. " at the target"
  end
  local ok, n = pcall(target.insert, {name = step.item, count = math.min(count, have)})
  if not ok then
    u.log_error("insert: " .. target.name .. ".insert failed: " .. tostring(n), "task_pool")
    return false, "insert: the " .. target.name .. " refused " .. step.item
  end
  if n <= 0 then
    -- the inventory the item belongs in (a fuel's: the fuel slot) full of it already:
    -- the fill's aim is met, no failure; else a failure naming what that inventory
    -- holds (factorio-ai smokes 1118zc, 1119d: "the stone-furnace took no coal" -- not
    -- a full slot: a script insert keeps no inserter limit, probe_furnace_insert_limit)
    local fi = target.get_fuel_inventory and target.get_fuel_inventory()
    local is_fuel = fi ~= nil and (prototypes.item[step.item].fuel_value or 0) > 0
    local held = is_fuel and fi.get_item_count(step.item) or target.get_item_count(step.item)
    local room = is_fuel and fi.get_insertable_count(step.item) or 0
    if held > 0 and room == 0 then return true, nil end
    local inside = {}
    for _, it in pairs(((is_fuel and fi) or target.get_output_inventory()
                        or {get_contents = function() return {} end}).get_contents()) do
      inside[#inside + 1] = it.count .. " " .. it.name
    end
    return false, "insert: the " .. target.name .. " took no " .. step.item
                  .. " (" .. (is_fuel and "its fuel slot" or "it") .. " holds "
                  .. (#inside > 0 and table.concat(inside, ", ") or "nothing") .. ")"
  end
  local removed = inv.remove{name = step.item, count = n}
  if removed < n then
    -- (her inventory held less than it said: what is missing goes back out of the target)
    target.remove_item{name = step.item, count = n - removed}
    u.log_error(string.format("insert: %d %s put in, only %d taken from her inventory",
                              n, step.item, removed), "task_pool")
  end
  if removed > 0 then ledger.consume(t, step.item, removed) end
  if removed <= 0 then return false, "insert: no " .. step.item .. " left in inventory" end
  if step.item == "coal" then            -- (the early coal wait's trace: where her coal goes)
    log(string.format("[ai-companion] [COALPUT] insert step: %d coal into %s at (%.1f,%.1f) "
                      .. "(task %s kind %s)", removed, target.name, target.position.x,
                      target.position.y, tostring(t.id), tostring(t.kind)))
  end
  return true, nil
end

-- a fuel step's swap: its target is the burner this near its position
local SWAP_RADIUS = 0.5

-- A fuel step's swap ({type="fuel", ..., swap=true} -- commands/upkeep.lua: a slot
-- holding wood takes no coal; topping it up with wood drained the wood she keeps for
-- the builds): every other fuel in the fuel inventory of `target` (the burner nearest
-- the step's position `pos`) moved into her inventory, so the step's item fits it.
-- Nothing is moved unless all of it fits her inventory and she holds the step's whole
-- count free (review: a partial swap, or too little coal, left it less fuel than
-- before).
-- @param have what she holds of the item free (ledger.free_count -- what the fuel step
--   may put in; 0.16.173 review: her raw count let a swap empty the burner for 2 coal)
-- @return nil (no swap asked, or done) or the error (not her burner at the position, too
-- little of the item, or no room in her inventory for what would come out)
function M.swap_at_target(c, step, target, pos, have)
  if not step.swap then return nil end
  if not (target and target.valid and target.force.name == c.entity.force.name
          and u.distance(target.position, pos) <= SWAP_RADIUS) then
    return "fuel: swap -- no burner of hers at the target"
  end
  local fi = target.get_fuel_inventory()
  if not fi then return "fuel: swap -- the " .. target.name .. " has no fuel inventory" end
  local inv = c.entity.get_main_inventory()
  local count = step.count or 1
  if have < count then
    return string.format("fuel: swap -- %d %s free with her, the step needs %d", have,
                         step.item, count)
  end
  -- (per entry -- the fuel slot of every burner the upkeep keeps is a single one)
  for _, it in pairs(fi.get_contents()) do
    if it.name ~= step.item
       and inv.get_insertable_count({name = it.name, quality = it.quality}) < it.count then
      return "fuel: swap -- no room in her inventory for the " .. it.name
    end
  end
  for i = 1, #fi do
    local stack = fi[i]
    if stack.valid_for_read and stack.name ~= step.item then
      local name, n = stack.name, stack.count
      local got = c.entity.insert(stack)
      if got > 0 then inv_watch.gained(c.entity) end
      if got >= n then
        stack.clear()
      else
        -- (room was checked: logged, what came out stays with her)
        if got > 0 then stack.count = n - got end
        u.log_error(string.format("fuel: swap -- %d of %d %s fit her inventory", got, n,
                                  name), "task_pool")
        return "fuel: swap -- no room in her inventory for the " .. name
      end
    end
  end
  return nil
end

-- {type="set_recipe", x=, y=, entity=NAME, recipe=NAME} (0.16.174): the recipe of her
-- force's machine of that name nearest (x, y) within machine_recipe.RADIUS -- a build plan's
-- assembler, chemical plant or refinery (its piece's "recipe", set right after it is
-- placed: build_plan.lua). An unknown or still-locked recipe, or no such machine, fails
-- the step.
-- @return boolean ok, string|nil err
function M.run_set_recipe(c, t, step)
  local pos = step_target_pos(t, step)
  if not pos then return false, "set_recipe: no target position resolved" end
  return machine_recipe.set(c, pos, step.recipe, step.entity, "task_pool")
end

-- {type="take", x=, y=, entity=NAME, item=NAME, count=N, store=true|nil}: up to N of
-- the item from her force's chest of that name nearest (x, y) within INSERT_RADIUS into
-- her inventory -- the upkeep's getting material (commands/upkeep_fetch.lua: a coal
-- store). Takes what the chest has (at least 1, else the step fails); what does not fit
-- into her inventory goes back into the chest. store: the chest must still be a store
-- on her arrival, she takes only its store share (upkeep_feeds.store_share: a drill's
-- output chest less what its partner's inserter keeps; none from a chest an inserter
-- picks from otherwise -- review: one built since the plan would have been robbed).
-- @return boolean ok, string|nil err
function M.run_take(c, t, step)
  local pos = step_target_pos(t, step)
  if not pos then return false, "take: no target position resolved" end
  if type(step.item) ~= "string" or not prototypes.item[step.item] then
    return false, "take: unknown item " .. tostring(step.item)
  end
  local count = tonumber(step.count) or 1
  if count < 1 or count ~= math.floor(count) then
    return false, "take: count must be a whole number >= 1, got " .. tostring(step.count)
  end
  local filter = {position = pos, radius = INSERT_RADIUS, force = c.entity.force}
  if step.entity then filter.name = step.entity end
  local chest, best = nil, math.huge
  for _, e in pairs(c.entity.surface.find_entities_filtered(filter)) do
    if e.valid and e.get_inventory(defines.inventory.chest) then
      local d = u.distance(e.position, pos)
      if d < best then chest, best = e, d end
    end
  end
  if not chest then
    return false, "take: no " .. tostring(step.entity or "chest") .. " at the target"
  end
  local inv = chest.get_inventory(defines.inventory.chest)
  local avail = inv.get_item_count(step.item)
  if step.store then
    avail = feeds.store_share(chest, step.item)
    if avail <= 0 then
      return false, "take: the " .. chest.name .. " is no store of " .. step.item
                    .. " now (an inserter picks from it, or only its keep is left)"
    end
  end
  if avail <= 0 then return false, "take: the " .. chest.name .. " holds no " .. step.item end
  local n = inv.remove{name = step.item, count = math.min(count, avail)}
  if n <= 0 then return false, "take: the " .. chest.name .. " gave no " .. step.item end
  local got = c.entity.insert{name = step.item, count = n}
  if got < n then inv.insert{name = step.item, count = n - got} end
  if got <= 0 then return false, "take: no room in her inventory for " .. step.item end
  inv_watch.gained(c.entity)
  if step.item == "coal" then            -- (the early coal wait's trace: who takes what)
    log(string.format("[ai-companion] [COALTAKE] take step: %d coal from %s at (%.1f,%.1f) "
                      .. "(%d left)", got, chest.name, chest.position.x, chest.position.y,
                      inv.get_item_count(step.item)))
  end
  return true, nil
end

function M.run_read_drop_position(c, t, step)
  local pos = step_target_pos(t, step)
  if not pos then return false, "read_drop_position: no source position resolved" end
  local es = c.entity.surface.find_entities_filtered{
    name = step.entity, position = pos, radius = 1}
  if #es == 0 then return false, "read_drop_position: no " .. tostring(step.entity) .. " found at source" end
  local dp = es[1].drop_position
  if not dp then return false, "read_drop_position: entity has no drop_position" end
  t.ctx.saved = t.ctx.saved or {}
  t.ctx.saved[step.save_as] = {x = dp.x, y = dp.y}
  return true
end

-- find_existing: ctx.px/py = the placed entity of that name nearest her, for a task that
-- adds to something already built.
function M.run_find_existing(c, t, step)
  local surf = c.entity.surface
  local es = surf.find_entities_filtered{
    name = step.entity, position = c.entity.position, radius = step.radius or 400}
  local best, best_d = nil, math.huge
  for _, e in ipairs(es) do
    if e.valid then
      local d = u.distance(e.position, c.entity.position)
      if d < best_d then best, best_d = e, d end
    end
  end
  if not best then return false, "no existing " .. step.entity .. " found" end
  t.ctx.px, t.ctx.py = best.position.x, best.position.y
  return true
end

-- set_position: sets ctx.px/py from caller-supplied coordinates -- the anchor a build
-- plan's verify_tile and later steps read (commands/build_plan.lua), found by Python.
function M.run_set_position(c, t, step)
  if not (step.x and step.y) then return false, "set_position: x/y required" end
  t.ctx.px, t.ctx.py = step.x, step.y
  return true
end

-- find_patch: ctx.px/py = the nearest tile of the resource that she can walk up to.
function M.run_find_patch(c, t, step)
  local surf = c.entity.surface
  local es = surf.find_entities_filtered{name = step.resource, position = c.entity.position, radius = 400}
  table.sort(es, function(a, b)
    return u.distance(a.position, c.entity.position) < u.distance(b.position, c.entity.position)
  end)
  for _, e in ipairs(es) do
    if e.valid and (e.amount or 1) > 0
       and surf.find_non_colliding_position("character", e.position, WALK_REACH, 0.5) then
      t.ctx.px, t.ctx.py = e.position.x, e.position.y
      return true
    end
  end
  return false, "no reachable " .. step.resource .. " patch found"
end

-- verify_tile: the resource tile at ctx.px/py must still be there.
function M.run_verify_tile(c, t, step)
  local surf = c.entity.surface
  local es = surf.find_entities_filtered{name = step.resource, position = {x = t.ctx.px, y = t.ctx.py}, radius = 1}
  if #es == 0 then return false, "patch tile no longer present" end
  return true
end

return M
