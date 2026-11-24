-- The task journal (factorio-ai docs/run_timeline.md): every task of the pool that ended
-- -- done, failed or cancelled -- with its kind, who asked (the companion), when it was
-- made and ended, why it failed, and each step's type, start and end tick, place and
-- tiles walked (task_pool_ledger.step_record). Python reads it in order once in a while
-- (/fac_task_journal <after seq>) and keeps it in a file: a run's timeline is made from it.
--
-- storage.task_journal = {seq = the last number given, items = {[seq] = entry}}; at most
-- KEEP entries (the oldest dropped first).
-- /fac_task_journal <after> -> {last = seq, first = the oldest kept, items = [entry with
--   seq > after, at most PAGE]}
local u = require("commands.init")

local M = {}

M.KEEP = 4000
M.PAGE = 50

local function book()
  storage.task_journal = storage.task_journal or {seq = 0, items = {}, first = 1}
  return storage.task_journal
end

-- Add the ended task `t` (its id `task_id`).
function M.add(task_id, t)
  local j = book()
  j.seq = j.seq + 1
  j.items[j.seq] = {seq = j.seq, id = task_id, cid = t.cid, kind = t.kind, status = t.status,
                    error = t.error and tostring(t.error) or nil, created = t.created_tick,
                    done = t.done_tick, steps = t.step_ticks}
  while j.seq - j.first + 1 > M.KEEP do
    j.items[j.first] = nil
    j.first = j.first + 1
  end
end

commands.add_command("fac_task_journal", nil, function(cmd)
  u.safe_command(function()
    local after = tonumber(cmd.parameter or "") or 0
    local j = storage.task_journal or {seq = 0, items = {}, first = 1}   -- (read only)
    local out = {}
    -- (a reader behind the oldest kept entry goes on from that one)
    local from = math.max(after + 1, j.first)
    for seq = from, math.min(j.seq, from + M.PAGE - 1) do
      out[#out + 1] = j.items[seq]
    end
    u.json_response({last = j.seq, first = j.first, items = out})
  end)
end)

return M
