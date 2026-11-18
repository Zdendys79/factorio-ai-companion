-- Her inventory checked when she GAINS material (Zdendys: the overflow check need not run
-- every tick -- only when new materials come in: taken from a chest, picked from the
-- ground, a building taken down, mined and the like).
--
-- Every place of the mod that puts items into her inventory calls M.gained(char) after
-- it; with FLOOR or fewer empty slots left it sends a job-end event (commands/events.lua)
-- {kind = "inventory", id = cid, status = "tight", empty = n} -- factorio-ai's overflow
-- relief reacts to it before its next action. At most one per REPORT_GAP ticks a
-- companion while she stays tight (in storage, made lazily here: whether an event is
-- emitted changes storage.events, so a module local would desync a joining client --
-- review).
local events = require("commands.events")

local M = {}

M.FLOOR = 3            -- factorio-ai INVENTORY_OVERFLOW_EMPTY_STACKS_FLOOR
M.REPORT_GAP = 600     -- ticks between two reports of one companion

-- The companion id of character `char`, or nil.
local function cid_of(char)
  for id, c in pairs(storage.companions or {}) do
    if c.entity == char then return id end
  end
  return nil
end

-- After items went into character `char`'s inventory: report her slots when tight.
function M.gained(char)
  if not (char and char.valid) then return end
  local inv = char.get_main_inventory()
  if not inv then return end
  local empty = inv.count_empty_stacks()
  if empty > M.FLOOR then return end
  local cid = cid_of(char)
  if not cid then return end
  storage.inventory_watch_last = storage.inventory_watch_last or {}
  local t = storage.inventory_watch_last[cid]
  if t and game.tick - t < M.REPORT_GAP then return end
  storage.inventory_watch_last[cid] = game.tick
  events.emit({kind = "inventory", id = cid, cid = cid, status = "tight", empty = empty})
end

return M
