-- The team: Python names no helper (Zdendys: "Python need not know how many helpers solve its
-- tasks" -- the mod distributes, so that the helpers do not get in each other's way). A command
-- taking a companion id accepts the word "team" where the work is submitted
-- (/fac_task_submit team ...): the mod picks the helper at submit time, the task stays with
-- that helper (its reservations, its inventory). The pick, by the task's ANCHOR (the first
-- place it works at):
--   1. a helper that already works within AREA_R tiles of the anchor (standing there, or an
--      open task anchored there) takes it -- two bodies, two walk queues and two sets of
--      reserved tiles in one spot are what makes them pluck at each other;
--   2. else the helper with the fewest open tasks (an active step counts), the nearest to the
--      anchor on a tie, the lowest id after that.
-- The helpers are INTERCHANGEABLE (Zdendys): any of them can do any task, so nothing is bound to
-- a named one -- a helper that is gone (dead, unavailable) is simply not picked, a task of it
-- that failed is submitted again and lands on another. Only two things tie a task to a helper:
-- its own inventory (its reservations) and its SURFACE: later each helper works on another
-- planet, so a task naming a surface ("surface": "nauvis" in the submit wrapper) goes only to a
-- helper standing on that surface (none: an error, never a helper on another planet).
-- With one companion it is that one: nothing changes for a single helper.
local u = require("commands.init")

local M = {}

M.WORD = "team"
M.AREA_R = 14           -- tiles: the same area (their reach, a build's footprint and routes)

-- The first place a step list works at ({x, y}), or nil: the first step with a position, the
-- first piece of an expanded plan.
function M.anchor_of(steps)
  if type(steps) ~= "table" then return nil end
  for _, s in ipairs(steps) do
    if type(s) == "table" and type(s.x) == "number" and type(s.y) == "number" then
      return {x = s.x, y = s.y}
    end
    if type(s) == "table" and type(s.pieces) == "table" and s.pieces[1]
       and type(s.pieces[1].x) == "number" then
      return {x = s.pieces[1].x, y = s.pieces[1].y}
    end
  end
  return nil
end

-- Open (active) tasks of each companion: {[cid] = n}, and the anchors of those tasks.
local function open_tasks()
  local n, anchors = {}, {}
  for _, t in pairs(storage.tasks or {}) do
    if t.status == "active" and t.cid then
      n[t.cid] = (n[t.cid] or 0) + 1
      if t.anchor then
        anchors[t.cid] = anchors[t.cid] or {}
        anchors[t.cid][#anchors[t.cid] + 1] = t.anchor
      end
    end
  end
  return n, anchors
end

-- Whether companion `cid` works within AREA_R of `anchor` (stands there or has a task there).
local function works_near(cid, c, anchor, anchors)
  if u.distance(c.entity.position, anchor) <= M.AREA_R then return true end
  for _, a in ipairs(anchors[cid] or {}) do
    if u.distance(a, anchor) <= M.AREA_R then return true end
  end
  return false
end

-- The helper for a new task anchored at `anchor` (or nil): its id and record, or nil when no
-- companion stands.
function M.pick(anchor, surface, primary)
  local open, anchors = open_tasks()
  local best, best_id, best_key = nil, nil, nil
  local near_id, near_c, near_d = nil, nil, math.huge
  for cid, c in pairs(storage.companions or {}) do
    if c.entity and c.entity.valid and (not surface or c.entity.surface.name == surface) then
      local n = (open[cid] or 0) + ((storage.active_step and storage.active_step[cid]) and 1 or 0)
      local d = anchor and u.distance(c.entity.position, anchor) or 0
      -- 1. already working in that area (with something open): it keeps the area
      if anchor and n > 0 and works_near(cid, c, anchor, anchors) and d < near_d then
        near_id, near_c, near_d = cid, c, d
      end
      -- 2. the fewest open tasks, then the nearest, then the lowest id
      local key = n * 1e9 + d * 1e3 + cid
      if best_key == nil or key < best_key then best, best_id, best_key = c, cid, key end
    end
  end
  if primary then
    -- a task whose result the controller uses with its own direct commands (items fetched or
    -- crafted for it): it stays with the PRIMARY body -- the lowest id that stands on the
    -- surface -- until the controller's direct sequences are tasks of their own
    -- (docs/second_helper_serine.md, S2b)
    local low, low_c = nil, nil
    for cid, c in pairs(storage.companions or {}) do
      if c.entity and c.entity.valid and (not surface or c.entity.surface.name == surface)
         and (low == nil or cid < low) then
        low, low_c = cid, c
      end
    end
    return low, low_c
  end
  if near_id then return near_id, near_c end
  return best_id, best
end

-- u.find_companion that also understands "team" (anchor: where the task works first, or nil;
-- surface: the planet's name the task is for, or nil = any; primary: stay with the primary body).
function M.find(identifier, anchor, surface, primary)
  if identifier == M.WORD then return M.pick(anchor, surface, primary) end
  return u.find_companion(identifier)
end

-- /fac_team_status -- the helpers for the dashboard (one light read): {helpers = [{id, name,
-- color "#rrggbb", x, y, surface, open_tasks}]} -- one entry per companion that stands.
commands.add_command("fac_team_status", nil, function()
  u.safe_command(function()
    local open = open_tasks()
    local out = {}
    for cid, c in pairs(storage.companions or {}) do
      if c.entity and c.entity.valid then
        local col = c.color or u.get_companion_color(cid)
        out[#out + 1] = {
          id = cid, name = c.name or ("#" .. cid),
          color = string.format("#%02x%02x%02x", math.floor((col.r or 1) * 255),
                                math.floor((col.g or 1) * 255), math.floor((col.b or 1) * 255)),
          x = c.entity.position.x, y = c.entity.position.y,
          surface = c.entity.surface.name, open_tasks = open[cid] or 0}
      end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    u.json_response({helpers = out})
  end)
end)

return M
