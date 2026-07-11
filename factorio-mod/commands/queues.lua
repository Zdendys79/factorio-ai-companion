-- AI Companion v0.9.0 - Tick-based queue system
local u = require("commands.init")
local pathfind = require("commands.pathfind")

local M = {}

-- Constants
local TICK_INTERVAL = 5
local MIN_ACTION_TICKS = 30
local BUILD_TICKS = 60
local ATTACK_COOLDOWN = 15
local ATTACK_RANGE = 6
local MINING_RANGE = 5
-- Real mining requires standing basically ON/adjacent to the resource -- confirmed live
-- 2026-07-03 (Zdendys, watching: "Stojí postava přímo na uhlí! nic nejde dolovat na dálku"):
-- unlike build/reach_distance (~10) or MINING_RANGE (5, used elsewhere as a generous "still
-- close enough to keep going" bound), native mining_state silently does nothing at a genuine
-- multi-tile distance even with `selected` correctly set -- it only actually starts once the
-- companion is essentially touching the resource tile.
local MINE_ADJACENT_RANGE = 2
-- SELECT_FAIL_TICKS (2026-07-11, live-reproduced iron-ore-gather-returns-0 bootstrap
-- stall, scripts/test_gather_select_fail.py -- see that test + queues.lua's "mine" state
-- comment below for the full mechanism): `character.selected = <entity>` is documented
-- (Factorio runtime API, LuaControl::selected) to SILENTLY CLEAR the selection instead of
-- erroring when the target isn't currently selectable -- confirmed live to happen
-- INTERMITTENTLY for an otherwise perfectly valid, in-range (well under both
-- MINE_ADJACENT_RANGE and the character's own 2.7-tile reach_resource_distance),
-- amount>0 resource tile, with no code-visible cause pinned down (same distance/tile
-- shape succeeds most of the time). A short, tick-count-based (not distance-scaled)
-- retry budget before giving up on THIS tile and trying the next candidate -- small
-- enough to recover fast (a few real seconds even at normal game speed), bounded so it
-- can never itself hang.
-- KNOWN LIMITATION (live-verified 2026-07-11, scripts/test_gather_select_fail.py,
-- select_fail_verify.log): this only self-heals the "selected didn't stick for THIS
-- one tile" shape. A live repro (scratchpad/r8a.log) also caught a SECOND, structurally
-- different failure where `selected` sticks correctly and mining_state.mining stays
-- true continuously for 2500+ ticks at a fine distance, yet gathered stays 0 the whole
-- time -- this guard does nothing there (selected == res, so the branch below never
-- fires). Also, in roughly half of live test runs the "didn't stick" failure recurs on
-- EVERY candidate tried in the session, not just one bad tile -- the blacklist-and-
-- retry below then burns through the entire reachable field before giving up (fast,
-- loud failure instead of a silent hang -- real but modest value), which suggests the
-- true defect may be session-wide rather than per-tile. Root cause of both NOT yet
-- pinned down; see scripts/test_gather_select_fail.py's docstring for the full status.
local SELECT_FAIL_TICKS = 120

-- Validate companion exists and is valid
local function valid_companion(id)
  local c = u.get_companion(id)
  return c and c.entity and c.entity.valid and c
end

-- Universal stale-progress backstop threshold (2026-07-06, Zdendys: "to bychom mohli
-- udelat jako obecny fallback na vsechny akce" -- then: "jestli uz tam nekde je 600
-- ticku, tak dame taky 600!", matching tick_harvest_queues's own existing stale-progress
-- constant below, for one consistent number project-wide).
local UNIVERSAL_STALE_TICKS = 600

-- Generic queue processor - eliminates repetition across all tick functions
local function process_queue(queue_name, processor)
  local queues = storage[queue_name]
  if not queues then return end

  local to_remove = {}
  for cid, q in pairs(queues) do
    local c = valid_companion(cid)
    if not c then
      to_remove[#to_remove + 1] = cid
    else
      -- UNIVERSAL stale-progress backstop, ONE level above every queue type's own
      -- specific checks (2026-07-06, Zdendys: "obecny fallback na vsechny akce" -- if
      -- NEITHER the companion's total inventory item count NOR its position has changed
      -- in UNIVERSAL_STALE_TICKS ticks, whatever this queue is doing isn't making real
      -- progress, regardless of queue type or the specific reason -- including cases
      -- where the queue-specific logic never even runs, or a bug like the orphaned-
      -- mining one found earlier tonight where a queue got silently dropped elsewhere
      -- without ever reaching this check). Position is checked TOGETHER with item count
      -- (not item count alone) so a long, genuinely-in-progress walk toward a distant
      -- target -- which changes position but not inventory -- is correctly NOT flagged
      -- as stuck; only a companion that is BOTH stationary AND not gaining/losing items
      -- counts as truly stuck. Tracked ON the queue entry itself (q._stale_*), so
      -- concurrent queues on the same companion (e.g. walking + harvesting) don't
      -- interfere with each other's own staleness tracking.
      -- moved threshold raised 0.1 -> 5 tiles (2026-07-06, Zdendys live-caught: "zmena
      -- pozice znamena alespon o 5" -- control.lua's own perpendicular-bypass mechanism
      -- shuffles the companion sideways in small steps while stuck against a large
      -- obstacle, which satisfied the old near-zero threshold on almost every check,
      -- continuously resetting _stale_pos to the CURRENT position and defeating this
      -- entire backstop (confirmed live: stuck against the big wreck's collision for 3+
      -- minutes, this check never fired). At 5 tiles, small shuffle movements stay
      -- within range of the ORIGINAL reference point (so _stale_pos does NOT get
      -- updated and stale_ticks keeps accumulating correctly); only cumulative movement
      -- that actually clears 5 tiles counts as real progress and resets the counter.
      local total = c.entity.get_inventory(defines.inventory.character_main).get_item_count()
      local pos = c.entity.position
      local moved = q._stale_pos and (u.distance(q._stale_pos, pos) > 5)
      if q._stale_total == total and q._stale_pos and not moved then
        q._stale_ticks = (q._stale_ticks or 0) + TICK_INTERVAL
      else
        q._stale_total = total
        q._stale_pos = {x = pos.x, y = pos.y}
        q._stale_ticks = 0
      end
      if q._stale_ticks > UNIVERSAL_STALE_TICKS then
        -- Diagnostic (2026-07-09, live-caught: gather("iron-ore") force-stopped this
        -- way intermittently with NO further clue why -- this generic backstop is
        -- shared across every queue type, so it never recorded WHERE the companion
        -- actually got stuck or what she was walking toward. q.state/q.entity_pos/
        -- q.target are nil-safe reads: present on SOME queue types, absent (and
        -- harmlessly omitted) on others -- but their TYPE also varies by queue type
        -- (e.g. gather_queues' own q.target is the target ITEM COUNT, a plain number,
        -- NOT a position -- unlike walking-style queues where target IS a position
        -- table). Live-caught the FIRST time this fired: an unguarded string.format
        -- assuming q.target.x/.y crashed with "attempt to index field 'target' (a
        -- number value)", silently swallowed by guard_tick's own pcall every tick
        -- thereafter -- which ALSO meant the mining_state/walking_state reset and
        -- to_remove cleanup below NEVER RAN, since the crash happened before reaching
        -- them, leaving the stuck queue entry (and the crash) recurring every tick
        -- indefinitely instead of actually force-stopping anything. fmt_maybe_pos
        -- checks the real type before formatting, so this can never crash regardless
        -- of what shape a given queue type's field happens to be.
        local function fmt_maybe_pos(v)
          if type(v) == "table" and v.x and v.y then
            return string.format("(%.1f,%.1f)", v.x, v.y)
          end
          return tostring(v)
        end
        u.log_error(string.format(
          "%s queue for companion %d force-stopped: neither inventory count nor " ..
          "position changed in %d ticks -- no real progress regardless of queue-" ..
          "specific state -- stuck_at=(%.1f,%.1f) queue_state=%s entity_pos=%s target=%s",
          queue_name, cid, q._stale_ticks, pos.x, pos.y, tostring(q.state),
          fmt_maybe_pos(q.entity_pos), fmt_maybe_pos(q.target)),
          queue_name)
        c.entity.mining_state = {mining = false}
        c.entity.walking_state = {walking = false}
        to_remove[#to_remove + 1] = cid
      else
        local should_remove = processor(cid, q, c)
        if should_remove then to_remove[#to_remove + 1] = cid end
      end
    end
  end

  for _, cid in ipairs(to_remove) do queues[cid] = nil end
end

function M.init()
  storage.harvest_queues = storage.harvest_queues or {}
  storage.gather_queues = storage.gather_queues or {}
  storage.fuel_queues = storage.fuel_queues or {}
  storage.craft_queues = storage.craft_queues or {}
  storage.build_queues = storage.build_queues or {}
  storage.combat_queues = storage.combat_queues or {}
  storage.belt_queues = storage.belt_queues or {}
end

-- ============ HARVEST ============

function M.start_harvest(cid, position, target_count, resource_name)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end

  -- Filter by resource name if specified, otherwise get all resources
  local filter = {position = position, radius = 3, type = "resource"}
  if resource_name then filter.name = resource_name end

  local entities = c.entity.surface.find_entities_filtered(filter)
  if #entities == 0 then return {error = "No resource"} end

  table.sort(entities, function(a, b)
    return u.distance(a.position, c.entity.position) < u.distance(b.position, c.entity.position)
  end)

  -- Resolve the actual MINED ITEM name from the resource prototype, same as tick_gather_queues
  -- already does (cubic-dev-ai review, 2026-07-03): the resource entity name (used to find/filter
  -- entities) is NOT reliably the same as the item you receive -- they happen to match for every
  -- vanilla solid ore (iron-ore, copper-ore, coal, stone, uranium-ore) but NOT in general (a fluid
  -- resource like crude-oil has no item at all; modded resources can name the entity and item
  -- differently, or emit >1 product). Using the raw entity name as an inventory item key would
  -- silently track the WRONG (or a nonexistent) item, so q.harvested would never advance despite
  -- real mining happening. Only resolvable when resource_name narrowed the entities to ONE
  -- resource type; a mixed-resource harvest (resource_name=nil) has no single product to track and
  -- keeps the whole-inventory-delta fallback in tick_harvest_queues.
  local product = nil
  if resource_name then
    local mp = entities[1].prototype.mineable_properties
    product = mp and mp.products and mp.products[1] and mp.products[1].name or nil
    if not product then
      u.log_error("harvest: resource '" .. resource_name .. "' has no minable item product " ..
        "-- progress will fall back to whole-inventory tracking", "harvest_queue")
    end
  end

  storage.harvest_queues[cid] = {
    entities = entities,
    position = position,
    target = target_count,
    harvested = 0,
    current = nil,
    resource_name = resource_name,
    product = product
  }

  M.start_mining_next(cid)
  -- Set inv_snapshot immediately after starting mining
  storage.harvest_queues[cid].inv_snapshot = c.entity.get_main_inventory().get_contents()
  return {started = true, entities = #entities, target = target_count, resource = resource_name}
end

function M.start_mining_next(cid)
  local q = storage.harvest_queues[cid]
  if not q then return false end

  local c = valid_companion(cid)
  if not c then
    storage.harvest_queues[cid] = nil
    return false
  end

  -- NATIVE mining, the SAME mechanic a real player uses: setting mining_state lets the GAME
  -- ENGINE run the whole mining cycle itself (real per-resource mining_time, real swinging
  -- animation, real extraction into the inventory) -- we do NOT call entity.mine{} ourselves
  -- at all (Zdendys 2026-07-03: "pouzit proste nativni schopnosti postavy", same as
  -- character.mining_state a player's client sets while holding the mine button). The engine
  -- keeps mining the SAME target automatically, one unit per completed swing, for as long as
  -- mining_state stays true and the target is valid+in range -- tick_harvest_queues just
  -- watches inventory deltas and moves mining_state to the next tile once one depletes.
  --
  -- mining_state.position is ONLY consulted for TILE mining (e.g. landfill/cliffs); per the
  -- Factorio API docs, "when the player isn't mining tiles the player will mine whatever
  -- entity is currently selected" -- so an ore/resource ENTITY must be set via `selected`
  -- first, or mining_state silently does nothing (0 extraction forever, no error) even
  -- though mining=true and the position looks correct. Live-caught 2026-07-03: harvest
  -- queues stuck at "0/N harvested" indefinitely until this was added.
  while #q.entities > 0 do
    local entity = q.entities[1]
    if not (entity and entity.valid and entity.type == "resource") then
      table.remove(q.entities, 1)   -- invalid / non-resource -> skip to next tile
    else
      c.entity.selected = entity
      c.entity.mining_state = {mining = true, position = entity.position}
      q.current = {entity = entity, done = false}
      return true
    end
  end
  return false
end

function M.tick_harvest_queues()
  process_queue("harvest_queues", function(cid, q, c)
    -- Target reached
    if q.harvested >= q.target then
      c.entity.mining_state = {mining = false}
      return true
    end

    -- Too far from mining area
    if u.distance(c.entity.position, q.position) > MINING_RANGE then
      c.entity.mining_state = {mining = false}
      return true
    end

    -- TRUE adjacency check (2026-07-05, Zdendys live-caught: harvest queue froze forever at
    -- "harvested=0, mining=true" on TWO different maps/positions, game.tick advancing normally,
    -- companion stationary, `selected` correctly set to a valid resource entity). Root cause:
    -- the companion was within MINING_RANGE (5) of q.position (the original command's x,y) but
    -- NOT within the ~2-tile MINE_ADJACENT_RANGE of the SPECIFIC entity start_mining_next
    -- selected -- native mining_state silently does nothing at that distance even with
    -- `selected` set (see this file's own MINE_ADJACENT_RANGE comment above). This exact
    -- adjacency check was already added to tick_gather_queues on 2026-07-03 (below, "mine"
    -- state) but never backported to tick_harvest_queues, which is what fac_resource_mine /
    -- Python's mine_and_wait actually uses -- and Python's own go_to() "arrived" tolerance
    -- (MINE_DIST=4.5) is looser than this mod's true ~2-tile requirement, so a caller can
    -- easily "arrive" while still being just out of native mining range. Treat an
    -- out-of-adjacency current entity the same as a depleted one: skip it and try the next
    -- candidate in q.entities, instead of spinning on it forever.
    local cur_entity = q.current and q.current.entity
    if cur_entity and cur_entity.valid and
       u.distance(c.entity.position, cur_entity.position) > MINE_ADJACENT_RANGE then
      if #q.entities > 0 and q.entities[1] == cur_entity then table.remove(q.entities, 1) end
      q.current = nil
      if not M.start_mining_next(cid) then
        c.entity.mining_state = {mining = false}
        u.log_error(string.format(
          "harvest queue for companion %d ended short (%d/%d %s): no candidate entity was ever " ..
          "within true mining adjacency (%d tiles) -- caller likely approached with too loose a " ..
          "tolerance", cid, q.harvested, q.target, q.resource_name or "?", MINE_ADJACENT_RANGE),
          "harvest_queue")
        return true
      end
      return false   -- fresh candidate selected -- re-check adjacency/progress next tick
    end

    -- Stale-progress backstop (defense in depth, mirrors the bounded-deadline requirement
    -- already enforced for every other queue type in this mod -- walking/gather/fuel/craft/
    -- build/belt/combat): if harvested hasn't moved for a bounded number of ticks despite
    -- passing every check above, terminate rather than hang indefinitely on some future/
    -- unknown stall this adjacency fix doesn't cover.
    q.stale_ticks = (q.last_harvested == q.harvested) and (q.stale_ticks or 0) + TICK_INTERVAL or 0
    q.last_harvested = q.harvested
    if q.stale_ticks > 600 then
      c.entity.mining_state = {mining = false}
      u.log_error(string.format(
        "harvest queue for companion %d ended short (%d/%d %s): no progress for %d ticks despite " ..
        "passing all reachability checks -- unknown stall", cid, q.harvested, q.target,
        q.resource_name or "?", q.stale_ticks), "harvest_queue")
      return true
    end

    -- NATIVE mining (Zdendys 2026-07-03: "pouzit proste nativni schopnosti postavy"): the
    -- engine itself runs the mining cycle once mining_state is set in start_mining_next --
    -- same speed, same animation, same extraction as a real player holding the mine button.
    -- We just watch the inventory for what the engine actually produced.
    --
    -- Track the SPECIFIC mined ITEM (q.product, resolved in start_harvest from the resource
    -- prototype's mineable_properties -- NOT q.resource_name, which is the resource ENTITY name
    -- and only coincidentally matches the item name for vanilla solid ores; a second cubic-dev-ai
    -- review caught that using the entity name directly would silently track the wrong/nonexistent
    -- item for fluids or modded resources with a different entity/item name), not the whole-
    -- inventory total (first cubic-dev-ai review, 2026-07-03): a plain get_item_count() total is
    -- thrown off by ANY concurrent queue on the same companion (fuel top-up removing coal, a craft
    -- consuming ingredients, a build consuming a placed item) -- completely unrelated inventory
    -- changes get misread as mined progress or lost progress. When start_harvest was called
    -- without a resource filter (mines whatever resource is nearby, product unknown up front) or
    -- the product couldn't be resolved, there's no single item to track, so this falls back to the
    -- old whole-inventory delta -- same limitation there, but at least the baseline-staleness bug
    -- below is fixed in both cases.
    local inv = c.entity.get_main_inventory()
    local now_count = q.product and inv.get_item_count(q.product) or inv.get_item_count()
    if q.last_inv_count == nil then q.last_inv_count = now_count end
    local gained = now_count - q.last_inv_count
    if gained > 0 then
      q.harvested = q.harvested + gained
    end
    -- ALWAYS refresh the baseline (not just when gained > 0): otherwise any net inventory
    -- DECREASE (a concurrent queue consuming items) leaves last_inv_count stale/too-high, and
    -- every subsequent tick's mined units get silently swallowed by the still-negative delta
    -- until the total climbs back above the old stale baseline (cubic-dev-ai review).
    q.last_inv_count = now_count

    -- Current target depleted (engine removed it) or never set -> advance to the next tile.
    local cur = q.current and q.current.entity
    if not (cur and cur.valid) then
      if #q.entities > 0 and q.entities[1] == cur then table.remove(q.entities, 1) end
      if not M.start_mining_next(cid) then
        c.entity.mining_state = {mining = false}
        -- A depleted tile normally means its full amount was MINED (game inserts or, if the
        -- inventory is full, spills the item on the ground -- either way the tile empties).
        -- If harvested is still short of target here, every listed entity ran out while
        -- items were spilling instead of landing in inventory -- silently reporting this as
        -- plain "queue done" would hide a real inventory-full condition from the caller.
        if q.harvested < q.target then
          u.log_error(string.format(
            "harvest queue for companion %d ended short (%d/%d %s): entities exhausted, " ..
            "possible full inventory (mined items spilled to ground)",
            cid, q.harvested, q.target, q.resource_name or "?"), "harvest_queue")
        end
        return true
      end
    end

    return q.harvested >= q.target
  end)
end

function M.get_harvest_status(cid)
  local q = storage.harvest_queues[cid]
  if not q then return {active = false} end
  return {
    active = true,
    harvested = q.harvested,
    target = q.target,
    remaining = #q.entities,
    mining = q.current ~= nil
  }
end

function M.stop_harvest(cid)
  local q = storage.harvest_queues[cid]
  if not q then return {stopped = false} end

  local c = valid_companion(cid)
  if c then c.entity.mining_state = {mining = false} end

  local harvested = q.harvested
  storage.harvest_queues[cid] = nil
  return {stopped = true, harvested = harvested}
end

-- ============ ORPHANED MINING SAFETY NET ============
-- Defense in depth (2026-07-06, Zdendys live-caught: a companion mined a single stone
-- tile CONTINUOUSLY for 10+ minutes -- stone climbing from ~144 to 335+ -- while BOTH
-- storage.harvest_queues and storage.gather_queues were confirmed completely EMPTY for
-- every companion id (checked via direct RCON query, no race). Every normal completion
-- path in tick_harvest_queues/tick_gather_queues explicitly sets mining_state=false
-- before returning, but process_queue's own early-exit branch (when valid_companion(cid)
-- returns falsy) removes the queue entry WITHOUT ever calling the processor callback --
-- so if a companion's registry entry ever goes missing while its physical character
-- entity and native mining_state persist (exact trigger not fully pinned down this
-- session), nothing is left to ever stop it; the engine just keeps mining the same tile
-- forever, completely untracked. Regardless of the precise trigger, nothing should ever
-- be able to mine with zero tracking -- this backstop periodically scans every
-- COMPANION (non-player) character actually mining and stops any that isn't accounted
-- for by an in-flight harvest/gather queue, mirroring the stale-progress backstop
-- pattern tick_harvest_queues already uses internally, one level up (whole-mod scan,
-- not per-queue). `not e.player` excludes real human-controlled characters (e.g. Zdendys
-- connected and mining by hand) -- this must NEVER touch a player's own actions.
local ORPHAN_CHECK_INTERVAL = 300  -- ~5s at 60 UPS -- a backstop, not time-critical

function M.tick_orphan_mining_cleanup()
  if (game.tick % ORPHAN_CHECK_INTERVAL) ~= 0 then return end
  local tracked = {}
  for cid in pairs(storage.harvest_queues or {}) do
    local c = valid_companion(cid)
    if c then tracked[c.entity.unit_number] = true end
  end
  for cid in pairs(storage.gather_queues or {}) do
    local c = valid_companion(cid)
    if c then tracked[c.entity.unit_number] = true end
  end
  for _, surface in pairs(game.surfaces) do
    for _, e in ipairs(surface.find_entities_filtered{type = "character"}) do
      if e.valid and not e.player and e.mining_state.mining and not tracked[e.unit_number] then
        e.mining_state = {mining = false}
        u.log_error(string.format(
          "orphan mining stopped: character #%d at (%.0f,%.0f) was mining with no " ..
          "tracking harvest/gather queue (likely a stale companion registry)",
          e.unit_number, e.position.x, e.position.y), "orphan_mining")
      end
    end
  end
end

-- ============ GATHER (autonomous: find reachable patch -> walk -> mine to target) ============
-- Self-contained composite: the mod finds the nearest REACHABLE + SAFE patch of `resource`, walks the
-- companion within reach, and mines it NATIVELY via character.mining_state (same speed/animation/
-- extraction as a real player holding the mine button; amount--, game removes depleted tile), moving
-- to the next patch until the inventory holds `count` of the mined product (or no reachable patch
-- remains). Replaces the Python go_to + start_harvest + poll glue.
-- shared tile-key helper (gather blacklist of unreachable patches + fuel-group visited set)
local function _tile_key(pos) return math.floor(pos.x) .. "," .. math.floor(pos.y) end

local function find_reachable_resource(surf, from, resource, blacklist)
  local ores = surf.find_entities_filtered{name = resource, position = from, radius = 400}
  table.sort(ores, function(a, b) return u.distance(a.position, from) < u.distance(b.position, from) end)
  for _, e in ipairs(ores) do
    if e.valid and (e.amount or 0) > 0
       and not (blacklist and blacklist[_tile_key(e.position)])
       and surf.count_entities_filtered{type = "unit-spawner", position = e.position, radius = 20} == 0
       and surf.find_non_colliding_position("character", e.position, 2.5, 0.5) then
      return e
    end
  end
  -- Diagnostic (2026-07-08, live-caught: gather("coal",5) stalled ~42 real seconds with
  -- 0 gathered on one live run, despite an isolated repro of the identical call
  -- completing in ~2s -- no code difference found between the two paths, so the
  -- CAUSE must be map/entity-state-specific to that one run. This logs exactly WHY
  -- the search came up empty (zero candidates at all vs. every candidate rejected by
  -- a specific filter), so the next occurrence shows the real reason instead of just
  -- "gathered 0" with no further clue. Zdendys: "Pokud je něco 'nedosažitelné' je to
  -- bug! NIKDY chyba mapy!" -- this is a diagnostic-only addition, no behavior change.
  local total = #ores
  local depleted, blacklisted, near_spawner, no_stand_pos = 0, 0, 0, 0
  for _, e in ipairs(ores) do
    if e.valid then
      if (e.amount or 0) <= 0 then depleted = depleted + 1
      elseif blacklist and blacklist[_tile_key(e.position)] then blacklisted = blacklisted + 1
      elseif surf.count_entities_filtered{type = "unit-spawner", position = e.position, radius = 20} > 0 then
        near_spawner = near_spawner + 1
      elseif not surf.find_non_colliding_position("character", e.position, 2.5, 0.5) then
        no_stand_pos = no_stand_pos + 1
      end
    end
  end
  u.log_error(string.format(
    "find_reachable_resource: no usable %s within 400 tiles of (%.1f,%.1f) -- total=%d "
    .. "depleted=%d blacklisted=%d near_spawner=%d no_stand_pos=%d",
    resource, from.x, from.y, total, depleted, blacklisted, near_spawner, no_stand_pos),
    "gather_queue")
  return nil
end

function M.start_gather(cid, resource, count, exclude)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  -- Don't steal this companion from an ACTIVE task-pool step (2026-07-08, task #42,
  -- generalizing move.lua's fac_move_to guard from earlier tonight to the other
  -- storage.walking_queues[cid] writers): task_pool.lua's tick() drives a companion
  -- toward its own step targets independently of whatever Python is doing right now:
  -- an unguarded gather() call here would silently overwrite that in-progress walk the
  -- same way direct move_to() used to. Reject instead -- Python callers already retry
  -- on their own next cycle when a dispatch is refused.
  if storage.active_step and storage.active_step[cid] then
    return {error = "companion busy with an active task-pool step"}
  end
  -- exclude (2026-07-07, Zdendys/Claude: replacing the Python-side manual
  -- goto_resource()+mine_and_wait() flow, which needed its OWN distance-vs-
  -- MINE_DIST guessing purely to know "did I arrive" -- a guessed threshold
  -- that kept landing on the wrong side of the mod's real MINE_ADJACENT_RANGE
  -- boundary across 3 separate live-caught bugs today. gather() already does
  -- the whole walk+adjacency+mine cycle server-side with no Python distance
  -- math at all; the ONE thing it was missing to fully replace goto_resource
  -- was a way for the CALLER to say "skip these positions, already proven
  -- unreachable/exhausted this episode" -- goto_resource's own persistent
  -- per-resource exclude list (spatial_bc.py's resource_exclude). Optional
  -- list of {x=,y=} tables, seeded into q.blacklist UPFRONT using the SAME
  -- tile-key format find_reachable_resource/tick_gather_queues already use
  -- internally for patches THIS queue discovers unreachable on its own.
  local blacklist = {}
  if exclude then
    for _, p in ipairs(exclude) do
      blacklist[_tile_key(p)] = true
    end
  end
  storage.gather_queues[cid] = {resource = resource, target = count, state = "find",
    last_mine_tick = 0, blacklist = blacklist}
  return {started = true, resource = resource, target = count}
end

function M.tick_gather_queues()
  process_queue("gather_queues", function(cid, q, c)
    local surf = c.entity.surface
    local inv = c.entity.get_main_inventory()

    if q.state == "find" then
      local e = find_reachable_resource(surf, c.entity.position, q.resource, q.blacklist)
      if not e then
        -- Bounded retry (2026-07-08, live-caught: gather("coal") returned {gathered=0,
        -- done=true, blacklist=[]} on the VERY FIRST check on one fresh map -- 5
        -- follow-up trials with the same map-gen settings all found 400-600+ reachable
        -- coal patches, ruling out "genuinely no coal nearby" as the norm. A transient
        -- miss here (e.g. this companion's own position not yet settled right after
        -- spawn, or some other momentary condition) previously gave up PERMANENTLY on
        -- the very first empty result with no second look at all -- same class of fix
        -- as the collision-retry above, just for "found nothing" instead of "found
        -- something blocked".
        q.find_retry_deadline = q.find_retry_deadline or (game.tick + 300)
        if game.tick < q.find_retry_deadline then return false end
        return true   -- no reachable patch left after retrying -> done, return what we have
      end
      local mp = e.prototype.mineable_properties
      if not (mp and mp.products and mp.products[1]) then
        -- Non-standard resource (no item product, e.g. a fluid-only patch) -- blacklist this
        -- tile and retry next tick instead of crashing on a nil index.
        q.blacklist = q.blacklist or {}
        q.blacklist[_tile_key(e.position)] = true
        u.log_error("gather queue: resource '" .. q.resource .. "' at (" ..
          math.floor(e.position.x) .. "," .. math.floor(e.position.y) ..
          ") has no minable item product, skipping", "gather_queue")
        return false
      end
      q.entity_pos = {x = e.position.x, y = e.position.y}
      q.product = mp.products[1].name
      if not q.start_count then q.start_count = inv.get_item_count(q.product) end
      -- distance-scaled deadline: 25 ticks/tile (~3.7x the expected walk) so a legit long walk is
      -- never aborted, but a companion STUCK on an obstacle (standable != path-reachable) bails fast
      -- instead of hanging the whole 180s (the "3 min and 0 coal" bug).
      q.approach_deadline = game.tick + math.max(1800, math.floor(u.distance(c.entity.position, e.position) * 25))
      -- radius=1 (not 3): walk essentially ONTO the resource tile, not just "in the
      -- neighborhood" -- see MINE_ADJACENT_RANGE comment above (native mining needs real
      -- adjacency, confirmed live 2026-07-03).
      storage.walking_queues[cid] = {target = surf.find_non_colliding_position("character", e.position, 1, 0.5) or e.position}
      q.state = "approach"
      return false
    end

    if q.state == "approach" then
      if u.distance(c.entity.position, q.entity_pos) <= MINE_ADJACENT_RANGE then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "mine"
      elseif game.tick >= (q.approach_deadline or 0) then   -- cannot reach this patch -> blacklist + try next
        q.blacklist = q.blacklist or {}
        -- Blacklist every tile of `resource` within patch range (not just q.entity_pos):
        -- an entirely unreachable patch (e.g. coal across water from a far-flung shore) is
        -- typically dozens of adjacent 1-tile entities at nearly identical distance, so
        -- blacklisting only the one candidate tile let "find" immediately re-pick the NEXT
        -- tile of the SAME dead patch -- exhausting a large patch needed O(patch size)
        -- deadline cycles, each costing real time, and could burn through the entire 180s
        -- Python-side gather() timeout with zero gathered (live-caught 2026-07-04,
        -- scripts/test_phase_b_asm.py: coal gather near a far shore stuck in "approach"
        -- for the full 180s, 0 coal). radius=15 mirrors the same "same patch" radius
        -- already used by spatial_demo.py's nearest(exclude_r=15.0).
        for _, e in ipairs(surf.find_entities_filtered{name = q.resource, position = q.entity_pos, radius = 15}) do
          q.blacklist[_tile_key(e.position)] = true
        end
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "find"
      end
      return false
    end

    if q.state == "mine" then
      if inv.get_item_count(q.product) - (q.start_count or 0) >= q.target then
        c.entity.mining_state = {mining = false}
        return true   -- target met
      end
      -- Pick the NEAREST resource entity to the companion's ACTUAL position, not just any
      -- entity within radius=1 of the originally-recorded q.entity_pos: a resource patch is
      -- many individually-tiled entities ~1 tile apart, so a radius=1 query around q.entity_pos
      -- can catch 2+ neighboring tiles, and an unsorted [1] pick can be the WRONG (slightly
      -- farther) one -- close enough to have satisfied the "approach" exit check against
      -- q.entity_pos, yet just over MINE_ADJACENT_RANGE from where the companion is actually
      -- standing. Live-caught 2026-07-03: state flipped mine->find within one tick, mining_state
      -- never even attempted (selected stayed nil), even though the companion visibly reached
      -- and stopped right next to the coal.
      local candidates = surf.find_entities_filtered{name = q.resource, position = q.entity_pos, radius = 2}
      local res, best_d = nil, 1e18
      for _, e in ipairs(candidates) do
        if e.valid then
          local d = u.distance(c.entity.position, e.position)
          if d < best_d then best_d, res = d, e end
        end
      end
      if not res then
        c.entity.mining_state = {mining = false}
        q.select_fail_ticks = nil   -- leaving "mine" -- don't let a stale count leak into the next tile
        q.state = "find"; return false   -- depleted -> next patch
      end
      if best_d > MINE_ADJACENT_RANGE then
        c.entity.mining_state = {mining = false}
        q.select_fail_ticks = nil
        q.state = "find"; return false
      end
      -- DIAGNOSTIC TRACE (2026-07-09, task #41 investigation -- purely additive, NOT a
      -- behavior change): tests the hypothesis that `res` (re-derived from scratch every
      -- tick, see the loop above) could flip between near-tied candidates on consecutive
      -- ticks, re-triggering the `selected` reassignment below in a way that might
      -- interrupt the engine's mining swing -- the same failure SHAPE as the already-fixed
      -- "re-setting mining_state every tick" bug documented below, but for `selected`
      -- instead. Logs ONLY on the tick `res` actually changes identity while still mining
      -- the same patch (not the first tick, not real patch-exhaustion/find transitions
      -- above, which already returned) -- should stay rare/bounded even if the hypothesis
      -- is correct, safe to leave in for live investigation of the #41 stall.
      local res_key = _tile_key(res.position)
      if q.last_res_key and q.last_res_key ~= res_key then
        u.log_error(string.format(
          "gather mine-state: selected entity changed mid-mine %s -> %s (best_d=%.2f, tick=%d)",
          q.last_res_key, res_key, best_d, game.tick), "gather_trace")
      end
      q.last_res_key = res_key
      -- NATIVE mining (Zdendys 2026-07-03: "pouzit proste nativni schopnosti postavy"):
      -- setting mining_state lets the GAME ENGINE run the whole cycle -- same speed,
      -- animation, and extraction as a real player holding the mine button. No more manual
      -- res.mine{} timer call; just let the engine run its own mining_time countdown.
      -- `selected` must be set too: mining_state.position only applies to TILE mining
      -- (landfill/cliffs) -- an ore ENTITY is only mined via the currently `selected` entity,
      -- else mining_state=true silently mines nothing (live-caught 2026-07-03: "0/N harvested"
      -- forever, no error).
      --
      -- CRITICAL: do NOT reassign mining_state every tick once it's already active. Live-caught
      -- 2026-07-03 (test_gather_diag.py): re-setting mining_state = {mining=true,...} on EVERY
      -- tick (as the old comment here claimed was "harmless") restarts the engine's per-resource
      -- mining_time countdown each time, so the swing NEVER completes -- state sat at "mine" with
      -- gathered=0 for 36s+ straight, companion stationary the whole time. A real player only
      -- sends the mine-button-down event ONCE and holds it; we now do the same -- only assign
      -- when the engine reports it isn't already mining (a fresh read of mining_state.mining
      -- each tick, not a cached value, so this correctly resumes if the engine ever stops it,
      -- e.g. after the target changes).
      if c.entity.selected ~= res then
        c.entity.selected = res
      end
      -- SELECTION-DID-NOT-STICK GUARD (2026-07-11, live-reproduced via
      -- scripts/test_gather_select_fail.py -- root cause of the "gather(iron-ore,N)
      -- got only 0 (done, ...)" 12x-in-a-row bootstrap-stall bug, live-caught in
      -- test_stage_b_wiring_recheck1.log): Factorio's own docs (LuaControl::selected)
      -- say assigning an entity "will select it if it is selectable, otherwise the
      -- selection is cleared" -- confirmed live that an entirely valid, in-range,
      -- amount>0 resource tile can INTERMITTENTLY fail to become selected (reads back
      -- nil) for reasons not pinned down at the script level (the SAME tile/distance
      -- succeeds most of the time). The OLD code below set mining_state=true
      -- UNCONDITIONALLY whenever the engine wasn't already mining, regardless of
      -- whether `selected` actually took -- creating an inert "mining_state.mining=true
      -- + selected=nil" zombie that silently mines NOTHING (game.speed=8: ~1.2s) until
      -- process_queue's generic UNIVERSAL_STALE_TICKS=600 backstop finally force-stops
      -- the WHOLE queue with zero resource-specific diagnostic, reporting
      -- {gathered=0, done=true} indistinguishable from "nothing left to mine". Gate
      -- mining_state=true on selection having ACTUALLY stuck, and self-heal exactly
      -- like the approach_deadline reachability failure above: a short, tick-count
      -- retry budget (not distance-scaled -- this isn't a walking failure), then
      -- blacklist this tile's whole neighborhood and try the next candidate.
      if c.entity.selected ~= res then
        q.select_fail_ticks = (q.select_fail_ticks or 0) + TICK_INTERVAL
        if q.select_fail_ticks > SELECT_FAIL_TICKS then
          u.log_error(string.format(
            "gather mine-state: %s at %s never became selectable after %d ticks " ..
            "(best_d=%.2f) -- blacklisting, trying next patch",
            q.resource, res_key, q.select_fail_ticks, best_d), "gather_queue")
          q.blacklist = q.blacklist or {}
          for _, e in ipairs(surf.find_entities_filtered{name = q.resource, position = q.entity_pos, radius = 15}) do
            q.blacklist[_tile_key(e.position)] = true
          end
          q.select_fail_ticks = nil
          q.last_res_key = nil
          q.state = "find"
        end
        return false
      end
      q.select_fail_ticks = nil
      if not c.entity.mining_state.mining then
        c.entity.mining_state = {mining = true, position = res.position}
      end
      return false
    end
    return true
  end)
end

function M.get_gather_status(cid)
  local q = storage.gather_queues[cid]
  if not q then return {active = false} end
  local c = valid_companion(cid)
  local have = (c and q.product) and c.entity.get_main_inventory().get_item_count(q.product) - (q.start_count or 0) or 0
  -- blacklist tile-keys (2026-07-07): lets the Python caller fold any patch THIS
  -- run discovered unreachable into its OWN persistent exclude list, so a LATER
  -- gather() call (this queue is per-call, not per-episode) doesn't waste an
  -- approach_deadline cycle re-discovering the same dead patch.
  local bl = {}
  if q.blacklist then
    for k in pairs(q.blacklist) do bl[#bl + 1] = k end
  end
  -- ENGINE-level mining diagnostics (2026-07-09, iron-ore gather-stall investigation):
  -- q.state="mine" alone doesn't reveal whether the ENGINE actually has a valid
  -- selected/mining_state -- exposing the real character.selected/mining_state lets a
  -- live poll catch the exact tick things diverge (e.g. selected pointing at something
  -- other than the intended resource, or mining_state.mining reading false/true
  -- unexpectedly) instead of only learning about a stall after the fact via the
  -- generic force-stop backstop.
  local selected_name, mining = nil, nil
  if c then
    selected_name = c.entity.selected and c.entity.selected.name or nil
    mining = c.entity.mining_state and c.entity.mining_state.mining or false
  end
  return {active = true, resource = q.resource, target = q.target, gathered = have,
    state = q.state, blacklist = bl, entity_pos = q.entity_pos,
    selected = selected_name, mining_state_mining = mining}
end

-- ============ FUEL GROUP (autonomous: walk to each burner in range -> top up fuel) ============
-- Self-contained composite: the mod finds every burner machine (one with a fuel inventory) of the
-- FUEL_TYPES within `radius` of the companion, walks to each (nearest-first), and tops it up FROM
-- THE COMPANION'S OWN INVENTORY (native insert -> consumes real coal, no cheat). Replaces the Python
-- go_to + fuel + poll loop over a hardcoded machine list.
-- ROUND-ROBIN, not greedy: with scarce coal, filling burner #1 to `per` in one visit can exhaust the
-- WHOLE supply before burner #2 is ever tried (the top-of-tick "out of coal -> done" check fires
-- first) -- observed live as "only the first furnace gets fed". Each burner is visited AT MOST ONCE
-- per round (tracked in `served`, reset when a round completes); a burner still short after being
-- served waits for the NEXT round, so every reachable burner gets a turn before any one is topped off
-- twice, spreading a limited supply evenly instead of draining it on whichever is nearest.
-- Valid entity TYPES (not names): burner-inserter's type is "inserter"; electric inserters/drills
-- return nil get_fuel_inventory() and are skipped, so filtering by type + fuel-inv is exact.
local FUEL_TYPES = {"furnace", "boiler", "inserter", "mining-drill"}
local APPROACH_TIMEOUT = 900   -- ticks (~15s@60ups): give up on an unreachable burner, skip it
-- _tile_key is defined once above (shared with the gather blacklist).

local function find_next_burner(surf, from, radius, per, blacklist, served)
  local es = surf.find_entities_filtered{position = from, radius = radius, type = FUEL_TYPES}
  table.sort(es, function(a, b) return u.distance(a.position, from) < u.distance(b.position, from) end)
  for _, e in ipairs(es) do
    local key = _tile_key(e.position)
    if e.valid and not blacklist[key] and not served[key] then
      local fi = e.get_fuel_inventory()
      if fi and fi.get_item_count("coal") < per then return e end   -- burner (electric = nil fi) that needs topping up
    end
  end
  return nil
end

function M.start_fuel_group(cid, per, radius)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  -- Same task-pool-ownership guard as start_gather above (2026-07-08, task #42).
  if storage.active_step and storage.active_step[cid] then
    return {error = "companion busy with an active task-pool step"}
  end
  storage.fuel_queues[cid] = {per = per or 20, radius = radius or 200, state = "find",
                              blacklist = {}, served = {}, fueled = 0, machines = 0}
  return {started = true, per = per or 20, radius = radius or 200}
end

function M.tick_fuel_queues()
  process_queue("fuel_queues", function(cid, q, c)
    local surf = c.entity.surface
    local inv = c.entity.get_main_inventory()

    -- TERMINAL: freeze here until get_fuel_status consumes+clears this entry -- same fix as the
    -- build queue: deleting the entry the instant it's done meant a Python poll a moment later saw
    -- plain "active:false" with NO fueled/machines counts (observed live: real coal WAS split across
    -- both furnaces, but the reported result said "fueled:0, machines:0" because the run finished
    -- inside the first 2s poll interval, before Python ever saw an in-progress snapshot).
    if q.state == "done" then return false end

    if inv.get_item_count("coal") <= 0 then q.state = "done"; return false end   -- out of coal -> done

    if q.state == "find" then
      local e = find_next_burner(surf, c.entity.position, q.radius, q.per, q.blacklist, q.served)
      if not e then
        if next(q.served) then q.served = {}; return false end   -- round complete, some still need more -> new round
        q.state = "done"; return false                           -- truly nothing left to fuel -> done
      end
      q.target_pos = {x = e.position.x, y = e.position.y}
      q.target_key = _tile_key(e.position)
      q.approach_deadline = game.tick + APPROACH_TIMEOUT
      storage.walking_queues[cid] = {target = surf.find_non_colliding_position("character", e.position, 2, 0.5) or e.position}
      q.state = "approach"
      return false
    end

    if q.state == "approach" then
      if u.distance(c.entity.position, q.target_pos) <= (c.entity.reach_distance or 10) then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "fuel"
      elseif game.tick >= (q.approach_deadline or 0) then    -- unreachable -> skip PERMANENTLY (every round)
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.blacklist[q.target_key] = true
        q.state = "find"
      end
      return false
    end

    if q.state == "fuel" then
      q.served[q.target_key] = true                           -- mark BEFORE fueling: at-most-once per ROUND
      local e = surf.find_entities_filtered{position = q.target_pos, radius = 1, type = FUEL_TYPES}[1]
      if e and e.valid then
        local fi = e.get_fuel_inventory()
        local have = inv.get_item_count("coal")
        if fi and have > 0 then
          local want = q.per - fi.get_item_count("coal")
          if want > 0 then
            local r = fi.insert{name = "coal", count = math.min(want, have)}
            if r > 0 then inv.remove{name = "coal", count = r}; q.fueled = q.fueled + r; q.machines = q.machines + 1 end
          end
        end
      end
      q.state = "find"
      return false
    end
    q.state = "done"
    return false
  end)
end

function M.get_fuel_status(cid)
  local q = storage.fuel_queues[cid]
  if not q then return {active = false} end
  if q.state == "done" then
    storage.fuel_queues[cid] = nil
    return {active = false, fueled = q.fueled, machines = q.machines}
  end
  return {active = true, state = q.state, fueled = q.fueled, machines = q.machines}
end

-- ============ CRAFT ============

function M.start_craft(cid, recipe, count)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end

  local proto = prototypes.recipe[recipe]
  if not proto then return {error = "Unknown recipe: " .. recipe} end

  local craftable = c.entity.get_craftable_count(recipe)
  if craftable < 1 then return {error = "Missing ingredients"} end

  local actual = math.min(count, craftable)
  local ticks = math.max(MIN_ACTION_TICKS, (proto.energy or 0.5) * 60)

  storage.craft_queues[cid] = {
    recipe = recipe,
    target = actual,
    crafted = 0,
    ticks_per = ticks,
    tick_start = game.tick
  }

  return {started = true, recipe = recipe, target = actual, ticks_per = ticks}
end

function M.tick_craft_queues()
  process_queue("craft_queues", function(cid, q, c)
    local elapsed = game.tick - q.tick_start
    if elapsed < q.ticks_per then return false end

    local crafted = c.entity.begin_crafting{recipe = q.recipe, count = 1}
    if crafted < 1 then return true end
    -- headless: fire craft-item research triggers the scripted craft would otherwise miss
    u.fire_craft_triggers(c.entity.force, q.recipe, crafted)

    q.crafted = q.crafted + 1
    q.tick_start = game.tick
    return q.crafted >= q.target
  end)
end

function M.get_craft_status(cid)
  local q = storage.craft_queues[cid]
  if not q then return {active = false} end
  return {
    active = true,
    recipe = q.recipe,
    crafted = q.crafted,
    target = q.target,
    progress = math.floor((game.tick - q.tick_start) / q.ticks_per * 100)
  }
end

function M.stop_craft(cid)
  local q = storage.craft_queues[cid]
  if not q then return {stopped = false} end
  local crafted = q.crafted
  storage.craft_queues[cid] = nil
  return {stopped = true, crafted = crafted}
end

-- ============ BUILD ============

-- Entity types that block character movement (used for approach-position search).
-- These MUST be valid Factorio 2.0 prototype TYPE names, not entity names — a
-- single invalid string makes find_entities_filtered{type=...} raise and (without
-- the pcall in control.lua) would crash the whole tick scheduler. Notably:
-- steam-engine's type is "generator"; chests are "container"/"logistic-container".
local SOLID_TYPES = {
  "offshore-pump", "boiler", "generator", "pipe", "pipe-to-ground",
  "mining-drill", "furnace", "assembling-machine", "inserter",
  "transport-belt", "splitter", "underground-belt",
  "lab", "wall", "gate", "electric-pole", "container", "logistic-container",
  "storage-tank", "beacon", "radar", "solar-panel", "accumulator",
  "roboport", "pump", "cliff"
}

-- Find a walkable tile near build_pos from which the character can reach it
local function find_approach_pos(surf, char_pos, build_pos)
  local candidates = {}
  for _, dist in ipairs({5, 4, 6, 3, 7}) do
    for _, angle in ipairs({0, 45, 90, 135, 180, 225, 270, 315}) do
      local rad = math.rad(angle)
      local p = {
        x = math.floor(build_pos.x + dist * math.sin(rad) + 0.5),
        y = math.floor(build_pos.y - dist * math.cos(rad) + 0.5)
      }
      local blocked = surf.find_entities_filtered{position = p, radius = 0.5, type = SOLID_TYPES}
      if #blocked == 0 then
        candidates[#candidates + 1] = {pos = p, dist = u.distance(char_pos, p)}
      end
    end
  end
  if #candidates > 0 then
    table.sort(candidates, function(a, b) return a.dist < b.dist end)
    return candidates[1].pos
  end
  return {x = build_pos.x, y = build_pos.y - 5}
end

-- Remove trees and small rocks from the entity's collision footprint
local function clear_build_area(surf, entity_name, position, inv)
  local proto = prototypes.entity[entity_name]
  if not proto or not proto.collision_box then return end
  local bb = proto.collision_box
  local area = {
    {x = position.x + bb.left_top.x - 0.5, y = position.y + bb.left_top.y - 0.5},
    {x = position.x + bb.right_bottom.x + 0.5, y = position.y + bb.right_bottom.y + 0.5}
  }
  local obstacles = surf.find_entities_filtered{area = area, type = {"tree", "simple-entity"}}
  for _, obs in ipairs(obstacles) do
    if obs.valid then obs.mine{inventory = inv} end   -- MINE (wood/stone into inventory), not free-destroy
  end
end

-- Start a smart build: auto-approach + auto-clear + place
-- State machine: approaching -> clearing -> building -> done
function M.start_build(cid, entity_name, position, direction)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end

  local dir = direction or defines.direction.north
  local inv = c.entity.get_main_inventory()
  if inv.get_item_count(entity_name) < 1 then
    return {error = "No " .. entity_name .. " in inventory"}
  end

  -- Find safe approach position and start walking there
  local approach = find_approach_pos(c.entity.surface, c.entity.position, position)
  storage.walking_queues[cid] = {target = approach}

  storage.build_queues[cid] = {
    entity = entity_name,
    position = position,
    direction = dir,
    approach = approach,
    state = "approaching",
    tick_start = game.tick,
    -- Bounded deadline for the approach walk (2026-07-07, live-caught via
    -- task_pool.lua: a companion that couldn't physically reach the build target
    -- left this queue stuck in "approaching" forever -- CLAUDE.md checklist item
    -- #3, this was the ONE async queue in this file missing the deadline every
    -- other one (tick_gather_queues/tick_fuel_queues/belt_connect) already has).
    -- Same distance-scaled formula as those: 25 ticks/tile, floor 1800.
    approach_deadline = game.tick + math.max(1800, math.floor(
      u.distance(c.entity.position, approach) * 25)),
  }

  return {started = true, entity = entity_name, position = position, state = "approaching"}
end

function M.tick_build_queues()
  process_queue("build_queues", function(cid, q, c)
    local surf = c.entity.surface
    local reach = c.entity.build_distance or 10

    -- TERMINAL: sit here (do nothing more) until get_build_status consumes+clears this entry.
    -- Returning true immediately on failure used to delete the queue in the SAME tick it was set,
    -- so a Python poll a moment later saw plain "active:false" -- indistinguishable from success
    -- (place_smart then reported {"placed": true} for a build that never happened; the entity was
    -- never created, e.g. collision or item consumed mid-walk). Now the failure reason survives
    -- until it is actually read.
    if q.state == "done" or q.state == "failed" then return false end

    -- APPROACHING: wait until character is within build reach of target
    if q.state == "approaching" then
      -- Nil-safe heal for a build_queues entry persisted by an OLDER mod version
      -- (before approach_deadline existed): give it a fresh deadline instead of
      -- either failing it instantly (bare "or 0" would make game.tick>=0 true on
      -- the very next check) or leaving it to hang forever (mirrors the identical
      -- fix already applied to belt_connect's own walking-with-deadline entries).
      if not q.approach_deadline then
        q.approach_deadline = game.tick + math.max(1800, math.floor(
          u.distance(c.entity.position, q.position) * 25))
      end
      if u.distance(c.entity.position, q.position) <= reach then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "clearing"
      elseif game.tick >= q.approach_deadline then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.failed = "cannot reach build target (" .. q.position.x .. "," .. q.position.y .. ")"
        q.state = "failed"
      end
      return false
    end

    -- CLEARING: remove trees/rocks from build footprint
    if q.state == "clearing" then
      clear_build_area(surf, q.entity, q.position, c.entity.get_main_inventory())
      q.state = "building"
      q.tick_start = game.tick
      return false
    end

    -- BUILDING: wait BUILD_TICKS then place
    if q.state == "building" then
      if game.tick - q.tick_start < BUILD_TICKS then return false end

      -- Re-check reach (companion may have drifted)
      if u.distance(c.entity.position, q.position) > reach then
        local approach = find_approach_pos(surf, c.entity.position, q.position)
        storage.walking_queues[cid] = {target = approach}
        q.approach = approach
        q.state = "approaching"
        return false
      end

      -- COLLISION CHECK (same guard the game applies to a player): create_entity does
      -- NOT reject overlaps, so without this the async build could stack a building on
      -- top of another (observed: output furnace overlapping the drill by one row).
      -- Refuse instead of force-overlapping; the caller verifies via entity presence.
      -- This check already runs IMMEDIATELY before create_entity below (same tick, same
      -- function call, zero movement in between) -- the gap task #35 actually needed
      -- closed was never "check happens too early", it was "check fails once -> give up
      -- immediately, no retry at all" (unlike task_pool.lua's OWN candidates check,
      -- which already retries for 60 ticks -- see that fix, commit 464185f -- this was
      -- the one remaining unprotected collision check task #35's own investigation
      -- found). 2026-07-08, Zdendys: "ať je ověření těsně před stavbou, bez jakéhokoli
      -- pohybu" (the check IS already right before the build with no movement -- what
      -- was missing was giving a TRANSIENT collision a chance to clear before failing
      -- the whole task over it). Bounded retry IN PLACE (no re-approach, no step-away --
      -- she's already within reach and isn't moved here), same 60-tick budget as the
      -- task_pool.lua candidates fix, so a genuinely permanent collision still correctly
      -- fails, just after a few retries instead of the very first check.
      if not surf.can_place_entity{name = q.entity, position = q.position,
                                   direction = q.direction, force = c.entity.force} then
        q.collision_retry_deadline = q.collision_retry_deadline or (game.tick + 60)
        if game.tick < q.collision_retry_deadline then
          return false
        end
        -- Diagnostic (2026-07-08, task #35): a bare "Cannot place (collision)" carried
        -- zero forensic info in every prior occurrence -- log what's ACTUALLY at the
        -- target once retries are exhausted, including whether the companion's own
        -- body (collision_box {{-0.2,-0.2},{0.2,0.2}}, verified in base game prototype
        -- data) is the culprit, same "log every retry" lesson as place_pipe()'s own
        -- diagnostic in demonstrator.py.
        local near = surf.find_entities_filtered{position = q.position, radius = 1.5}
        local names = {}
        for _, e in ipairs(near) do
          names[#names + 1] = e.name .. (e.unit_number == c.entity.unit_number and "(COMPANION)" or "")
        end
        -- Tile check (2026-07-08, live-caught same night as this fix): a first live
        -- occurrence showed NO entity/companion overlap at all (AABB boxes computed
        -- by hand, 0.44-tile gap) -- can_place_entity also rejects unbuildable TILES
        -- (water, out-of-map), which find_entities_filtered can never reveal since
        -- tiles aren't entities. Logging the tile name closes that blind spot.
        local tile = surf.get_tile(math.floor(q.position.x), math.floor(q.position.y))
        u.log_error(string.format(
          "build queue: Cannot place %s at (%.1f,%.1f) tile=%s after %d retry ticks -- nearby: %s",
          q.entity, q.position.x, q.position.y, tile and tile.name or "?", 60, table.concat(names, ",")),
          "build_queue")
        q.failed = "Cannot place (collision)"
        q.state = "failed"
        return false
      end

      -- Re-check the item is STILL in inventory right before placing (it may have been consumed
      -- during the walk -- crafted away / dropped). Never create a building for free.
      if c.entity.get_main_inventory().get_item_count(q.entity) < 1 then
        q.failed = "No " .. q.entity .. " in inventory"
        q.state = "failed"
        return false
      end
      local placed = surf.create_entity{
        name = q.entity,
        position = q.position,
        direction = q.direction,
        force = c.entity.force
      }
      -- Only keep the building if a real item was actually consumed; else remove it (no free build).
      local destroyed = false
      if placed and c.entity.remove_item{name = q.entity, count = 1} < 1 then
        placed.destroy()
        destroyed = true
      end
      if not placed then
        q.failed = "create_entity returned nil"
        q.state = "failed"
        return false
      end
      if destroyed then
        q.failed = "item consumed before placement could complete"
        q.state = "failed"
        return false
      end
      -- Capture the REAL post-snap position (2026-07-07, live-caught via task_pool.lua):
      -- create_entity does NOT always place at the exact requested q.position -- Factorio
      -- snaps an entity to its own valid grid alignment (e.g. a 2x2 drill requested at a
      -- 1x1 ore tile's half-tile-centered position (46.5,-185.5) actually landed at
      -- (47,-185), a 0.5-tile shift in both axes). A caller that computes a SECOND
      -- entity's position as an offset from the ORIGINAL requested q.position (not the
      -- real one) can end up overlapping the first entity's real footprint. (placed is
      -- guaranteed valid here -- the destroyed case returned above already.)
      q.placed_position = {x = placed.position.x, y = placed.position.y}
      q.state = "done"
      return false
    end

    return true
  end)
end

function M.get_build_status(cid)
  local q = storage.build_queues[cid]
  if not q then return {active = false} end
  -- Terminal states are consumed HERE (not by tick_build_queues) so the result -- success OR the
  -- failure reason -- survives long enough for a Python poll to actually read it. Previously the
  -- queue was deleted the same tick a failure was detected, so the NEXT poll just saw plain
  -- "active:false" (indistinguishable from success) and place_smart reported a build that never
  -- happened as {"placed": true}.
  if q.state == "done" then
    storage.build_queues[cid] = nil
    return {active = false, placed = true, position = q.placed_position}
  end
  if q.state == "failed" then
    storage.build_queues[cid] = nil
    return {active = false, placed = false, error = q.failed}
  end
  local progress = 0
  if q.state == "approaching" then progress = 10
  elseif q.state == "clearing" then progress = 50
  elseif q.state == "building" then
    progress = 60 + math.floor((game.tick - q.tick_start) / BUILD_TICKS * 40)
  end
  return {
    active = true,
    entity = q.entity,
    position = q.position,
    state = q.state,
    progress = progress
  }
end

function M.stop_build(cid)
  if not storage.build_queues[cid] then return {stopped = false} end
  storage.walking_queues[cid] = nil
  storage.build_queues[cid] = nil
  return {stopped = true}
end

-- ============ BELT CONNECT (Stage 0.2, 2026-07-04) ============
-- Model=WHAT/mod=HOW split (belt/inserter automation plan): the model/Python side already
-- knows the exact relative geometry of what it just built (furnace, drill, assembler --
-- same proven pattern as _build_ore_drill_furnace) and places any INSERTERS itself via the
-- existing fac_building_place/_rotate/fac_inserter_set_filter primitives. This command
-- handles ONLY the one genuinely-new problem: routing a transport-belt corridor between two
-- already-chosen points, avoiding ore patches/water/buildings (pathfind.lua's A*), with an
-- underground-belt straight-line fallback (max 4 tiles, yellow tier) for a gap no walkable
-- route crosses. No `material`/inserter-type param -- narrower than the original plan
-- sketch (which had this command also place+type both end inserters); simplified during
-- implementation per the plan's own flagged Open Question #3 ("exact algorithm needs its
-- own design pass"). Async like fac_building_place_start/_status: the companion really
-- walks the path (no teleporting) and consumes real transport-belt/underground-belt items,
-- one tile per queue tick.
-- Confirmed straight from the engine's own prototype data (not the ambiguous/contradictory
-- wiki wording -- cubic dev ai bot flagged this as an off-by-one, 2026-07-04):
-- /base/prototypes/entity/transport-belts.lua's "underground-belt" (yellow tier) entry has
-- max_distance = 5 -- entrance and exit tiles can be up to 5 tiles apart (4 tiles of actual
-- underground gap in between), NOT 4 tiles apart. Named to match the engine field exactly
-- so this stays unambiguous.
local UNDERGROUND_MAX_DISTANCE = 5   -- yellow-tier underground-belt (entrance-to-exit span)

local function step_dir(a, b)
  if b.x > a.x then return defines.direction.east end
  if b.x < a.x then return defines.direction.west end
  if b.y > a.y then return defines.direction.south end
  return defines.direction.north
end

function M.start_belt_connect(cid, from_pos, to_pos)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  -- Same task-pool-ownership guard as start_gather/start_fuel_group (2026-07-08, task
  -- #42) -- safe here (unlike start_build) since task_pool.lua never calls
  -- start_belt_connect internally, only the direct fac_belt_connect command does.
  if storage.active_step and storage.active_step[cid] then
    return {error = "companion busy with an active task-pool step"}
  end
  local surf = c.entity.surface
  local force = c.entity.force

  local path, reason = pathfind.find_path(surf, from_pos, to_pos, force)
  if not path then
    -- No walkable route at all within the search budget -- try a direct underground-belt
    -- pair across the gap (only when it's a straight axis-aligned hop within the yellow
    -- tier's max distance; A* already tried routing AROUND anything shorter/bypassable).
    local fx, fy = math.floor(from_pos.x), math.floor(from_pos.y)
    local tx, ty = math.floor(to_pos.x), math.floor(to_pos.y)
    local same_row = (fx == tx) or (fy == ty)
    local dist = math.abs(tx - fx) + math.abs(ty - fy)
    if same_row and dist >= 1 and dist <= UNDERGROUND_MAX_DISTANCE then
      path = {
        {x = fx, y = fy, dir = step_dir({x = fx, y = fy}, {x = tx, y = ty}), underground = "entrance"},
        {x = tx, y = ty, dir = step_dir({x = fx, y = fy}, {x = tx, y = ty}), underground = "exit"},
      }
    else
      -- `reason` distinguishes WHY find_path failed (task #43 diagnostic follow-up,
      -- 2026-07-10): "start-blocked" / "dest-blocked" / "budget-exhausted". Additive
      -- only -- `error` stays exactly "no path" so every existing caller checking
      -- `.get("error")` for truthiness is unaffected.
      return {error = "no path", reason = reason or "budget-exhausted"}
    end
  else
    -- Recompute each tile's direction as OUTGOING (toward the next tile), not the A*
    -- search's internal "arrived from" bookkeeping -- a Factorio belt's direction is the
    -- way it moves items (matches the tile-to-tile step it feeds INTO), so tile i's belt
    -- must face tile i+1, not tile i-1. The last tile has no next -- continue straight.
    for i = 1, #path do
      if path[i + 1] then
        path[i].dir = step_dir(path[i], path[i + 1])
      else
        path[i].dir = (path[i - 1] and path[i - 1].dir) or defines.direction.north
      end
    end
  end

  local need_belt, need_underground = 0, 0
  for _, node in ipairs(path) do
    if node.underground then need_underground = need_underground + 1
    else need_belt = need_belt + 1 end
  end

  local inv = c.entity.get_main_inventory()
  local have_belt = inv.get_item_count("transport-belt")
  local have_underground = inv.get_item_count("underground-belt")
  if have_belt < need_belt or have_underground < need_underground then
    return {
      error = "Insufficient belt items", need_belt = need_belt, need_underground = need_underground,
      have_belt = have_belt, have_underground = have_underground
    }
  end

  storage.belt_queues[cid] = {path = path, idx = 1, tiles_placed = 0, state = "placing"}
  return {started = true, tiles = #path, need_belt = need_belt, need_underground = need_underground}
end

function M.tick_belt_queues()
  process_queue("belt_queues", function(cid, q, c)
    -- TERMINAL: sit here until get_belt_connect_status consumes+clears this entry (same
    -- fix as tick_build_queues -- otherwise a poll a moment after completion just sees
    -- plain "active:false", indistinguishable from success).
    if q.state == "done" or q.state == "failed" then return false end

    local surf = c.entity.surface
    local reach = c.entity.build_distance or 10
    local node = q.path[q.idx]
    if not node then q.state = "done"; return false end

    if u.distance(c.entity.position, {x = node.x, y = node.y}) > reach then
      -- APPROACH DEADLINE (cubic dev ai bot, 2026-07-04): unlike tick_gather_queues/
      -- tick_fuel_queues, this had NO elapsed-time guard at all -- a permanently blocked
      -- tile (water/cliff/train in the way) left q.walking=true and this branch returning
      -- `false` (still active) forever, hanging get_belt_connect_status indefinitely with
      -- no way for a caller to ever learn it failed. Same distance-scaled deadline formula
      -- as tick_gather_queues (25 ticks/tile, floor 1800) so a legitimately long walk isn't
      -- cut short but a genuinely stuck one bails instead of hanging.
      -- Also (re)seed the deadline if it's simply MISSING, not just on the first tick of
      -- walking: `storage` is Factorio's persistent save-game state, so a belt_queues entry
      -- written by an OLDER mod version (before approach_deadline existed) could still have
      -- q.walking=true with no deadline after a save/reload -- `(q.approach_deadline or 0)`
      -- would then make `game.tick >= 0` true on the very next tick and kill a build that's
      -- still genuinely walking (cubic dev ai bot, 2026-07-04). Healing it here (instead of
      -- just nil-guarding the comparison) gives that legacy entry a fresh, bounded deadline
      -- rather than either failing it instantly OR leaving it to hang forever again.
      if not q.walking or not q.approach_deadline then
        q.approach_deadline = game.tick + math.max(1800, math.floor(
          u.distance(c.entity.position, {x = node.x, y = node.y}) * 25))
        if not q.walking then
          storage.walking_queues[cid] = {
            target = surf.find_non_colliding_position("character", {x = node.x, y = node.y}, 3, 0.5)
                     or {x = node.x, y = node.y}
          }
          q.walking = true
        end
      elseif game.tick >= q.approach_deadline then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.failed = "cannot reach belt tile (" .. node.x .. "," .. node.y .. ") -- " ..
                   (q.idx) .. "/" .. #q.path .. " placed before giving up"
        q.state = "failed"
      end
      return false
    end
    if q.walking then
      storage.walking_queues[cid] = nil
      c.entity.walking_state = {walking = false}
      q.walking = false
    end

    local item = node.underground and "underground-belt" or "transport-belt"
    local pos = {x = node.x, y = node.y}
    if c.entity.get_main_inventory().get_item_count(item) < 1 then
      q.failed = "Out of " .. item .. " mid-build (" .. q.idx .. "/" .. #q.path .. " placed)"
      q.state = "failed"; return false
    end
    -- `type` (input/output) is a create_entity-only field for underground belts, not a
    -- valid can_place_entity param -- keep the collision check's args separate so an
    -- unrecognized key can't make the check itself error or behave unexpectedly.
    if not surf.can_place_entity{name = item, position = pos, direction = node.dir, force = c.entity.force} then
      q.failed = "Cannot place " .. item .. " at (" .. node.x .. "," .. node.y .. ")"
      q.state = "failed"; return false
    end
    local create_args = {name = item, position = pos, direction = node.dir, force = c.entity.force}
    if node.underground then create_args.type = (node.underground == "entrance") and "input" or "output" end
    local placed = surf.create_entity(create_args)
    if not placed then
      q.failed = "create_entity returned nil"
      q.state = "failed"; return false
    end
    -- Never a free build: consume the real item, undo if it somehow isn't there anymore.
    if c.entity.remove_item{name = item, count = 1} < 1 then
      placed.destroy()
      q.failed = "item vanished before consuming"
      q.state = "failed"; return false
    end
    q.tiles_placed = q.tiles_placed + 1
    q.idx = q.idx + 1
    if q.idx > #q.path then q.state = "done" end
    return false
  end)
end

function M.get_belt_connect_status(cid)
  local q = storage.belt_queues[cid]
  if not q then return {active = false} end
  if q.state == "done" then
    storage.belt_queues[cid] = nil
    return {active = false, connected = true, tiles = q.tiles_placed}
  end
  if q.state == "failed" then
    storage.belt_queues[cid] = nil
    return {active = false, connected = false, error = q.failed, tiles = q.tiles_placed}
  end
  return {active = true, tiles_placed = q.tiles_placed, tiles_total = #q.path}
end

function M.stop_belt_connect(cid)
  if not storage.belt_queues[cid] then return {stopped = false} end
  storage.walking_queues[cid] = nil
  storage.belt_queues[cid] = nil
  return {stopped = true}
end

-- ============ COMBAT ============

function M.start_combat(cid, target_pos)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end

  local enemies = c.entity.surface.find_entities_filtered{
    position = target_pos,
    radius = 10,
    force = "enemy",
    type = {"unit", "unit-spawner"}
  }
  if #enemies == 0 then return {error = "No enemies"} end

  table.sort(enemies, function(a, b)
    return u.distance(a.position, c.entity.position) < u.distance(b.position, c.entity.position)
  end)

  storage.combat_queues[cid] = {
    targets = enemies,
    current = enemies[1],
    cooldown = 0,
    kills = 0
  }

  return {started = true, targets = #enemies}
end

function M.tick_combat_queues()
  process_queue("combat_queues", function(cid, q, c)
    if q.cooldown > 0 then
      q.cooldown = q.cooldown - TICK_INTERVAL
      return false
    end

    if not q.current or not q.current.valid then
      -- Find next valid target (build new list to avoid mutation during iteration)
      local valid_targets = {}
      for _, t in ipairs(q.targets) do
        if t.valid then valid_targets[#valid_targets + 1] = t end
      end
      q.targets = valid_targets

      if #q.targets == 0 then
        c.entity.shooting_state = {state = defines.shooting.not_shooting}
        return true
      end
      q.current = table.remove(q.targets, 1)
    end

    local dist = u.distance(c.entity.position, q.current.position)

    if dist <= ATTACK_RANGE then
      c.entity.shooting_state = {
        state = defines.shooting.shooting_enemies,
        position = q.current.position
      }
      q.cooldown = ATTACK_COOLDOWN
    else
      c.entity.shooting_state = {state = defines.shooting.not_shooting}
      local dir = u.get_direction(c.entity.position, q.current.position)
      if dir then c.entity.walking_state = {walking = true, direction = dir} end
    end
    return false
  end)
end

function M.get_combat_status(cid)
  local q = storage.combat_queues[cid]
  if not q then return {active = false} end

  local remaining = #q.targets
  if q.current and q.current.valid then remaining = remaining + 1 end

  return {
    active = true,
    targets_remaining = remaining,
    current_target = q.current and q.current.valid and q.current.name or nil
  }
end

function M.stop_combat(cid)
  local q = storage.combat_queues[cid]
  if not q then return {stopped = false} end

  local c = valid_companion(cid)
  if c then
    c.entity.shooting_state = {state = defines.shooting.not_shooting}
    c.entity.walking_state = {walking = false}
  end

  storage.combat_queues[cid] = nil
  return {stopped = true}
end

return M
