-- Her surplus (factorio-ai, Zdendys 2026-11-09: her stock of every directly handled
-- material is half to one stack, target 70 %). Called by the upkeep's scan
-- (commands/upkeep.lua) every SCAN_TICKS for a companion with upkeep on.
--
-- For each item of ITEMS (raw materials she never needs in hand beyond a build's part --
-- the builds take them from the stores): above KEEP_SHARE of a stack in her inventory
-- (less what open tasks reserved), the surplus down to TARGET_SHARE goes into a store of
-- it -- the nearest plain chest
-- within RADIUS that already holds that item and has room for some, no inserter
-- picking from it (a store, not a fuel chest -- commands/upkeep_feeds.lua picked_from)
-- and not marked the controller's own. One "insert" task per item (MAX_TASKS in all),
-- priority PRIORITY (below every need of the upkeep). Smoke (factorio-ai
-- data/reports/smoke_no_give_up6.log): a stone drill's relocation picked its old chest
-- up with ~480 stone and she carried 610-658 stone for the rest of the run.
-- Not while a build / relocate / dismantle task of hers is ready (upkeep_stock.building:
-- its parts may be what she holds); an open task not being acted on is cancelled then,
-- or when no longer wanted. A failed task holds its chest off FAIL_BACKOFF_TICKS for
-- that item; no store found is logged (once per NOSTORE_LOG_TICKS).
local u = require("commands.init")
local ledger = require("commands.task_pool_ledger")
local F = require("commands.upkeep_feeds")
local Regs = require("commands.upkeep_feed_regs")
local Stock = require("commands.upkeep_stock")

local M = {}

M.ITEMS = {"stone", "iron-ore", "copper-ore"}
M.KEEP_SHARE = 1.0       -- above this share of a stack: a surplus
M.TARGET_SHARE = 0.7     -- what she keeps after a deposit
M.RADIUS = 300           -- the stores looked for within this many tiles of her
M.PRIORITY = 0.5         -- below every upkeep need (their MIN_P and up)
M.MAX_TASKS = 1
local NOSTORE_LOG_TICKS = 18000
-- a search that found no store is not repeated sooner than this
local NOSTORE_RESEARCH_TICKS = 1800
local FAIL_BACKOFF_TICKS = 3600
-- its log books (pruned by the upkeep with its own: commands/upkeep.lua LOG_BOOKS)
M.LOG_BOOKS = {nostore = NOSTORE_LOG_TICKS}

function M.init()
  -- storage.upkeep.surplus = {tasks = {[cid] = {[item] = task_id}}, into = {[cid] =
  --   {[item] = "x,y"}}, backoff = {[cid] = {["x,y|item"] = until_tick}}, search =
  --   {[cid] = {[item] = the tick the next store search may run}}}
  storage.upkeep = storage.upkeep or {}
  local s = storage.upkeep.surplus or {}
  for _, k in ipairs({"tasks", "into", "backoff", "search"}) do s[k] = s[k] or {} end
  storage.upkeep.surplus = s
  return s
end

local function per(t, cid)
  t[cid] = t[cid] or {}
  return t[cid]
end

local function pos_key(e)
  return string.format("%.1f,%.1f", e.position.x, e.position.y)
end

-- The store for `item` nearest her: a plain chest of her force within RADIUS that holds
-- the item already, has room for some, no inserter picks from, not the controller's
-- own and not held off -- or nil.
local function store_for(c, item, off)
  local pos = c.entity.position
  local best, best_d = nil, math.huge
  for _, e in pairs(c.entity.surface.find_entities_filtered{
      type = "container", force = c.entity.force, position = pos, radius = M.RADIUS}) do
    local inv = e.get_inventory(defines.inventory.chest)
    local held = off[pos_key(e) .. "|" .. item]
    if inv and inv.get_item_count(item) > 0 and inv.get_insertable_count(item) > 0
       and not (held and game.tick < held) and not F.picked_from(e) and not Regs.own(e) then
      local d = u.distance(pos, e.position)
      if d < best_d then best, best_d = e, d end
    end
  end
  return best
end

-- Ended tasks forgotten; a failed one holds its chest off for its item (logged).
local function prune(cid, s, mine)
  local into, off = per(s.into, cid), per(s.backoff, cid)
  for item, task_id in pairs(mine) do
    local t = storage.tasks[task_id]
    if not t or t.status ~= "active" then
      if t and t.status == "failed" and into[item] then
        off[into[item] .. "|" .. item] = game.tick + FAIL_BACKOFF_TICKS
        log(string.format("[ai-companion] upkeep surplus: the deposit of %s at %s failed "
                          .. "(%s) -- held off %d ticks", item, into[item], tostring(t.error),
                          FAIL_BACKOFF_TICKS))
      end
      storage.tasks[task_id] = nil
      mine[item] = nil
      into[item] = nil
    end
  end
  for key, until_tick in pairs(off) do
    if game.tick >= until_tick then off[key] = nil end
  end
end

-- The surplus scan of one companion (module header). `acting(task_id)`: whether that
-- task is her current step; `log_once(book, cid, key, every, msg)`: the upkeep's books.
function M.scan(cid, c, acting, log_once)
  local s = M.init()
  local mine, into, off = per(s.tasks, cid), per(s.into, cid), per(s.backoff, cid)
  prune(cid, s, mine)
  local building = Stock.building(cid)
  local inv = c.entity.get_main_inventory()
  local wanted = {}
  if not building then
    local open = 0
    for _ in pairs(mine) do open = open + 1 end
    for _, item in ipairs(M.ITEMS) do
      local stack = prototypes.item[item].stack_size
      -- (what OTHER open tasks reserved is theirs, not a surplus -- the ledger's
      -- storage.reserved less this part's own open task's unused reservation (review:
      -- counting its own, the next scan read no surplus and cancelled it);
      -- docs/mod_upkeep_supply.md C)
      local own = 0
      local t = mine[item] and storage.tasks[mine[item]]
      if t and t.reserved then
        own = (t.reserved[item] or 0) - ((t.consumed and t.consumed[item]) or 0)
      end
      local have = inv.get_item_count(item) - ((storage.reserved or {})[item] or 0) + own
      if have > M.KEEP_SHARE * stack then
        local surplus = have - math.floor(M.TARGET_SHARE * stack)
        wanted[item] = surplus
        local next_search = per(s.search, cid)[item]
        if not mine[item] and open < M.MAX_TASKS
           and not (next_search and game.tick < next_search) then
          local box = store_for(c, item, off)
          if not box then
            -- (the surface search not again before NOSTORE_RESEARCH_TICKS -- review)
            s.search[cid][item] = game.tick + NOSTORE_RESEARCH_TICKS
            log_once("nostore", cid, item, NOSTORE_LOG_TICKS, string.format(
              "upkeep surplus: %d %s on hand (above a stack) and no store of it within "
              .. "%d tiles to put the surplus into", have, item, M.RADIUS))
          else
            local count = math.min(surplus,
                                   box.get_inventory(defines.inventory.chest)
                                      .get_insertable_count(item))
            local r = ledger.submit_task(cid, {{type = "insert", x = box.position.x,
                                                y = box.position.y, entity = box.name,
                                                item = item, count = count}},
                                         "upkeep", M.PRIORITY)
            if r.task_id then
              mine[item] = r.task_id
              into[item] = pos_key(box)
              open = open + 1
            else
              u.log_error("upkeep surplus: submit for " .. item .. " failed: "
                          .. tostring(r.error), "upkeep")
            end
          end
        end
      end
    end
  end
  -- open tasks no longer wanted (the surplus gone, or a build became ready) cancelled
  -- unless being acted on
  for item, task_id in pairs(mine) do
    if not wanted[item] and not acting(task_id) then
      ledger.cancel_task(task_id, building and "upkeep surplus: a build is ready"
                                  or "upkeep surplus: no longer needed")
      storage.tasks[task_id] = nil
      mine[item] = nil
      into[item] = nil
    end
  end
end

-- Whether the companion has surplus task records left (upkeep.tick: cleaned up while
-- off).
function M.has_tasks(cid)
  local s = storage.upkeep and storage.upkeep.surplus
  return s ~= nil and s.tasks[cid] ~= nil and next(s.tasks[cid]) ~= nil
end

-- Upkeep switched off: its open surplus tasks not being acted on cancelled; the record
-- of one being acted on is cleared by a later call once it ended; its back-offs dropped.
function M.stop(cid, acting)
  local s = M.init()
  for item, task_id in pairs(s.tasks[cid] or {}) do
    local t = storage.tasks[task_id]
    if t and t.status == "active" and not acting(task_id) then
      ledger.cancel_task(task_id, "upkeep switched off")
    end
    if not (t and t.status == "active" and acting(task_id)) then
      storage.tasks[task_id] = nil
      s.tasks[cid][item] = nil
      if s.into[cid] then s.into[cid][item] = nil end
    end
  end
  s.backoff[cid] = nil
  s.search[cid] = nil
end

return M
