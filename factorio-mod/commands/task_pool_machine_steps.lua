-- AI Companion -- the task pool's machine steps: loading a machine or a chest ("fill")
-- and taking out of one ("take_out"), the mod walking there (task_pool.lua's acting
-- state, a hand step within her reach). Their result is the step's result
-- (fac_task_status step_results). factorio-ai: CompanionAPI.fill / fill_many /
-- collect / collect_many.

local targeting = require("commands.task_pool_targeting")
local ledger = require("commands.task_pool_ledger")
local machine_fill = require("commands.machine_fill")
local machine_empty = require("commands.machine_empty")

local M = {}

-- a lane of one straight belt tile holds 4 items; full at a belt's last tile means backed up
M.BELT_FULL_LANE = 4

-- Whether `b` is a belt's last tile: a transport belt with no belt after it.
function M.belt_end(b)
  return b.type == "transport-belt" and #b.belt_neighbours.outputs == 0
end

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
-- Not a need of the task (derive_needs): it loads what she holds FREE, up to N -- what
-- she holds less what other tasks reserved (ledger.free_count, as the fuel and insert
-- steps since 0.16.173 -- factorio-ai STATUS item 8h: a fill took another task's
-- reserved items). Result {inserted, item, into}.
-- @return boolean ok, string|nil err, table|nil result
function M.run_fill(c, t, step)
  local pos, item, count, err = resolve(t, step)
  if err then return false, err end
  local raw = c.entity.get_main_inventory().get_item_count(item)
  local have, others = ledger.free_count(t, item, raw)
  if raw > 0 and have <= 0 then
    return false, string.format("fill: no %s free in inventory (%d held, %d reserved by "
                                .. "other tasks)", item, raw, others)
  end
  local r = machine_fill.fill(c, pos, item, math.min(count, math.max(have, 0)))
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

-- {type="take_belt", x=, y=, item=NAME, count=N}: up to N of the item taken off the belts
-- at (x, y) and next to it (within 1.5 tiles), lane by lane, into her inventory -- a
-- player's pick-up off a belt (factorio-ai: her stock taken from a belt nearer than any
-- furnace or store). Only off a belt's LAST tile (no belt after it: what reaches it passed
-- every consumer upstream) and only a lane full of the item there (BELT_FULL_LANE: it stands
-- backed up) -- a production fed by the belt keeps priority (factorio-ai game rule 11
-- answer 2). Never more than her inventory takes; taking none fails the step (the
-- upkeep's back-off). Result {extracted, item}.
-- @return boolean ok, string|nil err, table|nil result
function M.run_take_belt(c, t, step)
  local pos, item, count, err = resolve(t, step)
  if err then return false, err end
  local inv = c.entity.get_main_inventory()
  local left = math.min(count, inv.get_insertable_count(item))
  local got = 0
  local belts = {}
  for _, b in pairs(c.entity.surface.find_entities_filtered{
      type = "transport-belt", position = pos, radius = 1.5, force = c.entity.force}) do
    if M.belt_end(b) then belts[#belts + 1] = b end
  end
  table.sort(belts, function(a, b)
    return (a.position.x - pos.x) ^ 2 + (a.position.y - pos.y) ^ 2
         < (b.position.x - pos.x) ^ 2 + (b.position.y - pos.y) ^ 2 end)
  for _, b in ipairs(belts) do
    for i = 1, b.get_max_transport_line_index() do
      if left < 1 then break end
      local line = b.get_transport_line(i)
      local n = 0
      if line.get_item_count(item) >= M.BELT_FULL_LANE then
        n = line.remove_item{name = item, count = left}
      end
      if n > 0 then
        local put = inv.insert{name = item, count = n}
        if put < n then
          c.entity.surface.spill_item_stack{position = c.entity.position,
                                            stack = {name = item, count = n - put}}
        end
        got, left = got + n, left - n
      end
    end
  end
  if got < 1 then
    return false, "take_belt: no belt end with a full lane of " .. item .. " there (nothing taken)"
  end
  return true, nil, {extracted = got, item = item}
end

return M
