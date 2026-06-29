-- AI Companion v0.9.0
local M = {}

M.COLORS = {
  player = {r=0.4, g=0.8, b=1},
  orchestrator = {r=0.3, g=1, b=0.3},
  system = {r=1, g=0.5, b=0},
  error = {r=1, g=0, b=0}
}

M.COMPANION_COLORS = {
  {r=1, g=0.6, b=0.2}, {r=0.8, g=0.4, b=1}, {r=1, g=1, b=0.3}, {r=0.4, g=1, b=0.8},
  {r=1, g=0.4, b=0.6}, {r=0.6, g=0.8, b=1}, {r=1, g=0.8, b=0.4}, {r=0.7, g=1, b=0.5}
}

M.dir_map = {
  -- Simple 0-3 convention (MCP tools API)
  [0] = defines.direction.north, [1] = defines.direction.east,
  [2] = defines.direction.south, [3] = defines.direction.west,
  -- Factorio native 16-direction values (aliases)
  [4] = defines.direction.east,  [8] = defines.direction.south, [12] = defines.direction.west,
}

function M.print_color(c) return {color = c} end

function M.get_companion_color(id)
  return M.COMPANION_COLORS[((id - 1) % #M.COMPANION_COLORS) + 1]
end

function M.json_response(data)
  local ok, result = pcall(helpers.table_to_json, data)
  rcon.print(ok and result or '{"error":"JSON failed"}')
end

function M.error_response(msg, ctx)
  if storage.errors then
    table.insert(storage.errors, {context = ctx or "rcon", error = tostring(msg), tick = game.tick})
    if #storage.errors > 50 then table.remove(storage.errors, 1) end
  end
  rcon.print('{"error":"' .. tostring(msg) .. '"}')
end

function M.safe_command(callback)
  local ok, err = pcall(callback)
  if not ok then
    M.error_response(err)
  end
end

function M.get_companion(id)
  local c = storage.companions[id]
  return (c and c.entity and c.entity.valid) and c or nil
end

function M.find_companion(identifier)
  local id = tonumber(identifier)
  if id then
    local c = M.get_companion(id)
    if c then return id, c end
  end
  for cid, c in pairs(storage.companions) do
    if c.name and c.name:lower() == identifier:lower() and c.entity and c.entity.valid then
      return cid, c
    end
  end
  return nil, nil
end

function M.get_companion_display(id)
  local c = storage.companions[id]
  return c and c.name and (c.name .. "(#" .. id .. ")") or ("#" .. id)
end

function M.parse_args(pattern, args)
  return args and {args:match(pattern)} or {}
end

function M.distance(a, b)
  return math.sqrt((a.x - b.x)^2 + (a.y - b.y)^2)
end

function M.get_direction(from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  if math.abs(dx) < 0.5 and math.abs(dy) < 0.5 then return nil end
  local deg = math.atan2(dy, dx) * 180 / math.pi
  if deg < 0 then deg = deg + 360 end
  local dirs = {
    {337.5, 22.5, defines.direction.east}, {22.5, 67.5, defines.direction.southeast},
    {67.5, 112.5, defines.direction.south}, {112.5, 157.5, defines.direction.southwest},
    {157.5, 202.5, defines.direction.west}, {202.5, 247.5, defines.direction.northwest},
    {247.5, 292.5, defines.direction.north}, {292.5, 337.5, defines.direction.northeast}
  }
  for _, d in ipairs(dirs) do
    if d[1] > d[2] then
      if deg >= d[1] or deg < d[2] then return d[3] end
    elseif deg >= d[1] and deg < d[2] then return d[3] end
  end
  return defines.direction.east
end

function M.render_label(entity, text, color)
  if not rendering then return nil end
  return rendering.draw_text{
    text = text, surface = entity.surface, target = entity,
    target_offset = {0, -2.5}, color = color, scale = 1.5, alignment = "center", use_rich_text = false
  }
end

-- Factorio 2.0 "craft-item" research triggers fire only when a PLAYER completes a
-- craft; a headless scripted companion's begin_crafting does NOT fire them, so a
-- crafted item that should unlock a technology (e.g. crafting a lab unlocks the
-- automation-science-pack recipe) leaves the tech enabled-but-unresearched. This
-- compensates: after the companion REALLY crafts an item (ingredients consumed via
-- begin_crafting), research any matching craft-item trigger tech whose prereqs are
-- met. NOT a cheat -- the item was genuinely produced through game mechanics; this
-- only replicates the craft event a connected player would have generated. Items
-- producible by machines (plates from furnaces) already fire their triggers normally.
function M.fire_craft_triggers(force, item_name, crafted)
  if not item_name or (crafted or 0) < 1 then return end
  for _, tech in pairs(force.technologies) do
    if tech.enabled and not tech.researched then
      local rt = tech.prototype.research_trigger
      if rt and rt.type == "craft-item" then
        local rname = type(rt.item) == "table" and (rt.item.name or rt.item[1]) or rt.item
        if rname == item_name then
          -- count cumulative production if available; fall back to this craft's count
          -- (covers count==1 triggers like the lab even if hand-crafts are not tallied).
          local ok_stats, produced = pcall(function()
            return force.item_production_statistics.get_input_count(item_name)
          end)
          local total = (ok_stats and produced or 0)
          if total >= (rt.count or 1) or (crafted or 0) >= (rt.count or 1) then
            tech.researched = true
            game.print("[companion] crafted " .. item_name ..
              " -> trigger tech researched: " .. tech.name, M.print_color(M.COLORS.system))
          end
        end
      end
    end
  end
end

return M
