-- AI Companion v0.9.0 - Belt-connection pathfinding (Stage 0.2, 2026-07-04)
-- A* over the tile grid between two points, avoiding anything that blocks a
-- transport-belt (water, cliffs, existing buildings/trees/rocks -- delegated to the
-- ENGINE's own surf.can_place_entity check rather than re-implementing collision rules,
-- so it stays correct as the game's placement logic evolves), with a small turn-penalty
-- so the result is a reasonably direct corridor, not a serpentine walk ("not just some
-- zigzagging snake"). Bounded search area + node cap so a genuinely blocked/far target fails
-- fast instead of burning the RCON command's time budget.
--
-- Resource tiles are ordinary ground: a belt may cross an ore/coal/stone patch (Zdendys
-- 2026-10-24: "why shouldn't belts go over a resource patch?"). Until 0.16.136 is_blocked
-- had a resource check meant to route around patches, but it queried the integer tile
-- CORNER with radius 0.3 while resource entities sit at tile CENTRES -- live 2026-10-24 it
-- matched 0 of 491 ore tiles, so it never blocked ore/coal/stone (only crude oil, whose
-- collision box is large, could have matched) and was removed.
local reserved = require("commands.reserved_tiles")

local M = {}

-- MAX_SEARCH_MARGIN raised 15->40 (2026-07-05, Zdendys live-caught: a diagnostic sweep of
-- 7 distances/shapes on ONE fresh map found a NON-monotonic success pattern by bounding-box
-- area -- e.g. a 2340-tile-area route failed "no path" while a LARGER 7018-tile-area route
-- on the SAME map succeeded -- inconsistent with a pure node-budget explanation (which would
-- predict smaller-area routes succeed more reliably than larger ones). This points to a real
-- obstacle (most likely a lake, since this mod's map-gen deliberately favors a nearby water
-- body for the power plant) that some specific routes need to detour around by MORE than the
-- old 15-tile margin, independent of how many nodes the search budget allows -- no margin
-- increase can be substituted for by a bigger MAX_NODES, since a blocked tile just outside
-- the bounding box is never even a candidate node regardless of budget. 40 gives real
-- clearance for a sizeable lake without exploding the search area unreasonably (the
-- companion's own tie-break fix, added the same day, already lets the search converge
-- toward the goal instead of fanning out across the whole box, so a wider margin shouldn't
-- by itself blow the existing MAX_NODES budget for the common case).
local MAX_SEARCH_MARGIN = 60     -- tiles of slack around the from/to bounding box (2026-07-08,
-- raised 40->60, Zdendys: "vetsina vody nelze podejit" -- a genuinely wide lake needs real
-- room to route around, not just underground-belt's 5-tile max span (see UNDERGROUND_MAX_
-- DISTANCE below); 40 already got raised once for the same reason (see history above) and
-- live-caught tonight (bc_0708night1) still hit "no path" on a ~93-tile route.
local MAX_NODES = 128000         -- hard cap on A* expansions (bounded, no infinite loop) -- raised
-- 2500->4000 alongside the margin increase so the larger search area doesn't just make the
-- SAME "no path" failure happen after burning more of the budget with no detour room to show
-- for it -- both numbers need to move together.
--
-- Raised 4000->8000 (2026-07-10, task #43, alongside the open-list binary-heap change
-- above -- NOT a standalone "just raise the number again" tweak, this project's own
-- established anti-pattern; done because the heap made a larger cap cheap AND there is
-- real, reproducible offline evidence the bigger cap alone fixes a genuine failure --
-- see the correction below, though, for what this evidence does NOT yet cover). Offline
-- `lua5.3` measurements (scratchpad harness, not committed -- see task report) on the
-- exact worst case this number governs (search must exhaust the ENTIRE node budget,
-- e.g. a genuinely unreachable/heavily-obstacle-laden target): the OLD linear-scan pop
-- cost ~108-119ms at 4000 nodes and would have cost ~227ms at 8000 (measured directly,
-- reproduced independently twice more during adversarial verify) -- doubling the budget
-- under the old algorithm would have meaningfully increased real cost. With the heap,
-- 8000 nodes costs only ~45-51ms -- LESS than the OLD code's own cost at the SMALLER
-- 4000 cap. Separately, a synthetic ~130-tile route over deliberately scattered
-- obstacles (12% blocked terrain) hit "budget-exhausted" at 4000 nodes despite a real
-- 143-tile path existing just beyond that cutoff -- raising to 8000 found it, at no
-- measurable extra cost. This synthetic case is real, reproducible evidence for the cap
-- bump on its own terms.
--
-- CORRECTION (2026-07-10, same day, caught during adversarial verify): an earlier draft
-- of this comment additionally claimed the live scripts/test_belt_connect_dest_diag.py
-- diagnostic "confirmed" this fix by going from 4/8 to 5/8 genuine pathfinds -- that
-- claim was overclaimed and has been removed. The two runs used two DIFFERENT sets of 8
-- fresh random maps; the delta is a single flipped sample, and this project's OWN memory
-- already documents an earlier 1/8->4/8 jump on this same diagnostic with ZERO relevant
-- code change, i.e. within normal map-to-map noise for n=8. All 3 remaining failures in
-- the post-bump run were the diagonal-direction targets (~182-186 tile Manhattan
-- distance, ~45000-tile bounding box at the current MAX_SEARCH_MARGIN=60) -- this
-- failure class is NOT confirmed fixed by this change and remains OPEN. The heap's own
-- ~5x per-node speedup means a much larger cap is now cheap to try (measured: 32000
-- nodes costs only ~192ms, far below the RCON client's 60s socket timeout in
-- src/rcon_client.py) -- but raising it further needs its own real evidence (a
-- larger-sample or fixed-seed diagnostic run), not another guessed number. Left as the
-- concrete next step for task #43. MAX_SEARCH_MARGIN is intentionally NOT touched here
-- (it was raised previously for an unrelated geometric reason, routing room around real
-- obstacles like lakes, not a node-budget concern; nothing measured this session bears
-- on whether it separately needs to change).
--
-- RAISED 8000->16000 (2026-07-10, later same session, task #43 REAL-DATA follow-up): the
-- live diagnostic-delta approach above was explicitly flagged as inconclusive (a single
-- flipped sample, indistinguishable from map-to-map noise). Instead of another live
-- re-roll, this time captured the REAL per-tile is_blocked()/near_water() data (via direct
-- surf.count_entities_filtered/can_place_entity/find_tiles_filtered calls that mirror this
-- file's own logic exactly) for 5 GENUINELY failing (reason=="budget-exhausted") diagonal
-- routes across 2 independent fresh maps (~184-tile Manhattan distance, ~45369-tile
-- bounding box each -- exactly the failure class flagged above as open), then replayed
-- that EXACT captured obstacle geometry OFFLINE (no server) through this real source file
-- (scratchpad harness, MAX_NODES patched via a regex substitution that ASSERTS it actually
-- changed the byte content -- fixes the exact "silently no-ops once the file already
-- matches the target value" bug this project's own memory flagged in the sibling
-- explore_max_nodes.lua/explore_scaling.lua harnesses from earlier the same day) at
-- candidate caps {8000 [then-current], 16000, 32000, 64000} -- a true PAIRED comparison,
-- identical obstacle geometry every run, eliminating the map-to-map noise problem entirely.
-- Result: 0/5 scenarios succeeded at 8000 (matches each one's live "budget-exhausted"
-- origin, confirming the capture faithfully reproduces what the live search actually saw);
-- 5/5 succeeded at 16000, EVERY one finding the exact 185-tile path (184 Manhattan distance
-- + 1 for the start tile itself -- the true zero-detour optimum), with 32000 and 64000
-- finding the IDENTICAL 185-tile path in every scenario, i.e. 16000 is already the exact
-- sufficient cap for everything captured, and this evidence does not support going higher.
-- The optimal path being found comfortably inside the CURRENT MAX_SEARCH_MARGIN=60
-- bounding box also rules OUT the margin as this failure class's bottleneck -- it was
-- purely a node-budget shortfall. Measured real wall-clock cost (lua5.3 os.clock(), Python
-- time.time() around the live-capture RCON calls separately): 219-302ms per scenario at
-- cap=8000 (full exhaustion, all 5 failing cases) and 229-391ms at cap=16000/32000/64000
-- (successful, early-exits on reaching the goal) -- higher than the water-FREE synthetic
-- benchmark quoted above (~45-51ms at 8000) because these are REAL captured maps with real
-- lakes (up to 1918 water tiles each), so near_water's shore-penalty lookups add real cost
-- the synthetic case omitted entirely; still 2-3 orders of magnitude below the RCON
-- client's 60s socket timeout. Caveat, stated plainly rather than overclaimed: this is 5
-- real samples across 2 maps -- a genuine noise-free paired comparison for the EXACT
-- geometry captured, not a guarantee every possible diagonal/long route succeeds at
-- 16000 -- it is simply the smallest of the 4 prescribed candidate values that cleared
-- 100% of what was captured. See scripts/capture_pathfind_diagonal_scenarios.py (live
-- capture, factorio-ai repo) and this session's scratchpad's
-- sweep_max_nodes_real_scenarios.lua (offline replay+sweep) for the full methodology --
-- neither is committed to this repo (the harness lives in factorio-ai's scratchpad and the
-- capture script in the factorio-ai repo's scripts/, not factorio-ai-companion).
--
-- RAISED 16000->128000 (2026-07-10/11, task #43 CONTINUATION, LONG-THIN shape): a live run
-- (test_stage_b_wiring_postcoalanchor.log) hit belt_connect(54,2)->(-94,-14) failing "no
-- path"/"budget-exhausted" 3 separate times -- dx=-148, dy=-16 (~164 Manhattan), a long,
-- THIN bounding box (268x136=~36448 tiles at MAX_SEARCH_MARGIN=60) SMALLER by area than the
-- diagonal routes just confirmed above to succeed at 16000 (~45369 tiles each) -- i.e. a
-- genuinely DIFFERENT failure shape, not just "the same problem in a bigger box." Captured
-- REAL is_blocked()/near_water() data (factorio-ai's scripts/capture_pathfind_longthin_
-- scenarios.py, mirroring the diagonal capture script's method) for 8 GENUINELY failing
-- (reason=="budget-exhausted") long-thin routes (dx~148-150, dy~16-20, matching the real
-- failing route's ratio) across 3 INDEPENDENT fresh maps -- not just 2, since long-thin
-- failures turned out much RARER per-map than the diagonal case: only 3 of 11 distinct maps
-- tried produced ANY long-thin "budget-exhausted" result at all (the other 8 maps' 64
-- long-thin attempts all either pathfound successfully or only hit "Insufficient belt
-- items", i.e. pathfinding itself succeeded). Captured at CAPTURE_MARGIN=120 (double the
-- then-current MAX_SEARCH_MARGIN=60) specifically so the offline sweep could ALSO test
-- MAX_SEARCH_MARGIN independently of MAX_NODES against the exact same real geometry
-- (factorio-ai's scratchpad sweep_longthin_real_scenarios.lua), instrumented to additionally
-- surface, on every failure, the raw (expansions, #open-at-exit) the search already computes
-- internally but never returned before -- distinguishing NODE-CAP-BOUND (expansions==cap,
-- more budget could help) from MARGIN-BOUND (open list emptied before reaching cap, only a
-- wider box could help). Result: at margin=60 (current), swept cap in {16000 [then-current],
-- 32000, 64000, 128000} -- 0/8 scenarios succeed at 16000 (every one hits expansions==16000
-- exactly, matching each one's live "budget-exhausted" origin); 6/8 succeed at 32000; 7/8 at
-- 64000; 8/8 (ALL) succeed at 128000. EVERY failing row across all 8 scenarios showed
-- expansions==cap exactly (never open==0 before reaching cap) -- this shape's failures are
-- ENTIRELY node-cap-bound, NEVER margin-bound, in everything captured. Separately swept
-- MAX_SEARCH_MARGIN in {60, 90, 120} at each cap: the result (found/not-found, ms, and path
-- length when found) was IDENTICAL across all 3 margins for every single scenario/cap
-- combination -- margin measurably had ZERO effect on this shape's outcome. This directly
-- answers this task's own open question (a long-thin box's small vertical slack COULD in
-- principle force a wider detour) with real evidence: it does NOT, for any of the 8 real
-- routes captured -- MAX_SEARCH_MARGIN=60 is left unchanged. Real wall-clock cost (lua5.3
-- os.clock()): 212-253ms at cap=16000 (full exhaustion, all 8 failing, across all 8
-- scenarios x 3 margins), up to ~1249-1261ms for the single hardest scenario at
-- cap=128000 (still ~48x below the RCON client's 60s socket timeout) -- cost scales
-- roughly linearly with cap, no evidence of the heap's per-node cost exploding at this
-- larger size. Raised MAX_NODES to 128000, the smallest of
-- the 4 candidates that cleared 100% of what was captured (same selection rule as the 16000
-- decision above). Caveat, same discipline as above: this is 8 real samples across 3 maps
-- for the EXACT captured geometry, not a guarantee every possible long-thin route succeeds
-- at 128000 -- if a future live run still hits "budget-exhausted" on a route that is neither
-- this long-thin shape nor the earlier diagonal shape, the right next step is to capture
-- THAT case specifically, not guess a bigger number again. Live-verified end-to-end
-- afterward (factorio-ai's scripts/live_verify_longthin_fix.py, mirroring
-- live_verify_diagonal_fix.py's own pattern): reloaded the 3 actual captured maps
-- (AI-pfltcapture1/2/16.zip) with the fixed mod and re-issued the identical belt_connect
-- calls that previously returned "budget-exhausted" -- all 8/8 now return a found path
-- (checked via the same "reason ~= budget-exhausted" criterion the diagonal verify script
-- used; each call actually reported "Insufficient belt items" instead, confirming
-- pathfinding itself succeeded -- expected, this diagnostic never provisions belts). Real
-- live wall-clock cost: 512-2225ms per call (full engine + RCON round-trip, naturally
-- higher than the offline lua5.3-only measurements above) -- still far below the RCON
-- client's 60s socket timeout.

-- Shore buffer (2026-07-08, Zdendys: "go around water at a distance of at least 5-10 from the shore"):
-- a SOFT cost, not a hard block, added to any tile within SHORE_BUFFER of a water tile, so
-- the route PREFERS to stay clear of the coast when a choice exists (leaves room for the
-- power plant's own shore-adjacent structures, and avoids a corridor that hugs the water's
-- edge for its whole length) without making an unavoidable coast-hugging stretch impossible.
local SHORE_BUFFER = 8
local SHORE_PENALTY = 3

local function tile_key(x, y) return x .. ":" .. y end
-- State key for the SEARCH bookkeeping (visited/gscore/came_from) MUST include the arrival
-- direction, not just (x,y): edge cost depends on it via turn_penalty below, so two paths
-- reaching the same tile with equal g but different incoming direction are genuinely
-- different states -- collapsing them onto one (x,y) key lets whichever is expanded FIRST
-- permanently block a later, better-oriented arrival at the same g (or even lower cost
-- overall once its own better-turn continuation is considered), breaking A*'s optimality
-- (cubic dev ai bot, 2026-07-04: worked example with a wall forcing an extra turn).
-- (Corrected 2026-07-10, adversarial verify: path reconstruction below also uses
-- state_key via came_from, not tile_key -- this comment previously claimed otherwise;
-- tile_key is only ever used by the make_is_blocked/make_near_water caches above.)
-- `ug` (2026-11-06): the node is an underground-belt EXIT, which may only continue
-- straight -- its expansion differs from a plain belt's, so it is a separate state.
local function state_key(x, y, dir, ug)
  return x .. ":" .. y .. ":" .. tostring(dir) .. (ug and ":u" or "")
end

-- UNDERGROUND CROSSINGS (opts.underground, 2026-11-06): besides the 4 neighbours, a
-- node entered straight (not the start, not an exit) with an obstacle right ahead may
-- become an underground-belt ENTRANCE whose EXIT is UG_MAX_DISTANCE or fewer tiles ahead
-- in the same direction
-- (yellow tier: max_distance 5, entrance-to-exit), hopping over whatever lies between
-- -- a belt, a pipe, a building. That is how one belt crosses another: without it a
-- plate belt boxed in by a coal belt (live 2026-11-06: a coal join wrapped round a
-- plate row and enclosed its plate exit) has no route at all. The exit only continues
-- straight. UG_PENALTY makes a hop cost like a detour of that many tiles, so a plain
-- route wins wherever one exists. No hop where an underground belt of the same axis
-- stands within UG_MAX_DISTANCE of the hop on that line: the game would pair the new
-- entrance or exit with it.
local UG_MAX_DISTANCE = 5
local UG_PENALTY = 6
local OWN_PATH_LOOKBACK = 16   -- path tiles a crossing route checks it does not step on
-- pipe mode (blue science B1'): pipe-to-ground links at a centre distance of up to 10
-- (prototype max_underground_distance 10; measured live 2026-11-05: 10 links, 11 not);
-- a surface pipe costs 1.5 per tile, a pair k + 1 -- the run stays underground
local PIPE_UG_MAX_DISTANCE = 10
local PIPE_STEP_COST = 1.5
local PIPE_HOP_PENALTY = 1
-- entity types whose prototypes can have fluid boxes (base + Space Age; a heat exchanger
-- is a "boiler"; checked against the 2.1.24 prototype data); an assembler or
-- an electric mining drill counts even when its box is unused -- a pipe beside it could
-- still join it, so the route keeps off (conservative)
local PIPE_FLUID_TYPES = {"pipe", "pipe-to-ground", "storage-tank", "pump", "offshore-pump",
  "boiler", "generator", "fluid-turret", "mining-drill", "assembling-machine", "furnace",
  "reactor", "infinity-pipe", "valve", "fusion-generator",
  "fusion-reactor", "thruster", "agricultural-tower", "rocket-silo", "fluid-wagon"}
-- pipe mode tries up to 9 hops from every expanded node (independent review: a search
-- with no route would otherwise run the full belt budget, ~3x the heap work, in one
-- tick); weighted (PIPE_H_WEIGHT), a live 456-tile crude route took 21456 expansions
local PIPE_MAX_NODES = 64000
-- weighted A* for pipes (see find_path): routes at most 1.5x the cheapest cost
local PIPE_H_WEIGHT = 1.5

-- Per-run cache: the same neighbor tile is checked from multiple expanded nodes, and
-- surf.can_place_entity is a real engine call (not a cheap table lookup) -- memoizing
-- avoids redundant checks within one search.
local function make_is_blocked(surf, force)
  local cache = {}
  return function(x, y)
    local key = tile_key(x, y)
    local cached = cache[key]
    if cached ~= nil then return cached end
    local blocked = not surf.can_place_entity{
      name = "transport-belt", position = {x, y},
      direction = defines.direction.north, force = force
    }
    cache[key] = blocked
    return blocked
  end
end

local DIRS = {
  {dx = 1, dy = 0, dir = defines.direction.east}, {dx = -1, dy = 0, dir = defines.direction.west},
  {dx = 0, dy = 1, dir = defines.direction.south}, {dx = 0, dy = -1, dir = defines.direction.north},
}

-- Memoized "is there water within SHORE_BUFFER tiles" check, same caching pattern as
-- make_is_blocked above (count_tiles_filtered is a real engine call). A single area query
-- per newly-discovered tile, not a hard block -- see SHORE_PENALTY comment above.
local function make_near_water(surf)
  local cache = {}
  return function(x, y)
    local key = tile_key(x, y)
    local cached = cache[key]
    if cached ~= nil then return cached end
    -- Same water-tile name set used elsewhere in this mod (e.g. demonstrator.py's own
    -- terrain surveys) -- shallow-water/mud variants are still unwalkable-for-belts water,
    -- not just "water"/"deepwater".
    local near = surf.count_tiles_filtered{
      area = {{x - SHORE_BUFFER, y - SHORE_BUFFER}, {x + SHORE_BUFFER, y + SHORE_BUFFER}},
      name = {"water", "deepwater", "water-shallow", "water-mud"}
    } > 0
    cache[key] = near
    return near
  end
end

-- Binary min-heap for the A* open list (2026-07-10, task #43 perf follow-up).
-- The OLD code popped the lowest-f node via a LINEAR SCAN over the entire `open`
-- array on every iteration -- with MAX_NODES=4000 and up to 4 pushes per
-- expansion, `open` can grow into the thousands, making every pop O(|open|) and
-- the whole search roughly O(n^2) instead of the O(n log n) a proper priority
-- queue gives. Lua has no built-in decrease-key heap, so this uses the standard
-- "lazy deletion" pattern: a state can be pushed multiple times (once per
-- successful relaxation -- the OLD linear-scan code already relied on this too,
-- since it never removed a stale `open` entry on relaxation either, only ever
-- appended a fresh one), and the existing `visited[state_key]` check (unchanged,
-- right after `heap_pop` at the call site below) discards a stale duplicate the
-- first time it's popped after its state has already been expanded via a
-- fresher, cheaper entry. This is safe BECAUSE edge costs are non-negative: each
-- successive relaxation of the same state produces a STRICTLY smaller g (the
-- `ng < gscore[nk]` guard below enforces this), and since h() depends only on
-- position (not on which relaxation produced the entry), a strictly smaller g
-- means a strictly smaller f too -- so the freshest (cheapest) entry for any
-- given state ALWAYS has the smallest f among all of that state's own entries,
-- and is therefore ALWAYS popped before any of its own staler duplicates,
-- regardless of push order. This is the exact same property the old linear scan
-- already depended on (it too just picked the global-minimum f/g node each
-- iteration, oblivious to which entries were "stale") -- a pure performance
-- change, not a new correctness assumption.
--
-- Comparator: lowest f first; among equal f, prefer LARGER g (2026-07-05
-- tie-break, see the historical comment preserved at the call site below --
-- unchanged, still biases the search to march toward the goal instead of
-- fanning out on a plateau); among equal f AND equal g (a real tie between two
-- distinct nodes), prefer whichever was pushed FIRST (`seq`, a monotonically
-- increasing push counter) -- this exactly reproduces the old linear scan's own
-- de-facto tie-break (it iterated `open` in insertion order and only overwrote
-- its running-best on a STRICT `<`, so among full ties the earliest-inserted
-- entry always won), so the heap's pop order is IDENTICAL to the old scan's pop
-- order at every single step, not just "equally optimal" -- same algorithm
-- trace, same expansions count, same final path, for any given input.
local function heap_less(a, b)
  if a.f ~= b.f then return a.f < b.f end
  if a.g ~= b.g then return a.g > b.g end
  return a.seq < b.seq
end

local function heap_push(heap, node)
  heap[#heap + 1] = node
  local i = #heap
  while i > 1 do
    local parent = math.floor(i / 2)
    if heap_less(heap[i], heap[parent]) then
      heap[i], heap[parent] = heap[parent], heap[i]
      i = parent
    else
      break
    end
  end
end

-- Pops and returns the minimum element (per heap_less above). Caller must only
-- call this on a non-empty heap (the while loop at the call site below already
-- guards on `#open > 0` before calling, matching the old code's own guard).
local function heap_pop(heap)
  local n = #heap
  local top = heap[1]
  heap[1] = heap[n]
  heap[n] = nil
  n = n - 1
  local i = 1
  while true do
    local left, right = i * 2, i * 2 + 1
    local smallest = i
    if left <= n and heap_less(heap[left], heap[smallest]) then smallest = left end
    if right <= n and heap_less(heap[right], heap[smallest]) then smallest = right end
    if smallest == i then break end
    heap[i], heap[smallest] = heap[smallest], heap[i]
    i = smallest
  end
  return top
end

-- PURE routes (2026-11-06, plate belts to a science line): tiles something from outside
-- would put items onto. Without this a plate route could run in front of a coal belt's
-- end, which would side-load coal onto it, or under an inserter that drops onto that
-- tile. It could also run under an inserter's empty pickup point, and that inserter would
-- take plates off. Collected ONCE for the whole search box (one engine call) rather than
-- per expanded tile. A tile counts when one of these points into it:
--   * a transport belt or an underground-belt exit faces it (a belt end; a tile in the
--     middle of a line is occupied anyway);
--   * an inserter's drop or pickup point, or a mining drill's drop point, lies on it;
--   * a splitter's output faces it (both of its 2 lanes' front tiles).
-- (Loaders are not craftable in the base game and are not handled.)
-- Keys are tile_key(floor x, floor y).
local DIR_VEC = {[defines.direction.north] = {0, -1}, [defines.direction.east] = {1, 0},
                 [defines.direction.south] = {0, 1}, [defines.direction.west] = {-1, 0}}

local function fed_tiles(surf, minx, miny, maxx, maxy)
  local fed = {}
  local function mark(p) fed[tile_key(math.floor(p.x), math.floor(p.y))] = true end
  for _, e in pairs(surf.find_entities_filtered{
      area = {{minx - 3, miny - 3}, {maxx + 4, maxy + 4}},
      type = {"transport-belt", "underground-belt", "splitter", "inserter", "mining-drill"}}) do
    if e.type == "transport-belt"
        or (e.type == "underground-belt" and e.belt_to_ground_type == "output") then
      local v = DIR_VEC[e.direction]
      if v then mark({x = e.position.x + v[1], y = e.position.y + v[2]}) end
    elseif e.type == "splitter" then
      -- 2 tiles wide across its direction, centred on the seam: one front tile per half
      local v = DIR_VEC[e.direction]
      if v then
        for _, side in ipairs({-0.5, 0.5}) do
          mark({x = e.position.x + v[1] + side * v[2], y = e.position.y + v[2] + side * v[1]})
        end
      end
    elseif e.type == "inserter" then
      mark(e.drop_position)
      mark(e.pickup_position)
    elseif e.type == "mining-drill" then
      mark(e.drop_position)
    end
  end
  return fed
end

-- 4-directional A* (belts are axis-aligned). Returns an ordered list of
-- {x, y, dir} (dir = the direction of travel INTO that tile, nil for the start tile),
-- or nil if no route was found within the search budget. On nil, a second string
-- return value distinguishes WHY (2026-07-10, task #43 diagnostic follow-up):
-- "start-blocked" / "dest-blocked" / "unreachable" (2026-10-23: open list emptied) /
-- "budget-exhausted" (MAX_NODES hit) -- callers that only capture
-- one return value (`local path = pathfind.find_path(...)`) are unaffected, per Lua's
-- own multi-return semantics (extra return values are simply discarded).
-- opts (optional): {pure = true} also blocks every fed tile (fed_tiles above) except the
-- start, which the caller's own belt end is meant to feed; a fed destination fails
-- as "dest-fed". {underground = true} adds underground crossings (UG_MAX_DISTANCE
-- above): path entries then may carry underground = "entrance" / "exit" (an entrance
-- is always directly followed by its exit, an exit by a tile straight ahead); the
-- destination is never an exit (a caller may need to turn its last belt).
-- {pipe = true} plans a fluid pipeline instead: hops of up to PIPE_UG_MAX_DISTANCE
-- (pipe-to-ground pairs, preferred over surface pipe), and no surface step onto a tile
-- beside a foreign fluid entity (start and destination exempt: they touch the source
-- and the sink -- an end touching two fluid entities fails as "start-fluid-mixed" /
-- "dest-fluid-mixed"; an end with no usable neighbour as "start-enclosed" /
-- "dest-enclosed"; the node budget is PIPE_MAX_NODES). Entries carry the same
-- underground = "entrance" / "exit" marks.
function M.find_path(surf, from, to, force, opts)
  M.last_expansions = 0          -- diagnostic: the last search's expansions (plan replies)
  local fx, fy = math.floor(from.x), math.floor(from.y)
  local tx, ty = math.floor(to.x), math.floor(to.y)
  local minx = math.min(fx, tx) - MAX_SEARCH_MARGIN
  local maxx = math.max(fx, tx) + MAX_SEARCH_MARGIN
  local miny = math.min(fy, ty) - MAX_SEARCH_MARGIN
  local maxy = math.max(fy, ty) + MAX_SEARCH_MARGIN
  local is_blocked = make_is_blocked(surf, force)
  -- a reserved tile (commands/reserved_tiles.lua: a block's join tile a later route must
  -- reach) is no tile for this route -- unless it is the route's own start or end
  local res = reserved.lookup()
  if res then
    local placeable = is_blocked
    is_blocked = function(x, y)
      local col = res[x]
      if col and col[y] and not (x == fx and y == fy) and not (x == tx and y == ty) then
        return true
      end
      return placeable(x, y)
    end
  end
  if opts and opts.pure then
    local fed = fed_tiles(surf, minx, miny, maxx, maxy)
    if fed[tile_key(tx, ty)] and not (tx == fx and ty == fy) then return nil, "dest-fed" end
    local placeable_blocked = is_blocked
    is_blocked = function(x, y)
      if fed[tile_key(x, y)] and not (x == fx and y == fy) then return true end
      return placeable_blocked(x, y)
    end
  end
  local near_water = make_near_water(surf)
  -- The start tile is seeded directly into `open` (never evaluated as a "neighbor"),
  -- so it needs its own explicit check for the same reason the destination tile does.
  if is_blocked(fx, fy) then return nil, "start-blocked" end
  -- Destination-blocked check (2026-07-10, task #43 diagnostic follow-up): without this,
  -- a destination sitting on water/a building/anything is_blocked rejects can NEVER be
  -- added to `open` (it's only ever validated as a side effect of neighbor-expansion
  -- below), so the search silently exhausts the whole budget before returning nil --
  -- indistinguishable from a genuine "too far/obstacle-heavy" failure. Checking it here
  -- fails fast AND tags the result with a distinguishable reason. `is_blocked` is a
  -- memoized per-call closure (see make_is_blocked above), so this extra call just
  -- seeds the (tx,ty) cache entry early -- no different from it being queried later
  -- during normal expansion, no stale-cache risk.
  if is_blocked(tx, ty) then return nil, "dest-blocked" end

  -- PIPE mode (opts.pipe, 2026-11-06, blue science B1'): the same search lays a fluid
  -- pipeline -- plain steps are pipes, hops are pipe-to-ground pairs (up to
  -- PIPE_UG_MAX_DISTANCE). A surface pipe costs more than the tiles a pair covers, so the
  -- run stays underground (it does not block walking, and touches nothing on the way),
  -- and a hop needs no obstacle ahead.
  local pipe = opts and opts.pipe
  -- The cheapest tile in pipe mode is one of a longest hop, (max + penalty) / max = 1.1;
  -- scaling the heuristic by it keeps it admissible and consistent (a step costs 1.5, a
  -- hop of k costs k + 1 >= 1.1 k for k <= 10) while narrowing the search band of a long
  -- pipeline (with h = Manhattan alone every tile within ~0.14 x length of the line would
  -- tie with the best route).
  -- On top of that the pipe search is WEIGHTED (PIPE_H_WEIGHT; live 2026-11-06: a
  -- 456-tile crude route over a real map ran out of the node budget with the plain
  -- bound): the route found costs at most PIPE_H_WEIGHT x the cheapest one, which for a
  -- pipeline only means a few more pieces -- finding one at all is what matters.
  local h_scale = pipe and PIPE_H_WEIGHT * (PIPE_UG_MAX_DISTANCE + PIPE_HOP_PENALTY)
                           / PIPE_UG_MAX_DISTANCE or 1
  local function h(x, y) return h_scale * (math.abs(tx - x) + math.abs(ty - y)) end

  local ug_max = pipe and PIPE_UG_MAX_DISTANCE
                 or ((opts and opts.underground) and UG_MAX_DISTANCE or nil)
  local ug_type = pipe and "pipe-to-ground" or "underground-belt"
  local step_cost = pipe and PIPE_STEP_COST or 1
  local hop_penalty = pipe and PIPE_HOP_PENALTY or UG_PENALTY
  local DIR_OF = {}
  for _, d in ipairs(DIRS) do DIR_OF[d.dir] = d end
  -- whether an underground of the axis of `d` stands on the line through (x, y) within
  -- ug_max either way (memoized per tile and axis): the game would pair with it
  local ug_axis_cache = {}
  local function axis_underground_near(x, y, d)
    local key = tile_key(x, y) .. ":" .. (d.dir % 8)
    local v = ug_axis_cache[key]
    if v ~= nil then return v end
    local ax, bx = x - math.abs(d.dx) * ug_max, x + math.abs(d.dx) * ug_max
    local ay, by = y - math.abs(d.dy) * ug_max, y + math.abs(d.dy) * ug_max
    v = false
    for _, e in pairs(surf.find_entities_filtered{
        area = {{ax + 0.1, ay + 0.1}, {bx + 0.9, by + 0.9}}, type = ug_type}) do
      if (e.direction - d.dir) % 8 == 0 then v = true break end
    end
    ug_axis_cache[key] = v
    return v
  end
  -- PIPE mode: a plain pipe joins every adjacent fluid box, so it may not stand next to a
  -- FOREIGN fluid entity (crude must not mix with water or steam). The tiles touching any
  -- fluid entity's footprint are collected once (one area query); the start and goal
  -- tiles are exempt -- they are meant to touch their source and sink, and nothing else:
  -- an end tile touching TWO fluid entities is refused below (independent review). A
  -- pipe-to-ground connects only on its facing side (the route itself), so hop ends are
  -- exempt too. fluid_adj[tile] = the set of fluid entities touching it.
  local fluid_adj = {}
  local anon = 0                -- ids for fluid entities without a unit_number
  if pipe then
    -- the entity types that can carry a fluid box (a long pipeline's box holds many trees
    -- and rocks -- those are not queried); each is still checked for real fluid boxes
    for _, e in pairs(surf.find_entities_filtered{area = {{minx - 6, miny - 6}, {maxx + 7, maxy + 7}},
        type = PIPE_FLUID_TYPES}) do
      local ok, boxes = pcall(function() return e.prototype.fluidbox_prototypes end)
      if ok and boxes and #boxes > 0 then
        local b = e.bounding_box
        local x0, y0 = math.floor(b.left_top.x + 0.01), math.floor(b.left_top.y + 0.01)
        local x1, y1 = math.ceil(b.right_bottom.x - 0.01) - 1, math.ceil(b.right_bottom.y - 0.01) - 1
        anon = anon + 1
        local id = e.unit_number or ("anon" .. anon)
        local function mark(x, y)
          local k = tile_key(x, y)
          fluid_adj[k] = fluid_adj[k] or {}
          fluid_adj[k][id] = true
        end
        for x = x0, x1 do mark(x, y0 - 1) mark(x, y1 + 1) end
        for y = y0, y1 do mark(x0 - 1, y) mark(x1 + 1, y) end
      end
    end
  end
  local function fluid_touch(x, y)
    return pipe and fluid_adj[tile_key(x, y)] ~= nil and not (x == fx and y == fy)
           and not (x == tx and y == ty)
  end
  if pipe then
    -- an end pipe joins every fluid entity beside it: more than one = a foreign fluid
    -- would mix in at the very first (or last) tile
    for _, e in ipairs({{fx, fy, "start-fluid-mixed"}, {tx, ty, "dest-fluid-mixed"}}) do
      local n = 0
      for _ in pairs(fluid_adj[tile_key(e[1], e[2])] or {}) do n = n + 1 end
      if n > 1 then return nil, e[3] end
    end
    -- fail fast on an enclosed end (the search would otherwise expand the whole box):
    -- the start needs a free, clean neighbour (it cannot hop -- no direction yet); the
    -- goal needs a free neighbour (an exit may arrive there, exits touch nothing)
    local start_ok, goal_ok = false, false
    for _, d in ipairs(DIRS) do
      local sx, sy = fx + d.dx, fy + d.dy
      if not is_blocked(sx, sy) and not fluid_touch(sx, sy) then start_ok = true end
      if not is_blocked(tx + d.dx, ty + d.dy) then goal_ok = true end
    end
    if not start_ok and not (math.abs(tx - fx) + math.abs(ty - fy) <= 1) then
      return nil, "start-enclosed"
    end
    if not goal_ok then return nil, "dest-enclosed" end
  end
  local max_nodes = pipe and PIPE_MAX_NODES or MAX_NODES

  -- a route never steps onto its own start or a tile of its recent path: with
  -- crossings, looping back to enter a hop straight can look cheapest (live 2026-11-06:
  -- an underground entrance planned on the start tile's own belt). Without crossings a
  -- loop is never cheaper, so plain routes do not use this. Each node carries its
  -- parent, so no state-key strings are built on this hot path (independent review).
  local function on_own_path(node, x, y)
    if x == fx and y == fy then return true end
    local n, steps = node, 0
    while n and steps < OWN_PATH_LOOKBACK do
      if n.x == x and n.y == y then return true end
      n = n.parent
      steps = steps + 1
    end
    return false
  end

  local open = {}
  local seq = 0                           -- monotonic push counter, see heap_less above
  seq = seq + 1
  heap_push(open, {x = fx, y = fy, dir = nil, g = 0, f = h(fx, fy), seq = seq})
  local came_from = {}                    -- state_key -> predecessor node
  local gscore = {[state_key(fx, fy, nil)] = 0}
  local visited = {}
  local expansions = 0

  while #open > 0 and expansions < max_nodes do
    -- Pop lowest-f via the binary min-heap above (O(log n), see heap_pop/heap_less
    -- for the full mechanism + why its pop order is provably identical to the OLD
    -- linear-scan's pop order at every step). Tie-break toward the LARGER g
    -- (2026-07-05, Zdendys live-caught: a 134-tile route reported "no path" despite
    -- there being no water/cliffs in the way -- root cause: with a Manhattan
    -- heuristic and 4-directional movement, every tile inside the from/to bounding
    -- rectangle has the SAME f = g+h (the whole rectangle is one tied plateau), and
    -- the old tie-break ("keep whichever equal-f node was found first") made the
    -- search fan out breadth-first across nearly the ENTIRE rectangle before ever
    -- reaching the goal corner -- for a 121x58 box that's ~7000 tiles against a
    -- 2500-node cap, guaranteeing a false "no path" on a fully open field. Preferring
    -- the larger-g (equivalently smaller-h, i.e. closer to the goal) node among ties
    -- biases expansion to march toward the target instead of radiating outward evenly,
    -- without changing A*'s optimality guarantee at all (ties by definition share the
    -- same f, so picking a different one among them cannot produce a worse-than-optimal
    -- final path -- see the state_key/goal-test comments below, unaffected by this).
    local cur = heap_pop(open)
    local ck = state_key(cur.x, cur.y, cur.dir, cur.ug)
    if not visited[ck] then
      visited[ck] = true
      expansions = expansions + 1
      if cur.x == tx and cur.y == ty then
        -- Any (goal-tile, *) state popped here is guaranteed minimum-cost for the goal
        -- POSITION (not just for this particular direction): h() doesn't depend on dir, so
        -- among all direction-variants of the goal tile the lowest-g one always has the
        -- lowest f and is popped first (edge costs are non-negative, so g only grows along
        -- a path) -- position-only goal test is correct even though the state space isn't.
        -- (Pipe mode is weighted -- PIPE_H_WEIGHT: there the route is within 1.5x of the
        -- cheapest, not minimum; the lowest-g goal variant still pops first, h = 0 there.)
        -- an exit's predecessor is its entrance (hops start only from non-exit nodes)
        local path, node, after_exit, seen = {}, cur, false, {}
        while node do
          local entry = {x = node.x, y = node.y, dir = node.dir}
          if node.ug then entry.underground = "exit"
          elseif after_exit then entry.underground = "entrance" end
          after_exit = node.ug == true
          -- a tile used twice cannot be built (live 2026-11-06: a crossing route looped
          -- back over its own start) -- the expansion below avoids it; this is the net
          local tk = tile_key(node.x, node.y)
          if seen[tk] then M.last_expansions = expansions return nil, "self-overlap" end
          seen[tk] = true
          table.insert(path, 1, entry)
          node = came_from[state_key(node.x, node.y, node.dir, node.ug)]
        end
        M.last_expansions = expansions
        return path
      end
      -- underground hops: from a node entered straight that is not itself an exit
      if ug_max and cur.dir and not cur.ug then
        local d = DIR_OF[cur.dir]
        -- only right before an obstacle: with the tile ahead free, stepping onto it and
        -- hopping from there costs the same (1 + (k-1) + UG_PENALTY) and reaches one tile
        -- further, so nothing is lost -- and the axis check (an engine call) runs only
        -- at obstacles, and only once a free exit tile exists (independent review:
        -- worst-case tick time). Pipe mode hops anywhere: a pair is cheaper than the
        -- surface pipes it replaces, so the run is meant to stay underground.
        local axis_ok = nil
        if d and (pipe or is_blocked(cur.x + d.dx, cur.y + d.dy)) then
          for k = 2, ug_max do
            local nx, ny = cur.x + d.dx * k, cur.y + d.dy * k
            if nx < minx or nx > maxx or ny < miny or ny > maxy then break end
            if not (nx == tx and ny == ty) and not is_blocked(nx, ny)
                and not on_own_path(cur, nx, ny) then
              if axis_ok == nil then axis_ok = not axis_underground_near(cur.x, cur.y, d) end
              if not axis_ok then break end
              local ng = cur.g + k + hop_penalty + (near_water(nx, ny) and SHORE_PENALTY or 0)
              local nk = state_key(nx, ny, cur.dir, true)
              -- (no relaxing an expanded state: the weighted pipe heuristic is not
              -- consistent, and came_from must stay the chain on_own_path checked)
              if not visited[nk] and ng < (gscore[nk] or math.huge) then
                gscore[nk] = ng
                came_from[nk] = cur
                seq = seq + 1
                heap_push(open, {x = nx, y = ny, dir = cur.dir, g = ng, f = ng + h(nx, ny),
                                 seq = seq, ug = true, parent = cur})
              end
            end
          end
        end
      end
      for _, d in ipairs(DIRS) do
        local nx, ny = cur.x + d.dx, cur.y + d.dy
        -- an underground exit only continues straight
        if (not cur.ug or d.dir == cur.dir)
            and nx >= minx and nx <= maxx and ny >= miny and ny <= maxy then
          -- No endpoint exemption: the destination tile must be a genuinely valid belt
          -- spot too (not water/occupied), same as every other tile on the route.
          if not is_blocked(nx, ny) and not (ug_max and on_own_path(cur, nx, ny))
              and not fluid_touch(nx, ny) then
            local turn_penalty = (cur.dir and cur.dir ~= d.dir) and 0.5 or 0
            local shore_penalty = near_water(nx, ny) and SHORE_PENALTY or 0
            local ng = cur.g + step_cost + turn_penalty + shore_penalty
            local nk = state_key(nx, ny, d.dir)
            if not visited[nk] and ng < (gscore[nk] or math.huge) then
              gscore[nk] = ng
              came_from[nk] = cur
              seq = seq + 1
              heap_push(open, {x = nx, y = ny, dir = d.dir, g = ng, f = ng + h(nx, ny), seq = seq,
                               parent = cur})
            end
          end
        end
      end
    end
  end
  -- 2026-10-23: an EMPTY open list means every tile reachable from the start (inside the
  -- search box) was expanded without meeting the goal -- the start or the goal sits in an
  -- enclosed pocket, and more MAX_NODES cannot help. It used to be reported as
  -- "budget-exhausted" too, which made enclosed starts (live: a coal-belt end boxed in by
  -- boiler fuel chests, failing in 2 ticks) indistinguishable from genuinely long searches.
  M.last_expansions = expansions
  if #open == 0 then return nil, "unreachable" end
  return nil, "budget-exhausted"   -- node budget ran out before the goal was reached
end

return M
