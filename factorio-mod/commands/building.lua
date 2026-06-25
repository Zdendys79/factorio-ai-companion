-- AI Companion v0.9.0 - Building commands
local u = require("commands.init")
local queues = require("commands.queues")

commands.add_command("fac_building_can_place", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s+([%d.-]+)%s+([%d.-]+)%s*(%d*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.error_response("Companion not found"); return end
    local name, x, y = args[2], tonumber(args[3]), tonumber(args[4])
    local dir = u.dir_map[tonumber(args[5]) or 0] or defines.direction.north
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local dist = u.distance(c.entity.position, {x=x, y=y})
    if dist > (c.entity.reach_distance or 10) then u.json_response({id = id, can_place = false, reason = "Too far"}); return end
    local inv = c.entity.get_inventory(defines.inventory.character_main)
    if inv.get_item_count(name) == 0 then u.json_response({id = id, can_place = false, reason = "Not in inventory"}); return end
    local can = c.entity.surface.can_place_entity{name = name, position = {x=x, y=y}, direction = dir, force = c.entity.force}
    u.json_response({id = id, can_place = can, entity = name})
  end)
end)

commands.add_command("fac_building_place", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s+([%d.-]+)%s+([%d.-]+)%s*(%d*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.error_response("Companion not found"); return end
    local name, x, y = args[2], tonumber(args[3]), tonumber(args[4])
    local dir = u.dir_map[tonumber(args[5]) or 0] or defines.direction.north
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local dist = u.distance(c.entity.position, {x=x, y=y})
    if dist > (c.entity.reach_distance or 10) then u.json_response({id = id, error = "Too far"}); return end
    local inv = c.entity.get_inventory(defines.inventory.character_main)
    if inv.get_item_count(name) == 0 then u.json_response({id = id, error = "Not in inventory"}); return end
    local surf = c.entity.surface
    if not surf.can_place_entity{name = name, position = {x=x, y=y}, direction = dir, force = c.entity.force} then
      u.json_response({id = id, error = "Cannot place"}); return
    end
    local e = surf.create_entity{name = name, position = {x=x, y=y}, direction = dir, force = c.entity.force}
    if e then inv.remove{name = name, count = 1}; u.json_response({id = id, placed = true, entity = name})
    else u.json_response({id = id, error = "Failed"}) end
  end)
end)

commands.add_command("fac_building_remove", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s+([%d.-]+)%s+([%d.-]+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.error_response("Companion not found"); return end
    local name, x, y = args[2], tonumber(args[3]), tonumber(args[4])
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local es = c.entity.surface.find_entities_filtered{name = name, position = {x=x, y=y}, radius = 1, force = c.entity.force}
    if #es == 0 then u.json_response({id = id, error = "Not found"}); return end
    local t = es[1]
    if u.distance(c.entity.position, t.position) > 10 then u.json_response({id = id, error = "Too far"}); return end
    if t.can_be_destroyed() then
      c.entity.insert{name = name, count = 1}; t.destroy{raise_destroy = false}
      u.json_response({id = id, removed = true, entity = name})
    else u.json_response({id = id, error = "Cannot remove"}) end
  end)
end)

commands.add_command("fac_building_rotate", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+([%d.-]+)%s+([%d.-]+)%s*(%d*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.error_response("Companion not found"); return end
    local x, y, dir = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local es = c.entity.surface.find_entities_filtered{position = {x=x, y=y}, radius = 1}
    local t
    for _, e in ipairs(es) do if e.valid and e ~= c.entity and e.type ~= "character" and e.rotatable then t = e; break end end
    if not t then u.json_response({id = id, error = "No rotatable entity"}); return end
    if dir then
      t.direction = u.dir_map[dir] or defines.direction.north
    else
      t.rotate()
    end
    u.json_response({id = id, rotated = t.name, direction = t.direction})
  end)
end)

commands.add_command("fac_building_info", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+([%d.-]+)%s+([%d.-]+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.error_response("Companion not found"); return end
    local x, y = tonumber(args[2]), tonumber(args[3])
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local es = c.entity.surface.find_entities_filtered{position = {x=x, y=y}, radius = 2}
    if #es == 0 then u.json_response({id = id, error = "Not found"}); return end
    local t, min = nil, math.huge
    for _, e in ipairs(es) do
      if e.type ~= "resource" and e.type ~= "item-entity" then
        local d = u.distance(e.position, {x=x, y=y}); if d < min then min, t = d, e end
      end
    end
    if not t then u.json_response({id = id, error = "Not found"}); return end
    local info = {name = t.name, type = t.type, position = {x = t.position.x, y = t.position.y}, direction = t.direction}
    if t.health then info.health = t.health end
    if t.energy then info.energy = t.energy end
    if t.get_recipe then local r = t.get_recipe(); if r then info.recipe = r.name end end
    u.json_response({id = id, entity = info})
  end)
end)

commands.add_command("fac_building_recipe", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s+([%d.-]+)%s+([%d.-]+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.error_response("Companion not found"); return end
    local recipe, x, y = args[2], tonumber(args[3]), tonumber(args[4])
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local es = c.entity.surface.find_entities_filtered{position = {x=x, y=y}, radius = 1, type = "assembling-machine"}
    if #es == 0 then u.json_response({id = id, error = "No machine"}); return end
    if not c.entity.force.recipes[recipe] then u.json_response({id = id, error = "Recipe not found"}); return end
    es[1].set_recipe(recipe)
    u.json_response({id = id, set_recipe = true, recipe = recipe})
  end)
end)

commands.add_command("fac_building_fuel", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s*(%d*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.error_response("Companion not found"); return end
    local fuel, amount = args[2], tonumber(args[3]) or 5
    local inv = c.entity.get_inventory(defines.inventory.character_main)
    local have = inv.get_item_count(fuel)
    if have == 0 then u.json_response({id = id, error = "No " .. fuel}); return end
    local es = c.entity.surface.find_entities_filtered{position = c.entity.position, radius = 3, type = {"furnace", "boiler", "burner-inserter", "car", "locomotive", "mining-drill"}}
    if #es == 0 then u.json_response({id = id, error = "No burner nearby"}); return end
    local fi = es[1].get_fuel_inventory()
    if not fi then u.json_response({id = id, error = "No fuel slot"}); return end
    local ins = fi.insert{name = fuel, count = math.min(amount, have)}
    if ins > 0 then inv.remove{name = fuel, count = ins}; u.json_response({id = id, inserted = ins, fuel = fuel})
    else u.json_response({id = id, error = "Full"}) end
  end)
end)

commands.add_command("fac_building_empty", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s*(%d*)%s*([%d.-]*)%s*([%d.-]*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.error_response("Companion not found"); return end
    local item, count = args[2], tonumber(args[3]) or 10
    local pos = (tonumber(args[4]) and tonumber(args[5])) and {x = tonumber(args[4]), y = tonumber(args[5])} or c.entity.position
    local es = c.entity.surface.find_entities_filtered{position = pos, radius = 5}
    local ext = 0
    for _, e in ipairs(es) do
      if e.valid and e ~= c.entity then
        for _, it in ipairs({defines.inventory.chest, defines.inventory.furnace_result, defines.inventory.assembling_machine_output}) do
          local inv = e.get_inventory(it)
          if inv then
            local av = inv.get_item_count(item)
            if av > 0 then
              local rm = inv.remove{name = item, count = math.min(count - ext, av)}
              if rm > 0 then c.entity.insert{name = item, count = rm}; ext = ext + rm end
            end
          end
        end
        if ext >= count then break end
      end
    end
    u.json_response({id = id, extracted = ext, item = item})
  end)
end)

commands.add_command("fac_building_fill", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s*(%d*)%s*([%d.-]*)%s*([%d.-]*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.error_response("Companion not found"); return end
    local item, count = args[2], tonumber(args[3]) or 10
    local pos = (tonumber(args[4]) and tonumber(args[5])) and {x = tonumber(args[4]), y = tonumber(args[5])} or c.entity.position
    local inv = c.entity.get_inventory(defines.inventory.character_main)
    local have = inv.get_item_count(item)
    if have == 0 then u.json_response({id = id, error = "No " .. item}); return end
    local es = c.entity.surface.find_entities_filtered{position = pos, radius = 3}
    local ins = 0
    for _, e in ipairs(es) do
      if e.valid and e ~= c.entity then
        local r = e.insert{name = item, count = math.min(count - ins, have)}
        if r > 0 then inv.remove{name = item, count = r}; ins, have = ins + r, have - r end
        if ins >= count then break end
      end
    end
    if ins > 0 then u.json_response({id = id, inserted = ins, item = item})
    else u.json_response({id = id, error = "Could not insert"}) end
  end)
end)

-- Realistic tick-based building placement
-- Mine (destroy) any entity at position - works on crash site wrecks, decoratives, etc.
commands.add_command("fac_mine_entity", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+([%d.-]+)%s+([%d.-]+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.error_response("Companion not found"); return end
    local x, y = tonumber(args[2]), tonumber(args[3])
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local es = c.entity.surface.find_entities_filtered{position = {x=x, y=y}, radius = 3}
    local target = nil
    for _, e in ipairs(es) do
      if e.valid and e ~= c.entity and e.type ~= "character" and e.type ~= "resource" then
        target = e; break
      end
    end
    if not target then u.json_response({id = id, error = "No entity found"}); return end
    if u.distance(c.entity.position, target.position) > 15 then u.json_response({id = id, error = "Too far"}); return end
    local entity_name = target.name
    local items_received = {}
    for inv_id = 1, 10 do
      local inv = target.get_inventory(inv_id)
      if inv then
        for i = 1, #inv do
          local stack = inv[i]
          if stack and stack.valid_for_read then
            c.entity.insert{name = stack.name, count = stack.count}
            items_received[stack.name] = (items_received[stack.name] or 0) + stack.count
          end
        end
      end
    end
    if target.prototype and target.prototype.mineable_properties then
      local mp = target.prototype.mineable_properties
      if mp.minable and mp.products then
        for _, prod in ipairs(mp.products) do
          if prod.name then
            local amt = prod.amount or 1
            c.entity.insert{name = prod.name, count = amt}
            items_received[prod.name] = (items_received[prod.name] or 0) + amt
          end
        end
      end
    end
    target.destroy{raise_destroy = false}
    u.json_response({id = id, mined = true, entity = entity_name, items = items_received})
  end)
end)

commands.add_command("fac_building_place_start", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s+(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)%s*(%S*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.error_response("Companion not found"); return end
    local entity = args[2]
    local x, y = tonumber(args[3]), tonumber(args[4])
    local dir = args[5] ~= "" and defines.direction[args[5]] or defines.direction.north
    local result = queues.start_build(id, entity, {x = x, y = y}, dir)
    result.id = id
    u.json_response(result)
  end)
end)

commands.add_command("fac_building_place_status", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)$", cmd.parameter)
    local id = u.find_companion(args[1])
    if not id then u.error_response("Companion not found"); return end
    local status = queues.get_build_status(id)
    u.json_response({id = id, status = status})
  end)
end)
