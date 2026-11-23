-- Her hand crafting after "automation" (factorio-ai game rules 6, 68, 69; docs/
-- production_for_every_item.md, "Hand-craft policy after automation").
--
-- Why: from "automation" on every item comes from its production's stores; hand crafting
-- is cut down as far as it goes, and Python must KNOW where a production falls short
-- (Zdendys: "mod mu rekne, kdyz si musel stavet neco v ruce, protoze je vyroba slaba").
--
-- What:
-- - limited(force): hand crafting is limited once "automation" is researched;
-- - reason(force, item, under): why a hand craft of `item` (made for `under`, the root
--   item of the craft chain) is no shortfall -- "before" (automation not researched),
--   "exempt" (a lab; a stone furnace until advanced-material-processing), "exempt_all"
--   (everything while Python says the first productions do not stand yet:
--   /fac_craft_exempt) -- or nil: the craft makes up a production's shortfall;
-- - note(item, pieces, why): a hand craft booked -- a shortfall (why nil, logged
--   [HAND_SHORT], at most once per LOG_TICKS per item) or a far one ("far": the store
--   holding it lay beyond FAR_DIST and she needed at most FAR_MAX pieces -- the walk
--   costs more than the craft); kept per item as the pieces so far and the tick of the
--   last (and of the last log line), for /fac_upkeep's status (status());
-- - is_far(deficit, dist): whether a shortfall that small is crafted rather than
--   fetched from a place that far.
local u = require("commands.init")

local M = {}

M.FAR_MAX = 5        -- pieces: a shortfall this small ...
M.FAR_DIST = 50      -- tiles: ... whose nearest store lies farther is crafted on the spot
M.LOG_TICKS = 3600   -- a shortfall of an item logged at most this often
-- the technology from which on no stone furnace is made by hand any more
local FASTER_FURNACES = "advanced-material-processing"
-- always hand-made after automation (game rule 69: an assembler for them does not pay)
local ALWAYS_EXEMPT = {lab = true}

-- storage.hand_policy = {exempt_all = bool, short = {[item] = {pieces, tick,
--   logged_tick, logged_pieces}}, far = {[item] = {pieces, tick}}}; created on first use
--   (older saves have none; an entry without the logged fields logs at its next craft)
local function book()
  storage.hand_policy = storage.hand_policy or {}
  local b = storage.hand_policy
  b.short = b.short or {}
  b.far = b.far or {}
  return b
end

local function researched(force, tech)
  local t = force.technologies[tech]
  return t ~= nil and t.researched
end

-- Whether her hand crafting is limited (module header).
function M.limited(force)
  return researched(force, "automation")
end

local function exempt(force, item)
  if not item then return false end
  if ALWAYS_EXEMPT[item] then return true end
  return item == "stone-furnace" and not researched(force, FASTER_FURNACES)
end

-- Why a hand craft of `item` made for `under` is no shortfall, or nil (module header).
function M.reason(force, item, under)
  if not M.limited(force) then return "before" end
  if exempt(force, item) or exempt(force, under) then return "exempt" end
  if storage.hand_policy and storage.hand_policy.exempt_all then return "exempt_all" end
  return nil
end

-- Whether a shortfall of `deficit` pieces is crafted rather than fetched from a place
-- `dist` tiles away (module header).
function M.is_far(deficit, dist)
  return deficit <= M.FAR_MAX and dist > M.FAR_DIST
end

-- A hand craft of `pieces` of `item` booked (module header): why nil -- a shortfall,
-- "far" -- a far one; any other why books nothing.
function M.note(item, pieces, why)
  if not item or (pieces or 0) < 1 or (why ~= nil and why ~= "far") then return end
  local b = book()
  local shelf = why == "far" and b.far or b.short
  local e = shelf[item] or {pieces = 0}
  e.pieces = e.pieces + pieces
  e.tick = game.tick
  shelf[item] = e
  if why == nil then
    -- (one line per item per LOG_TICKS with the pieces since the last -- each craft its
    -- own line flooded the log)
    local last = e.logged_tick
    if last == nil or game.tick - last >= M.LOG_TICKS then
      log("[ai-companion] [HAND_SHORT] " .. (e.pieces - (e.logged_pieces or 0)) .. " "
          .. item .. " made by hand: no store held it -- its production is short or "
          .. "missing (" .. e.pieces .. " so far)")
      e.logged_tick, e.logged_pieces = game.tick, e.pieces
    end
  end
end

-- The policy for the /fac_upkeep status: {limited, exempt_all, short, far} (the books
-- as in book(): the pieces so far per item and the tick of the last).
function M.status(force)
  local b = book()
  return {limited = M.limited(force), exempt_all = b.exempt_all or false,
          short = b.short, far = b.far}
end

-- /fac_craft_exempt <all|none>: whether every hand craft counts as exempt (Python: the
-- first productions -- the mall row -- do not stand yet). Replies {exempt_all}.
commands.add_command("fac_craft_exempt", nil, function(cmd)
  u.safe_command(function()
    local word = cmd.parameter
    if word ~= "all" and word ~= "none" then
      u.json_response({error = "usage: /fac_craft_exempt all|none"}); return
    end
    local b = book()
    b.exempt_all = word == "all"
    u.json_response({exempt_all = b.exempt_all})
  end)
end)

return M
