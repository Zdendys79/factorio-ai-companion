-- A splitter's priorities and filter set as it is placed (factorio-ai game rule 96: a
-- production's next machine first with the overflow onto the main belt, a sorter line's
-- filter splitter, a surplus chest's belt drained first). Used by queues_build.lua right
-- after create_entity; a plan piece carries them (build_plan.lua: "splitter").

local u = require("commands.init")

local M = {}

local SIDES = {left = true, none = true, right = true}

-- The problem of a piece's splitter settings `s` ({input=, output=, filter=}), or nil.
function M.problem(entity_name, s)
  if type(s) ~= "table" then return "splitter must be a table" end
  local proto = prototypes.entity[entity_name]
  if not proto or proto.type ~= "splitter" then
    return entity_name .. " is no splitter"
  end
  if s.input ~= nil and not SIDES[s.input] then return "splitter input must be left, none or right" end
  if s.output ~= nil and not SIDES[s.output] then return "splitter output must be left, none or right" end
  if s.filter ~= nil and (type(s.filter) ~= "string" or not prototypes.item[s.filter]) then
    return "splitter filter must be a known item"
  end
  if s.filter ~= nil and (s.output == nil or s.output == "none") then
    return "a splitter filter needs an output side (its item goes there)"
  end
  return nil
end

-- Set `s` on the placed splitter and read it back. nil when it holds; else the splitter is
-- taken back -- its item returned to `char` (spilled beside it when her inventory is full,
-- never lost), logged -- and the reason returned, prefixed "splitter not set: ".
function M.apply(placed, s, char)
  local ok, err = pcall(function()
    if s.input then placed.splitter_input_priority = s.input end
    if s.output then placed.splitter_output_priority = s.output end
    if s.filter then placed.splitter_filter = {name = s.filter} end
    local f = placed.splitter_filter
    local n = f and f.name
    n = (type(n) == "string" and n) or (n and n.name)
    if (s.input and placed.splitter_input_priority ~= s.input)
        or (s.output and placed.splitter_output_priority ~= s.output)
        or (s.filter and n ~= s.filter) then
      error("read back input=" .. tostring(placed.splitter_input_priority) .. " output="
            .. tostring(placed.splitter_output_priority) .. " filter=" .. tostring(n))
    end
  end)
  if ok then return nil end
  local name, surf = placed.name, placed.surface
  local at = {x = placed.position.x, y = placed.position.y}
  placed.destroy()
  local back = char.insert{name = name, count = 1}
  if back < 1 then
    surf.spill_item_stack{position = at, stack = {name = name, count = 1}}
  end
  u.log_error("build queue: splitter settings on " .. name .. " failed: " .. tostring(err)
              .. " -- taken back (item returned: " .. back .. ")", "build_queue")
  return "splitter not set: " .. tostring(err)
end

return M
