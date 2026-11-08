-- AI Companion v0.7.0 - Move commands
local u = require("commands.init")
local requests = require("commands.controller_requests")

-- Start the controller's walk to (x, y) (fac_move_to now, or its queued request later).
-- giveup_enabled (2026-07-16, Zdendys's fast-giveup directive): ONLY fac_move_to's OWN
-- walks opt into process_walking_queues' fast-giveup check (control.lua) -- every OTHER
-- walking_queues[cid] writer in this mod (queues.start_build's approach walk,
-- task_pool.lua's step-driven movement) omits this field entirely.
--
-- Clear any stale walk_last_outcome (2026-07-16, independent-review finding): without
-- this, staleness protection relied only on Python's OWN giveup timeout (~8640 ticks)
-- being much larger than the mod's new one (600 active ticks) -- an implicit numeric
-- coincidence across two files, not a structural guarantee. Explicitly clearing here
-- means a NEW walk can never see a leftover outcome from a PREVIOUS one.
-- The same for walk_last_arrived: fac_companion_position falls back to it as
-- "walk_target" once the queue is gone. Left over from the PREVIOUS walk, it made a new
-- walk that gave up at once read as arrived: she stood by the old target, and go_to()
-- returned True 14 tiles from the new one (live 2026-11-06, factorio-ai
-- live_verify_lab_pole_route: every pole then "Too far").
local function start_move(id, x, y)
  if storage.walk_last_outcome then storage.walk_last_outcome[id] = nil end
  if storage.walk_last_arrived then storage.walk_last_arrived[id] = nil end
  storage.walking_queues[id] = {target = {x = x, y = y}, giveup_enabled = true}
  return {id = id, walking_to = {x = x, y = y}}
end

requests.register("move", function(cid, a) return start_move(cid, a.x, a.y) end)

commands.add_command("fac_move_to", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+([%d.-]+)%s+([%d.-]+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local x, y = tonumber(args[2]), tonumber(args[3])
    if not x or not y then u.error_response("Invalid coordinates"); return end
    -- Enemy-base protection (Zdendys): never walk the companion to a tile next to a biter
    -- nest, so it can't provoke enemies. The opening never needs to -- a single starting
    -- patch can't be depleted, so every legit target stays near the safe spawn.
    local DANGER = 16
    if c.entity.surface.count_entities_filtered{type = "unit-spawner", position = {x = x, y = y}, radius = DANGER} > 0 then
      u.error_response("target too close to enemy base")
      return
    end
    -- Don't steal the walking queue from an ACTIVE task-pool step (2026-07-08): a step
    -- walking to its own target would never arrive there once redirected. The walk is
    -- queued instead (controller_requests.lua: never refused, started by the scheduler;
    -- fac_companion_position reports walk_queued meanwhile).
    local queued = requests.gate(id, "move", {x = x, y = y}, {x = x, y = y})
    if queued then
      queued.id = id
      u.json_response(queued)
      return
    end
    u.json_response(start_move(id, x, y))
  end)
end)

commands.add_command("fac_move_follow", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(.+)$", cmd.parameter)
    local id = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local pname = args[2]
    if not game.get_player(pname) then u.error_response("Player not found"); return end
    storage.walking_queues[id] = {follow_player = pname}
    u.json_response({id = id, following = pname})
  end)
end)

commands.add_command("fac_move_stop", nil, function(cmd)
  u.safe_command(function()
    local id, c = u.find_companion(cmd.parameter)
    if not id then u.not_found(); return end
    -- Same guard as fac_move_to above (2026-07-08, independent review caught this
    -- gap in the first half of the fix): companion.py's wait_arrive() calls this on
    -- give-up to clean up ITS OWN abandoned walking_queues[id] entry -- but if
    -- fac_move_to's guard above REFUSED an earlier move_to() (task pool owns this
    -- companion), Python never actually claimed the queue in the first place, and
    -- this unconditional clear+halt would instead cut off the task pool's OWN
    -- in-progress walk (storage.walking_queues[id]=nil looks like "arrived" to
    -- task_pool.lua's "walking"->"acting" check, and c.entity.walking_state=false
    -- physically stops her mid-route) -- silently breaking the very thing this
    -- guard was meant to protect. Only clear/halt if the task pool doesn't own her --
    -- then the controller's own walk is only its queued request: that is dropped.
    if storage.active_step and storage.active_step[id] then
      local cancelled = requests.pending(id, "move") ~= nil and requests.cancel(id)
      u.json_response({id = id, stopped = false, cancelled = cancelled,
                       reason = "a task-pool step walks her -- its walk is not stopped"})
      return
    end
    if requests.pending(id, "move") then requests.cancel(id) end
    storage.walking_queues[id] = nil
    c.entity.walking_state = {walking = false}
    u.json_response({id = id, stopped = true})
  end)
end)
