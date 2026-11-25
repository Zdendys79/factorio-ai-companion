-- AI Companion v0.7.0 - World commands
local u = require("commands.init")
local seen_map = require("commands.seen_map")
local nearest = require("commands.nearest")

local normalize = {copper = "copper-ore", iron = "iron-ore", coal = "coal", stone = "stone", uranium = "uranium-ore"}

commands.add_command("fac_world_nearest", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local what = args[2]
    local name = normalize[what] or what
    local pos = c.entity.position
    local surf = c.entity.surface
    if what == "water" then
      local closest, dist = nearest.nearest_tile(surf, pos, {"water", "deepwater"})
      if not closest then u.json_response({id = id, error = "Not found"}); return end
      u.json_response({id = id, nearest = "water", position = closest, distance = math.floor(dist)}); return
    end
    local filter = (what == "wood" or name == "tree") and {type = "tree"} or {name = name}
    local closest, dist = nearest.nearest_entity(surf, pos, filter)
    if not closest then u.json_response({id = id, error = "Not found"}); return end
    u.json_response({id = id, nearest = closest.name, position = {x = math.floor(closest.position.x), y = math.floor(closest.position.y)}, distance = math.floor(dist)})
  end)
end)

-- Entities within a radius of her, filter applied in the search; a longer list is cut to
-- the SCAN_CAP nearest (`total` = matches before the cut).
local SCAN_CAP = 50

commands.add_command("fac_world_scan", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s*(%d*)%s*(%S*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local radius = tonumber(args[2]) or 10
    local filter = args[3] ~= "" and args[3] or nil
    local search = {position = c.entity.position, radius = radius}
    if filter then search.name = filter end
    local es = c.entity.surface.find_entities_filtered(search)
    local result = {}
    for _, e in ipairs(es) do
      -- (only what was seen: game rule 82, commands/seen_map.lua)
      if e.valid and e ~= c.entity
         and seen_map.is_seen(c.entity.surface.index, e.position.x, e.position.y) then
        local r = {name = e.name, type = e.type, position = {x = math.floor(e.position.x * 10) / 10, y = math.floor(e.position.y * 10) / 10}}
        if e.health then r.health = e.health end
        result[#result + 1] = r
      end
    end
    local total = #result
    if total > SCAN_CAP then
      local pos = c.entity.position
      table.sort(result, function(a, b) return u.distance(a.position, pos) < u.distance(b.position, pos) end)
      for i = total, SCAN_CAP + 1, -1 do result[i] = nil end
    end
    u.json_response({id = id, entities = result, count = #result, total = total})
  end)
end)
