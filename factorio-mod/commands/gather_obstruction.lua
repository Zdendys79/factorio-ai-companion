-- A tree or rock on or beside an ore tile keeps the tile from being selected for mining:
-- she clears it the way a player does -- stands within reach and mines it with the
-- engine's own mining (real mining time, her own mining speed), nearest first --
-- before the tile is given up on. Gather's "mine" state drives this while q.obs_clear
-- is set.
local u = require("commands.init")
local clearing = require("commands.clearing")

local M = {}

M.CLEAR_TICKS = 1500        -- the longest the whole clearing of one ore tile runs
local OBSTACLE_TYPES = {"tree", "simple-entity"}
local PAD = 0.5             -- the padding round the ore tile's box (as clear_build_area's)

local function key(e)
  return e.unit_number or string.format("%.2f,%.2f", e.position.x, e.position.y)
end

-- The nearest obstacle (to her) on or beside the ore tile that is not skipped, or nil.
local function nearest_obstacle(c, oc)
  local best, best_d = nil, math.huge
  for _, o in ipairs(c.entity.surface.find_entities_filtered{area = oc.area,
                                                             type = OBSTACLE_TYPES}) do
    if o.valid and not oc.skip[key(o)] then
      local d = u.distance(c.entity.position, o.position)
      if d < best_d then best, best_d = o, d end
    end
  end
  return best
end

-- Starts the clearing of the ore tile `res` when a tree or rock stands on or beside it.
-- @param c table the companion record
-- @param q table the gather queue (q.obs_clear is set when it starts)
-- @param tile string the tile's key (q.obs_tried is keyed by it)
-- @return boolean true when there is something to clear (the clearing runs from now on)
function M.start(c, q, res, tile)
  local bb = res.bounding_box
  local oc = {
    tile = tile,
    area = {{x = bb.left_top.x - PAD, y = bb.left_top.y - PAD},
            {x = bb.right_bottom.x + PAD, y = bb.right_bottom.y + PAD}},
    st = {}, skip = {}, cleared = 0, started = game.tick}
  if not nearest_obstacle(c, oc) then return false end
  q.obs_clear = oc
  return true
end

-- Ends the clearing: her mining and walk stop, the queue remembers the tile was tried.
local function finish(cid, c, q, oc, why)
  clearing.release(cid, c)
  q.obs_clear = nil
  q.obs_tried = q.obs_tried or {}
  q.obs_tried[oc.tile] = true
  u.log_error(string.format("gather obstruction: tile %s -- %s (%d cleared)", oc.tile,
                            why or "finished", oc.cleared), "gather_queue")
  return oc.cleared > 0 and "cleared" or "none"
end

-- One cycle of the clearing.
-- @return string "busy" (call again next cycle), "cleared" (something came down: select
--   the tile again) or "none" (nothing came down: the caller gives the tile up)
function M.step(cid, c, q)
  local oc = q.obs_clear
  if game.tick - oc.started >= M.CLEAR_TICKS then
    return finish(cid, c, q, oc, "clearing not finished in " .. M.CLEAR_TICKS .. " ticks")
  end
  if not oc.target then
    oc.target = nearest_obstacle(c, oc)
    if not oc.target then return finish(cid, c, q, oc, nil) end
    oc.st = {}
  end
  if clearing.step_target(cid, c, oc.st, oc.target) == "done" then
    if oc.target.valid then
      oc.skip[key(oc.target)] = true         -- (left standing: not reached or not mined in time)
    else
      oc.cleared = oc.cleared + 1
    end
    oc.target = nil
  end
  return "busy"
end

return M
