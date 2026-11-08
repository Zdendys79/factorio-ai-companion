-- The controller's word on its furnaces, for the feed and stock upkeep
-- (commands/upkeep_feed.lua, upkeep_stock.lua; factorio-ai docs/mod_upkeep_supply.md A):
-- /fac_upkeep_feed <id> <x> <y> <recipe | own | loading | release> --
-- - a recipe: what a fresh hand-fed furnace smelts (until the furnace knows it itself);
-- - "own": the controller loads it itself for good (the feed and stock upkeep neither
--   feed it nor take from it; the fuel upkeep still fuels it);
-- - "loading": the controller loads it for a while (a loop of its own) -- as "own" on top
--   of what was registered, until "release"; a companion's "loading" marks are dropped
--   when her upkeep is switched on or off (review: a run killed inside the loop, or a
--   hand-back that failed, left the furnace "own" in the save for good -- fed by nobody;
--   and per companion: another one's switch does not free a loop's furnaces).
-- Kept by the furnace's unit number with its surface: a furnace replaced at the spot
-- does not inherit it, and a visit to another surface keeps it. One word for every
-- companion (review: an "own" made through one companion did not hold for another's
-- upkeep). Dropped with the furnace (its surface's feed scan).
local u = require("commands.init")

local M = {}

M.OWN = "own"
M.LOADING = "loading"
M.RELEASE = "release"

function M.init()
  -- storage.upkeep.feed_regs = {[unit number] = {recipe = name or OWN or nil, loading =
  --   {[cid] = true} or nil (the companions whose controller loop loads it), surface =
  --   index, at = "x,y"}}
  storage.upkeep = storage.upkeep or {}
  storage.upkeep.feed_regs = storage.upkeep.feed_regs or {}
  return storage.upkeep.feed_regs
end

local function pos_key(e)
  return string.format("%.1f,%.1f", e.position.x, e.position.y)
end

local function reg_entry(e)
  local regs = storage.upkeep and storage.upkeep.feed_regs
  return regs and e.unit_number and regs[e.unit_number] or nil
end

-- The registration of the furnace `e`: OWN while it is loading, else its recipe name,
-- OWN, or nil.
function M.get(e)
  local reg = reg_entry(e)
  if not reg then return nil end
  if type(reg.loading) == "table" and next(reg.loading) then return M.OWN end
  return reg.recipe
end

-- Whether the controller registered a recipe (or OWN) for the furnace `e` -- its word
-- for good, not a loop's "loading" alone.
function M.registered(e)
  local reg = reg_entry(e)
  return reg ~= nil and reg.recipe ~= nil
end

-- Whether the controller marked the furnace `e` its own (for good, or loading).
function M.own(e)
  return M.get(e) == M.OWN
end

-- The one item ingredient of a recipe, or nil.
local function item_input(recipe)
  for _, ing in pairs(recipe.ingredients) do
    if ing.type == "item" then return ing.name end
  end
  return nil
end

-- Whether `recipe` is one the furnace `e` smelts: an item ingredient, a crafting
-- category of the furnace (2.1: LuaRecipePrototype.categories, an array of names; the
-- entity prototype's crafting_categories a {name = true} dictionary).
local function smeltable(e, recipe)
  if not item_input(recipe) then return false end
  local cats = e.prototype.crafting_categories or {}
  for _, cat in pairs(recipe.categories or {}) do
    if cats[cat] then return true end
  end
  return false
end

local WORDS = {[M.OWN] = true, [M.LOADING] = true, [M.RELEASE] = true}

-- Register the furnace at (x, y) -- the nearest of her force within 1 tile, by its own
-- position (a tile centre given for a 2x2 furnace matches) -- with `word`: a recipe it
-- smelts, OWN, LOADING or RELEASE (module header; LOADING / RELEASE for the companion
-- `cid`). A recipe the furnace cannot smelt is refused.
-- @return table {registered = true, at} or {error}
function M.register(c, x, y, word, cid)
  local proto = not WORDS[word] and prototypes.recipe[word]
  if not WORDS[word] and not proto then
    return {error = "unknown recipe " .. word}
  end
  local best, bd = nil, math.huge
  for _, e in pairs(c.entity.surface.find_entities_filtered{type = "furnace",
                                                            position = {x, y}, radius = 1,
                                                            force = c.entity.force}) do
    local d = u.distance(e.position, {x = x, y = y})
    if d < bd then best, bd = e, d end
  end
  if not best then return {error = string.format("no furnace at %.1f,%.1f", x, y)} end
  if proto and not smeltable(best, proto) then
    return {error = "the " .. best.name .. " at " .. pos_key(best) .. " does not smelt "
                    .. word}
  end
  if not best.unit_number then
    return {error = "the " .. best.name .. " at " .. pos_key(best) .. " has no unit number"}
  end
  local regs = M.init()
  local reg = regs[best.unit_number] or {surface = best.surface.index, at = pos_key(best)}
  if type(reg.loading) ~= "table" then reg.loading = nil end
  if word == M.LOADING then
    reg.loading = reg.loading or {}
    reg.loading[cid] = true
  elseif word == M.RELEASE then
    if reg.loading then reg.loading[cid] = nil end
    if reg.loading and not next(reg.loading) then reg.loading = nil end
  else
    reg.recipe = word
  end
  regs[best.unit_number] = (reg.recipe or reg.loading) and reg or nil
  return {registered = true, at = pos_key(best)}
end

-- The companion `cid`'s "loading" marks dropped (her upkeep switched on or off: no loop
-- of the controller's outlives its run); an entry left with nothing goes.
function M.drop_loading(cid)
  local regs = M.init()
  for unit, reg in pairs(regs) do
    if type(reg) == "table" then
      if type(reg.loading) == "table" then reg.loading[cid] = nil end
      if type(reg.loading) ~= "table" or not next(reg.loading) then reg.loading = nil end
    end
    if type(reg) ~= "table" or (reg.recipe == nil and reg.loading == nil) then
      regs[unit] = nil
    end
  end
end

-- Drop the registrations of furnaces gone from `surface_index`: `present` holds the
-- unit numbers its scan saw.
function M.prune(surface_index, present)
  local regs = M.init()
  for unit, reg in pairs(regs) do
    if type(reg) ~= "table" or (reg.recipe == nil and reg.loading == nil)
       or (reg.surface == surface_index and not present[unit]) then
      regs[unit] = nil
    end
  end
end

return M
