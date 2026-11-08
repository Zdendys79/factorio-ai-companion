-- Her stock (factorio-ai docs/mod_upkeep_supply.md B; game rules 11 and 33 -- Zdendys:
-- keeping her inventory is purely Nyara's while she is not building). Stage 1: the
-- furnaces' plates. Called by the upkeep's scan (commands/upkeep.lua) every SCAN_TICKS
-- for a companion with upkeep on.
--
-- For each item of STOCK_ITEMS: below half a stack in her inventory, a stock need --
-- p = log2(the shortfall to TARGET_SHARE of a stack); its sources are her force's
-- furnaces holding it in their output that no inserter picks from (an output an
-- inserter takes feeds a line, not her) and that the controller did not mark its own --
-- the nearest holding the whole shortfall, else the nearest holding MIN_TAKE (or the
-- whole shortfall, when it is less); one task: a "take_out" there, the shortfall at
-- most (never above TARGET_SHARE of a stack, never more than fits her inventory -- a
-- full one takes nothing), priority p kept up to date; none: logged. A task that
-- failed holds its source off FAIL_BACKOFF_TICKS for that item, doubled while it
-- repeats (at most x16), logged (review: an unreachable furnace was walked to again
-- every scan).
-- The gate (Zdendys: "when she is not building"): no stock task while a build /
-- relocate / dismantle task of hers is ready (its needs reserved -- a task Python
-- submitted ahead, waiting for its parts, is no building); an open one not being acted
-- on is cancelled when one becomes ready. At most MAX_TASKS stock tasks per companion.
local u = require("commands.init")
local ledger = require("commands.task_pool_ledger")
local targeting = require("commands.task_pool_targeting")
local F = require("commands.upkeep_feeds")
local N = require("commands.upkeep_need")
local Regs = require("commands.upkeep_feed_regs")

local M = {}

M.STOCK_ITEMS = {"iron-plate", "copper-plate", "steel-plate", "stone-brick"}
M.LOW_SHARE = N.STOCK_LOW_SHARE   -- below this share of a stack: a need
M.TARGET_SHARE = N.STOCK_TARGET_SHARE   -- what a stock task fills up to
M.MIN_TAKE = 10          -- a source holding less (unless the whole need) is no source
M.MAX_TASKS = 2
local NOSOURCE_LOG_TICKS = 18000
local FAIL_BACKOFF_TICKS = 3600
local BUILDING = {build = true, relocate = true, dismantle = true}
-- its log books (pruned by the upkeep with its own: commands/upkeep.lua LOG_BOOKS)
M.LOG_BOOKS = {nosource = NOSOURCE_LOG_TICKS}

function M.init()
  -- storage.upkeep.stock = {tasks = {[cid] = {[item] = task_id}}, from = {[cid] =
  --   {[item] = "x,y" of its task's source}}, backoff = {[cid] = {["x,y|item"] =
  --   {until_tick, n}}}}
  storage.upkeep = storage.upkeep or {}
  local s = storage.upkeep.stock or {}
  for _, k in ipairs({"tasks", "from", "backoff"}) do s[k] = s[k] or {} end
  storage.upkeep.stock = s
  return s
end

local function pos_key(e)
  return string.format("%.1f,%.1f", e.position.x, e.position.y)
end

local function per(t, cid)
  t[cid] = t[cid] or {}
  return t[cid]
end

-- The stock priority of a shortfall of `want` items.
local function priority_of(want)
  return math.log(math.max(2, want), 2)
end

-- Whether a build / relocate / dismantle task of hers is ready to run (the gate).
function M.building(cid)
  for _, t in pairs(storage.tasks) do
    if t.cid == cid and t.status == "active" and BUILDING[t.kind or "build"]
       and t.cursor <= #t.steps and targeting.task_ready(t) then
      return true
    end
  end
  return false
end

-- The source for `want` of `item` nearest her among `furnaces`: (furnace, count there)
-- or nil -- one holding the whole of it, else the nearest holding MIN_TAKE at least (no
-- walk for a plate or two); never a furnace the controller marked its own (it loads
-- and empties it itself -- oil_ops' temporary smelt furnace waits for its product
-- there), nor one held off for this item (`off`).
local function source_for(c, furnaces, off, item, want)
  local pos = c.entity.position
  local least = math.min(M.MIN_TAKE, want)
  local whole, whole_d, some, some_d, some_n = nil, math.huge, nil, math.huge, 0
  for _, e in pairs(furnaces) do
    local inv = e.valid and e.get_inventory(defines.inventory.crafter_output)
    local n = inv and inv.get_item_count(item) or 0
    local held_off = n >= least and off[pos_key(e) .. "|" .. item]
    held_off = held_off and game.tick < held_off[1]
    if n >= least and not held_off and not Regs.own(e) and not F.picked_from(e) then
      local d = u.distance(pos, e.position)
      if n >= want and d < whole_d then whole, whole_d = e, d end
      if d < some_d then some, some_d, some_n = e, d, n end
    end
  end
  if whole then
    return whole, whole.get_inventory(defines.inventory.crafter_output).get_item_count(item)
  end
  return some, some_n
end

-- The stock scan of one companion (module header). `acting(task_id)`: whether that task
-- is her current step; `log_once(book, cid, key, every, msg)`: the upkeep's log books.
-- Forget ended tasks; one that failed holds its source off for its item, every failure
-- logged (the back-off spaces them -- review: a log book keyed by the doubled wait
-- swallowed the repeats).
local function prune(cid, s, mine)
  local from, off = per(s.from, cid), per(s.backoff, cid)
  for item, task_id in pairs(mine) do
    local t = storage.tasks[task_id]
    if not t or t.status ~= "active" then
      local key = from[item] and (from[item] .. "|" .. item)
      if key and t and t.status == "failed" then
        local n = ((off[key] and off[key][2]) or 0) + 1
        local wait = FAIL_BACKOFF_TICKS * 2 ^ math.min(n - 1, 4)
        off[key] = {game.tick + wait, n}
        log(string.format("[ai-companion] upkeep stock: the take of %s at %s failed (%s) "
                          .. "-- held off %d ticks", item, from[item], tostring(t.error), wait))
      elseif key and t and t.status == "done" then
        off[key] = nil
      end
      storage.tasks[task_id] = nil
      mine[item] = nil
      from[item] = nil
    end
  end
  for key, v in pairs(off) do
    if game.tick >= v[1] then off[key] = nil end
  end
end

function M.scan(cid, c, acting, log_once)
  local s = M.init()
  local mine, from, off = per(s.tasks, cid), per(s.from, cid), per(s.backoff, cid)
  prune(cid, s, mine)
  local building = M.building(cid)
  local inv = c.entity.get_main_inventory()
  local wanted = {}
  local furnaces = nil         -- (one surface search per scan, only when a task is due)
  if not building then
    local open = 0
    for _ in pairs(mine) do open = open + 1 end
    for _, item in ipairs(M.STOCK_ITEMS) do
      local stack = prototypes.item[item].stack_size
      local have = inv.get_item_count(item)
      -- (what fits her inventory: a full one takes nothing -- no walk for it)
      local want = math.min(math.ceil(M.TARGET_SHARE * stack) - have,
                            inv.get_insertable_count(item))
      if have < M.LOW_SHARE * stack and want >= 1 then
        wanted[item] = want
        if not mine[item] and open < M.MAX_TASKS then
          furnaces = furnaces or c.entity.surface.find_entities_filtered{
            type = "furnace", force = c.entity.force}
          local src, n = source_for(c, furnaces, off, item, want)
          if not src then
            log_once("nosource", cid, item, NOSOURCE_LOG_TICKS, string.format(
              "upkeep stock: %d %s on hand (under half a stack) and no furnace output "
              .. "to take it from", have, item))
          else
            local r = ledger.submit_task(cid, {{type = "take_out", x = src.position.x,
                                                y = src.position.y, item = item,
                                                count = math.min(want, n)}},
                                         "upkeep", priority_of(want))
            if r.task_id then
              mine[item] = r.task_id
              from[item] = pos_key(src)
              open = open + 1
            else
              u.log_error("upkeep stock: submit for " .. item .. " failed: "
                          .. tostring(r.error), "upkeep")
            end
          end
        end
      end
    end
  end
  -- open tasks still wanted: their priority kept up to date (review)
  for item, task_id in pairs(mine) do
    local t = storage.tasks[task_id]
    if wanted[item] and t then t.priority = priority_of(wanted[item]) end
  end
  -- open tasks no longer wanted (the stock filled, or a build became ready) cancelled
  -- unless being acted on
  for item, task_id in pairs(mine) do
    if not wanted[item] and not acting(task_id) then
      ledger.cancel_task(task_id, building and "upkeep stock: a build is ready"
                                  or "upkeep stock: no longer needed")
      storage.tasks[task_id] = nil
      mine[item] = nil
      from[item] = nil
    end
  end
end

-- The stock part of the status: its open tasks, each with its source ("x,y").
function M.status(cid)
  local s = (storage.upkeep and storage.upkeep.stock) or {}
  local from = (s.from and s.from[cid]) or {}
  local out = {}
  for item, task_id in pairs((s.tasks and s.tasks[cid]) or {}) do
    local t = storage.tasks[task_id]
    if t and t.status == "active" then
      out[#out + 1] = {item = item, task_id = task_id, priority = t.priority,
                       at = from[item]}
    end
  end
  return out
end

-- Whether an open stock task of any companion takes `item` from the furnace output at
-- `pos` ("x,y") -- the fetch of a hand craft's material leaves that one (task_pool_fetch:
-- else the stock task found it emptied and held a good source off).
function M.claimed(pos, item)
  local s = storage.upkeep and storage.upkeep.stock
  for cid, from in pairs((s and s.from) or {}) do
    local task_id = s.tasks and s.tasks[cid] and s.tasks[cid][item]
    local t = task_id and storage.tasks[task_id]
    if from[item] == pos and t and t.status == "active" then return true end
  end
  return false
end

-- Whether the companion has stock task records left (upkeep.tick: clean them up while off).
function M.has_tasks(cid)
  local s = storage.upkeep and storage.upkeep.stock
  return s ~= nil and s.tasks[cid] ~= nil and next(s.tasks[cid]) ~= nil
end

-- Upkeep switched off: its open stock tasks not being acted on cancelled; the record of
-- one being acted on is cleared by a later call once it ended; its back-offs dropped.
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
      if s.from[cid] then s.from[cid][item] = nil end
    end
  end
  s.backoff[cid] = nil
end

return M
