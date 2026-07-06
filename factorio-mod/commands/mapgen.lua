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
    -- Prefer a caller-supplied seed ("seed=12345") over math.random(): Factorio's own
    -- RNG turned out to produce the IDENTICAL value across separate fresh server
    -- restarts (confirmed live, 2026-07-06 -- two independent restarts both produced
    -- seed 1428491079), so it isn't actually varying run-to-run the way a real random
    -- source would. The caller (serve_watch.py) generates a genuinely random seed in
    -- Python instead and passes it explicitly; math.random() stays as a fallback only
    -- for direct/manual invocation.
    local req_seed = cmd.parameter and cmd.parameter:match("seed=(%d+)")
    mgs.seed = req_seed and tonumber(req_seed) or math.random(0, 4000000000)
    surf.map_gen_settings = mgs

    local force = game.forces.player
    local spawn = force.get_spawn_position(surf)
    -- map_gen_settings only affects chunks generated AFTER this point (existing ones
    -- keep their old terrain) -- delete the chunks around spawn to force them to
    -- regenerate with the new seed. R=4 chunks (~128 tiles, 81 chunks total) -- lowered
    -- from an initial R=8 (2026-07-06 live test: 289 chunks at R=8 never finished
    -- generating within 30s of real time even with force_generate_chunk_requests(), so
    -- is_chunk_generated at spawn stayed false the whole time) -- still comfortably
    -- covers the opening's IMMEDIATE needs (coal/stone/iron typically found within 100
    -- tiles); anything beyond this ring keeps using the OLD seed's terrain, which is
    -- fine since decide()'s own resource-search radii extend further out regardless.
    local ccx, ccy = math.floor(spawn.x / 32), math.floor(spawn.y / 32)
    local R = 4
    for cx = -R, R do
      for cy = -R, R do
        pcall(function() surf.delete_chunk({ccx + cx, ccy + cy}) end)
      end
    end
    surf.request_to_generate_chunks(spawn, R)
    surf.force_generate_chunk_requests()

    -- Chunk generation is ASYNCHRONOUS even after force_generate_chunk_requests()
    -- (confirmed live, 2026-07-06: is_chunk_generated at spawn was still false
    -- immediately after this call returned) -- spawning the crash site here would try
    -- to place entities on not-yet-real terrain and silently do nothing. Remember
    -- WHERE to spawn it and let fac_regenerate_map_status (polled by the caller) do the
    -- actual spawn once the chunk is confirmed ready, instead of guessing a fixed delay.
    storage.pending_crash_site = {surface_index = surf.index, x = spawn.x, y = spawn.y}

    u.json_response({regenerated = true, seed = mgs.seed})
  end)
end)

commands.add_command("fac_regenerate_map_status", nil, function(cmd)
  u.safe_command(function()
    local pending = storage.pending_crash_site
    if not pending then
      u.json_response({done = true, already_done = true})
      return
    end
    local surf = game.surfaces[pending.surface_index]
    local cx, cy = math.floor(pending.x / 32), math.floor(pending.y / 32)
    if not surf.is_chunk_generated({cx, cy}) then
      u.json_response({done = false, generating = true})
      return
    end
    -- Fresh crash site at the (unchanged) spawn point, same function freeplay's own
    -- scenario uses (core/lualib/crash-site.lua) -- not a reimplementation. Minimal
    -- ship_items/part_items (this mod isn't the freeplay scenario, so there's no
    -- storage.crashed_ship_items to reuse) -- the ship's own default wreck loot
    -- (iron-plate etc., scattered by create_crash_site itself) still applies regardless.
    crash_site.create_crash_site(surf, {pending.x, pending.y}, {["firearm-magazine"] = 8},
                                 {}, crash_site.default_ship_parts())
    storage.pending_crash_site = nil
    u.json_response({done = true, spawned = true})
  end)
end)
