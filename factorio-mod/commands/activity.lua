-- Nyara's activity: game ticks with an action in hand vs. ticks standing idle.
--
-- Zdendys (2026-11-07): the game runs at a fixed speed, so the ticks that pass while
-- Python reads the state and decides are not the mod's slowness -- but they must be
-- tracked, apart from the mod's own action time (the mod and Python are to run
-- asynchronously; docs/companion_task_queue.md in factorio-ai, "Decided").
--
-- M.tick runs every 5 ticks (control.lua's on_nth_tick(5), after every queue had its
-- turn) and credits the ticks since its last sample to "busy" or "idle"
-- per companion. Read through M.counters (attached to every json_response that names
-- the companion, and /fac_companion_activity).
--
-- Busy:
-- - one of her queues holds a running entry (a finished one -- state "done" / "failed",
--   kept until its status poll reads it -- does not count: she stands);
-- - a task-pool step is in flight (storage.active_step), including the step's own waits
--   (an ensure_item smelt wait, a place step's retry): the mod is working on it;
-- - she is mining or walking, or she hand-crafts (her character's craft queue or the
--   mod's timed craft queue).
-- A follow-player entry counts only while she walks (it never leaves the queue).
-- Idle: everything else -- also a submitted task-pool task that waits for its items
-- (no step in flight): the mod holds it, but she does nothing for it.
-- Craft-only (a part of busy): hand-crafting is the only thing busy -- she stands while
-- it crafts (review: the measured ~68 % of a run's ticks spent hand-
-- crafting research packs while Python waited would otherwise all read "busy").
local M = {}

-- the mod-side queues one of which holding her running entry means she has an action in
-- hand (init.lua's companion_queue_status list; the craft queue -- a timed hand craft
-- she stands for -- counts as crafting, below)
local QUEUE_TABLES = {"walking_queues", "harvest_queues", "gather_queues", "fuel_queues",
                      "build_queues", "belt_queues", "combat_queues"}

-- a queue entry's states after its job ended
local ENDED = {done = true, failed = true}

-- a gap longer than this between two samples of a companion (her entity was invalid --
-- dead, respawning -- so she was not sampled) is credited to neither side
local MAX_CREDIT_TICKS = 60

function M.init()
  -- storage.activity[cid] = {busy = ticks, idle = ticks, craft_only = ticks (a part of
  -- busy), last = tick of the last sample}
  storage.activity = storage.activity or {}
end

-- What the companion is doing right now.
-- @param cid number the companion id
-- @param entity LuaEntity her character
-- @return string "busy", "craft_only" (only her hand-craft queue runs) or "idle"
function M.state(cid, entity)
  for _, name in ipairs(QUEUE_TABLES) do
    local qs = storage[name]
    local q = qs and qs[cid]
    if q and type(q) == "table" and not ENDED[q.state] and not q.follow_player then
      return "busy"
    end
  end
  if storage.active_step and storage.active_step[cid] then return "busy" end
  local mining = entity.mining_state
  if mining and mining.mining then return "busy" end
  local walking = entity.walking_state
  if walking and walking.walking then return "busy" end
  local crafting = storage.craft_queues and storage.craft_queues[cid]
  if crafting or (entity.crafting_queue_size or 0) > 0 then return "craft_only" end
  return "idle"
end

-- Credit the ticks since each companion's last sample to busy or idle. Reads game.tick
-- itself: control.lua's guard_tick runs every tick function as pcall(fn), with no
-- argument (live check: a `tick` parameter was nil, the arithmetic failed every call
-- and the counters stood at 0).
function M.tick()
  local tick = game.tick
  storage.activity = storage.activity or {}
  local companions = storage.companions or {}
  for cid in pairs(storage.activity) do            -- a companion gone: her record too
    if not companions[cid] then storage.activity[cid] = nil end
  end
  for cid, c in pairs(companions) do
    if c.entity and c.entity.valid then
      local rec = storage.activity[cid]
      if not rec then
        rec = {busy = 0, idle = 0, last = tick}
        storage.activity[cid] = rec
      end
      local dt = tick - (rec.last or tick)
      if dt > 0 and dt <= MAX_CREDIT_TICKS then
        local state = M.state(cid, c.entity)
        if state == "idle" then
          rec.idle = (rec.idle or 0) + dt
        else
          rec.busy = (rec.busy or 0) + dt
          if state == "craft_only" then rec.craft_only = (rec.craft_only or 0) + dt end
        end
      end
      rec.last = tick
    end
  end
end

-- The companion's counters for a reply.
-- @param cid number
-- @return table|nil {busy = ticks, idle = ticks, craft_only = ticks}, nil before her
--   first sample
function M.counters(cid)
  local rec = storage.activity and storage.activity[cid]
  if not rec then return nil end
  return {busy = rec.busy or 0, idle = rec.idle or 0, craft_only = rec.craft_only or 0}
end

return M
