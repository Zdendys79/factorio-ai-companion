-- Reserved tiles: tiles a later route must arrive at (a block's join tile -- factorio-ai:
-- the lab row's green join held another route's underground belt, so the green pack
-- belt could never join, "dest-blocked"). The route search (commands/pathfind.lua)
-- treats a reserved tile as blocked unless it is that route's own start or destination;
-- Python's pole chains read them (all) and keep off them too.
--
-- storage.reserved_tiles = {["x:y"] = owner} (whole tiles, as pathfind's tile_key).
-- /fac_reserve_tiles <owner> add x1 y1 [x2 y2 ...] -- reserve (every pair checked
--   first; a tile reserved by another owner stays theirs: listed in "taken");
-- /fac_reserve_tiles <owner> remove -- release every tile of the owner;
-- /fac_reserve_tiles <owner> list -- the owner's tiles;
-- /fac_reserve_tiles <any> all -- every reserved tile, of any owner.
-- Replies {owner, tiles = n (the owner's count), taken = ["x:y", ...],
-- at = [[x, y], ...] (tile centres; list / all only)} or {error}. No game state is
-- touched.
local u = require("commands.init")

local M = {}

local function key(x, y)
  return math.floor(x) .. ":" .. math.floor(y)
end

-- The reserved whole tiles as a lookup {[x] = {[y] = true}} (integers), or nil when
-- none is reserved -- built once per route search, so the search's tile checks make no
-- strings.
function M.lookup()
  local book = storage.reserved_tiles
  if not book or next(book) == nil then return nil end
  local res = {}
  for k in pairs(book) do
    local x, y = k:match("^(-?%d+):(-?%d+)$")
    x, y = tonumber(x), tonumber(y)
    if x and y then
      res[x] = res[x] or {}
      res[x][y] = true
    end
  end
  return res
end

-- The tile centres of the reserved tiles whose owner passes `keep(owner)`.
local function centres(book, keep)
  local at = {}
  for k, o in pairs(book) do
    local x, y = k:match("^(-?%d+):(-?%d+)$")
    if x and keep(o) then at[#at + 1] = {tonumber(x) + 0.5, tonumber(y) + 0.5} end
  end
  return at
end

commands.add_command("fac_reserve_tiles", nil, function(cmd)
  u.safe_command(function()
    local words = {}
    for w in (cmd.parameter or ""):gmatch("%S+") do words[#words + 1] = w end
    local owner, op = words[1], words[2]
    if not owner or not (op == "add" or op == "remove" or op == "list" or op == "all") then
      u.json_response({error = "usage: <owner> add|remove|list|all [x y ...]"}); return
    end
    storage.reserved_tiles = storage.reserved_tiles or {}
    local book = storage.reserved_tiles
    local taken = {}
    local at = nil
    if op == "add" then
      if #words < 4 or (#words - 2) % 2 ~= 0 then
        u.json_response({error = "add needs x y pairs"}); return
      end
      local tiles = {}
      for i = 3, #words, 2 do
        local x, y = tonumber(words[i]), tonumber(words[i + 1])
        if not (x and y) then
          u.json_response({error = "bad tile " .. words[i] .. " " .. words[i + 1]}); return
        end
        tiles[#tiles + 1] = key(x, y)
      end
      for _, k in ipairs(tiles) do
        if book[k] and book[k] ~= owner then
          taken[#taken + 1] = k
        else
          book[k] = owner
        end
      end
    elseif op == "remove" then
      for k, o in pairs(book) do
        if o == owner then book[k] = nil end
      end
    elseif op == "list" then
      at = centres(book, function(o) return o == owner end)
    else
      at = centres(book, function() return true end)
    end
    local n = 0
    for _, o in pairs(book) do
      if o == owner then n = n + 1 end
    end
    u.json_response({owner = owner, tiles = n, taken = taken, at = at})
  end)
end)

return M
