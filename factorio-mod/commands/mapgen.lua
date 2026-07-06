-- AI Companion - Map (re)generation commands.
-- 2026-07-06, Zdendys: "MAPA je stale stejna!!! ... musime zapracovat na zmene mapy!"
-- serve_watch.py (factorio-ai) always replayed the SAME fixed AI-base-clean.zip save --
-- this command lets it give nauvis a genuinely fresh, random layout on every watch
-- session instead, while staying a GUI-client-joinable save (a headless `--create` with
-- a random seed embeds different __level__/control.lua data than a GUI-created save,
-- which a real client refuses to join -- already hit and documented in this project;
-- regenerating the EXISTING surface in place sidesteps that entirely).
--
-- require("crash-site") only works from a proper mod-loading context like this file
-- (confirmed live, 2026-07-06: calling it from an ad-hoc /c RCON command fails --
-- Factorio's console sandbox doesn't expose the same require path a real mod file gets),
-- which is why this needs to be a real command in the mod, not an inline RCON script.
local u = require("commands.init")
local crash_site = require("crash-site")

commands.add_command("fac_regenerate_map", nil, function(cmd)
  u.safe_command(function()
    local surf = game.surfaces[1]
    local mgs = surf.map_gen_settings
    mgs.seed = math.random(0, 4000000000)
    surf.map_gen_settings = mgs

    local force = game.forces.player
    local spawn = force.get_spawn_position(surf)
    -- map_gen_settings only affects chunks generated AFTER this point (existing ones
    -- keep their old terrain) -- delete the chunks around spawn to force them to
    -- regenerate with the new seed. R=8 chunks (~256 tiles) comfortably covers the
    -- opening's whole operating radius (wreck salvage alone searches up to 150 tiles).
    local ccx, ccy = math.floor(spawn.x / 32), math.floor(spawn.y / 32)
    local R = 8
    for cx = -R, R do
      for cy = -R, R do
        pcall(function() surf.delete_chunk({ccx + cx, ccy + cy}) end)
      end
    end
    surf.request_to_generate_chunks(spawn, R)
    surf.force_generate_chunk_requests()

    -- Fresh crash site at the (unchanged) spawn point, same function freeplay's own
    -- scenario uses (core/lualib/crash-site.lua) -- not a reimplementation. Minimal
    -- ship_items/part_items (this mod isn't the freeplay scenario, so there's no
    -- storage.crashed_ship_items to reuse) -- the ship's own default wreck loot
    -- (iron-plate etc., scattered by create_crash_site itself) still applies regardless.
    crash_site.create_crash_site(surf, {spawn.x, spawn.y}, {["firearm-magazine"] = 8}, {},
                                 crash_site.default_ship_parts())

    u.json_response({regenerated = true, seed = mgs.seed})
  end)
end)
