-- AI Companion -- RCON entry points for the generic task pool (2026-07-07)
local u = require("commands.init")
local task_pool = require("commands.task_pool")
local priority = require("commands.priority")
local upkeep = require("commands.upkeep")

-- Usage: /fac_upkeep <id> [on|off] -- the mod's own fuel upkeep for the companion
-- (commands/upkeep.lua): switched on / off, or (no argument) its state: enabled and
-- its open upkeep tasks.
commands.add_command("fac_upkeep", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s*(%S*)$", cmd.parameter)
    local id = u.find_companion(args[1])
    if not id then u.not_found(); return end
    if args[2] == "on" then
      upkeep.set_enabled(id, true)
    elseif args[2] == "off" then
      upkeep.set_enabled(id, false)
    elseif args[2] ~= "" then
      u.error_response("Usage: fac_upkeep <id> [on|off]"); return
    end
    local out = upkeep.status(id)
    out.id = id
    u.json_response(out, id)
  end)
end)

-- Usage: /fac_task_submit <id> <json_step_list | {"kind": KIND, "steps": json_step_list}>
-- KIND: build (the default), relocate, dismantle -- the task's base priority
-- (commands/priority.lua).
-- json_step_list is a JSON array of step objects, e.g.
--   [{"type":"find_patch","resource":"iron-ore"},
--    {"type":"verify_tile","resource":"iron-ore"},
--    {"type":"pick_orientation","primary":"burner-mining-drill","secondary":"stone-furnace",
--     "offsets":[[0,2],[0,-2],[2,0],[-2,0]]},
--    {"type":"place","which":"primary","entity":"burner-mining-drill"},
--    {"type":"place","which":"secondary","entity":"stone-furnace"},
--    {"type":"fuel","which":"primary","item":"coal","count":10},
--    {"type":"fuel","which":"secondary","item":"coal","count":10}]
commands.add_command("fac_task_submit", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(.+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local ok, steps = pcall(helpers.json_to_table, args[2])
    if not ok or not steps then
      -- 2026-07-12 (task #46): include the companion id this submit was FOR -- a bare
      -- "Invalid step list JSON" gave no way to tell which companion's task_submit call
      -- failed once several are in flight. Not a dump_context call (no position involved,
      -- this is a JSON-parse failure) -- just the id, via error_response's existing ctx param.
      u.error_response("Invalid step list JSON for companion #" .. id .. ": " .. tostring(steps), "task_submit")
      return
    end
    -- {"kind": "relocate", "steps": [...]} gives the task its kind (its base priority,
    -- commands/priority.lua); a plain step array is a build
    local kind = nil
    if type(steps) == "table" and type(steps.steps) == "table" then
      kind = steps.kind
      steps = steps.steps
    end
    if kind == priority.UPKEEP_KIND then
      u.error_response("kind \"upkeep\" is the mod's own (commands/upkeep.lua)", "task_submit")
      return
    end
    local result = task_pool.submit_task(id, steps, kind)
    result.id = id
    u.json_response(result)
  end)
end)

-- Usage: /fac_task_status <task_id>
commands.add_command("fac_task_status", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%d+)$", cmd.parameter)
    local task_id = tonumber(args[1])
    if not task_id then u.error_response("Usage: fac_task_status <task_id>"); return end
    u.json_response(task_pool.get_task_status(task_id))
  end)
end)

-- Usage: /fac_task_pool_diag <cid>
-- Read-only diagnostic (2026-07-09): dumps active_step/task/walking_queue/busy_elsewhere
-- state for a companion, to root-cause a stuck task-pool job without guessing.
commands.add_command("fac_task_pool_diag", nil, function(cmd)
  u.safe_command(function()
    local id = u.find_companion(cmd.parameter)
    if not id then u.not_found(); return end
    u.json_response(task_pool.get_diag(id))
  end)
end)
