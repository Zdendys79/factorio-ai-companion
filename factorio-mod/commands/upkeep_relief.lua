-- A full furnace emptied by the mod (factorio-ai docs/furnace_output_relief.md; Zdendys:
-- Python is the designer and site manager -- when, from where, to where, never how). A
-- furnace whose output holds RELIEF_SHARE of a stack of a stock item (plates, steel,
-- bricks) is about to stop, and its drill with it; the stock band does not help while her
-- stock is above half a stack. So, on the upkeep's scan: for each stock item the nearest
-- such furnace -- not one an inserter picks from (it feeds a line), not a controller-owned
-- one -- is emptied: one task of two steps, "take_out" there and "insert" into the
-- nearest store or surplus chest of the item by role (upkeep_surplus.store_for: the
-- item's store, else a surplus chest at a consumer or a belt's start, else a central one).
-- With no such chest within upkeep_surplus.RADIUS Python is asked for a surplus chest
-- (the "surplus" job-end event) and nothing is taken -- never plates she cannot put away.
-- Not while a build / relocate / dismantle task of hers is ready (upkeep_stock.building);
-- one open task at a time; a failed one holds its furnace off FAIL_BACKOFF_TICKS, doubled
-- while it repeats (at most x16), logged.
local u = require("commands.init")
local ledger = require("commands.task_pool_ledger")
local F = require("commands.upkeep_feeds")
local Regs = require("commands.upkeep_feed_regs")
local Stock = require("commands.upkeep_stock")
local Surplus = require("commands.upkeep_surplus")

local M = {}

M.RELIEF_SHARE = 0.8     -- an output at or above this share of a stack is full enough
M.MIN_TAKE = 10          -- not worth a walk below this many plates (her room or the chest's)
M.PRIORITY = 0.6         -- above the surplus band (0.5), below every need of the upkeep
local FAIL_BACKOFF_TICKS = 3600
M.LOG_BOOKS = {}

function M.init()
  -- storage.upkeep.relief = {tasks = {[cid] = task_id}, from = {[cid] = "x,y|item"},
  --   backoff = {[cid] = {["x,y|item"] = {until_tick, failures}}}}
  storage.upkeep = storage.upkeep or {}
  local s = storage.upkeep.relief or {}
  for _, k in ipairs({"tasks", "from", "backoff"}) do s[k] = s[k] or {} end
  storage.upkeep.relief = s
  return s
end

local function key_of(e, item)
  return string.format("%.1f,%.1f|%s", e.position.x, e.position.y, item)
end

-- The nearest furnace holding RELIEF_SHARE of a stack of `item` in its output (module
-- header), not held off; nil when none. Returns the furnace and the plates in it.
local function full_furnace(c, furnaces, off, item)
  local share = math.ceil(M.RELIEF_SHARE * prototypes.item[item].stack_size)
  local pos = c.entity.position
  local best, best_d, best_n = nil, math.huge, 0
  for _, e in pairs(furnaces) do
    local inv = e.valid and e.get_inventory(defines.inventory.crafter_output)
    local n = inv and inv.get_item_count(item) or 0
    if n >= share and not Regs.own(e) and not F.picked_from(e) then
      local held = off[key_of(e, item)]
      if not (held and game.tick < held[1]) then
        local d = u.distance(pos, e.position)
        if d < best_d then best, best_d, best_n = e, d, n end
      end
    end
  end
  return best, best_n
end

-- Ended tasks forgotten; a failed one holds its furnace off (logged).
local function prune(cid, s)
  local task_id = s.tasks[cid]
  if task_id then
    local t = storage.tasks[task_id]
    if not t or t.status ~= "active" then
      local key = s.from[cid]
      local off = s.backoff[cid] or {}
      s.backoff[cid] = off
      if key and t and t.status == "failed" then
        local n = ((off[key] and off[key][2]) or 0) + 1
        local wait = FAIL_BACKOFF_TICKS * 2 ^ math.min(n - 1, 4)
        off[key] = {game.tick + wait, n}
        log(string.format("[ai-companion] upkeep relief: emptying %s failed (%s) -- held off "
                          .. "%d ticks", key, tostring(t.error), wait))
      elseif key and t and t.status == "done" then
        off[key] = nil
      end
      storage.tasks[task_id] = nil
      s.tasks[cid], s.from[cid] = nil, nil
    end
  end
  for key, v in pairs(s.backoff[cid] or {}) do
    if game.tick >= v[1] then s.backoff[cid][key] = nil end
  end
end

-- The relief scan of one companion (module header). `acting(task_id)`: whether that task
-- is her current step; `log_once` is the upkeep's log books (unused: nothing here repeats).
function M.scan(cid, c, acting, _log_once)
  local s = M.init()
  prune(cid, s)
  local building = Stock.building(cid)
  local open = s.tasks[cid]
  if building then
    if open and not acting(open) then
      ledger.cancel_task(open, "upkeep relief: a build is ready")
      storage.tasks[open] = nil
      s.tasks[cid], s.from[cid] = nil, nil
    end
    return
  end
  if open then return end
  local off = s.backoff[cid] or {}
  s.backoff[cid] = off
  local furnaces = c.entity.surface.find_entities_filtered{type = "furnace",
                                                           force = c.entity.force}
  for _, item in ipairs(Stock.STOCK_ITEMS) do
    local src, n = full_furnace(c, furnaces, off, item)
    if src then
      local box = Surplus.store_for(c, item, {}, src.position)
      if not box then
        Surplus.relief_chest(cid, c, item, n)     -- (asks Python for a surplus chest)
      else
        -- (what the chest takes and what fits her inventory beyond her own stock: the take
        -- may bring less, the insert step is optional and puts in what she holds)
        local count = math.min(n, box.get_inventory(defines.inventory.chest)
                                   .get_insertable_count(item),
                               c.entity.get_main_inventory().get_insertable_count(item))
        if count >= M.MIN_TAKE then
          local r = ledger.submit_task(cid, {
            {type = "take_out", x = src.position.x, y = src.position.y, item = item,
             count = count},
            {type = "insert", x = box.position.x, y = box.position.y, entity = box.name,
             item = item, count = count, optional = true}}, "upkeep", M.PRIORITY)
          if r.task_id then
            s.tasks[cid], s.from[cid] = r.task_id, key_of(src, item)
            return
          end
          u.log_error("upkeep relief: submit for " .. item .. " failed: " .. tostring(r.error),
                      "upkeep")
        end
      end
    end
  end
end

-- Whether the companion has a relief task record left (upkeep.tick: cleaned up while off).
function M.has_tasks(cid)
  local s = storage.upkeep and storage.upkeep.relief
  return s ~= nil and s.tasks[cid] ~= nil
end

-- Upkeep switched off: its open task not being acted on cancelled, its record cleared once
-- it ended, its back-offs dropped.
function M.stop(cid, acting)
  local s = M.init()
  local task_id = s.tasks[cid]
  if task_id then
    local t = storage.tasks[task_id]
    if t and t.status == "active" and not acting(task_id) then
      ledger.cancel_task(task_id, "upkeep switched off")
    end
    if not (t and t.status == "active" and acting(task_id)) then
      storage.tasks[task_id] = nil
      s.tasks[cid], s.from[cid] = nil, nil
    end
  end
  s.backoff[cid] = nil
end

return M
