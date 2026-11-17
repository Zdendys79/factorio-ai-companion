-- AI Companion -- belt runs in a build plan (factorio-ai docs/belt_planning.md step
-- 1b): build_plan.lua's expand turns a run of two or more belt pieces, each following
-- the last, into one "lay" step (task_pool_lay.lua lays it as she walks along). Pure
-- data -- no requires, so build_plan.lua (required by task_pool_ledger.lua) can use it
-- without a require loop.

local M = {}

local BELT_TYPES = {["transport-belt"] = true, ["underground-belt"] = true}

-- Whether `p` is a belt piece a lay can carry (no role, recipe, filter or mirror).
local function belt_piece(p)
  local proto = prototypes.entity[p.entity]
  return proto and BELT_TYPES[proto.type] and not p.role and not p.recipe
    and not p.filter and not p.mirror
end

-- Whether `b` follows `a` in one run: the next tile (adjacent), or the exit paired with
-- an underground entrance on its line within the prototype's max distance.
local function follows(a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  if math.abs(dx) + math.abs(dy) == 1 then return true end
  if a.ug ~= "input" or b.ug ~= "output" or a.entity ~= b.entity then return false end
  if dx ~= 0 and dy ~= 0 then return false end
  -- (max_underground_distance: the entrance-to-exit span -- 5 for the yellow tier, as
  -- queues_belt.lua's UNDERGROUND_MAX_DISTANCE)
  local max = prototypes.entity[a.entity].max_underground_distance or 0
  return math.abs(dx) + math.abs(dy) <= max
end

-- The plan's pieces grouped: a run of two or more belt pieces, each following the
-- last, becomes one lay step; every other piece stays a place step (build_plan.lua's
-- expand calls this). Returns a list of {lay = {pieces}} or {piece = p}, in order.
function M.group(pieces)
  local out, run = {}, nil
  local function flush()
    if not run then return end
    if #run >= 2 then
      out[#out + 1] = {lay = run}
    else
      out[#out + 1] = {piece = run[1]}
    end
    run = nil
  end
  for _, p in ipairs(pieces) do
    if belt_piece(p) and run and follows(run[#run], p) then
      run[#run + 1] = p
    else
      flush()
      if belt_piece(p) then run = {p} else out[#out + 1] = {piece = p} end
    end
  end
  flush()
  return out
end

return M
