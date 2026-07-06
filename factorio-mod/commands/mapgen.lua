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
    -- Deleting+re-requesting the spawn chunks in THIS SAME call (right after changing
    -- map_gen_settings.seed above) never completed live no matter the radius or
    -- request granularity (confirmed 2026-07-06: is_chunk_generated at spawn stayed
    -- false for 100+ real seconds) -- yet the IDENTICAL delete+request steps run
    -- STANDALONE against an already-settled surface (i.e. at least one tick after the
    -- seed change) completed instantly every time tested, including the exact spawn
    -- chunk itself. So the delete+request work is deliberately NOT done here -- only
    -- recorded as pending -- and actually performed on fac_regenerate_map_status's
    -- FIRST poll instead, which the caller only calls after at least one RCON
    -- round-trip (>=1 tick) has passed since this command returned.
    storage.pending_crash_site = {surface_index = surf.index, x = spawn.x, y = spawn.y,
                                   requested = false}

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

    if not pending.requested then
      -- FIRST poll after fac_regenerate_map: now do the delete+regenerate-request work
      -- (see the comment in fac_regenerate_map for why it's deferred to here instead of
      -- running immediately after the seed change). R=4 chunks (~128 tiles, 81 chunks
      -- total) -- comfortably covers the opening's IMMEDIATE needs (coal/stone/iron
      -- typically found within 100 tiles); anything beyond this ring keeps using the
      -- OLD seed's terrain, which is fine since decide()'s own resource-search radii
      -- extend further out regardless.
      local ccx, ccy = math.floor(pending.x / 32), math.floor(pending.y / 32)
      local R = 4
      for cx = -R, R do
        for cy = -R, R do
          pcall(function() surf.delete_chunk({ccx + cx, ccy + cy}) end)
        end
      end
      -- Per-chunk requests (radius=0 each), not one bulk request_to_generate_chunks(
      -- pos, R) call -- the bulk form never completed live even standalone, but
      -- individual per-chunk requests did every time tested.
      for cx = -R, R do
        for cy = -R, R do
          surf.request_to_generate_chunks({(ccx + cx) * 32, (ccy + cy) * 32}, 0)
        end
      end
      surf.force_generate_chunk_requests()
      pending.requested = true
      u.json_response({done = false, generating = true})
      return
    end

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
