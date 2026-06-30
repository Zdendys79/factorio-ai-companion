-- AI Companion v0.7.0 - Move commands
local u = require("commands.init")

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
    storage.walking_queues[id] = {target = {x = x, y = y}}
    u.json_response({id = id, walking_to = {x = x, y = y}})
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
    storage.walking_queues[id] = nil
    c.entity.walking_state = {walking = false}
    u.json_response({id = id, stopped = true})
  end)
end)
