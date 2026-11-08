-- The scheduler's pick log, for the analysis of its priorities (factorio-ai
-- scripts/analyze_pick_priorities.py; Zdendys: how far tasks are, what their values are,
-- how the aging and the nearness balance). Off by default; /fac_task_pool_pick_log on|off.
-- While on, every pick of the task pool's idle dispatch writes one line to the log:
--   [pick] tick=<t> cid=<c> chosen=<id|controller> | <candidate>; <candidate>; ...
-- a candidate: <id>:<kind> p=<base priority> age=<ticks> d=<tiles> eff=<effective>
-- (the controller's pending command: controller:<kind>). Read-only otherwise.
local u = require("commands.init")

local M = {}

-- Whether the log is on.
function M.enabled()
  return storage.task_pool_pick_log == true
end

-- One pick's line.
-- @param cid number the companion
-- @param chosen any the picked task id or the controller's mark
-- @param candidates table [{id, kind, p, age, d, eff}]
function M.write(cid, chosen, candidates)
  local parts = {}
  for _, k in ipairs(candidates) do
    parts[#parts + 1] = string.format("%s:%s p=%.3f age=%d d=%.1f eff=%.4f", tostring(k.id),
      tostring(k.kind), k.p, k.age, k.d, k.eff)
  end
  log(string.format("[pick] tick=%d cid=%d chosen=%s | %s", game.tick, cid, tostring(chosen),
                    table.concat(parts, "; ")))
end

commands.add_command("fac_task_pool_pick_log", nil, function(cmd)
  u.safe_command(function()
    local word = cmd.parameter
    if word == "on" then storage.task_pool_pick_log = true
    elseif word == "off" then storage.task_pool_pick_log = nil
    elseif word ~= nil and word ~= "" then
      u.json_response({error = "usage: on|off"}); return
    end
    u.json_response({pick_log = M.enabled()})
  end)
end)

return M
