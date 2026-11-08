-- The controller's (Python's) direct commands while a task-pool step holds her: never
-- refused (Zdendys: the mod has no right to refuse -- Python's commands must be carried
-- out), but queued here and started by the task pool when its scheduler picks them
-- (task_pool.lua pick_next). A request's priority is the base priority of a build
-- times log2 of its age in ticks (commands/priority.lua aged -- every command and task
-- ages alike, so one that keeps losing to other steps gains on them -- a far one only
-- slowly, the nearness root weakens it; a fresh
-- one starts with the lowest priority, and is done at once when nothing else waits).
--
-- storage.controller_requests[cid] = {kind, args, pos, tick, id}: the one pending
--   request of a companion (the controller issues one command at a time; a newer one
--   replaces it, logged);
-- storage.controller_request_results[cid] = {kind, result}: a started request whose
--   start failed, until its status poll reads it (the queue's own status reports
--   everything after a successful start).
-- Kinds: "place", "belt", "gather", "fuel", "combat", "move" -- each module registers
-- its starter (M.register) so this file requires none of them. The starter runs when
-- no step holds her, so its own guards pass.
-- /fac_controller_cancel <cid> drops a pending request (the controller gave up on it).
local u = require("commands.init")
local priority = require("commands.priority")

local M = {}

local starters = {}

local function book()
  storage.controller_requests = storage.controller_requests or {}
  storage.controller_request_results = storage.controller_request_results or {}
  return storage.controller_requests, storage.controller_request_results
end

-- Register the function that starts a request of `kind`.
-- @param kind string
-- @param fn function(cid, args) -> table the start's reply ({error = ...} on failure)
function M.register(kind, fn)
  starters[kind] = fn
end

-- Queue a command for later (a step holds her). Replaces a pending one (logged).
-- @param cid number the companion
-- @param kind string a registered kind
-- @param args table the starter's arguments
-- @param pos table|nil where it acts ({x, y}; nil: wherever she stands)
-- @return table the command's reply: {queued = true, request = id, kind = kind}
function M.defer(cid, kind, args, pos)
  local pending = book()
  local old = pending[cid]
  if old then
    log("[ai-companion] controller request " .. old.id .. " (" .. old.kind
        .. ") replaced by a new " .. kind .. " request")
  end
  storage.next_controller_request = (storage.next_controller_request or 0) + 1
  pending[cid] = {kind = kind, args = args, pos = pos, tick = game.tick,
                  id = storage.next_controller_request}
  storage.controller_request_results[cid] = nil
  return {queued = true, request = pending[cid].id, kind = kind}
end

-- The entry of every direct command: while a task-pool step holds her the command is
-- queued (M.defer -- the reply to send back); otherwise it runs at once, and a pending
-- older request is dropped first (logged) -- the controller gave its newer command, so
-- the old one must not start over it later.
-- @return table|nil the queued reply, or nil: run the command now
function M.gate(cid, kind, args, pos)
  if storage.active_step and storage.active_step[cid] then
    return M.defer(cid, kind, args, pos)
  end
  local old = M.pending(cid)
  if old then
    M.cancel(cid)
    log("[ai-companion] controller request " .. old.id .. " (" .. old.kind
        .. ") dropped: a new " .. kind .. " command runs at once")
  end
  -- an older request's failed start, never read, must not answer this command's status
  -- poll (independent review: the next place_smart read the old failure)
  book()
  storage.controller_request_results[cid] = nil
  return nil
end

-- The pending request of the companion (of `kind` when given), or nil.
function M.pending(cid, kind)
  local r = storage.controller_requests and storage.controller_requests[cid]
  if r and (kind == nil or r.kind == kind) then return r end
  return nil
end

-- What a status poll of `kind` reports while the request waits or after its start
-- failed: {active = true, state = "queued", request = id} / the failed start's reply
-- with active = false (read once); nil when neither -- the queue's own status applies.
function M.status(cid, kind)
  local r = M.pending(cid, kind)
  if r then return {active = true, state = "queued", request = r.id, queued_ticks = game.tick - r.tick} end
  local results = storage.controller_request_results
  local done = results and results[cid]
  if done and done.kind == kind then
    results[cid] = nil
    local out = {}
    for k, v in pairs(done.result) do out[k] = v end
    out.active = false
    return out
  end
  return nil
end

-- The pending request's effective priority from where she stands (nil: none).
-- @param cid number
-- @param c table the companion record
-- @return number|nil
function M.effective(cid, c)
  local r = M.pending(cid)
  if not r then return nil end
  local p = priority.aged(priority.base(priority.DEFAULT_KIND), r.tick)
  return priority.effective(p, r.pos and u.distance(c.entity.position, r.pos) or 0), r.pos
end

-- Start the pending request (the scheduler picked it; no step holds her). A failed
-- start is kept for its status poll and logged.
-- @param cid number
function M.run(cid)
  local pending, results = book()
  local r = pending[cid]
  if not r then return end
  pending[cid] = nil
  local fn = starters[r.kind]
  local result
  if not fn then
    result = {error = "no starter registered for a " .. r.kind .. " request"}
  else
    local ok, res = pcall(fn, cid, r.args)
    result = ok and res or {error = "starting the " .. r.kind .. " request failed: " .. tostring(res)}
  end
  if type(result) ~= "table" then result = {} end
  if result.error then
    results[cid] = {kind = r.kind, result = result}
    log("[ai-companion] controller request " .. r.id .. " (" .. r.kind .. ") failed to start: "
        .. tostring(result.error))
  end
end

-- Drop the companion's pending request. @return boolean whether one was pending
function M.cancel(cid)
  local pending = book()
  local had = pending[cid] ~= nil
  pending[cid] = nil
  return had
end

commands.add_command("fac_controller_cancel", nil, function(cmd)
  u.safe_command(function()
    local id = u.find_companion(cmd.parameter)
    if not id then u.not_found(); return end
    u.json_response({id = id, cancelled = M.cancel(id)})
  end)
end)

return M
