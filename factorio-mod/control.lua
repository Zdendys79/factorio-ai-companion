-- AI Companion - Factorio 2.x
local u = require("commands.init")
local queues = require("commands.queues")
local spectate = require("commands.spectate")

-- Get version dynamically from mod info
local MOD_VERSION = script.active_mods["ai-companion"] or "unknown"

-- Decorative rocks worth opportunistically clearing (2026-07-05, Zdendys's exhaustive
-- list: "Vsechny hledane typy kamenu jsou: Big rock, big sandy rock: 120 tick / Huge
-- rock: 180tick"). Named explicitly rather than matching the broader type='simple-entity'
-- prototype category: that type ALSO covers a lot of other-planet Space Age content
-- (Vulcanus volcanic-rock/stromatolite/demolisher-corpse, Fulgora rock/ruins,
-- lithium-iceberg, etc. -- confirmed live via prototypes.entity, 2026-07-05) that must
-- NOT be swept up by a home-planet obstacle-clearing rule if the companion ever operates
-- elsewhere. Trees, by contrast, ARE matched by the generic type='tree' prototype
-- category everywhere below -- confirmed live that this correctly covers every variant
-- Zdendys listed (tree-01/02/07/08/09 and color variants, dry-tree, dead-grey-trunk,
-- dead-tree-desert, dead-dry-hairy-tree, dry-hairy-tree), so no equivalent name list is
-- needed for trees.
local CLEARABLE_ROCK_NAMES = {"big-rock", "big-sand-rock", "huge-rock"}

local function init_storage()
  storage.companion_messages = storage.companion_messages or {}
  storage.companions = storage.companions or {}
  storage.dead_companions = storage.dead_companions or {}
  storage.companion_next_id = storage.companion_next_id or 1
  storage.walking_queues = storage.walking_queues or {}
  storage.context_clear_requests = storage.context_clear_requests or {}
  storage.errors = storage.errors or {}
  storage.companion_markers = storage.companion_markers or {}
  storage.path_requests = storage.path_requests or {}
  queues.init()
end

local function cleanup_messages()
  local new_msgs, now = {}, game.tick
  for _, m in ipairs(storage.companion_messages) do
    if not m.read or (now - m.tick) < 18000 then new_msgs[#new_msgs + 1] = m end
  end
  if #new_msgs > 100 then
    local trimmed = {}
    for i = #new_msgs - 99, #new_msgs do trimmed[#trimmed + 1] = new_msgs[i] end
    new_msgs = trimmed
  end
  storage.companion_messages = new_msgs
end

script.on_init(function()
  init_storage()
  game.print("[AI Companion] v" .. MOD_VERSION .. " ready. /fac for help", u.print_color(u.COLORS.system))
end)

script.on_configuration_changed(function()
  init_storage()
  game.print("[AI Companion] Updated to v" .. MOD_VERSION, u.print_color(u.COLORS.system))
end)

local subcommands = {}

subcommands.spawn = function(player, args)
  local count = math.min(tonumber(args) or 1, 10)
  table.insert(storage.companion_messages, {player = player.name, message = "spawn " .. count, tick = game.tick, read = false, spawn_request = count})
  game.print("[" .. player.name .. "] Spawn " .. count .. " companion(s)...", u.print_color(u.COLORS.player))
end

subcommands.list = function(player)
  local count = 0
  for id, c in pairs(storage.companions) do
    if c.entity and c.entity.valid then
      local p = c.entity.position
      game.print(string.format("[#%d] (%.1f, %.1f)", id, p.x, p.y), u.print_color(c.color or u.get_companion_color(id)))
      count = count + 1
    else storage.companions[id] = nil end
  end
  if count == 0 then game.print("[AI Companion] No companions. /fac spawn", u.print_color(u.COLORS.system)) end
end

subcommands.kill = function(player, args)
  local id, killed = tonumber(args), 0
  local function kill_one(cid)
    local c = storage.companions[cid]
    if c then
      if c.label and c.label.valid then c.label.destroy() end
      -- Remove map marker
      if storage.companion_markers and storage.companion_markers[cid] then
        if storage.companion_markers[cid].valid then storage.companion_markers[cid].destroy() end
        storage.companion_markers[cid] = nil
      end
      if c.entity and c.entity.valid then c.entity.destroy(); killed = killed + 1 end
      storage.companions[cid] = nil
    end
  end
  if id then kill_one(id) else for cid in pairs(storage.companions) do kill_one(cid) end end
  game.print("[AI Companion] Killed " .. killed, u.print_color(u.COLORS.system))
end

subcommands.clear = function()
  local count = #storage.companion_messages
  storage.companion_messages = {}
  game.print("[AI Companion] Cleared " .. count .. " msg(s)", u.print_color(u.COLORS.system))
end

subcommands.name = function(player, args)
  local id_str, name = args:match("^(%d+)%s+(.+)$")
  local id = tonumber(id_str)
  if not id or not name then player.print("/fac name <id> <name>", u.print_color(u.COLORS.system)); return end
  local c = u.get_companion(id)
  if not c then player.print("#" .. id .. " not found", u.print_color(u.COLORS.error)); return end
  c.name = name
  if c.label and c.label.valid then c.label.destroy() end
  local color = c.color or u.get_companion_color(id)
  c.label = u.render_label(c.entity, name .. "(#" .. id .. ")", color)
  game.print("#" .. id .. " -> " .. name, u.print_color(color))
end

local function handle_fac(cmd)
  local ok, err = pcall(function()
    local player = cmd.player_index and game.players[cmd.player_index]
    if cmd.player_index and (not player or not player.valid) then return end
    local param = cmd.parameter
    if not param or param == "" then
      if player then player.print("/fac <msg> | <id> <msg> | spawn | list | kill | clear | name", u.print_color(u.COLORS.system)) end
      return
    end
    local first, rest = param:match("^(%S+)%s+(.+)$")
    if first and rest and not subcommands[first] then
      local id, comp = u.find_companion(first)
      if id then
        table.insert(storage.companion_messages, {player = player.name, message = rest, tick = game.tick, read = false, target_companion = id})
        game.print("[" .. player.name .. " -> " .. u.get_companion_display(id) .. "] " .. rest, u.print_color(comp.color or u.get_companion_color(id)))
        return
      end
    end
    local sub, args = param:match("^(%S+)%s*(.*)")
    if subcommands[sub] then subcommands[sub](player, args)
    else
      table.insert(storage.companion_messages, {player = player and player.name or "server", message = param, tick = game.tick, read = false})
      game.print("[" .. (player and player.name or "server") .. "] " .. param, u.print_color(u.COLORS.player))
    end
  end)
  if not ok then u.error_response(err, "fac"); game.print("Error: " .. tostring(err), u.print_color(u.COLORS.error)) end
end

commands.add_command("fac", "AI Companion", handle_fac)

require("commands.action")
require("commands.building")
require("commands.chat")
require("commands.companion")
require("commands.context")
require("commands.item")
require("commands.move")
require("commands.research")
require("commands.resource")
require("commands.world")
require("commands.combat")
require("commands.help")

-- Update companion map markers
local function update_companion_markers()
  if not storage.companion_markers then storage.companion_markers = {} end
  for cid, c in pairs(storage.companions) do
    if c.entity and c.entity.valid then
      local marker = storage.companion_markers[cid]
      local display = u.get_companion_display(cid)
      -- Create marker if doesn't exist
      if not marker or not marker.valid then
        local force = c.entity.force
        local surf = c.entity.surface
        marker = force.add_chart_tag(surf, {
          position = c.entity.position,
          text = display
        })
        storage.companion_markers[cid] = marker
      else
        -- Update marker position
        marker.position = c.entity.position
      end
    else
      -- Companion died/invalid, remove marker
      local marker = storage.companion_markers[cid]
      if marker and marker.valid then marker.destroy() end
      storage.companion_markers[cid] = nil
    end
  end
end

-- Run one tick subsystem defensively: a runtime error (e.g. an invalid
-- prototype-type filter) must NEVER propagate out of on_nth_tick, or it would
-- crash the whole scheduler / the game. Errors are recorded and printed
-- throttled (once per ~5s) instead.
local function guard_tick(name, fn, tick)
  local ok, err = pcall(fn)
  if not ok then
    storage.errors = storage.errors or {}
    storage.errors[name] = {tick = tick, error = tostring(err)}
    if tick % 300 == 0 then
      game.print("[AI Companion] " .. name .. " tick error: " .. tostring(err),
        u.print_color(u.COLORS.error))
    end
  end
end

-- Trees matched by the generic type='tree' prototype category (covers every variant,
-- confirmed live 2026-07-05 -- see CLEARABLE_ROCK_NAMES comment above for why rocks are
-- NOT matched this same broad way) + the exact named rocks worth clearing. Two separate
-- find_entities_filtered calls (Factorio's filter ANDs type/name together within one
-- call, it can't OR a type against a name list) merged into one result list.
local function find_clearable_obstacles(surf, pos, radius)
  local trees = surf.find_entities_filtered{position = pos, radius = radius, type = "tree"}
  local rocks = surf.find_entities_filtered{position = pos, radius = radius, name = CLEARABLE_ROCK_NAMES}
  local out = {}
  for _, e in ipairs(trees) do out[#out + 1] = e end
  for _, e in ipairs(rocks) do out[#out + 1] = e end
  return out
end

-- Ask the game pathfinder for a route to q.target that goes AROUND large obstacles
-- (water, cliffs) -- the straight-line + perpendicular bypass only clears small
-- stuff (trees/rocks) and cannot navigate around a lake. Result arrives async via
-- on_script_path_request_finished and is stored as q.path (list of waypoints).
local function request_walk_path(cid, q, e)
  local proto = prototypes.entity["character"]
  local ok, id = pcall(function()
    return e.surface.request_path{
      bounding_box = proto.collision_box,
      collision_mask = proto.collision_mask,
      start = e.position,
      goal = q.target,
      force = e.force,
      radius = 2,
      can_open_gates = true,
      -- CRITICAL: ignore the companion itself, otherwise its own collision box makes
      -- the START position collide -> pathfinder returns nil (no path) every time.
      entity_to_ignore = e,
      pathfind_flags = {cache = false, low_priority = false},
    }
  end)
  if ok and id then
    storage.path_requests[id] = cid
    q.path_pending = true
    q.path_req_tick = game.tick
  else
    -- API/call failed -> fall back to straight-line; retry later
    q.path_failed_tick = game.tick
  end
end

script.on_event(defines.events.on_script_path_request_finished, function(ev)
  local cid = storage.path_requests and storage.path_requests[ev.id]
  if not cid then return end
  storage.path_requests[ev.id] = nil
  local q = storage.walking_queues and storage.walking_queues[cid]
  if not q then return end
  q.path_pending = false
  if ev.path and #ev.path > 0 then
    q.path = ev.path           -- array of {position=, needs_destroy_to_reach=}
    q.path_idx = 1
  else
    q.path = nil               -- no route found / try later -> straight-line fallback
    q.path_failed_tick = game.tick
  end
end)

-- Walking queues: follow a pathfinder route around obstacles when available, with
-- straight-line + perpendicular bypass as the fallback for small obstacles.
local function process_walking_queues()
  if not storage.walking_queues then return end
  for cid, q in pairs(storage.walking_queues) do
    local c = u.get_companion(cid)
    if not c then storage.walking_queues[cid] = nil; goto skip end
    if q.follow_player then
      local p = game.players[q.follow_player]
      if p and p.valid then q.target = {x = p.position.x, y = p.position.y}
      else storage.walking_queues[cid] = nil; goto skip end
    end
    if not q.target then storage.walking_queues[cid] = nil; goto skip end
    local e = c.entity
    local dist = u.distance(e.position, q.target)

    -- Proactive reach=1 clearing (2026-07-05, Zdendys): "kdykoli companion narazi na
    -- okrasny kamen (entitu, nikoli naleziste kamene), nebo jakykoli strom (v dosahu 1
    -- od postavy) vytezi ho" -- ANY tree or decorative rock within reach=1 gets mined on
    -- sight, regardless of whether the companion is stuck, still approaching, or has
    -- just arrived. MUST run unconditionally BEFORE the dist<2 arrival check below, not
    -- inside the still-approaching `else` branch: live-testing found the two states race
    -- -- a target whose collision box keeps the companion within [1, 2) tiles (e.g. a
    -- big-rock placed as the destination itself) satisfies "arrived" (dist<2) on the very
    -- tick it FIRST comes within reach=1, so a check placed only in the "still walking"
    -- branch never runs at all for that tick (arrival short-circuits into the `if` branch
    -- and removes the queue entry before the `else`'s clearing logic is ever reached).
    --
    -- NATIVE sustained mining (2026-07-05, Zdendys: "to je zakladni pozadavek jakehokoli
    -- mininguu, to mod nevi?" -- correctly called out): a big-rock's mining_time is real
    -- (tens of ticks or more, same as a player holding the mine button) -- a single
    -- scripted `entity.mine{}` call does NOT model that gradual progress and simply fails
    -- silently on anything with non-trivial mining_time. Reusing the EXACT pattern already
    -- proven for ore/resource harvesting elsewhere in this mod (queues.lua's
    -- start_mining_next/tick_harvest_queues): set `selected` + `mining_state={mining=true,
    -- position=...}` and let the GAME ENGINE run the real mining cycle -- same speed,
    -- animation, extraction as a real player. `q.clearing_target` tracks which entity is
    -- currently being sustained-mined so mining_state is only ever ASSIGNED once per
    -- target: re-assigning it every cycle (every 5 ticks here) would restart the engine's
    -- mining_time countdown from zero every time and it would NEVER complete (the exact
    -- "re-setting mining_state every tick" bug already caught and fixed in
    -- tick_gather_queues, 2026-07-03).
    if q.clearing_target and not q.clearing_target.valid then
      q.clearing_target = nil  -- previous target is gone (fully mined, or otherwise removed)
    end
    -- Stale-but-still-valid target guard (cubic-dev-ai bot, 2026-07-05): a target only
    -- ever got cleared above when the ENTITY itself became invalid -- not when the
    -- companion simply walked away from it (e.g. redirected to a new q.target, or
    -- follow_player moved elsewhere). Factorio's engine auto-cancels mining_state.mining
    -- once the selected entity is out of reach, but q.clearing_target itself stayed set
    -- (still a valid entity, just distant) -- and since ALL new-target acquisition below
    -- is gated by `if not q.clearing_target`, a stale distant target would silently block
    -- the reach=2 AND the radius=4 stuck-fallback scans from EVER picking a new, genuinely
    -- nearby obstacle again, for as long as this walking_queue entry lives (which can be
    -- indefinitely in follow_player mode). 6 tiles = a bit more than the widest radius
    -- (4) either scan below can acquire a target from, so this only fires once the
    -- companion has clearly moved on, not from ordinary approach jitter at the boundary.
    if q.clearing_target and u.distance(e.position, q.clearing_target.position) > 6 then
      q.clearing_target = nil
    end
    if not q.clearing_target then
      -- radius=2, not a literal 1 (2026-07-05, live-tested): collision keeps the
      -- companion's CENTER measurably farther than 1 tile from a big/huge-rock's
      -- CENTER (their collision box extends to ~1-1.5 tiles from center, confirmed via
      -- prototypes.entity[...].collision_box) -- the companion stably parks at ~1.6
      -- tiles away, which IS "right next to it" in any visual/practical sense, just not
      -- within a literal radius=1 sample from center-to-center. radius=2 matches the
      -- SAME threshold this function already uses elsewhere for "arrived" (dist<2), and
      -- still only ever catches things genuinely adjacent (trees have a much smaller
      -- ~0.4-tile collision box and stop even closer).
      local adjacent = find_clearable_obstacles(e.surface, e.position, 2)
      if adjacent[1] then
        q.clearing_target = adjacent[1]
      end
    end
    if q.clearing_target then
      if e.selected ~= q.clearing_target then
        e.selected = q.clearing_target
      end
      if not e.mining_state.mining then
        e.mining_state = {mining = true, position = q.clearing_target.position}
      end
    end

    if dist < 2 then
      e.walking_state = {walking = false}
      if not q.follow_player then storage.walking_queues[cid] = nil end
      q.stuck_ticks = 0
      q.bypass_ticks = 0
    else
      -- Pathfind around big obstacles (water/cliffs): request a route once per
      -- target, then steer toward the current WAYPOINT instead of straight at the
      -- final goal. Falls back to straight-line below while no route is available.
      -- timeout a stuck pending request: if the finished-event never arrives (e.g. the
      -- request id was lost across save/load), reset so pathfinding isn't disabled forever.
      if q.path_pending and q.path_req_tick and (game.tick - q.path_req_tick) > 600 then
        q.path_pending = false
        q.path_failed_tick = game.tick
      end
      if not q.follow_player and not q.path and not q.path_pending then
        local cooling = q.path_failed_tick and (game.tick - q.path_failed_tick) < 180
        if not cooling then request_walk_path(cid, q, e) end
      end
      local goal = q.target
      if q.path and q.path_idx then
        while q.path[q.path_idx] and u.distance(e.position, q.path[q.path_idx].position) < 2 do
          q.path_idx = q.path_idx + 1
        end
        if q.path[q.path_idx] then
          goal = q.path[q.path_idx].position
        else
          q.path = nil  -- consumed all waypoints; head straight to final target
        end
      end

      -- Stuck detection: compare position to previous call
      local prev = q.prev_pos
      local moved = prev and u.distance(prev, e.position) or 1
      q.prev_pos = {x = e.position.x, y = e.position.y}

      -- Stuck AND nothing within reach=1 to sustained-mine (the block above already
      -- covers the common case): the actual blocker may be slightly farther away than
      -- reach=1 (a wider obstacle's collision edge, or simply not centered under the
      -- reach=1 sample point) -- widen the search to radius=4 and target it via the SAME
      -- q.clearing_target + mining_state mechanism (not a separate one-shot entity.mine{}
      -- -- same reasoning as above: mining_time is real, one-shot calls fail silently).
      if moved < 0.3 and not q.clearing_target then
        local nearby = find_clearable_obstacles(e.surface, e.position, 4)
        if nearby[1] then
          q.clearing_target = nearby[1]
          e.selected = nearby[1]
          e.mining_state = {mining = true, position = nearby[1].position}
        end
      end

      if moved < 0.3 then
        q.stuck_ticks = (q.stuck_ticks or 0) + 1
      else
        q.stuck_ticks = 0
        q.bypass_ticks = 0
        q.bypass_side = nil
      end

      local dir_to_target = u.get_direction(e.position, goal)

      if (q.bypass_ticks or 0) > 0 then
        -- Continue bypass: walk perpendicular to unblock
        if q.bypass_dir then
          e.walking_state = {walking = true, direction = q.bypass_dir}
        end
        q.bypass_ticks = q.bypass_ticks - 1
      elseif (q.stuck_ticks or 0) >= 4 then
        -- Stuck for ~0.3s: try perpendicular bypass, alternating left/right
        q.stuck_ticks = 0
        q.bypass_side = ((q.bypass_side or 0) + 1) % 2
        local perp_dirs = {
          [defines.direction.north] = {defines.direction.west, defines.direction.east},
          [defines.direction.south] = {defines.direction.east, defines.direction.west},
          [defines.direction.east]  = {defines.direction.north, defines.direction.south},
          [defines.direction.west]  = {defines.direction.south, defines.direction.north},
          [defines.direction.northeast] = {defines.direction.northwest, defines.direction.southeast},
          [defines.direction.southeast] = {defines.direction.northeast, defines.direction.southwest},
          [defines.direction.southwest] = {defines.direction.southeast, defines.direction.northwest},
          [defines.direction.northwest] = {defines.direction.southwest, defines.direction.northeast},
        }
        local choices = dir_to_target and perp_dirs[dir_to_target]
        if choices then
          q.bypass_dir = choices[(q.bypass_side % 2) + 1]
          q.bypass_ticks = 10  -- bypass for 10 calls (~0.5s)
          e.walking_state = {walking = true, direction = q.bypass_dir}
        end
      else
        -- Normal movement toward target
        if dir_to_target then e.walking_state = {walking = true, direction = dir_to_target} end
      end
    end
    ::skip::
  end
end

script.on_nth_tick(5, function(ev)
  if ev.tick % 1800 == 0 then cleanup_messages() end
  -- Update map markers every 30 ticks (0.5 sec)
  if ev.tick % 30 == 0 then update_companion_markers() end
  -- Process all tick-based queues (each guarded so one failure can't kill the rest)
  guard_tick("harvest", queues.tick_harvest_queues, ev.tick)
  guard_tick("gather",  queues.tick_gather_queues,  ev.tick)
  guard_tick("fuel",    queues.tick_fuel_queues,    ev.tick)
  guard_tick("craft",   queues.tick_craft_queues,   ev.tick)
  guard_tick("build",   queues.tick_build_queues,   ev.tick)
  guard_tick("belt",    queues.tick_belt_queues,    ev.tick)
  guard_tick("combat",  queues.tick_combat_queues,  ev.tick)
  guard_tick("walking", process_walking_queues,     ev.tick)
  guard_tick("spectate", spectate.tick_spectators,  ev.tick)
  guard_tick("orphan_mining", queues.tick_orphan_mining_cleanup, ev.tick)
end)
