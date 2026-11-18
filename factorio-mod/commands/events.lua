-- Job-end events for the factorio-ai caller (2026-11-18, Zdendys: "synchronise these
-- events between the mod and Python").
--
-- RCON is request/response only: the mod cannot call Python. But it can write a file:
-- every job end -- a task-pool task done / failed / cancelled -- is appended as one JSON
-- line to script-output/ai-companion/events.jsonl (helpers.write_file, for_player 0: the
-- dedicated server's own output), and the caller waits on that file for its job's line
-- instead of polling the job's status over RCON until a real-time timeout. A line:
--   {"seq": N, "tick": T, "kind": "task", "id": task_id, "cid": cid,
--    "status": "done" | "failed" | "cancelled", "error": reason or nil}
-- The file holds the current session only (its first event rewrites it). seq grows by one
-- per event and survives a save (storage.event_seq), so a reader tells
-- new lines from old ones. The last RING events are also kept in storage.events and read
-- by /fac_events <since_seq> -- the fallback when the file cannot be read.
local u = require("commands.init")

local M = {}

M.FILE = "ai-companion/events.jsonl"
local RING = 200
-- the first event after the game loaded (a server start, a save loaded) starts the file
-- afresh, the later ones append: the file holds this session only and never grows past
-- it. A module local -- not storage: it is no game state (the file is the server's own)
local session_started = false

-- Record one event (the module header); its table gains seq and tick.
function M.emit(ev)
  storage.event_seq = (storage.event_seq or 0) + 1
  storage.events = storage.events or {}
  ev.seq = storage.event_seq
  ev.tick = game.tick
  local ring = storage.events
  ring[#ring + 1] = ev
  if #ring > RING then table.remove(ring, 1) end
  local ok, err = pcall(function()
    helpers.write_file(M.FILE, helpers.table_to_json(ev) .. "\n", session_started, 0)
  end)
  if not ok then u.log_error("event not written: " .. tostring(err), "events") end
  session_started = true
end

-- /fac_events <since_seq>: the kept events with seq above since_seq, oldest first.
commands.add_command("fac_events", nil, function(cmd)
  u.safe_command(function()
    local since = tonumber(cmd.parameter) or 0
    local out = {}
    for _, ev in ipairs(storage.events or {}) do
      if ev.seq > since then out[#out + 1] = ev end
    end
    u.json_response({seq = storage.event_seq or 0, events = out})
  end)
end)

return M
