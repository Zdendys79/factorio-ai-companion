-- The fuel chests she supplies (the fuel upkeep, commands/upkeep.lua; Zdendys
-- 2026-11-09, factorio-ai docs/architecture_roles.md Decided 5: a supply chest is the
-- burners' inventory extended, kept at 4 stacks): a book per companion, the chests found
-- through their burners (upkeep.lua's scan: a burner's nearest fuel chest), each judged
-- at every scan while within the scan's radius (review: one judged only through a
-- burner passing the scan's gate had its task cancelled whenever its burners stood idle
-- or full) -- one need for all the burners it feeds (upkeep_need.chest_need).
local u = require("commands.init")
local F = require("commands.upkeep_feeds")
local N = require("commands.upkeep_need")

local M = {}

local function key_of(e)
  return string.format("%.1f,%.1f", e.position.x, e.position.y)
end

-- The companion's book: {[chest key] = {chest, burners = the burners it feeds, tick =
-- when they were read}} (storage.upkeep.chests[cid]).
function M.book(cid)
  storage.upkeep.chests = storage.upkeep.chests or {}
  storage.upkeep.chests[cid] = storage.upkeep.chests[cid] or {}
  return storage.upkeep.chests[cid]
end

-- The chest in the book (a new entity at the key starts afresh).
function M.remember(book, chest)
  local ck = key_of(chest)
  if not book[ck] or book[ck].chest ~= chest then book[ck] = {chest = chest} end
end

-- Each chest of the book judged (ctx: {pos = her position, radius = the scan's,
-- recheck = ticks after which its burners are read again, fuel, wood = the fuels whose
-- room makes it fillable, target_s, fill = the filling marks by key, is_off(e), add(need,
-- e)}): one need for all the burners it feeds (review: the whole chest's burners, not
-- only those under the scan's cheap check) -- their list read again after `recheck`
-- (review: area searches per chest at every scan); a burner idle for want of
-- ingredients counts (the chest is its buffer -- review: the chest's task was cancelled
-- at every gap in its ore), a mined-out drill does not; a chest out of the radius, gone
-- or feeding nothing that burns is forgotten; a chest with no room for coal or wood is
-- full of fuel -- no need (review: serving its burners by hand then went to burners
-- whose chest supplies them). A chest's filling mark is dropped once it needs nothing.
function M.judge(book, ctx)
  for ck, rec in pairs(book) do
    local chest = rec.chest
    if not (chest and chest.valid) or u.distance(ctx.pos, chest.position) > ctx.radius then
      book[ck] = nil
    else
      if not rec.tick or game.tick - rec.tick >= ctx.recheck then
        rec.burners, rec.tick = F.chest_burners(chest), game.tick
      end
      local g = {chest = chest, usage = 0, energy = 0, fill = 1}
      for _, b in ipairs(rec.burners) do
        local _, _, usage, energy
        if b.valid and b.status ~= defines.entity_status.no_minable_resources then
          _, _, usage, energy = N.fuel_seconds(b, ctx.fuel)
        end
        if usage then
          g.usage, g.energy = g.usage + usage, g.energy + energy
          g.fill = math.min(g.fill, N.output_fill(b))
        end
      end
      local inv = chest.get_inventory(defines.inventory.chest)
      if g.usage <= 0 then
        book[ck] = nil
      elseif inv and (inv.get_insertable_count(ctx.fuel) > 0
                      or inv.get_insertable_count(ctx.wood) > 0)
             and not ctx.is_off(chest) then
        local need = N.chest_need(g, ctx.target_s, ctx.fuel, ctx.fill[ck] ~= nil)
        if not need then ctx.fill[ck] = nil end
        ctx.add(need, chest)
      end
    end
  end
end

return M
