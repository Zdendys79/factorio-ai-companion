-- The scout (factorio-ai docs/second_helper_serine.md, "The scout"; game rule 50 (1), Zdendys:
-- the second helper walks a spiral round the base from the start, its radius growing, out to
-- about 2000 tiles and on while she has no other work, so the deposits, wells, water and cliffs
-- are known before they are needed).
--
-- A companion with the role "scout" takes no team task (team.pick skips her); Python walks her
-- along the spiral (/fac_move_to). What she sees is booked as for every companion
-- (commands/seen_map.lua).
--
-- /fac_companion_role <cid> <scout|none> -> {id, role}
local u = require("commands.init")

commands.add_command("fac_companion_role", nil, function(cmd)
  u.safe_command(function()
    local w = {}
    for x in string.gmatch(cmd.parameter or "", "%S+") do w[#w + 1] = x end
    local id, c = u.find_companion(w[1] or "")
    if not c or (w[2] ~= "scout" and w[2] ~= "none") then
      u.json_response({error = "usage: /fac_companion_role <cid> <scout|none>"})
      return
    end
    c.role = (w[2] == "scout") and "scout" or nil
    u.json_response({id = id, role = c.role or "none"})
  end)
end)
