-- AI Companion -- generic task pool (2026-07-07, Zdendys's redesign)
--
-- Replaces Python-orchestrated monolithic macros (which block on ONE goal's whole
-- step sequence at a time, and restart every step from scratch after any failure)
-- with a mod-side pool: Python submits an ORDERED list of generic atomic STEPS
-- under a task_id. The mod derives item NEEDS from those steps, reserves whatever
-- is already on hand, and works through the remaining steps of ALL currently-
-- submitted tasks together -- each time the companion goes idle, the NEXT step
-- executed is whichever ready task's next step has the highest priority raised by
-- nearness (commands/priority.lua; among tasks of one kind: the CLOSEST step; task_id
-- order as the tiebreak), not necessarily the same task as last time.
-- This is what lets an unrelated-but-nearby task's step get done WHILE a slow/
-- distant task is still working out its own next move, instead of the whole
-- companion sitting idle-but-blocked on one goal (Zdendys: "coal_pair @259k je
-- naprosto nepredstavitelne pomalu").
--
-- Procurement (mining raw ore, crafting intermediate items) is NOT reimplemented
-- here -- a task with unmet needs just stays blocked until enough of the needed
-- item exists in the main inventory; something ELSE (the existing gather_queues/
-- craft_queues macros, or a future task that supplies coal/plates as a side
-- effect) is expected to top that up. This keeps this first version's scope to
-- the mechanism Zdendys actually described tonight (pool/reservation/priority),
-- not a from-scratch reimplementation of every existing procurement macro.
--
-- Step vocabulary (v1 -- exactly what iron_drill/stone_drill/coal_pair/coal_pair
-- upgrade/furnace-upgrade need, not yet a fully general DSL):
--   {type="find_patch", resource=NAME}                 -> ctx.px, ctx.py
--   {type="find_existing", entity=NAME, radius=N}       -> ctx.px, ctx.py
--   {type="set_position", x=, y=}                       -> ctx.px, ctx.py
--   {type="verify_tile", resource=NAME}                -> aborts task if patch gone
--   {type="pick_orientation", primary=ENTITY, secondary=ENTITY, offsets={{dx,dy},...},
--                             opposite_direction=true|nil, primary_exists=true|nil,
--                             secondary_resource=NAME|nil,
--                             ignore_entities_at={{x=,y=},...}|nil}
--                                                       -> ctx.sx, ctx.sy, ctx.dir, ctx.dir2
--   {type="place", which=/x,y/ref/candidates={{x=,y=,dir=},...}, entity=NAME, dir=N,
--                  mirror=true|nil}                       -> horizontal mirror (live-
--                                                             verified: burner-mining-drill's
--                                                             own drop_position flips side)
--   {type="remove", which=/x,y/ref=, entity=NAME}
--   {type="fuel", which=/x,y/ref=, item=NAME, count=N, swap=true|nil}
--                                                       -> swap: the target's other fuel
--                                                          into her inventory first
--                                                          (task_pool_steps.swap_at_target)
--   {type="insert", x=, y=, entity=NAME, item=NAME, count=N}
--                                                       -> N into the entity of that name
--                                                          (a fuel chest -- the upkeep's;
--                                                          task_pool_steps.run_insert)
--   {type="take", x=, y=, entity=NAME, item=NAME, count=N}
--                                                       -> up to N out of the chest of
--                                                          that name (the upkeep's
--                                                          coal store; run_take)
--   {type="fill", x=, y=, item=NAME, count=N}            -> up to N of what she holds into
--                                                          the entity closest to (x, y)
--                                                          (fac_building_fill's load;
--                                                          run_fill) -- its result
--                                                          {inserted, item, into} in the
--                                                          task's step_results
--   {type="take_out", x=, y=, item=NAME, count=N}        -> up to N out of the entity
--                                                          closest to (x, y): chest,
--                                                          crafter output, fuel
--                                                          (fac_building_empty's take;
--                                                          run_take_out) -- {extracted,
--                                                          item} in step_results
--   {type="read_drop_position", which=/x,y/ref=, entity=NAME, save_as=NAME}
--                                                       -> ctx.saved[save_as]
--   {type="ensure_item", item=NAME, count=N}            -> gathers/crafts NAME
--                                                          up to N in inventory
--                                                          BEFORE the next step
--     options: no_pull=true (no chest within 5 tiles is emptied first -- mining
--     only), raw=true (N counts all she holds of NAME, not what other tasks
--     have not reserved) -- both the upkeep's getting material
-- Any step: optional=true -- when it fails, its error goes into the task's step_errors
-- and the task goes on with the next step (task_pool_ledger.step_failed).
-- The hand steps (remove, fuel, insert, take, fill, take_out) act only within her reach.
--
-- ensure_item (2026-07-17, Zdendys's own architecture correction: procurement was
-- kept OUT of this module by the ORIGINAL v1 design above, back when neither
-- recipe resolution nor a hand-craftable check existed anywhere in this repo --
-- both now do (resolve_recipe/HAND_CRAFTABLE_CATEGORIES below, mirroring
-- companion.py's get_recipe_ingredients; queues.start_gather/start_craft), so
-- there is no longer a reason to keep this Python's job). Recursively resolves
-- missing INGREDIENTS first (bottom-up, exactly like ColdStartOpening.ensure_item,
-- spatial_demo.py) via an explicit stack in ctx.ensure_stack, bounded to depth
-- ENSURE_ITEM_MAX_DEPTH -- a raw/minable resource (no recipe) is gathered via the
-- existing gather_queues machinery, a non-hand-craftable recipe (smelting) fails
-- fast instead of wasting a doomed start_craft attempt, and wood (no
-- gather()-compatible resource-tile path -- trees are type="tree", not
-- type="resource") is chopped via its own small bounded walk+mine sub-state.
-- Should normally be the FIRST step of a task whose later place/fuel steps
-- consume the same item, so the whole task is self-sufficient once submitted.
--
-- find_existing (2026-07-07, furnace-upgrade task): locates an ALREADY-PLACED
-- entity by name nearest the companion's CURRENT position (radius search, no
-- ore/resource patch involved) and sets ctx.px/py to it -- for a task that
-- upgrades something already built (e.g. adding a drill next to a lone
-- bootstrap furnace, Zdendys: "it's the same as building a new pair, but the
-- furnace is already there, just add a drill to it") rather than starting from a raw
-- resource tile like find_patch does.
--
-- pick_orientation's primary_exists (2026-07-07, furnace-upgrade task): when
-- true, the primary (at ctx.px/py, e.g. an EXISTING furnace from find_existing)
-- is NOT can_place_entity-checked or re-placed -- it's already there. Only the
-- secondary's (e.g. a NEW drill's) candidate offset is checked/placed. Pairs
-- with secondary_resource=NAME to ALSO require that offset tile actually have
-- that resource underneath (a drill next to an existing furnace still needs
-- REAL ore there, same as run_verify_tile checks for the primary elsewhere) --
-- without this a candidate could pass can_place_entity yet sit on bare ground.
--
-- pick_orientation's ignore_entities_at (2026-07-07, coal_pair v1->v2 upgrade safety
-- fix): for an UPGRADE task that will "remove" existing entities and rebuild wider at
-- the SAME anchor, checking the wider candidates BEFORE removing anything can suffer
-- FALSE rejections (the still-present old entities' collision boxes can overlap a
-- wider candidate's footprint). Pass the old entities' known {x=,y=} positions here --
-- they get teleported far away, checked, and teleported back, all within this single
-- call (no player-visible flicker, no tick where they're actually gone) -- letting the
-- caller verify a rebuild position is valid BEFORE ever issuing a "remove" step, so a
-- failed pick_orientation never leaves a working setup mid-demolished.
--
-- Every place/fuel/remove/read_drop_position step resolves ITS OWN target
-- position the SAME way (step_target_pos), trying in order: explicit {x=,y=}
-- (caller precomputed it) > candidates[1] (nominal walking target only -- see
-- "place"'s own candidates note for actual placement resolution) > {ref=NAME}
-- (a position an earlier read_drop_position step in THIS task saved under that
-- name) > which="primary"|"secondary" (ctx.px/py or ctx.sx/sy, from find_patch/
-- pick_orientation earlier in this task).
--
-- "place"'s candidates (2026-07-07, live-caught TWICE across separate runs: a
-- single precomputed position -- e.g. an inserter placed exactly 1 tile from a
-- chest's read_drop_position -- can intermittently fail with "Cannot place
-- (collision)" from sub-tile snap variance at that specific spot, even though
-- the SAME code succeeds on a different map). An optional list of {x=,y=,dir=}
-- alternatives lets the caller offer a few nearby fallback spots; the FIRST one
-- that passes can_place_entity at "acting" time is used -- mirrors
-- pick_orientation's own try-candidates-in-order robustness, applied to a
-- single free-standing placement instead of a primary/secondary pair.
--
-- read_drop_position (2026-07-07, coal_pair upgrade task) reads an entity's LIVE
-- LuaEntity.drop_position -- the engine's own already-rotated absolute output
-- position -- rather than reimplementing vector_to_place_result rotation math on
-- the Python side (a real, verified-via-doc field; deliberately not guessed).
-- Lets a task place a chest/container exactly where an EXISTING drill's mined
-- output actually lands, whatever direction that drill happens to face.
--
-- "place" also accepts an explicit simple-0-3 `dir` (bypassing ctx.dir/dir2,
-- which only exist when a pick_orientation step ran earlier in this task) --
-- needed when the caller precomputed the whole layout itself with no
-- pick_orientation step at all.

local u = require("commands.init")
local queues = require("commands.queues")
local ledger = require("commands.task_pool_ledger")
local ensure_item = require("commands.task_pool_ensure_item")
local targeting = require("commands.task_pool_targeting")
local steps = require("commands.task_pool_steps")
local priority = require("commands.priority")
local requests = require("commands.controller_requests")
local picklog = require("commands.task_pool_pick_log")
local activity = require("commands.activity")
local entity_at = require("commands.entity_at")
local machine_steps = require("commands.task_pool_machine_steps")

-- the steps that act on their target by hand, only within her reach (the acting state)
local REACH_STEPS = {remove = true, fuel = true, insert = true, take = true, fill = true,
                     take_out = true}

local M = {}

local FUEL_REACH = 3      -- mirrors fac_building_fuel's own radius (building.lua)
local step_target_pos = targeting.step_target_pos
local task_ready = targeting.task_ready
local run_read_drop_position = steps.run_read_drop_position
local run_find_existing = steps.run_find_existing
local run_set_position = steps.run_set_position
local run_find_patch = steps.run_find_patch
local run_verify_tile = steps.run_verify_tile
local run_pick_orientation = steps.run_pick_orientation
local run_insert = steps.run_insert
local run_take = steps.run_take

-- ensure_item step (2026-07-17, Zdendys's own architecture correction -- see
-- task_pool_ensure_item.lua's own header for the full design/history): the
-- {type="ensure_item", item=NAME, count=N} step's actual recipe-resolution/
-- gather/craft/chop engine moved there in the 2026-07-19 size-refactor split
-- (this file only dispatches to ensure_item.start_ensure_item_action below and
-- handles the resulting "gather"/"craft"/"chop" async polling itself, since that
-- polling is scheduler state, not procurement logic).
local WOOD_CHOP_REACH = 3           -- mirrors fac_mine_entity's own distance<=15 check loosely; close enough to swing
                                     -- (sole remaining use: the "chop" dispatch below, in M.tick)

function M.init()
  storage.tasks = storage.tasks or {}
  storage.next_task_id = storage.next_task_id or 1
  storage.reserved = storage.reserved or {}
  -- storage.active_step[cid] = {task_id=, state="walking"|"acting"} -- at most ONE step
  -- in flight per companion at a time (single physical entity, can only do one thing).
  storage.active_step = storage.active_step or {}
end

-- ---- needs derivation + reservation ledger ----
-- Moved to task_pool_ledger.lua (2026-07-12 size-refactor split): derive_needs,
-- fail_task, complete_task, M.submit_task, M.get_task_status now live there --
-- see that file for the full historical-rationale comments attached to each.
-- Thin re-exports below so external callers (require("commands.task_pool").
-- submit_task/.get_task_status) keep working unchanged.
M.submit_task = ledger.submit_task
M.get_task_status = ledger.get_task_status

-- Withdraw a task its submitter no longer waits for (/fac_task_cancel: Python gave up
-- on it -- left in the pool, it would still run later, unseen). Status "cancelled",
-- its reservations released (ledger.cancel_task); when it is her current step, the
-- step is dropped: her walk to it stopped (the step's own walk, or its wood walk), a
-- build it started ended (no entity placed after the cancel). A gather or craft
-- queue a step started while ensuring an item ends by itself, with its own walk, as
-- for the upkeep's cancellations (independent review: stopping that walk made the
-- gather blacklist a reachable tile). Returns {cancelled = true} or
-- {cancelled = false, status | error}.
function M.cancel_task(task_id)
  local t = storage.tasks[task_id]
  if not t then return {cancelled = false, error = "no task " .. tostring(task_id)} end
  if t.status ~= "active" then return {cancelled = false, status = t.status} end
  local active = storage.active_step[t.cid]
  if active and active.task_id == task_id then
    storage.active_step[t.cid] = nil
    local own_walk = active.state == "walking" or active.state == "building"
      or (active.state == "ensuring" and active.ensuring_kind == "chop_walk")
    if active.state == "building" then storage.build_queues[t.cid] = nil end
    if own_walk then
      storage.walking_queues[t.cid] = nil
      local c = u.get_companion(t.cid)
      if c then c.entity.walking_state = {walking = false} end
    end
  end
  ledger.cancel_task(task_id, "cancelled by its submitter")
  return {cancelled = true}
end

-- step_target_pos/task_ready moved to task_pool_targeting.lua (2026-07-19
-- size-refactor split) -- see local aliases above (targeting.step_target_pos/
-- task_ready; the walk's end: targeting.step_reach).

-- The 6 run_* synchronous step handlers (read_drop_position/find_existing/
-- set_position/find_patch/verify_tile/pick_orientation) + their private
-- clear_natural_obstacles/restore_moved/run_pick_orientation_checks helpers
-- moved to task_pool_steps.lua (2026-07-19 size-refactor split) -- see local
-- aliases above.

-- ---- main scheduler tick ----

-- Picks the single best (task, step) to advance right now: among all ACTIVE, READY
-- tasks whose companion is currently IDLE, the one whose current step has the highest
-- priority raised by nearness (commands/priority.lua: p ^ (1 / (distance + 1)), p the
-- task's base priority by its kind -- build < relocate < dismantle, Zdendys); ties
-- broken by task_id (older task wins -- Zdendys: "stari kroku odpovida cca poradi
-- taskID"). With every task of one kind this is the nearest step, as before.
-- Every task's priority ages (priority.aged: times log2 of the ticks since it was
-- given -- Zdendys: every command and task), and the controller's pending direct
-- command competes on the same scale (controller_requests.lua: never refused, queued
-- while a step holds her) -- picked, it is started instead of a step (M.CONTROLLER).
M.CONTROLLER = "controller"

-- A task's current step's effective priority from where she stands.
local function task_eff(t, c)
  local step = t.steps[t.cursor]
  local pos = step_target_pos(t, step)
  local dist = pos and u.distance(c.entity.position, pos) or 0  -- instant steps: distance 0
  -- (a task from an older save has no priority: a build's)
  local p = priority.aged(t.priority or priority.base(priority.DEFAULT_KIND), t.created_tick)
  return priority.effective(p, dist)
end

-- (task_id or M.CONTROLLER, its effective priority, its position) of the best step, or nil.
-- `record`: the idle dispatch's pick -- written to the pick log when that is on
-- (task_pool_pick_log.lua; not the walk takeover's checks every PREEMPT_CHECK_TICKS)
local function pick_next(cid, c, record)
  local best_task_id, best_eff, best_pos = nil, -math.huge, nil
  local cands = record and picklog.enabled() and {} or nil
  for task_id, t in pairs(storage.tasks) do
    if t.cid == cid and t.status == "active" and task_ready(t) and t.cursor <= #t.steps then
      local eff = task_eff(t, c)
      if cands then
        local pos = step_target_pos(t, t.steps[t.cursor])
        cands[#cands + 1] = {id = task_id, kind = t.kind, p = t.priority or 0,
                             age = game.tick - (t.created_tick or game.tick),
                             d = pos and u.distance(c.entity.position, pos) or 0, eff = eff}
      end
      if eff > best_eff or (eff == best_eff and (not best_task_id or task_id < best_task_id)) then
        best_task_id, best_eff = task_id, eff
        best_pos = step_target_pos(t, t.steps[t.cursor])
      end
    end
  end
  local req_eff, req_pos = requests.effective(cid, c)
  local chosen = best_task_id
  if req_eff and req_eff >= best_eff then       -- (a tie: the controller's command)
    chosen, best_eff, best_pos = M.CONTROLLER, req_eff, req_pos
  end
  if cands then
    local r = requests.pending(cid)
    if r then
      cands[#cands + 1] = {id = M.CONTROLLER, kind = r.kind,
                           p = priority.base(priority.DEFAULT_KIND), age = game.tick - r.tick,
                           d = r.pos and u.distance(c.entity.position, r.pos) or 0,
                           eff = req_eff}
    end
    if #cands > 0 then picklog.write(cid, chosen, cands) end
  end
  return chosen, best_eff, best_pos
end

-- While she walks to a step, the choice is re-evaluated every PREEMPT_CHECK_TICKS from
-- where she stands (factorio-ai docs/architecture_roles.md, Zdendys: the queue changes
-- its order dynamically by the priorities): a step whose effective priority beats the
-- walked-to one's by PREEMPT_MARGIN times takes over -- the walk is dropped, the walked-to
-- task keeps its place (its cursor), the next pick starts the better one. A step being
-- acted on is never preempted. (the margin: no flapping between two near equals)
local PREEMPT_CHECK_TICKS = 60
local PREEMPT_MARGIN = 1.05

-- Whether the walk of `active` (task t, its step) gives way to a better step now -- only
-- a step with a position of its own (review: a position-less step counts as distance 0,
-- its full priority -- an ensure_item / the coal fetch's mining, whose gather walks far
-- itself, would drop every walk; it waits for her to be free, as before).
local function walk_preempted(cid, c, active, t)
  local best_id, best_eff, best_pos = pick_next(cid, c)
  if not best_id or best_id == active.task_id or not best_pos then return false end
  return best_eff > task_eff(t, c) * PREEMPT_MARGIN
end

-- Re-check every active task's outstanding `needs` against CURRENT inventory
-- (2026-07-07, live-caught in scripts/test_task_pool.py: a task submitted before
-- its coal arrived stayed stuck on cursor 1 forever -- `needs` was computed ONCE
-- at submit_task time and nothing ever refreshed it afterward, even though the
-- whole point of submitting ahead of having materials is that something else
-- -- gather_queues, another task's own by-product, a later delivery -- can supply
-- them in the meantime). Iterates tasks in task_id order (oldest first) so an
-- older task claims newly-available stock before a younger one, consistent with
-- the pool's own task_id tiebreak elsewhere.
--
-- ONLY does this work for companions whose inventory actually CHANGED since the
-- last tick (2026-07-07, Zdendys: "Ono neni jakym jinym zpusobem, bez zasahu
-- companiona samotneho, by doslo ke zmene stavu jeho inventare!" -- correct,
-- inventory only ever changes as a result of the companion's OWN actions
-- (mining/crafting/fueling/collecting), so polling get_item_count for every
-- outstanding need on EVERY tick regardless was wasted work on every tick where
-- nothing could possibly have changed. storage.inv_count_cache[cid] tracks the
-- last-seen total item count per companion; a plain sum is enough to detect ANY
-- change cheaply without needing to hook into every individual queue type's own
-- completion point (harvest/gather/craft/fuel/build each add or remove items in
-- their own way -- comparing the total sidesteps enumerating all of them).
-- TASK_NEEDS_UNMET_GIVEUP_TICKS (2026-07-29, ep106 discard investigation): a task
-- whose needs are STILL unmet after this many ticks since submission is failed
-- explicitly, instead of sitting in storage.tasks forever with active_step[cid]
-- never set. This is a deliberate, bounded DEPARTURE from this module's own
-- documented v1 design above ("a task with unmet needs just stays blocked...
-- something ELSE is expected to top that up") -- that design has no give-up of
-- its own, and pick_next() (below) only ever considers task_ready() tasks, so a
-- task whose one missing item never actually arrives (crafted under a different
-- name, consumed by a concurrent task, or simply never provisioned) never gets a
-- chance to hit ANY of queues_build.lua's own bounded per-step deadlines --
-- those only start counting once a step is actually scheduled as active, which
-- never happens while task_ready() is false. Live-caught: power_plant's pump
-- "place" step (a single-item need, no ensure_item precondition of its own)
-- stalled this way for a full episode; the ONLY thing that eventually recovered
-- it was power_plant_dispatch.py's own outer POWER_PLANT_STAGE_DEADLINE_TICKS=
-- 18000 blind timeout, burning a full 300s per shore attempt before the 3-strikes
-- budget (_abort_power_build_failed_3x) was exhausted mid-episode.
-- Set well below every established *_STAGE_DEADLINE_TICKS=18000 convention in
-- this project's Python side, so a genuinely-stuck task gets a fast, explicit
-- "failed" status well within that outer deadline's own window -- Python's
-- existing st.get("status")=="failed" checks (already present at every stage
-- poll site, e.g. power_plant_dispatch.py's pump-stage branch) then react almost
-- immediately instead of waiting out the blind timeout, leaving MORE of the same
-- outer retry budget usable within one episode. Still generous relative to any
-- legitimate procurement wait actually in progress (gather_queues/craft_queues
-- deliveries typically resolve in low thousands of ticks when genuinely working;
-- a task with a truly active supplier is not the case this guards against --
-- see the reservation_epoch mechanism just below, which re-evaluates needs the
-- moment ANY inventory change makes them satisfiable, well before this ceiling).
local TASK_NEEDS_UNMET_GIVEUP_TICKS = 6000  -- 100 game-seconds @ 60 ticks/s

local function refresh_needs()
  local ids = {}
  for task_id, t in pairs(storage.tasks) do
    if t.status == "active" and next(t.needs) ~= nil then ids[#ids + 1] = task_id end
  end
  if #ids == 0 then return end
  table.sort(ids)
  for _, task_id in ipairs(ids) do
    local t = storage.tasks[task_id]
    if t.created_tick and game.tick - t.created_tick >= TASK_NEEDS_UNMET_GIVEUP_TICKS then
      local missing = {}
      for item, deficit in pairs(t.needs) do
        missing[#missing + 1] = item .. "x" .. deficit
      end
      ledger.fail_task(task_id, "needs never satisfied within "
        .. TASK_NEEDS_UNMET_GIVEUP_TICKS .. " ticks: " .. table.concat(missing, ","))
    end
  end
  -- Re-fetch: any task failed just above must be excluded from the reservation
  -- work below (release_reservations already cleared its t.reserved/t.needs,
  -- but it may still be in `ids` from the snapshot taken above).
  local ids2 = {}
  for _, task_id in ipairs(ids) do
    local t = storage.tasks[task_id]
    if t.status == "active" then ids2[#ids2 + 1] = task_id end
  end
  ids = ids2
  if #ids == 0 then return end
  storage.inv_count_cache = storage.inv_count_cache or {}
  -- reservation_epoch check (2026-07-09, see release_reservations' own comment for the
  -- full live-caught symptom): a task's needs must be re-evaluated not just when ITS
  -- OWN companion's inventory total changes, but also whenever ANY task anywhere
  -- released a reservation -- that release alone can be exactly what makes previously
  -- unavailable stock available now, with zero accompanying inventory-total change
  -- for THIS companion. epoch_changed is true at most once per actual release (cheap),
  -- and forces the full inv-count-mismatch bypass below for every pending task this
  -- call, exactly once.
  local epoch = storage.reservation_epoch or 0
  local epoch_changed = (storage.last_seen_reservation_epoch or -1) ~= epoch
  storage.last_seen_reservation_epoch = epoch
  for _, task_id in ipairs(ids) do
    local t = storage.tasks[task_id]
    local c = u.get_companion(t.cid)
    if c then
      local inv = c.entity.get_main_inventory()
      local total = inv.get_item_count()
      if storage.inv_count_cache[t.cid] ~= total or epoch_changed then
        storage.inv_count_cache[t.cid] = total
        for item, deficit in pairs(t.needs) do
          local have = inv.get_item_count(item)
          local already_reserved = storage.reserved[item] or 0
          local available = math.max(0, have - already_reserved)
          local take = math.min(available, deficit)
          if take > 0 then
            storage.reserved[item] = already_reserved + take
            t.reserved[item] = (t.reserved[item] or 0) + take
            if take >= deficit then
              t.needs[item] = nil
            else
              t.needs[item] = deficit - take
            end
          end
        end
      end
    end
  end
end

-- an ended gather / build entry ("done" / "failed") keeps holding the pool this long
-- after its job ended -- its caller's status poll has time to read the result before a
-- pool step's start_gather / start_build would overwrite it (review); after that it
-- holds nothing (live: a gather whose status nobody read -- its caller had given up --
-- blocked every task until the next gather). At least ENDED_GRACE_TICKS, and about
-- ENDED_GRACE_REAL_S of real time at a high game speed (60 ticks a second x speed).
local ENDED_GRACE_TICKS = 600
local ENDED_GRACE_REAL_S = 1

-- Whether a queue entry holds the pool: running, or -- `grace` set: a queue whose
-- result a pool step could overwrite -- ended within the read window (an entry without
-- run_end_tick, an older save, holds only while running).
local function holds_pool(q, grace)
  if activity.running(q) then return true end
  if not grace or type(q) ~= "table" or q.run_end_tick == nil then return false end
  local window = math.max(ENDED_GRACE_TICKS, 60 * ENDED_GRACE_REAL_S * game.speed)
  return game.tick - q.run_end_tick < window
end

-- 2026-07-08, task #42: true if cid is busy in gather/fuel/build/belt_queues (see the
-- "Extended" comment at this function's call site below for the full rationale) --
-- holds_pool: a running entry; a gather / build one also within its read window (the
-- pool starts gathers and builds itself, never fuel or belt jobs).
local function busy_elsewhere(cid)
  return holds_pool(storage.gather_queues and storage.gather_queues[cid], true)
      or holds_pool(storage.fuel_queues and storage.fuel_queues[cid], false)
      or holds_pool(storage.build_queues and storage.build_queues[cid], true)
      or holds_pool(storage.belt_queues and storage.belt_queues[cid], false)
      -- (an attack the controller's queued request started -- controller_requests.lua)
      or (storage.combat_queues and storage.combat_queues[cid]) ~= nil
end

function M.tick()
  refresh_needs()
  for cid, active in pairs(storage.active_step) do
    local c = u.get_companion(cid)
    if not c then storage.active_step[cid] = nil; goto continue end
    local t = storage.tasks[active.task_id]
    if not t or t.status ~= "active" then storage.active_step[cid] = nil; goto continue end
    local step = t.steps[t.cursor]

    if active.state == "walking" then
      local walk_pos = step_target_pos(t, step)
      if not storage.walking_queues[cid] then
        -- Arrived (or walking_queue was never set for a non-walk step) -> act.
        active.state = "acting"
      elseif walk_pos and u.distance(c.entity.position, walk_pos)
                          <= targeting.step_reach(c.entity, step) then
        -- within the step's reach (targeting.step_reach: a build, take, fill or empty
        -- reaches 10 tiles): no need to come closer -- an enclosed burner's centre was
        -- never reached, the walk timed out 2.5 tiles from it
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        active.state = "acting"
      elseif active.approach_deadline and game.tick >= active.approach_deadline then
        -- Bounded give-up (2026-07-08/09, task-pool's OWN walking phase previously had
        -- NO deadline at all -- see the dispatch site's own comment for the live
        -- symptom this caused). Mirrors queues.lua's identical "cannot reach -> fail
        -- and let the caller retry/relocate" pattern instead of spinning forever.
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        ledger.step_failed(active.task_id, "could not reach step target (walking timed out)", active.step_start_tick)
        storage.active_step[cid] = nil
        goto continue
      elseif game.tick % PREEMPT_CHECK_TICKS == 0 and walk_preempted(cid, c, active, t) then
        -- a better step takes over (walk_preempted): the walk dropped, the task keeps its
        -- cursor; the idle pick below starts the better one this same tick
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        storage.active_step[cid] = nil
        storage.walk_preempts = storage.walk_preempts or {}
        storage.walk_preempts[cid] = (storage.walk_preempts[cid] or 0) + 1
        goto continue
      else
        goto continue  -- still walking, check again next tick
      end
    end

    if active.state == "acting" then
      local ok, err, result = true, nil, nil
      -- A step that acts on a target by hand (remove, fuel, insert, take, fill, take_out)
      -- acts only
      -- within her reach: the walk also ends when the walker gives it up (its queue
      -- dropped -- an entity across water), and the step would then reach from any
      -- distance (independent review: a pick-up mined from tens of tiles away). Out
      -- of reach it fails "Too far", as fac_building_remove does.
      local reach_pos = REACH_STEPS[step.type] and step_target_pos(t, step)
      local too_far = reach_pos and u.distance(c.entity.position, reach_pos)
                                    > targeting.step_reach(c.entity, step)
      if too_far then
        ok, err = false, string.format("Too far: %s target (%.1f,%.1f) is %.1f tiles from her",
                                       step.type, reach_pos.x, reach_pos.y,
                                       u.distance(c.entity.position, reach_pos))
      elseif step.type == "place" then
        -- Handled entirely inline (not via the generic ok/err fall-through below,
        -- see the bug note there): start_build's OWN failure is reported
        -- immediately (queues.start_build never queues anything in that case, so
        -- there is no later "building" state to catch it) -- fail_task here or the
        -- task would sit stuck in "acting" forever with active_step never cleared.
        local pos = step_target_pos(t, step)
        -- Explicit step.dir (simple 0-3, 2026-07-07 coal_pair upgrade) overrides
        -- ctx.dir/dir2 when the caller precomputed the whole layout itself (no
        -- pick_orientation step at all for this task) -- translated the SAME way
        -- pick_orientation does, so callers use the identical simple convention.
        local place_dir
        if step.dir ~= nil then
          place_dir = u.dir_map[step.dir]
        else
          place_dir = (step.which == "secondary" and t.ctx.dir2) or t.ctx.dir or 0
        end
        -- candidates (2026-07-07, live-caught): a SINGLE precomputed {x,y,dir}
        -- position (e.g. an inserter placed 1 tile from a chest read via
        -- read_drop_position) can intermittently collide -- observed twice
        -- across separate live runs with the EXACT same code on different maps
        -- (sub-tile snap variance at that specific spot, not a logic bug). An
        -- optional list of {x=,y=,dir=} alternatives lets the caller offer a
        -- few nearby fallback spots; the FIRST one that passes can_place_entity
        -- is used, mirroring pick_orientation's own try-candidates-in-order
        -- robustness instead of committing to one fixed spot with no recourse.
        if step.candidates then
          local surf = c.entity.surface
          local chosen = nil
          for _, cand in ipairs(step.candidates) do
            local cdir = u.dir_map[cand.dir or 0]
            if surf.can_place_entity{name = step.entity, position = {x = cand.x, y = cand.y}, direction = cdir, force = c.entity.force, mirror = step.mirror} then
              chosen = {x = cand.x, y = cand.y, dir = cdir}
              break
            end
          end
          if not chosen and not active.candidates_cleared then
            -- CLEAR FIRST, like a player would (2026-11-05, live-caught: a coal pair's
            -- 2nd criss-cross inserter failed "no candidate position free" 3x on the only
            -- free gap tile; Zdendys placed it by hand later without trouble). A lying
            -- item-entity, a tree or a rock blocks can_place_entity (live A/B test
            -- 2026-07-27, see queues_build.lua's clear_build_area) -- start_build clears
            -- those from the footprint, but this pre-check ran BEFORE start_build ever
            -- got the chance. Clear each candidate's footprint once (mined into the
            -- companion's inventory, never destroyed) when it is within build reach,
            -- then re-check on the next tick.
            active.candidates_cleared = true
            local inv = c.entity.get_main_inventory()
            local reach = c.entity.build_distance or 10
            for _, cand in ipairs(step.candidates) do
              if u.distance(c.entity.position, cand) <= reach then
                queues.clear_build_area(surf, step.entity, {x = cand.x, y = cand.y}, inv,
                                        u.dir_map[cand.dir or 0])
              end
            end
            goto continue
          end
          if not chosen then
            -- Bounded retry across ticks (2026-07-08, task #35) instead of failing on
            -- the FIRST check: live-observed "no candidate position free" 3x across
            -- separate runs with the exact same code on different maps, leading
            -- hypothesis being a transient/settling-timing collision (sub-tile snap
            -- variance, or a moment where something else briefly occupies the tile)
            -- rather than a genuine permanent block. can_place_entity is re-evaluated
            -- fresh every tick (no caching here), so simply trying again on a LATER
            -- tick gives a transient blocker a real chance to clear before giving up
            -- -- same "bounded deadline, not instant give-up" pattern already used for
            -- approach_deadline elsewhere in this file. 60 ticks is deliberately short
            -- (this is meant to catch a passing moment, not wait out a real block) --
            -- a genuinely permanent collision still correctly fails, just after a
            -- few retries instead of zero.
            active.candidate_retry_deadline = active.candidate_retry_deadline or (game.tick + 60)
            if game.tick < active.candidate_retry_deadline then
              goto continue
            end
            ledger.step_failed(active.task_id, "no candidate position free for " .. step.entity, active.step_start_tick)
            storage.active_step[cid] = nil
            goto continue
          end
          pos, place_dir = {x = chosen.x, y = chosen.y}, chosen.dir
        end
        local r = queues.start_build(cid, step.entity, pos, place_dir, step.mirror)
        if r.error then
          ledger.step_failed(active.task_id, r.error, active.step_start_tick)
          storage.active_step[cid] = nil
        else
          -- Poll build_queues to completion via the SEPARATE "building" state
          -- below (own stale-progress backstop, same as every other queue type).
          active.state = "building"
        end
      elseif step.type == "ensure_item" then
        -- Handled entirely inline, like "place" above (see this step type's own
        -- header comment, near WOOD_CHOP_REACH, for the full design). Genuinely
        -- async (gather/craft/chop can each take many ticks) -- excluded from the
        -- generic ok/err fall-through below the same way "place" is.
        -- (no_pull / raw: the step's options, task_pool_ensure_item.lua)
        t.ctx.ensure_stack = t.ctx.ensure_stack or
          {{item = step.item, count = step.count, no_pull = step.no_pull, raw = step.raw}}
        local kind, err2 = ensure_item.start_ensure_item_action(c, cid, t)
        if kind == "satisfied" then
          table.remove(t.ctx.ensure_stack)
          if #t.ctx.ensure_stack == 0 then
            -- Reset to nil, not just an empty table (2026-07-17, live-caught crash:
            -- "attempt to index local 'need' (a nil value)" at start_ensure_item_action's
            -- own `local need = stack[#stack]`). t.ctx is shared across ALL steps of
            -- this task, and a task can have MULTIPLE ensure_item steps in a row (e.g.
            -- build_ore_drill_row_unit_steps' burner-mining-drill THEN stone-furnace,
            -- coal_pair.py). Leaving ensure_stack as `{}` here made line 866's own
            -- `t.ctx.ensure_stack or {...}` initializer a no-op for the NEXT ensure_item
            -- step -- an empty table is truthy in Lua -- so that step ran
            -- start_ensure_item_action against a permanently empty stack instead of
            -- pushing its own need, crashing every tick forever (active_step never
            -- cleared -> companion deadlocked for the rest of the episode).
            t.ctx.ensure_stack = nil
            -- Clear alongside ensure_stack (2026-07-27, same "shared across ALL
            -- steps of this task" reasoning as the comment above): without this,
            -- a stale expired deadline from an EARLIER ensure_item step could make
            -- a LATER step needing the SAME item name skip its own fresh 30s wait
            -- window entirely (see task_pool_ensure_item.lua's own SMELT_WAIT_TICKS
            -- docstring).
            t.ctx.smelt_wait_deadline = nil
            -- step_ticks (2026-07-28, action-timing instrumentation): recorded at
            -- every cursor advance, keyed by the PRE-increment cursor (the step
            -- that just finished) -- active.step_start_tick was stamped once when
            -- this step first entered active_step (see the 2 creation sites below),
            -- and survives the walking->acting sub-state transition untouched, so
            -- this captures the full wall-to-wall duration, not just the final
            -- sub-phase.
            t.step_ticks = t.step_ticks or {}
            t.step_ticks[t.cursor] = {type = step.type, start = active.step_start_tick, done = game.tick}
            t.cursor = t.cursor + 1
            storage.active_step[cid] = nil
            if t.cursor > #t.steps then ledger.complete_task(active.task_id) end
          end
          -- else: stay in "acting" this same tick's next pass (goto continue below
          -- falls through to end-of-loop; re-entering "acting" next tick reassesses
          -- the now-shorter stack) -- no state change needed, active.state is
          -- already "acting".
        elseif kind == "push" then
          -- A deeper ingredient need was pushed -- reassess next tick against the
          -- new top of stack, same as "satisfied"'s implicit re-entry above.
        elseif kind == "wait" then
          -- Waiting on an already-running furnace to top up a smelted ingredient
          -- (2026-07-27, see task_pool_ensure_item.lua's own SMELT_WAIT_TICKS
          -- docstring) -- no state change, same as "push": reassess next tick
          -- until either the stock arrives (kind flips to "satisfied") or the
          -- bounded wait deadline passes (kind flips to a genuine failure).
        elseif kind == "gather" or kind == "craft" then
          active.state = "ensuring"
          active.ensuring_kind = kind
        elseif kind == "chop" then
          -- Skip the walk entirely if already close enough (mirrors "place"'s own
          -- distance check in the idle-dispatch loop below) -- go straight to
          -- chop_mine so a tree that happens to be right next to the companion
          -- doesn't pay for a pointless 1-tick walking_queue round trip.
          if u.distance(c.entity.position, t.ctx.wood_target) <= WOOD_CHOP_REACH then
            active.state = "ensuring"
            active.ensuring_kind = "chop_mine"
          else
            storage.walking_queues[cid] = {target = t.ctx.wood_target}
            active.state = "ensuring"
            active.ensuring_kind = "chop_walk"
            active.chop_deadline = u.approach_deadline(c.entity.position, t.ctx.wood_target)
          end
        else
          ledger.step_failed(active.task_id, err2 or "ensure_item failed", active.step_start_tick)
          storage.active_step[cid] = nil
        end
      elseif step.type == "remove" then
        -- Pick up an existing entity (2026-07-07, coal_pair upgrade task: reuses
        -- the 2 ALREADY-BUILT coal_pair drills rather than crafting new ones --
        -- Zdendys: "zvedne obe vrtacky, nemusi je vyrabet"). Native mine into her
        -- inventory (entity_at.mine_into: done only when mine{} succeeds and the
        -- entity is gone -- mine{} leaves it INTACT if her inventory can't hold it,
        -- no silent item loss, no cheat).
        -- The entity is the one the position means (entity_at.find: the nearest of
        -- that name and force, on it -- not the first found, a neighbour of the same
        -- name could be mined; the same pick as fac_building_remove). An unresolved
        -- position fails the step cleanly (the fuel step's nil-pos wedge below).
        local pos = step_target_pos(t, step)
        local target = pos and entity_at.find(c.entity.surface, step.entity, pos,
                                              c.entity.force)
        if not pos then
          ok, err = false, "remove: no target position resolved"
        elseif not target then
          -- "Not found" first, as fac_building_remove's: a caller tells a part already
          -- gone from a real failure by it (CompanionAPI.pick_up)
          ok, err = false, "Not found: no " .. step.entity .. " at the target"
        else
          ok, err = entity_at.mine_into(c, target)
        end
      elseif step.type == "fuel" then
        local pos = step_target_pos(t, step)
        local inv = c.entity.get_main_inventory()
        local have = inv.get_item_count(step.item)
        -- NIL-POS CRASH (2026-07-28, live-caught: this exact step permanently wedged
        -- storage.active_step[cid] for the rest of a live episode -- `pos` reaching
        -- here nil, then flowing unguarded into the table.sort comparator added by
        -- THIS SAME NIGHT's nearest-first fix a few hours earlier, crashed every ~5
        -- ticks forever with "attempt to index local 'b' (a nil value)" inside
        -- init.lua's M.distance -- the crash happened BEFORE ok/err was ever
        -- assigned, so the cursor-advance/active_step-release cleanup below never
        -- ran, and go_to()/move_to() (companion.py) reject EVERY subsequent walk
        -- request while active_step[cid] stays set -- explaining why "could not
        -- reach drill" then appeared at many UNRELATED iron/copper positions: the
        -- failure had nothing to do with any specific target, the companion was
        -- simply locked. step_target_pos() legitimately returns nil (see its own
        -- docstring, task_pool_targeting.lua) whenever a step's ctx position isn't
        -- resolved yet -- pick_next() (this file, ~line 190) already guards this
        -- exact case (`pos and u.distance(...) or 0`); this step never got the same
        -- guard. Fail the step cleanly instead of touching pos at all -- matches
        -- this function's own established "ok, err = false, ..." convention used
        -- for every other unresolvable-step case just below.
        if not pos then
          ok, err = false, "fuel: no target position resolved"
        elseif have == 0 then
          ok, err = false, "no " .. step.item .. " in inventory"
        else
          -- TYPE-FILTER BUG (2026-07-28, live-caught: belt-row-tap iron-output-
          -- inserter refuel stuck at "still starved" for 790+ consecutive cycles
          -- despite "topped up unit" logging success every time): "burner-inserter"
          -- is an entity NAME, not a `type` -- Factorio 2.0's real `type` value for
          -- every inserter (burner/fast/long-handed/etc) is "inserter". Using the
          -- name here in a `type=` filter matched ZERO inserters, always, silently
          -- -- live-reproduced via RCON: the identical query at the iron-output-
          -- inserter's own position (radius=3) returned only nearby furnaces/drills,
          -- never the inserter itself even at distance 0. Fixed to the real type;
          -- the `if fi then` check right below already skips non-burner inserters
          -- (no fuel_inventory), so widening to all "inserter"-type entities is safe.
          local es = c.entity.surface.find_entities_filtered{
            position = pos, radius = FUEL_REACH,
            type = {"furnace", "boiler", "inserter", "mining-drill"}}
          -- NEAREST-FIRST BUG (2026-07-28, live-caught during coal-row-refuel discard-
          -- pause investigation, episode 69): find_entities_filtered's return order is
          -- NOT distance-sorted (engine-internal order, observed live: a burner-inserter
          -- 1.58 tiles away was returned BEFORE the actual target burner-mining-drill
          -- sitting AT `pos`, distance 0). The delivery loop below spends `remaining`
          -- (the whole step.count budget) on whichever entity it reaches FIRST -- live-
          -- confirmed at (-55,-7): every refuel call handed its entire 10-coal budget to
          -- the row's own local fuel-inserter (room for 45 more, so it absorbed all 10
          -- every time) and the drill AT the query position never received any, despite
          -- the caller (_build_coal_row_refuel, belt_connect_ops.py) walking the
          -- companion to the drill's own exact position and issuing the fuel step
          -- targeted there -- 29+ consecutive low-fuel reads on the drill while its own
          -- neighbor inserter looked "fed". Same root class the mod's OTHER fuel queue
          -- (queues_fuel.lua's find_next_burner) already guards against via its own
          -- explicit table.sort by distance -- this step never got that same sort.
          -- Sorting nearest-to-`pos` first guarantees the entity the caller actually
          -- meant to target gets first claim on the budget; any leftover still spills
          -- over to a genuinely-nearby neighbor exactly as before.
          table.sort(es, function(a, b)
            return u.distance(a.position, pos) < u.distance(b.position, pos)
          end)
          if #es == 0 then
            ok, err = false, "no burner near target"
          else
            local remaining = step.count or 1
            local delivered = 0
            -- swap: the target's other fuel (wood) into her inventory first, so the
            -- item fits it (task_pool_steps.swap_at_target) -- only at her own burner AT
            -- the position; one she cannot empty fails the step, no item handed to
            -- its neighbours (review: they took the whole budget, the step "done")
            local swap_err = steps.swap_at_target(c, step, es[1], pos)
            if swap_err then es = {} end
            for _, e in ipairs(es) do
              if remaining <= 0 then break end
              local fi = e.get_fuel_inventory()
              if fi then
                local n = math.min(remaining, have)
                local inserted = fi.insert({name = step.item, count = n})
                if inserted > 0 then
                  c.entity.remove_item({name = step.item, count = inserted})
                  remaining = remaining - inserted
                  have = have - inserted
                  delivered = delivered + inserted
                end
              end
            end
            -- FALSE-SUCCESS BUG (2026-07-28, same live incident): `ok` was never
            -- set in this branch once `es` was non-empty, so a cycle where every
            -- nearby burner already had a full fuel inventory (confirmed live: all
            -- 4 furnaces/drills sat at fuel=50/50 the whole stall) silently
            -- "succeeded" with delivered=0 -- the caller (_build_coal_row_refuel,
            -- belt_connect_ops.py) logged "topped up unit" every single attempt
            -- while the real fuel count never moved, hiding the failure completely.
            if swap_err then
              ok, err = false, swap_err
            elseif delivered == 0 then
              ok, err = false, "no burner nearby had room for " .. step.item
            else
              ledger.consume(t, step.item, delivered)   -- used up: out of the reservations
            end
          end
        end
      elseif step.type == "insert" then
        ok, err = run_insert(c, t, step)
      elseif step.type == "fill" then
        ok, err, result = machine_steps.run_fill(c, t, step)
      elseif step.type == "take_out" then
        ok, err, result = machine_steps.run_take_out(c, t, step)
      elseif step.type == "take" then
        ok, err = run_take(c, t, step)
      elseif step.type == "find_patch" then
        ok, err = run_find_patch(c, t, step)
      elseif step.type == "find_existing" then
        ok, err = run_find_existing(c, t, step)
      elseif step.type == "set_position" then
        ok, err = run_set_position(c, t, step)
      elseif step.type == "verify_tile" then
        ok, err = run_verify_tile(c, t, step)
      elseif step.type == "pick_orientation" then
        ok, err = run_pick_orientation(c, t, step)
      elseif step.type == "read_drop_position" then
        ok, err = run_read_drop_position(c, t, step)
      else
        ok, err = false, "unknown step type " .. tostring(step.type)
      end

      -- "place"/"ensure_item" are fully handled above (either resolved inline, or
      -- transitioned to their own separate polling state) -- every OTHER step
      -- type completes synchronously within this same tick, so their ok/err is
      -- resolved here.
      if step.type ~= "place" and step.type ~= "ensure_item" then
        if ok then
          -- step_ticks: see the "ensure_item" cursor-advance site above for the
          -- full rationale (same capture, same pre-increment cursor key).
          t.step_ticks = t.step_ticks or {}
          t.step_ticks[t.cursor] = {type = step.type, start = active.step_start_tick, done = game.tick}
          if result then
            -- what the step moved (a fill's {inserted, item, into}, a take_out's
            -- {extracted, item}), reported back:
            -- [{step = index, ...}] in fac_task_status step_results
            result.step = t.cursor
            t.step_results = t.step_results or {}
            t.step_results[#t.step_results + 1] = result
          end
          t.cursor = t.cursor + 1
          storage.active_step[cid] = nil
          if t.cursor > #t.steps then ledger.complete_task(active.task_id) end
        else
          ledger.step_failed(active.task_id, err, active.step_start_tick)
          storage.active_step[cid] = nil
        end
      end
    end

    if active.state == "building" then
      local st = queues.get_build_status(cid)
      if st.active then
        goto continue  -- still building, check again next tick
      elseif st.placed then
        -- Sync ctx to the REAL placed position (2026-07-07, live-caught): create_entity
        -- can snap a 2x2 entity to a different grid alignment than the 1x1 ore tile
        -- position find_patch recorded (observed: requested (46.5,-185.5), actually
        -- landed at (47,-185)). If this was the PRIMARY and a secondary offset was
        -- already chosen (pick_orientation ran before this), recompute sx/sy from the
        -- REAL px/py so the secondary's own place step doesn't overlap the primary's
        -- true footprint -- fuel steps use step_target_pos too, so this must happen
        -- before either later step's target position is read.
        if step.which == "primary" and st.position then
          t.ctx.px, t.ctx.py = st.position.x, st.position.y
          if t.ctx.offset_dx then
            t.ctx.sx = t.ctx.px + t.ctx.offset_dx
            t.ctx.sy = t.ctx.py + t.ctx.offset_dy
          end
        elseif step.which == "secondary" and st.position then
          t.ctx.sx, t.ctx.sy = st.position.x, st.position.y
        end
        -- the placed entity's item is used up: out of the shared reservations (ledger)
        ledger.consume(t, step.entity, 1)
        -- step_ticks: see the "ensure_item" cursor-advance site (near line 404) for
        -- the full rationale. This is the "place" step's own completion point.
        t.step_ticks = t.step_ticks or {}
        t.step_ticks[t.cursor] = {type = step.type, start = active.step_start_tick, done = game.tick}
        t.cursor = t.cursor + 1
        storage.active_step[cid] = nil
        if t.cursor > #t.steps then ledger.complete_task(active.task_id) end
      else
        ledger.step_failed(active.task_id, st.error or "build failed", active.step_start_tick)
        storage.active_step[cid] = nil
      end
    end

    if active.state == "ensuring" then
      -- Polls whichever underlying queue/walk start_ensure_item_action started,
      -- to completion, then falls back to "acting" so the NEXT "acting" pass
      -- reassesses t.ctx.ensure_stack fresh (real inventory counts, not a
      -- remembered target) -- exactly like ensure_item's own Python recursion,
      -- one incremental step of progress per round trip through this state.
      if active.ensuring_kind == "gather" then
        local st = queues.get_gather_status(cid)
        if st.active then goto continue end
        active.state = "acting"
      elseif active.ensuring_kind == "craft" then
        local st = queues.get_craft_status(cid)
        if st.active then goto continue end
        active.state = "acting"
      elseif active.ensuring_kind == "chop_walk" then
        if not storage.walking_queues[cid] then
          active.ensuring_kind = "chop_mine"  -- arrived -> fall through below, same tick
        elseif active.chop_deadline and game.tick >= active.chop_deadline then
          -- Bounded give-up (mirrors every other approach_deadline in this file):
          -- blacklist this SPECIFIC tree so the next "acting" pass picks a
          -- DIFFERENT one instead of re-selecting the identical unreachable tree
          -- forever (the exact "no exclude" bug class already fixed once for
          -- _chop_wood itself, spatial_demo.py -- applied here from the start).
          storage.walking_queues[cid] = nil
          c.entity.walking_state = {walking = false}
          local key = math.floor(t.ctx.wood_target.x) .. "," .. math.floor(t.ctx.wood_target.y)
          t.ctx.wood_tried[key] = true
          active.state = "acting"
        else
          goto continue
        end
      end
      if active.state == "ensuring" and active.ensuring_kind == "chop_mine" then
        local trees = c.entity.surface.find_entities_filtered{
          type = "tree", position = t.ctx.wood_target, radius = 1}
        if trees[1] and trees[1].valid then
          local inv = c.entity.get_main_inventory()
          local before = inv.get_item_count("wood")
          -- REVERTED (2026-08-02, task #82 course-correction) -- see
          -- queues_build.lua's clear_build_area comment for the full reasoning: the
          -- companion must NEVER refuse to collect wood -- back to unconditional
          -- mine{inventory=...} exactly as before the 2026-08-01 WOOD_STOCK_CAP
          -- attempt.
          trees[1].mine{inventory = inv}
          if inv.get_item_count("wood") > before then
            t.ctx.wood_chop_count = (t.ctx.wood_chop_count or 0) + 1
          else
            -- Mined but yielded nothing new (inventory full?) -- blacklist so this
            -- exact tree isn't retried forever; a genuinely full inventory will
            -- surface via the NEXT tree's identical failure, not silently loop.
            local key = math.floor(t.ctx.wood_target.x) .. "," .. math.floor(t.ctx.wood_target.y)
            t.ctx.wood_tried[key] = true
          end
        else
          -- Tree gone (another companion/process claimed it between selection and
          -- arrival) -- blacklist and retry with a fresh selection, don't fail the
          -- whole task over a single vanished tree.
          local key = math.floor(t.ctx.wood_target.x) .. "," .. math.floor(t.ctx.wood_target.y)
          t.ctx.wood_tried[key] = true
        end
        active.state = "acting"
      end
    end
    ::continue::
  end

  -- Companion(s) currently idle -> pick the next (task, step) to start.
  -- MUST also check storage.walking_queues[cid] is empty, not just active_step[cid]
  -- (2026-07-08, Zdendys live-caught via a movement/distance statistics review: "could
  -- not reach furnace" firing even at trivial distances like 12-18 tiles, proving this
  -- was never about map layout). active_step[cid] only tracks whether the TASK POOL
  -- itself is driving this companion -- it says nothing about an UNRELATED walk Python
  -- may have just started via /fac_move_to (e.g. spatial_bc.py's go_to() for furnace
  -- servicing, iron_drill upgrade, etc.), which sets storage.walking_queues[cid]
  -- directly without ever touching active_step[cid]. Without this guard, THIS loop
  -- runs every tick and, the moment a task-pool task is ready to walk somewhere, freely
  -- overwrites storage.walking_queues[cid] mid-flight -- silently discarding whatever
  -- unrelated destination Python had just set, so the companion walks toward the
  -- task-pool's target instead while Python's wait_arrive() keeps blocking on a
  -- destination she was never actually walking to anymore. Confirmed live: coal_pair's
  -- task-pool build was active in the SAME window as a failed "could not reach furnace"
  -- iron_drill-upgrade go_to(), at a distance (12-18 tiles) trivially walkable otherwise.
  -- Extended (2026-07-08, task #42, same session as the walking_queues fix above):
  -- walking_queues[cid] alone only protects the WALKING phase of gather/fuel/build/
  -- belt_queues -- once one of those arrives and moves on to its own "acting" phase
  -- (mining, fueling, placing), walking_queues[cid] clears (arrival) while the
  -- companion is STILL busy for that subsystem's purposes. Without also checking
  -- these, the task pool could grab a companion mid-mine/mid-fuel/mid-build from a
  -- direct (non-task-pool) command and redirect her walking_queues[cid] to its own
  -- target, corrupting that other queue's in-progress state. The pool's own steps DO
  -- start some of these (a place step's start_build, ensure_item's start_gather) --
  -- their entries are covered by active_step[cid] while those steps run. A finished
  -- entry holds the pool ENDED_GRACE_TICKS more (holds_pool), so a pool step's
  -- start_build / start_gather cannot overwrite a result its other caller has not
  -- read yet.
  for cid, c in pairs(storage.companions or {}) do
    if c.entity and c.entity.valid and not storage.active_step[cid]
       and not storage.walking_queues[cid] and not busy_elsewhere(cid) then
      local task_id = pick_next(cid, c, true)
      if task_id == M.CONTROLLER then
        -- the controller's queued command starts now; its own queue holds the pool
        -- from here (busy_elsewhere / walking_queues)
        requests.run(cid)
      elseif task_id then
        local t = storage.tasks[task_id]
        local step = t.steps[t.cursor]
        local pos = step_target_pos(t, step)
        if pos and u.distance(c.entity.position, pos) > targeting.step_reach(c.entity, step) then
          storage.walking_queues[cid] = {target = pos}
          -- approach_deadline (2026-07-08/09, live-caught: run_reactive's own new
          -- async-pending stale-exemption -- added specifically to stop penalizing
          -- LEGITIMATE in-flight task-pool work -- immediately started firing its
          -- "task-pool work pending for 40 actions with no resolution" backstop
          -- repeatedly, live, meaning this "walking" state genuinely never resolves
          -- on its own sometimes). Root cause: unlike EVERY OTHER queue type in this
          -- codebase (queues.lua's tick_gather_queues/tick_fuel_queues/
          -- tick_build_queues, pathfind.lua's belt_connect walk), this generic
          -- task-pool "walking" state (tick()'s own handler right above) had NO
          -- deadline at all -- if storage.walking_queues[cid] never clears (a
          -- persistently blocked approach, or some other queue silently claiming the
          -- companion mid-walk), active.state just sits at "walking" forever, the
          -- task never transitions to done/failed, and Python's own task_status()
          -- poll waits indefinitely. Distance-scaled exactly like
          -- tick_gather_queues' own q.approach_deadline (25 ticks/tile, floor 1800)
          -- for consistency with the rest of the codebase's convention.
          local walk_deadline = u.approach_deadline(c.entity.position, pos)
          -- step_start_tick (2026-07-28, action-timing instrumentation): stamped
          -- once here, when the step FIRST enters active_step -- covers the
          -- walking phase too, so the eventual step_ticks entry (see M.tick's own
          -- cursor-advance sites) reflects the full wall-to-wall duration, not
          -- just the "acting" sub-phase. Never reset by the later
          -- walking->acting transition (M.tick just flips active.state in place).
          -- route_extend: the walk's first route may extend the deadline to its length
          -- (control.lua on_script_path_request_finished)
          storage.active_step[cid] = {task_id = task_id, state = "walking",
                                       approach_deadline = walk_deadline,
                                       step_start_tick = game.tick, route_extend = true}
        else
          storage.active_step[cid] = {task_id = task_id, state = "acting",
                                       step_start_tick = game.tick}
        end
      end
    end
  end
end

-- Diagnostic (2026-07-09, task pool investigation): dumps everything relevant to WHY a
-- companion's task-pool work might be stuck -- active_step state/deadline, the task's
-- own status/cursor/needs, walking_queues entry, and the busy_elsewhere flags -- in one
-- call, so a live stall can be root-caused without guessing from static code reading.
-- Read-only, no side effects.
function M.get_diag(cid)
  local active = storage.active_step and storage.active_step[cid]
  local out = {
    active_step = active and {
      task_id = active.task_id, state = active.state,
      approach_deadline = active.approach_deadline,
      ticks_until_deadline = active.approach_deadline and (active.approach_deadline - game.tick) or nil,
      candidate_retry_deadline = active.candidate_retry_deadline,
      candidates_cleared = active.candidates_cleared,
    } or nil,
    walk_preempts = storage.walk_preempts and storage.walk_preempts[cid] or 0,
    walking_queue = storage.walking_queues and storage.walking_queues[cid] and {
      target = storage.walking_queues[cid].target,
    } or nil,
    busy_gather = (storage.gather_queues and storage.gather_queues[cid]) and true or false,
    busy_fuel = (storage.fuel_queues and storage.fuel_queues[cid]) and true or false,
    busy_build = (storage.build_queues and storage.build_queues[cid]) and true or false,
    busy_belt = (storage.belt_queues and storage.belt_queues[cid]) and true or false,
    -- 3 queue types added 2026-07-09 (task #46, "faster error diagnosis"): get_diag
    -- otherwise silently omitted these 3 of the 7 async queue types that
    -- companion_queue_status (init.lua) already knows about, so a companion stuck
    -- specifically on a harvest/craft/combat queue looked indistinguishable from
    -- "not busy at all" through this diagnostic.
    busy_harvest = (storage.harvest_queues and storage.harvest_queues[cid]) and true or false,
    busy_craft = (storage.craft_queues and storage.craft_queues[cid]) and true or false,
    busy_combat = (storage.combat_queues and storage.combat_queues[cid]) and true or false,
    -- which of the busy_* entries actually hold the pool (busy_elsewhere / holds_pool:
    -- running, or a gather / build ended within its read window) -- busy_* alone is
    -- true for any entry, also a long-finished one
    holds_pool = {
      gather = holds_pool(storage.gather_queues and storage.gather_queues[cid], true),
      fuel = holds_pool(storage.fuel_queues and storage.fuel_queues[cid], false),
      build = holds_pool(storage.build_queues and storage.build_queues[cid], true),
      belt = holds_pool(storage.belt_queues and storage.belt_queues[cid], false),
    },
  }
  if active and active.task_id then
    local t = storage.tasks[active.task_id]
    if t then
      out.task = {status = t.status, cursor = t.cursor, total_steps = #t.steps,
                  needs = t.needs, step_type = t.steps[t.cursor] and t.steps[t.cursor].type}
    end
  end
  -- Merge in gather's own richer engine-level diagnostics (state/selected/
  -- mining_state_mining/entity_pos, added 2026-07-09 for the #41 stall investigation)
  -- so a stuck-on-gather companion doesn't need a SEPARATE /fac_gather_status round
  -- trip on top of this call (task #46). peek=true (2026-07-11): this function is
  -- explicitly documented as read-only/no-side-effects -- must NOT consume+clear a
  -- gather queue's terminal "done" state (see get_gather_status's own "peek" comment
  -- for why that would silently discard the final gathered count).
  if out.busy_gather then
    out.gather = queues.get_gather_status(cid, true)
  end
  -- Last few entries of the errors ring buffer (task #46): surfaces recent silent
  -- pcall failures (u.error_response/u.log_error, storage.errors, capped 50 total)
  -- right alongside the queue/task state that was active when they happened, instead
  -- of needing a separate /fac_get_errors call and manually correlating timestamps.
  -- Capped at 5 here (not all 50) to keep this diagnostic response focused on what's
  -- actionable RIGHT NOW rather than dumping the whole history every time.
  local errs = storage.errors or {}
  local recent = {}
  for i = math.max(1, #errs - 4), #errs do recent[#recent + 1] = errs[i] end
  out.recent_errors = recent
  return out
end

return M
