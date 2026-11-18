-- Chest roles (factorio-ai docs/stores_and_buffers.md, stage 1a; Zdendys: a store chest
-- at each production, a buffer chest at a consumer filled by hand, a surplus chest at a
-- belt's start, a central store for items with no consumer).
--
-- storage.chest_roles[unit_number] = {entity, role, item}: role one of ROLES, item the
-- item it is for. A chest with a role is judged by it, not by the inserters round it:
--   store, central -- give everything (even with an inserter taking from it to a belt:
--     the old rule read such a chest as giving nothing) and are stores;
--   buffer -- belongs to its consumer: gives nothing (a fuel chest, the plastic plant's
--     coal chest -- review: her coal fetches drained them; once her surplus routing fills
--     buffers, stage 2, what lies above BUFFER_KEEP may be given), and is no store;
--   surplus -- a belt's, at its start: gives nothing (what is in it goes onto the belt
--     first -- a plate row's head coal chest), and is no store.
-- An entry goes with its chest (script.register_on_object_destroyed -> M.on_destroyed);
-- a read of an entry whose entity is gone drops it too.
--
-- /fac_chest_role <x> <y> <role|none> [item] -- set (or clear) the role of the chest at
--   (x, y) -> {role, item, unit} or {error}
-- /fac_chests -- {chests = [{x, y, role, item, name, count}]}
local u = require("commands.init")

local M = {}

M.ROLES = {store = true, buffer = true, surplus = true, central = true}
M.GIVING = {store = true, central = true}

local function book()
  storage.chest_roles = storage.chest_roles or {}     -- (lazily: no init without a version change)
  return storage.chest_roles
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
  return r
end

-- Set `chest`'s role (`role` nil clears it). Returns the entry or nil, error.
function M.set(chest, role, item)
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
  roles[chest.unit_number] = {entity = chest, role = role, item = item}
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
  if M.GIVING[r.role] then return n end
  return 0                                       -- (a buffer, a surplus chest)
end

-- Whether `chest` is a store of `item` by its role (true / false), or nil when it has
-- no role for that item.
function M.store(chest, item)
  local r = M.get(chest)
  if not r or r.item ~= item then return nil end
  return M.GIVING[r.role] == true
end

commands.add_command("fac_chest_role", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)%s+(%S+)%s*(%S*)$",
                              cmd.parameter)
    local x, y, role = tonumber(args[1]), tonumber(args[2]), args[3]
    local item = args[4] ~= "" and args[4] or nil
    local chest
    for _, e in pairs(game.surfaces[1].find_entities_filtered{
        position = {x, y}, radius = 0.5, type = {"container", "logistic-container"}}) do
      if not chest or u.distance(e.position, {x = x, y = y})
                      < u.distance(chest.position, {x = x, y = y}) then
        chest = e
      end
    end
    if not chest then u.json_response({error = "no chest at " .. x .. "," .. y}); return end
    local r, err = M.set(chest, role ~= "none" and role or nil, item)
    if err then u.json_response({error = err}); return end
    u.json_response({role = r and r.role or "none", item = r and r.item, unit = chest.unit_number})
  end)
end)

commands.add_command("fac_chests", nil, function(_cmd)
  u.safe_command(function()
    local out = {}
    for unit, r in pairs(book()) do
      if r.entity and r.entity.valid then
        out[#out + 1] = {x = r.entity.position.x, y = r.entity.position.y, role = r.role,
                         item = r.item, name = r.entity.name,
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
