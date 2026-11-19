-- Her surplus (factorio-ai docs/stores_and_buffers.md; Zdendys: her stock of every
-- directly handled material is half to one stack, target 70 %; hand crafting needs no
-- huge stocks). Called by the upkeep's scan (commands/upkeep.lua) every SCAN_TICKS for a
-- companion with upkeep on.
--
-- Every item she holds but coal and wood (the upkeep's own fuels) and her stock items
-- (upkeep_stock: plates, steel, bricks -- their band; Python holds them for its next
-- craft or build): above KEEP_SHARE of a stack (a placeable item: PLACEABLE_KEEP stacks)
-- in her inventory, less what open tasks reserved, the surplus down to TARGET_SHARE of a
-- stack below that keep goes -- by chest role, Zdendys's two kinds (chest_roles.lua) --
-- into the item's store while it has room; only with every store of it full (or none)
-- into a surplus chest of it at a consumer or a belt's start, else a central one; the
-- nearest within RADIUS in each rank; never a chest without a role, nor one marked the
-- controller's own. With none of them a job-end event {kind "surplus", id "<cid>:<item>"}
-- asks Python for a surplus chest (logged once per NOSTORE_LOG_TICKS). One "insert"
-- task per item (MAX_TASKS in all), priority PRIORITY (below every need of the upkeep).
-- Smoke (factorio-ai data/reports/smoke_no_give_up6.log): a stone drill's relocation
-- picked its old chest up with ~480 stone and she carried 610-658 stone for the rest of
-- the run. Not while a build / relocate / dismantle task of hers is ready
-- (upkeep_stock.building: its parts may be what she holds); an open task not being
-- acted on is cancelled then, or when no longer wanted. A failed task holds its chest
-- off FAIL_BACKOFF_TICKS for that item.
local u = require("commands.init")
local ledger = require("commands.task_pool_ledger")
local Regs = require("commands.upkeep_feed_regs")
local Stock = require("commands.upkeep_stock")
local roles = require("commands.chest_roles")
local events = require("commands.events")

local M = {}

M.ITEMS = {"stone", "iron-ore", "copper-ore"}
-- every other item she holds is a surplus above a stack too (factorio-ai
-- docs/stores_and_buffers.md stage 2; Zdendys: hand crafting needs no huge stocks) --
-- but not the fuels the upkeep itself keeps and feeds (coal, wood: their own rules)
M.NOT_SURPLUS = {coal = true, wood = true}
-- a placeable item (belts, poles, pipes...) Python crafts ahead for its builds: a
-- surplus only above this many stacks (its next routes take it from her hand)
M.PLACEABLE_KEEP = 2
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
  for _, k in ipairs({"tasks", "into", "backoff", "search", "asked"}) do
    s[k] = s[k] or {}
  end
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

-- The chest for her surplus of `item`: a store or a surplus chest of it by role
-- (chest_roles.target_rank) within RADIUS with room for some, not the controller's own
-- and not held off; the best rank, the nearest within it -- or nil.
local function store_for(c, item, off)
  -- (by role, docs/stores_and_buffers.md stage 2: the item's store, else a surplus chest
  -- of it at a consumer or a belt's start, else a central one; the nearest of the first
  -- kind found -- a chest without a role is none of Zdendys's two kinds: no target)
  local pos = c.entity.position
  local best, best_d, best_rank = nil, math.huge, math.huge
  for _, e in pairs(c.entity.surface.find_entities_filtered{
      type = {"container", "logistic-container"}, force = c.entity.force, position = pos,
      radius = M.RADIUS}) do
    local inv = e.get_inventory(defines.inventory.chest)
    local held = off[pos_key(e) .. "|" .. item]
    if inv and inv.get_insertable_count(item) > 0 and not (held and game.tick < held)
       and not Regs.own(e) then
      -- (only Zdendys's two kinds: a chest without a role is no target)
      local rank = roles.target_rank(e, item)
      if rank then
        local d = u.distance(pos, e.position)
        if rank < best_rank or (rank == best_rank and d < best_d) then
          best, best_d, best_rank = e, d, rank
        end
      end
    end
  end
  return best
end

-- The store for `item` (store_for, no back-offs) -- for commands/clearing.lua: her
-- inventory is full mid-clearing, she relieves it into the nearest role chest of the item;
-- with none within M.RADIUS Python is asked for a surplus chest (the "surplus" event, at
-- most one an item every NOSTORE_LOG_TICKS) and nil returned.
function M.relief_chest(cid, c, item, count)
  local chest = store_for(c, item, {})
  if chest then return chest end
  local asked = per(M.init().asked, cid)
  if not asked[item] or game.tick - asked[item] >= NOSTORE_LOG_TICKS then
    asked[item] = game.tick
    events.emit({kind = "surplus", id = cid .. ":" .. item, cid = cid,
                 status = "nostore", item = item, count = count})
  end
  return nil
end

-- The items above a stack she may put away: M.ITEMS and every other kind she holds but
-- the upkeep's own fuels.
local function surplus_items(inv)
  local out, seen = {}, {}
  for _, item in ipairs(M.ITEMS) do out[#out + 1] = item; seen[item] = true end
  for _, it in pairs(inv.get_contents()) do
    -- (not her stock items either -- plates, steel, bricks: the stock upkeep keeps their
    -- band, and Python holds them for its next craft or build -- review: a craft's plates
    -- fetched, then put away before it ran)
    if not seen[it.name] and not M.NOT_SURPLUS[it.name] and not Stock.is_stock_item(it.name)
       and prototypes.item[it.name] then
      out[#out + 1] = it.name
      seen[it.name] = true
    end
  end
  return out
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
    for _, item in ipairs(surplus_items(inv)) do
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
      local keep = prototypes.item[item].place_result and M.PLACEABLE_KEEP or M.KEEP_SHARE
      if have > keep * stack then
        -- (down to TARGET_SHARE of a stack below its keep: 0.7 a stack, 1.7 for a
        -- placeable item)
        local surplus = have - math.floor((keep - M.KEEP_SHARE + M.TARGET_SHARE) * stack)
        wanted[item] = surplus
        local next_search = per(s.search, cid)[item]
        if not mine[item] and open < M.MAX_TASKS
           and not (next_search and game.tick < next_search) then
          local box = store_for(c, item, off)
          if not box then
            -- (the surface search not again before NOSTORE_RESEARCH_TICKS -- review);
            -- the request for a chest to Python by the events file (kind "surplus":
            -- it plans a surplus chest at the item's consumer, or one in the central
            -- store for an item with no consumer)
            s.search[cid][item] = game.tick + NOSTORE_RESEARCH_TICKS
            -- (one id per item: a reader keeps the last event of a kind and id -- review;
            -- at most one a NOSTORE_LOG_TICKS an item: smoke_full_1118w sent 1552, one
            -- each search back-off, crowding the events ring the job ends share)
            local asked = per(s.asked, cid)
            if not asked[item] or game.tick - asked[item] >= NOSTORE_LOG_TICKS then
              asked[item] = game.tick
              events.emit({kind = "surplus", id = cid .. ":" .. item, cid = cid,
                           status = "nostore", item = item, count = surplus})
            end
            log_once("nostore", cid, item, NOSTORE_LOG_TICKS, string.format(
              "upkeep surplus: %d %s on hand (above its keep) and no store or surplus "
              .. "chest of it within %d tiles -- a surplus chest asked of the planner",
              have, item, M.RADIUS))
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
