-- The freeplay crash site at the map's start, not at the first player's join.
-- Freeplay (base/script/freeplay/freeplay.lua on_player_created) builds the crashed
-- ship and its wreckage once, when the FIRST player is created -- the companion is no
-- player, so on a server nobody joins it never comes, and when Zdendys joins late it
-- lands on the middle of her base regardless of what stands there; its burning
-- wreckage then damages her buildings (Zdendys: it always comes when the map starts,
-- as the game's authors meant it, and the server records that it came).
-- So, once per save, early in the game:
--   - freeplay already ran its start (a player was created) or its crash site is
--     disabled: nothing to do;
--   - the map is at its start (game.tick <= START_TICKS): the crash site is built here
--     with freeplay's own items and parts (the same core/lualib crash-site.lua call
--     freeplay makes, at its {-5, -6}) once the chunks around it are generated, and
--     freeplay's own one is disabled first -- the first player then gets freeplay's
--     start (its items, the charted area, the intro) without a second ship, without
--     the crash cutscene, and keeps the ship's and debris' items freeplay would
--     otherwise take back from them (they lie in the wreck too);
--   - later (a save past its start that never had a player): freeplay's crash site is
--     only disabled -- it would fall onto her buildings.
-- The decision is recorded (storage.crash_site_checked, freeplay's disable flag)
-- BEFORE the build: a build that fails half way is logged once, never built again on
-- top of itself (independent review).
local u = require("commands.init")
local crash_site = require("crash-site")

local M = {}

M.START_TICKS = 3600       -- the map's first game minute counts as its start
local SITE = {-5, -6}      -- freeplay's own crash site position

-- Whether the freeplay interface this needs is there.
local function has_freeplay()
  local fp = remote.interfaces["freeplay"]
  return fp and fp.get_init_ran and fp.get_disable_crashsite and fp.set_disable_crashsite
    and fp.get_ship_items and fp.get_debris_items and fp.get_ship_parts
end

-- Whether the chunks the wreck lands in are generated (its parts land up to ~50 tiles
-- from SITE: the 3x3 chunks round SITE's chunk); requests the missing ones.
local function chunks_ready(surf)
  local cx, cy = math.floor(SITE[1] / 32), math.floor(SITE[2] / 32)
  local ready = true
  for dx = -1, 1 do
    for dy = -1, 1 do
      if not surf.is_chunk_generated({cx + dx, cy + dy}) then ready = false end
    end
  end
  if not ready then surf.request_to_generate_chunks({SITE[1], SITE[2]}, 1) end
  return ready
end

-- One decision per save (see the file header). Called from the mod's nth-tick handler.
function M.tick()
  if storage.crash_site_checked then return end
  if not has_freeplay() then
    storage.crash_site_checked = true
    log("[ai-companion] crash site: no freeplay interface -- nothing to do")
    return
  end
  if remote.call("freeplay", "get_init_ran") or remote.call("freeplay", "get_disable_crashsite") then
    storage.crash_site_checked = true
    return
  end
  local surf = game.surfaces[1]
  if game.tick > M.START_TICKS then
    remote.call("freeplay", "set_disable_crashsite", true)
    storage.crash_site_checked = true
    log("[ai-companion] crash site: the map is past its start (tick " .. game.tick
        .. ") and never had one -- freeplay's disabled (it would fall onto her buildings)")
    return
  end
  if not chunks_ready(surf) then return end   -- built on a later tick, still at the start
  storage.crash_site_checked = true
  remote.call("freeplay", "set_disable_crashsite", true)
  local ok, err = pcall(crash_site.create_crash_site, surf, SITE,
                        remote.call("freeplay", "get_ship_items") or {},
                        remote.call("freeplay", "get_debris_items") or {},
                        remote.call("freeplay", "get_ship_parts"))
  if ok then
    log("[ai-companion] crash site: built at the map's start (tick " .. game.tick
        .. ", {" .. SITE[1] .. "," .. SITE[2] .. "}); freeplay's own on the first join disabled")
  else
    u.log_error("crash site: building it failed: " .. tostring(err), "crash_site")
  end
end

return M
