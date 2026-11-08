-- What a furnace needs fed by hand (the feed upkeep, commands/upkeep_feed.lua -- its
-- module header has the rules; factorio-ai docs/mod_upkeep_supply.md A): its recipe,
-- its input's seconds left and their priority, the reasons it stands out of the feed,
-- the line that feeds it, a wrong item jamming its output.
local u = require("commands.init")
local lines = require("commands.upkeep_lines")
local F = require("commands.upkeep_feeds")
local N = require("commands.upkeep_need")
local Regs = require("commands.upkeep_feed_regs")

local M = {}

M.TARGET_S = 300
M.MIN_BATCH = 5
M.LINE_RECHECK_TICKS = 600        -- a furnace seen fed by a line: judged again after this
M.OUTPUT_STOP_SHARE = 0.5         -- an output this full (of a stack): no feed

function M.pos_key(e)
  return string.format("%.1f,%.1f", e.position.x, e.position.y)
end
local pos_key = M.pos_key

-- Whether `item` is a raw input -- some resource's product (ore, stone, coal): she
-- mines it; the rest (plates) she does not make by hand. Cached per item.
local raw_cache = {}
local function is_raw(item)
  if raw_cache[item] == nil then
    raw_cache[item] = false
    for _, res in pairs(prototypes.get_entity_filtered{{filter = "type", type = "resource"}}) do
      for _, p in pairs((res.mineable_properties and res.mineable_properties.products) or {}) do
        if p.name == item then raw_cache[item] = true end
      end
    end
  end
  return raw_cache[item]
end

-- The recipe a furnace smelts: get_recipe(), else previous_recipe (live 2.1: a furnace
-- that ran keeps it -- {name, quality}), else the controller's registration; nil when
-- unknown; the registration OWN: false.
local function recipe_of(e)
  local reg = Regs.get(e)
  if reg == Regs.OWN then return false end
  local ok, r = pcall(e.get_recipe)
  if not ok then
    u.log_error("upkeep feed: get_recipe of the " .. e.name .. " at " .. pos_key(e)
                .. " failed: " .. tostring(r), "upkeep")
  elseif r then
    return r
  end
  local pr = e.previous_recipe
  local name = nil
  if type(pr) == "table" then
    name = type(pr.name) == "string" and pr.name or (pr.name and pr.name.name)
  elseif type(pr) == "string" then
    name = pr
  end
  name = name or reg
  return name and prototypes.recipe[name] or nil
end

-- The one item ingredient of a furnace recipe and its amount per craft, or nil.
local function input_of(recipe)
  for _, ing in pairs(recipe.ingredients) do
    if ing.type == "item" then return ing.name, ing.amount end
  end
  return nil
end

-- Whether `item` is one of the recipe's products.
local function makes(recipe, item)
  for _, p in pairs(recipe.products) do
    if p.name == item then return true end
  end
  return false
end

-- A wrong item in a furnace's output: name, count -- or nil.
local function wrong_output(e, recipe)
  local inv = e.get_inventory(defines.inventory.crafter_output)
  for _, it in pairs((inv and inv.get_contents()) or {}) do
    if not makes(recipe, it.name) then return it.name, it.count end
  end
  return nil
end

-- Her unreserved count of `item`.
function M.free_of(c, item)
  return c.entity.get_main_inventory().get_item_count(item) - (storage.reserved[item] or 0)
end

-- A furnace recipe's seconds per craft in `e` and its target seconds of input:
-- (secs, target = min(TARGET_S, what a full input stack lasts), stack) for its input
-- `item` taken `amount` per craft; nil when the furnace does not craft (a crafting
-- speed of 0).
local function timing(e, recipe, item, amount)
  local speed = e.crafting_speed or 0
  if speed <= 0 then return nil end
  local secs = recipe.energy / speed
  local stack = prototypes.item[item].stack_size
  return secs, math.min(M.TARGET_S, stack / amount * secs), stack
end

-- The furnace recipe's main item product, or nil.
local function product_of(recipe)
  for _, p in pairs(recipe.products) do
    if p.type == "item" then return p.name end
  end
  return nil
end

-- Whether the furnace `e` stands out of the feed now: a full output, no power, an
-- output nobody takes from (OUTPUT_STOP_SHARE), or without fuel beyond the fuel upkeep's
-- reach of her.
local function idle_by_choice(e, c)
  local s = e.status
  if s == defines.entity_status.full_output or s == defines.entity_status.no_power then
    return true
  end
  if s == defines.entity_status.no_fuel
     and u.distance(c.entity.position, e.position) > N.SCAN_RADIUS then
    return true
  end
  return N.output_fill(e) >= M.OUTPUT_STOP_SHARE
end

-- Whether nobody wants more of the furnace's product: she holds STOCK_TARGET_SHARE of a
-- stack of it unreserved (review: plates a waiting task had reserved counted, and the
-- build that needed more waited for a furnace never fed) and no inserter takes it from
-- the output to a line (review of the smoke: hand feeding one stone furnace by mining
-- its ore takes most of her time -- the controller fed it only while its plates were
-- short of its target; Zdendys: her stock is 0.5-1 stack). Judged only for a furnace
-- running low (the inserter check is an area search).
local function unwanted(e, c, recipe)
  local product = product_of(recipe)
  local proto = product and prototypes.item[product]
  return proto ~= nil
         and M.free_of(c, product) >= N.STOCK_TARGET_SHARE * proto.stack_size
         and not F.picked_from(e)
end

-- A furnace's feed need {key, e, item, p, t, want, raw, line, why} or nil. `b`: the
-- companion's books {down, lines, mine, picks}; `seen`: the keys judged this scan;
-- `c`: the companion (her position, her free stock of a smelted input).
local function feed_need(e, recipe, b, seen, c)
  local item, amount = input_of(recipe)
  if not item then return nil end
  local key = pos_key(e) .. "|" .. item
  seen[key] = true
  local secs, target, stack = timing(e, recipe, item, amount)
  if not secs or idle_by_choice(e, c) then
    -- (an earlier dry mark is stale once it stands out -- review)
    b.down[key] = nil
    return nil
  end
  local inv = e.get_inventory(defines.inventory.crafter_input)
  if not inv then return nil end
  local held = inv.get_item_count(item)
  local t = held / amount * secs
  local p = math.log(target / math.max(1, t), 2)
  p = 1 + (p - 1) * (1 - 0.9 * N.output_fill(e))
  if p <= 1 or unwanted(e, c, recipe) then
    -- (well stocked, or nobody wants more: an earlier dry mark is stale -- review: a
    -- much later single dry scan counted as two in a row)
    b.down[key] = nil
    return nil
  end
  local seen_line = b.lines[key]
  if seen_line and game.tick - seen_line < M.LINE_RECHECK_TICKS then return nil end
  b.lines[key] = nil
  local line, why = lines.input_line(e, item, b.picks)
  if line == "line" then
    b.down[key] = nil
    b.lines[key] = game.tick
    return nil
  elseif line == "dry" then
    b.down[key] = b.down[key] or game.tick
    -- (two scans in a row delivering nothing, and its input running low)
    if b.down[key] == game.tick or t >= N.LINE_DRY_S then return nil end
  else
    b.down[key] = nil
  end
  local raw = is_raw(item)
  local want = math.min(stack - held,
                        math.max(M.MIN_BATCH, math.ceil(target / secs * amount) - held))
  if not raw and not b.mine[key] then
    local keep = math.floor(N.STOCK_LOW_SHARE * stack)
    want = math.min(want, M.free_of(c, item) - keep)
    if want < M.MIN_BATCH then return nil end
  end
  if want < 1 then return nil end
  return {key = key, e = e, item = item, p = p, t = t, want = want, raw = raw,
          line = line, why = why and table.concat(why, " ") or ""}
end

-- The furnace `e`'s need: a clear of a wrong output item, a feed, or nil. Registers the
-- furnace in `unknown` when it cannot tell what it smelts, in `owned` when the
-- controller loads it itself. `inv`: her main inventory.
function M.need_of(e, b, seen, c, inv, unknown, owned)
  local recipe = recipe_of(e)
  if recipe == nil then
    unknown[pos_key(e)] = game.tick
    return nil
  end
  if not recipe then
    owned[pos_key(e)] = true
    return nil
  end
  local bad, n = wrong_output(e, recipe)
  if bad then
    local key = pos_key(e) .. "|clear"
    local item, amount = input_of(recipe)
    seen[key] = true
    -- (its feed key stays judged too: its back-off and its marks are kept -- review)
    if item then seen[pos_key(e) .. "|" .. item] = true end
    if inv.get_insertable_count(bad) < 1 then return nil end
    local _, target = timing(e, recipe, item or bad, amount or 1)
    if not target then return nil end
    return {key = key, e = e, item = bad, p = math.log(target, 2), want = n, clear = true}
  end
  return feed_need(e, recipe, b, seen, c)
end

return M
