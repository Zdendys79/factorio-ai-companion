-- Chest roles (factorio-ai docs/stores_and_buffers.md). Zdendys knows only TWO chest
-- kinds:
--   store   -- the "vyrovnavaci bedna": ONE per material, at its production (its machine
--              outputs into it); everyone may take from it;
--   surplus -- the "prebytkova bedna": the helpers put their surplus into it; several,
--              placed where its consumption is assured -- `at`:
--                "consumer" -- joined by an inserter into a consumer (a fuel chest, the
--                              plastic plant's coal chest): the consumer's;
--                "belt"     -- at a belt's start, its inserter putting onto the belt
--                              first (a plate row's head coal chest): the belt's;
--                "central"  -- in the central store near the map centre, for an item
--                              with no consumer: nobody's, so it may be taken from.
--
-- storage.chest_roles[unit_number] = {entity, role, item, at}. A chest with a role is
-- judged by it for its item (another item by the old rule), not by the inserters round
-- it: a store and a central surplus chest give everything (even with an inserter taking
-- from them -- the old rule read such a chest as giving nothing) and are stores; a
-- consumer's or a belt's surplus chest gives nothing (review: her coal fetches drained
-- the fuel chests) and is no store. An entry goes with its chest
-- (script.register_on_object_destroyed -> M.on_destroyed); a read of an entry whose
-- entity is gone drops it too.
--
-- /fac_chest_role <x> <y> <store|surplus|none> [item] [at] -- set (or clear) the role of
--   the chest at (x, y) -> {role, item, at, unit} or {error}
-- /fac_chests -- {count, chests = [{x, y, role, item, at, name, count}]}
local u = require("commands.init")

local M = {}

M.ROLES = {store = true, surplus = true}
M.BUFFER_SLOTS = 2          -- the slots of a store (buffer) chest: 2 stacks (game rule 74)
-- The materials building takes in quantity, and coal: their stores are not limited (game
-- rule 74, Zdendys: plates, gears, cables -- "all materials needed in quantity when
-- building"; coal added by him).
M.BULK = {["iron-plate"] = true, ["copper-plate"] = true, ["steel-plate"] = true,
          ["stone-brick"] = true, ["iron-gear-wheel"] = true, ["copper-cable"] = true,
          ["electronic-circuit"] = true, ["pipe"] = true, ["coal"] = true}
M.AT = {consumer = true, belt = true, central = true}

local function book()
  storage.chest_roles = storage.chest_roles or {}     -- (lazily: no init without a version change)
  return storage.chest_roles
end

-- An entry saved by 0.16.214/0.16.215 (roles buffer, central, surplus without a place)
-- converted to the two kinds in place (review: a relocation copying an old role made
-- the mod refuse its whole plan).
local OLD = {buffer = "consumer", central = "central"}
local function upgrade(r)
  if OLD[r.role] then
    r.at, r.role = OLD[r.role], "surplus"
  elseif r.role == "surplus" and not r.at then
    r.at = "belt"
  end
end

-- The role entry of `chest`, or nil.
function M.get(chest)
  if not (chest and chest.valid and chest.unit_number) then return nil end
  local roles = book()
  local r = roles[chest.unit_number]
  if r and not (r.entity and r.entity.valid) then
    roles[chest.unit_number] = nil
    return nil
  end
  if r then upgrade(r) end
  return r
end

-- Whether a role entry gives what it holds (a store, a central surplus chest).
local function giving(r)
  return r.role == "store" or (r.role == "surplus" and r.at == "central")
end

-- The bar of a store chest of `item`: a store is a BUFFER between a production and its
-- consumption (Zdendys: furnace > chest > belt, where she takes what her production needs),
-- not a warehouse -- its slots limited (BUFFER_SLOTS), so a surplus nobody consumes backs the
-- production up (a signal) instead of piling up tons; a bulk material's store (BULK) has no
-- limit (a bar an earlier rule left is lifted).
function M.store_bar(chest, item)
  local inv = chest.get_inventory(defines.inventory.chest)
  if not inv then return end
  if M.BULK[item] then inv.set_bar()
  elseif #inv > M.BUFFER_SLOTS then inv.set_bar(M.BUFFER_SLOTS + 1) end
end

-- on_configuration_changed: every store's bar set again by the current rule (a save made
-- with an older mod keeps the bars of its rule otherwise).
function M.reapply_store_bars()
  for unit, r in pairs(storage.chest_roles or {}) do
    if r.entity and r.entity.valid then
      if r.role == "store" then M.store_bar(r.entity, r.item) end
    else
      storage.chest_roles[unit] = nil
    end
  end
end

-- Set `chest`'s role (`role` nil clears it); `at` for a surplus chest. Returns the entry
-- or nil, error.
function M.set(chest, role, item, at)
  if not (chest and chest.valid and chest.unit_number) then return nil, "no chest" end
  if chest.type ~= "container" and chest.type ~= "logistic-container" then
    return nil, "not a chest: " .. chest.name
  end
  local roles = book()
  if role == nil then
    roles[chest.unit_number] = nil
    return nil
  end
  if not M.ROLES[role] then return nil, "unknown role: " .. tostring(role) end
  if not (item and prototypes.item[item]) then return nil, "unknown item: " .. tostring(item) end
  if role == "surplus" and not M.AT[at] then
    return nil, "a surplus chest needs at = consumer | belt | central, not " .. tostring(at)
  end
  roles[chest.unit_number] = {entity = chest, role = role, item = item,
                              at = role == "surplus" and at or nil}
  if role == "store" then M.store_bar(chest, item) end
  script.register_on_object_destroyed(chest)
  return roles[chest.unit_number]
end

-- on_object_destroyed: a registered chest gone -- its role goes with it.
function M.on_destroyed(ev)
  -- (registrations are global across mods and useful_id is per object type: only an
  -- entity's is a unit number -- review)
  if storage.chest_roles and ev.useful_id and ev.type == defines.target_type.entity then
    storage.chest_roles[ev.useful_id] = nil
  end
end

-- What `chest` gives of `item` by its role, or nil when it has no role for that item
-- (the caller's own rule then -- a store of iron plates holding coal is judged for the
-- coal by the old rule).
function M.share(chest, item, n)
  local r = M.get(chest)
  if not r or r.item ~= item then return nil end
  return giving(r) and n or 0
end

-- Whether `chest` is a store of `item` by its role (true / false), or nil when it has
-- no role for that item.
function M.store(chest, item)
  local r = M.get(chest)
  if not r or r.item ~= item then return nil end
  return giving(r)
end

-- The rank of `chest` as a target for her surplus of `item` (1 its store, 2 a
-- consumer's or a belt's surplus chest of it, 3 a central one), or nil: no role for it.
function M.target_rank(chest, item)
  local r = M.get(chest)
  if not r or r.item ~= item then return nil end
  if r.role == "store" then return 1 end
  return r.at == "central" and 3 or 2
end

commands.add_command("fac_chest_role", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)%s+(%S+)%s*(%S*)%s*(%S*)$",
                              cmd.parameter)
    local x, y, role = tonumber(args[1]), tonumber(args[2]), args[3]
    local item = args[4] ~= "" and args[4] or nil
    local at = args[5] ~= "" and args[5] or nil
    local chest
    for _, e in pairs(game.surfaces[1].find_entities_filtered{
        position = {x, y}, radius = 0.5, type = {"container", "logistic-container"}}) do
      if not chest or u.distance(e.position, {x = x, y = y})
                      < u.distance(chest.position, {x = x, y = y}) then
        chest = e
      end
    end
    if not chest then u.json_response({error = "no chest at " .. x .. "," .. y}); return end
    local r, err = M.set(chest, role ~= "none" and role or nil, item, at)
    if err then u.json_response({error = err}); return end
    u.json_response({role = r and r.role or "none", item = r and r.item, at = r and r.at,
                     unit = chest.unit_number})
  end)
end)

commands.add_command("fac_chests", nil, function(_cmd)
  u.safe_command(function()
    local out = {}
    for unit, r in pairs(book()) do
      if r.entity and r.entity.valid then
        upgrade(r)
        out[#out + 1] = {x = r.entity.position.x, y = r.entity.position.y, role = r.role,
                         item = r.item, at = r.at, name = r.entity.name,
                         count = r.entity.get_item_count(r.item)}
      else
        storage.chest_roles[unit] = nil
      end
    end
    -- (count too: an empty list encodes as {} -- review)
    u.json_response({count = #out, chests = out})
  end)
end)

return M
