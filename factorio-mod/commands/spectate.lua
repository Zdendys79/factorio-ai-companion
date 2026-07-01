-- AI Companion: spectate commands -- let a connected player watch a companion as a native SPECTATOR
-- (free-fly camera, no character, cannot interfere) with the camera auto-following the companion.
-- Native + server-side (tick handler), so no external RCON teleport loop / console spam is needed.
local u = require("commands.init")

local M = {}

-- storage.spectators[player_index] = companion_id  (who is following whom)

-- fac_spectate <player_name> <companion_id_or_name>
commands.add_command("fac_spectate", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)$", cmd.parameter)
    local pname, cident = args[1], args[2]
    if not pname or not cident then u.error_response("Usage: fac_spectate <player> <companion>") return end
    local p = game.players[pname]
    if not p then u.error_response("No such player: " .. tostring(pname)) return end
    local id, c = u.find_companion(cident)
    if not id then u.not_found(cident) return end
    p.set_controller{type = defines.controllers.spectator}
    storage.spectators = storage.spectators or {}
    storage.spectators[p.index] = id
    if c.entity and c.entity.valid then p.teleport(c.entity.position, c.entity.surface) end
    u.json_response({spectating = true, player = pname, companion = id})
  end)
end)

-- fac_spectate_stop <player_name>  (stops the camera follow; the player stays a spectator)
commands.add_command("fac_spectate_stop", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)$", cmd.parameter)
    local pname = args[1]
    if not pname then u.error_response("Usage: fac_spectate_stop <player>") return end
    local p = game.players[pname]
    if p and storage.spectators then storage.spectators[p.index] = nil end
    u.json_response({spectating = false, player = pname})
  end)
end)

-- Called from control.lua's on_nth_tick: keep each spectator's camera centered on its companion.
-- Auto-clears the entry if the player left, un-spectated, or the companion is gone.
function M.tick_spectators()
  if not storage.spectators then return end
  for pidx, cid in pairs(storage.spectators) do
    local p = game.players[pidx]
    if not (p and p.connected and p.controller_type == defines.controllers.spectator) then
      storage.spectators[pidx] = nil
    else
      local c = u.get_companion(cid)
      if c and c.entity and c.entity.valid then
        p.teleport(c.entity.position, c.entity.surface)
      end
    end
  end
end

return M
