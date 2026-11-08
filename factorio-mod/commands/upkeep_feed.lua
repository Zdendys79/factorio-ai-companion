-- Feeding a production that has no belt (factorio-ai docs/mod_upkeep_supply.md A; game
-- rules 6 and 32 -- Zdendys: the mod does it, Python does not watch what is missing
-- where). Stage 1: furnaces. Called by the upkeep's scan (commands/upkeep.lua) every
-- SCAN_TICKS for a companion with upkeep on.
--
-- Every furnace of her force on her surface (no recycler -- not a radius round her: a
-- hand-fed unit far away was left to nobody), per its input item (its recipe's
-- ingredient), except one the controller marked its own (commands/upkeep_feed_regs.lua
-- -- it loads it itself):
-- - what it smelts: get_recipe(), else previous_recipe (live 2.1: a furnace that ran
--   keeps it -- {name, quality}), else the controller's registration (a fresh hand-fed
--   furnace); unknown: not served, listed;
-- - t = held / amount per craft x energy per craft / crafting speed (its seconds of
--   input); target = min(TARGET_S, what a full input stack lasts); p = log2(target /
--   max(1, t)), lowered by its output's fill as the fuel need is (1 + (p-1)(1-0.9 fill));
--   no need with an output OUTPUT_STOP_SHARE full (nobody takes its product -- review:
--   furnaces left behind were fed by hand for good), while she holds STOCK_TARGET_SHARE
--   of a stack of its product unreserved and no inserter takes it to a line (nobody
--   wants more -- hand feeding is most of her time; judged for p > 1 only), or (an
--   electric one) no power. A
--   burner one without fuel is fed only within the fuel upkeep's SCAN_RADIUS of her
--   (it fuels it then; live: a fresh one is no_fuel) -- beyond it nothing would;
-- - then (only for p > 1 -- the line check is the expensive part) a line that delivers
--   the item (upkeep_lines.input_line) makes it not hers -- that verdict kept
--   LINE_RECHECK_TICKS (review: a line check per inserter-fed furnace every scan); one
--   delivering nothing at two scans in a row makes it hers once its input lasts under
--   LINE_DRY_S, logged as underfed;
-- - hand feeding is an emergency (rule 6): she feeds at most MAX_HAND_PER_ITEM furnaces
--   of one input item by hand -- the ones registered by the controller and those she
--   fed lately first; the rest is listed unfed and logged (a line for them is the
--   controller's; review: a plate row on a mined-out patch would have been fed ore
--   mined by hand, furnace by furnace);
-- - a feed task (kind "upkeep", priority p): an "insert" of the item to the target (at
--   least MIN_BATCH, capped by the room) -- a need of the task, so it reserves what it
--   carries. A raw input (a resource's product: ore) she does not stock is mined first
--   by an ensure_item step (no_pull: no chest near her is emptied -- an ore chest feeds
--   a line), at most MINE_CHUNK at a time (a whole slot took longer than the task
--   pool's give-up); a smelted input (a steel furnace's plates) comes from her free
--   stock only, leaving her STOCK_LOW_SHARE of a stack (review: else the stock upkeep
--   and the feed passed her plates to and fro), no new task under MIN_BATCH (an open
--   one keeps what it reserved: review -- its own reservation made it "no longer
--   needed" every other scan);
-- - a wrong item in its output (one its recipe does not make: the furnace is stuck): a
--   clear task -- a take_out of it when her inventory has room, priority log2(target)
--   (a stuck furnace makes nothing: as one with no input left).
-- At most MAX_TASKS feed tasks per companion, the highest p; an open task's priority is
-- kept up to date, one no longer needed (and not being acted on) cancelled; one that
-- failed holds that furnace off FAIL_BACKOFF_TICKS, doubled while it repeats (at most
-- x16), every failure logged. Every furnace fed by hand is listed once its feed is done
-- (rule 6: an emergency until a belt feeds it -- the controller plans one).
-- (what a furnace needs -- its recipe, seconds left, line, wrong item: the constants
-- TARGET_S, MIN_BATCH, LINE_RECHECK_TICKS, OUTPUT_STOP_SHARE -- is upkeep_feed_need.lua)
local u = require("commands.init")
local ledger = require("commands.task_pool_ledger")
local task_pool = require("commands.task_pool")
local lines = require("commands.upkeep_lines")
local N = require("commands.upkeep_need")
local Need = require("commands.upkeep_feed_need")
local Regs = require("commands.upkeep_feed_regs")

local M = {}

M.MAX_TASKS = 2
M.MINE_CHUNK = 20
M.MAX_HAND_PER_ITEM = 4           -- furnaces of one input item she feeds by hand
local FAIL_BACKOFF_TICKS = 3600
local HAND_KEEP_TICKS = 18000     -- a furnace fed by hand stays listed this long
-- its log books (pruned by the upkeep with its own: commands/upkeep.lua LOG_BOOKS;
-- "underfed" is the fuel upkeep's book, shared)
M.LOG_BOOKS = {noline = HAND_KEEP_TICKS, handcap = HAND_KEEP_TICKS}

-- her books kept per surface (review: a visit to another surface wiped them -- the hand
-- cap's order and the back-off doubling were lost)
local SURFACE_BOOKS = {"down", "lines", "backoff", "hand"}

function M.init()
  -- storage.upkeep.feed = {tasks = {[cid] = {[key] = task_id}}; per surface index s:
  --   down = {[cid] = {[s] = {[key] = first tick its line delivered nothing}}}, lines =
  --   {[cid] = {[s] = {[key] = tick a line was seen}}}, backoff = {[cid] = {[s] = {[key] =
  --   {until_tick, n}}}}, hand = {[cid] = {[s] = {[pos] = {item, tick}}}}; unknown /
  --   unfed = {[cid] = {[pos] = tick / item}} (rebuilt each scan; scanned = {[cid] = the
  --   surface index of her last scan}), picks = {[unit number]
  --   = {tick, items}: what an inserter's pickup last held -- upkeep_lines},
  --   books_version}; the registrations: upkeep_feed_regs.lua
  storage.upkeep = storage.upkeep or {}
  local f = storage.upkeep.feed or {}
  for _, k in ipairs({"tasks", "down", "lines", "backoff", "hand", "unknown", "unfed",
                      "scanned", "picks"}) do
    f[k] = f[k] or {}
  end
  -- (the first drafts kept these books without the surface level -- only in test saves;
  -- they are transient, started afresh)
  if f.books_version ~= 2 then
    for _, k in ipairs(SURFACE_BOOKS) do f[k] = {} end
    f.books_version = 2
  end
  -- (the first draft's per-companion registrations -- only in test saves: gone,
  -- upkeep_feed_regs.lua keeps them now; dropped with a log line)
  if f.regs then
    local n = 0
    for _, book in pairs(f.regs) do
      for _ in pairs(type(book) == "table" and book or {}) do n = n + 1 end
    end
    log("[ai-companion] upkeep feed: " .. n .. " registrations of the first draft "
        .. "dropped (register those furnaces again)")
    f.regs = nil
  end
  storage.upkeep.feed = f
  return f
end

local pos_key = Need.pos_key

local function per(f, cid)
  f[cid] = f[cid] or {}
  return f[cid]
end

-- The book `f`'s entries of the companion `cid` on the surface `s`.
local function per_surface(f, cid, s)
  local mine = per(f, cid)
  mine[s] = mine[s] or {}
  return mine[s]
end

-- Forget ended tasks: a feed done lists its furnace as fed by hand; one that failed
-- holds its furnace off (doubled while it repeats, at most x16), every failure logged
-- (the back-off spaces them -- review: a log book keyed by the doubled wait swallowed
-- the repeats).
local function prune(mine, off, hand)
  for key, task_id in pairs(mine) do
    local t = storage.tasks[task_id]
    if not t or t.status ~= "active" then
      local pos, item = key:match("^(.-)|(.+)$")
      if t and t.status == "done" then
        off[key] = nil
        if item ~= "clear" then hand[pos] = {item = item, tick = game.tick} end
      elseif t and t.status == "failed" then
        local n = ((off[key] and off[key][2]) or 0) + 1
        local wait = FAIL_BACKOFF_TICKS * 2 ^ math.min(n - 1, 4)
        off[key] = {game.tick + wait, n}
        log(string.format("[ai-companion] upkeep feed: the task at %s failed (%s) -- "
                          .. "held off %d ticks", key, tostring(t.error), wait))
      end
      storage.tasks[task_id] = nil
      mine[key] = nil
    end
  end
end

-- Why the feed need `n` is hers, logged (once per its book's interval): no line into
-- the machine, or one that delivers nothing -- only when its feed task goes out
-- (review: a capped or held-off one logged "fed by hand" while nothing fed it).
local function log_why(cid, n, log_once)
  if n.clear then return end
  local at = pos_key(n.e)
  if n.line == nil then
    -- (what it found round the machine: why it is hers)
    log_once("noline", cid, n.key, HAND_KEEP_TICKS, string.format(
      "upkeep: no %s line into the %s at %s (%s) -- fed by hand", n.item, n.e.name, at,
      n.why ~= "" and n.why or "no source round it"))
  elseif n.line == "dry" then
    log_once("underfed", cid, n.key, N.UNDERFED_LOG_TICKS, string.format(
      "upkeep: the %s line into the %s at %s delivers nothing (%s; %.0f s of input "
      .. "left) -- fed by hand", n.item, n.e.name, at, n.why, n.t))
  end
end

-- The steps of a feed or clear task for the need `n`.
local function steps_of(c, n)
  local x, y = n.e.position.x, n.e.position.y
  if n.clear then
    return {{type = "take_out", x = x, y = y, item = n.item, count = n.want}}
  end
  local steps, count = {}, n.want
  local free = Need.free_of(c, n.item)
  if n.raw and free < count then
    -- (mined in a chunk: at most MINE_CHUNK more than she has free)
    count = math.min(count, math.max(0, free) + M.MINE_CHUNK)
    steps[1] = {type = "ensure_item", item = n.item, count = count, no_pull = true}
  end
  steps[#steps + 1] = {type = "insert", x = x, y = y, entity = n.e.name, item = n.item,
                       count = count}
  return steps
end

-- The furnaces she feeds by hand now, per input item: {[item] = {[pos] = true}} -- fed
-- lately (`hand`) or with an open feed task (`mine`).
local function hand_fed(hand, mine)
  local by_item = {}
  local function add(pos, item)
    by_item[item] = by_item[item] or {}
    by_item[item][pos] = true
  end
  for pos, v in pairs(hand) do add(pos, v.item) end
  for key in pairs(mine) do
    local pos, item = key:match("^(.-)|(.+)$")
    if pos and item ~= "clear" then add(pos, item) end
  end
  return by_item
end

-- Whether the need `n` may be fed by hand (MAX_HAND_PER_ITEM -- module header; a
-- registration ranks first but is no exception -- review: the furnaces a loop of the
-- controller's had registered were hand-fed without a bound once their drills mined
-- out); a new furnace taken in is counted in `fed`.
local function within_cap(n, fed)
  if n.clear then return true end
  local pos = pos_key(n.e)
  local set = fed[n.item] or {}
  fed[n.item] = set
  if set[pos] then return true end
  local count = 0
  for _ in pairs(set) do count = count + 1 end
  if count >= M.MAX_HAND_PER_ITEM then return false end
  set[pos] = true
  return true
end

-- The feed scan of one companion (module header). `acting(task_id)`: whether that task
-- is her current step; `log_once(book, cid, key, every, msg)`: the upkeep's log books.
function M.scan(cid, c, acting, log_once)
  local f = M.init()
  local surface = c.entity.surface
  local s = surface.index
  local mine = per(f.tasks, cid)
  local b = {down = per_surface(f.down, cid, s), lines = per_surface(f.lines, cid, s),
             mine = mine, picks = f.picks}
  local off, hand = per_surface(f.backoff, cid, s), per_surface(f.hand, cid, s)
  -- (rebuilt every scan: a furnace gone leaves no entry behind; the status shows them
  -- only for the surface they were made on -- review)
  f.unknown[cid], f.unfed[cid] = {}, {}
  f.scanned[cid] = s
  local unknown, unfed = f.unknown[cid], f.unfed[cid]
  prune(mine, off, hand)
  local needs, by_key, seen, present, seen_pos, owned = {}, {}, {}, {}, {}, {}
  local inv = c.entity.get_main_inventory()
  for _, e in pairs(surface.find_entities_filtered{type = "furnace",
                                                   force = c.entity.force}) do
    if e.valid and e.name ~= "recycler" then
      if e.unit_number then present[e.unit_number] = true end
      seen_pos[pos_key(e)] = true
      local need = Need.need_of(e, b, seen, c, inv, unknown, owned)
      if need then
        by_key[need.key] = need
        needs[#needs + 1] = need
      end
    end
  end
  -- (book entries of furnaces gone are dropped -- a line fed again was dropped by
  -- feed_need; a registration only by its own surface's scan: review -- a visit to
  -- another surface wiped every registration)
  for _, book in pairs({b.down, b.lines, off}) do
    for key in pairs(book) do
      if not seen[key] then book[key] = nil end
    end
  end
  Regs.prune(surface.index, present)
  -- the hand cap, in its own order: the registered and the lately fed first, then by
  -- priority
  local function rank(n)
    return (Regs.registered(n.e) or hand[pos_key(n.e)]) and 1 or 0
  end
  local by_rank = {}
  for i, n in ipairs(needs) do by_rank[i] = n end
  table.sort(by_rank, function(a, b2)
    local ra, rb = rank(a), rank(b2)
    if ra ~= rb then return ra > rb end
    return a.p > b2.p
  end)
  -- (a furnace gone holds no cap slot -- review)
  for pos in pairs(hand) do
    if not seen_pos[pos] then hand[pos] = nil end
  end
  local fed = hand_fed(hand, mine)
  for _, n in ipairs(by_rank) do
    if not within_cap(n, fed) then
      n.capped = true
      by_key[n.key] = nil
      unfed[pos_key(n.e)] = n.item
      log_once("handcap", cid, n.key, HAND_KEEP_TICKS, string.format(
        "upkeep feed: the %s at %s needs %s by hand, but she feeds %d such furnaces by "
        .. "hand already -- not fed (a line for it is the controller's)", n.e.name,
        pos_key(n.e), n.item, M.MAX_HAND_PER_ITEM))
    end
  end
  -- the task slots by priority
  table.sort(needs, function(a, b2) return a.p > b2.p end)
  local open = 0
  for _ in pairs(mine) do open = open + 1 end
  for _, n in ipairs(needs) do
    local held_off = off[n.key] and game.tick < off[n.key][1]
    if not n.capped and not mine[n.key] and not held_off and open < M.MAX_TASKS then
      local r = ledger.submit_task(cid, steps_of(c, n), "upkeep", n.p)
      if r.task_id then
        -- (why it is hers -- logged only for a feed that goes out: review)
        log_why(cid, n, log_once)
        mine[n.key] = r.task_id
        open = open + 1
      else
        u.log_error("upkeep feed: submit for the " .. n.e.name .. " at " .. n.key
                    .. " failed: " .. tostring(r.error), "upkeep")
      end
    end
  end
  -- the open tasks: priority kept up to date, those no longer needed cancelled -- one
  -- for a furnace the controller now loads itself even while she acts on it (review:
  -- she kept mining and inserting for it while the controller's loop filled it;
  -- task_pool.cancel_task stops her step cleanly)
  for key, task_id in pairs(mine) do
    local t = storage.tasks[task_id]
    local pos = key:match("^(.-)|")
    if by_key[key] and t then
      t.priority = by_key[key].p
    elseif t and owned[pos] then
      task_pool.cancel_task(task_id)
      log("[ai-companion] upkeep feed: the task at " .. key .. " cancelled -- the "
          .. "controller loads that furnace itself now")
      storage.tasks[task_id] = nil
      mine[key] = nil
    elseif t and not acting(task_id) then
      ledger.cancel_task(task_id, "upkeep feed: no longer needed")
      storage.tasks[task_id] = nil
      mine[key] = nil
    end
  end
  for key, v in pairs(hand) do
    if game.tick - v.tick >= HAND_KEEP_TICKS then hand[key] = nil end
  end
  for unit, v in pairs(f.picks) do
    if game.tick - v.tick >= lines.MEMORY_TICKS then f.picks[unit] = nil end
  end
end

-- The surface index of the companion `cid` (u.get_companion: only one whose entity is
-- valid), or nil; the book `f`'s entries of hers on that surface ({} when she or it is
-- not there).
local function her_surface(cid)
  local c = u.get_companion(cid)
  return c and c.entity.surface.index or nil
end

local function on_her_surface(f, cid)
  local s = her_surface(cid)
  local book = s and f and f[cid] and f[cid][s]
  return type(book) == "table" and book or {}
end

-- The feed upkeep's part of the status -- her current surface's: its open tasks, the
-- furnaces fed by hand lately (rule 6), the furnaces whose input it cannot tell, the
-- furnaces over the hand cap (unfed: [{at, item}]), the feeds held off after failures
-- (held_off: [{at, item, until_tick}] -- the controller's own feeding steps in for its
-- furnaces meanwhile; review: another surface's entries matched furnaces here by their
-- position).
function M.status(cid)
  local f = (storage.upkeep and storage.upkeep.feed) or {}
  local out = {tasks = {}, hand_fed = {}, unknown = {}, unfed = {}, held_off = {}}
  for key, v in pairs(on_her_surface(f.backoff, cid)) do
    local pos, item
    if type(key) == "string" then pos, item = key:match("^(.-)|(.+)$") end
    if pos and type(v) == "table" and game.tick < (v[1] or 0) then
      out.held_off[#out.held_off + 1] = {at = pos, item = item, until_tick = v[1]}
    end
  end
  for key, task_id in pairs((f.tasks and f.tasks[cid]) or {}) do
    local t = storage.tasks[task_id]
    if t and t.status == "active" then
      out.tasks[#out.tasks + 1] = {key = key, task_id = task_id, priority = t.priority}
    end
  end
  for pos, v in pairs(on_her_surface(f.hand, cid)) do
    if type(v) == "table" then
      out.hand_fed[#out.hand_fed + 1] = {at = pos, item = v.item, tick = v.tick}
    end
  end
  -- (her last scan's lists, only while she is still on its surface)
  local here = f.scanned and f.scanned[cid] ~= nil and f.scanned[cid] == her_surface(cid)
  for pos in pairs((here and f.unknown and f.unknown[cid]) or {}) do
    out.unknown[#out.unknown + 1] = pos
  end
  for pos, item in pairs((here and f.unfed and f.unfed[cid]) or {}) do
    out.unfed[#out.unfed + 1] = {at = pos, item = item}
  end
  return out
end

-- Upkeep switched off: its open feed tasks not being acted on cancelled (the record of
-- one being acted on is cleared by a later call once it ended -- upkeep.tick calls it
-- while the upkeep is off and a record is left), and its books of her dropped (review:
-- a stale unknown list stayed in the status); the registrations stay (the controller's
-- word on its furnaces holds for the next run).
function M.stop(cid, acting)
  local f = M.init()
  for key, task_id in pairs(per(f.tasks, cid)) do
    local t = storage.tasks[task_id]
    if t and t.status == "active" and not acting(task_id) then
      ledger.cancel_task(task_id, "upkeep switched off")
    end
    if not (t and t.status == "active" and acting(task_id)) then
      storage.tasks[task_id] = nil
      f.tasks[cid][key] = nil
    end
  end
  for _, k in ipairs({"down", "lines", "backoff", "hand", "unknown", "unfed", "scanned"}) do
    f[k][cid] = nil
  end
end

-- Whether the companion has feed task records left (upkeep.tick: clean them up while off).
function M.has_tasks(cid)
  local f = storage.upkeep and storage.upkeep.feed
  return f ~= nil and f.tasks[cid] ~= nil and next(f.tasks[cid]) ~= nil
end

return M
