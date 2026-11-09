-- AI Companion -- task pool ensure_item procurement engine (2026-07-19 size-refactor
-- split out of task_pool.lua). This is the fully self-contained piece of that file:
-- recipe resolution, fetching from the stores, and the recursive gather/craft/chop
-- resolution loop for a single "ensure_item" step's ctx.ensure_stack. Zero calls to/from
-- the step-handler cluster or the scheduler tick, which both stay in task_pool.lua,
-- which requires this module and calls into it for start_ensure_item_action below.

local u = require("commands.init")
local queues = require("commands.queues")
local fetch = require("commands.task_pool_fetch")
local Stores = require("commands.supply_stores")

local M = {}

-- ensure_item (2026-07-17, Zdendys's own architecture correction: procurement was
-- kept OUT of this module by the ORIGINAL v1 task-pool design, back when neither
-- recipe resolution nor a hand-craftable check existed anywhere in this repo --
-- both now do (resolve_recipe/HAND_CRAFTABLE_CATEGORIES below, mirroring
-- companion.py's get_recipe_ingredients; queues.start_gather/start_craft), so
-- there is no longer a reason to keep this Python's job). Recursively resolves
-- missing INGREDIENTS first (bottom-up, exactly like ColdStartOpening.ensure_item,
-- spatial_demo.py) via an explicit stack in ctx.ensure_stack, bounded to depth
-- ENSURE_ITEM_MAX_DEPTH -- a raw/minable resource (no recipe) is gathered via the
-- existing gather_queues machinery, a non-hand-craftable recipe (smelting) fails
-- fast instead of wasting a doomed start_craft attempt, and wood (no
-- gather()-compatible resource-tile path -- trees are type="tree", not
-- type="resource") is chopped via its own small bounded walk+mine sub-state.
-- Should normally be the FIRST step of a task whose later place/fuel steps
-- consume the same item, so the whole task is self-sufficient once submitted.
local HAND_CRAFTABLE_CATEGORIES = {["crafting"] = true, ["hand-crafting"] = true}
local ENSURE_ITEM_MAX_DEPTH = 4     -- mirrors ColdStartOpening.ensure_item's own _depth cap (spatial_demo.py)
local WOOD_CHOP_MAX_TREES = 10      -- mirrors _chop_wood's own max_trees bound (spatial_demo.py)
-- ENSURE_ITEM_GATHER_MAX_ATTEMPTS (2026-07-17, independent-review-caught HIGH-
-- severity gap before this feature ever shipped): the raw-resource gather path
-- had NO bound at all -- a genuinely scarce/partially-unreachable patch (a real,
-- previously-observed scenario for coal specifically, see this project's own
-- memory) would re-issue start_gather forever with no failure signal, stranding
-- the task indefinitely. Mirrors WOOD_CHOP_MAX_TREES's own bounded-attempts
-- shape, applied to the gather path too instead of leaving it as the one
-- ensure_item sub-path with no give-up condition.
local ENSURE_ITEM_GATHER_MAX_ATTEMPTS = 5
-- RAW_WAIT_TICKS: how long a step short of a raw material waits for its drills' chests
-- when no store holds it but a drill of it stands (no hand mining -- Zdendys
-- 2026-11-09); as the smelt wait below
local RAW_WAIT_TICKS = 14400
-- the start of a no_mine step's failure when it would have to mine (the controller's
-- cue to mine itself -- CompanionAPI.ensure_raw)
local NO_MINE_REASON = "would mine "
M.NO_MINE_REASON = NO_MINE_REASON
-- the start of a step's failure after the drills' wait ran out (a drill of it with a
-- chest stands -- no hand mining: the controller does not mine either)
local DRILL_WAIT_REASON = "no store of "
M.DRILL_WAIT_REASON = DRILL_WAIT_REASON
-- SMELT_WAIT_TICKS (2026-07-27, Zdendys's own direct correction: "Companion neumi
-- tavit za pochodu -- od toho jsou pece! Z materialu umi companion vyrabet dily a
-- jednodussi budovy (vrtacky, pece, pasy, podavace atd.)" -- "The companion isn't
-- supposed to smelt on the fly, that's what furnaces are for! From materials the
-- companion CAN craft parts and simpler buildings (drills, furnaces, belts,
-- feeders etc.)"). The non-hand-craftable fail-fast below (2026-07-16) was and
-- remains CORRECT that the companion must never attempt to smelt -- but failing
-- the WHOLE task outright the very first time a smelted ingredient (iron-plate/
-- copper-plate) is short conflates "I can't produce this myself" with "nothing
-- else is producing it either". By the time these real failures were observed
-- live this session (coal_pair_upgrade, iron_drill_row, build_ore_drill_row_
-- unit_steps), the base drill+furnace pairs were already BUILT and running --
-- an already-fueled furnace keeps smelting on its own regardless of this task,
-- so a short-lived wait gives it a real chance to top up the stock before this
-- task gives up. 14400 ticks (30 real seconds at this project's game.speed=8) is
-- comfortably longer than a running furnace needs to produce far more than any
-- of these small crafts require (a stone-furnace smelts 1 plate per ~3.2 GAME
-- seconds = ~0.4 REAL seconds at speed=8) while still being a bounded, honest
-- wait -- not a silent infinite stall if genuinely no furnace exists yet.
local SMELT_WAIT_TICKS = 14400
-- Real Factorio recipe data for `item`, or nil if `item` has no recipe at all
-- (every raw/minable resource -- ore, coal, stone, wood -- has zero recipe
-- ingredients; nil means "raw resource, gather it, don't craft it"). Mirrors
-- companion.py's get_recipe_ingredients EXACTLY -- same prototypes.recipe[item]
-- access path (NOT game.recipe_prototypes, confirmed via that method's own
-- docstring/ground-truth citation not to exist in Factorio 2.0) -- just native
-- Lua instead of a JSON round-trip over RCON, since this now runs INSIDE the mod.
local function resolve_recipe(item)
  local r = prototypes.recipe[item]
  if not r then return nil end
  local ingredients = {}
  for _, x in ipairs(r.ingredients) do
    ingredients[#ingredients + 1] = {name = x.name, amount = x.amount}
  end
  local yield = 1
  for _, p in ipairs(r.products) do
    if p.name == item then yield = p.amount; break end
  end
  local hand_craftable = false
  for _, cat in ipairs(r.categories or {"crafting"}) do
    if HAND_CRAFTABLE_CATEGORIES[cat] then hand_craftable = true; break end
  end
  return {ingredients = ingredients, yield = yield, hand_craftable = hand_craftable}
end


-- Starts exactly ONE concrete action toward satisfying the need at the TOP of
-- t.ctx.ensure_stack (item=, count=) for companion c/cid. Returns a `kind`
-- string describing what was started ("gather"|"craft"|"chop"|"push"|"satisfied")
-- plus an error string on genuine failure (kind=nil). "push" means a NEW, deeper
-- need (a short ingredient) was pushed onto the stack -- no queue was started
-- this cycle, the caller should look at the stack again next "acting" pass.
-- "satisfied" means the top-of-stack need is ALREADY met (checked fresh here,
-- not assumed) -- pop it and reassess without starting anything. "fetch": a walk to
-- a place holding a smelted ingredient was set up (task_pool_fetch.begin_walk);
-- "wait": a furnace may still make it (the smelt wait), or a drill of a raw material
-- (no store holds it, no hand mining: the raw wait) -- reassess next pass.
function M.start_ensure_item_action(c, cid, t)
  local stack = t.ctx.ensure_stack
  local need = stack[#stack]
  if type(need.item) ~= "string" or type(need.count) ~= "number" then
    -- Input validation (2026-07-17, independent-review-caught LOW finding):
    -- mirrors run_set_position's own explicit guard -- a caller bug omitting
    -- item/count would otherwise crash on the get_item_count() call below,
    -- silently swallowed tick after tick by guard_tick's pcall (this file's own
    -- documented failure mode elsewhere) instead of failing this ONE task
    -- cleanly with a clear diagnostic.
    return nil, "ensure_item: step.item (string) and step.count (number) required"
  end
  local inv = c.entity.get_main_inventory()
  -- held(item): what she holds of it less what OTHER tasks have reserved -- theirs is
  -- not this task's (review: an upkeep task's reserved coal made a build's "ensure
  -- coal" pass, and its fuel step then never got ready until the 6000-tick give-up);
  -- used by every check below (the raw gather's deficit, the smelt pull, the craft's
  -- ingredients -- a second review: the first fix covered only this first check)
  local function held(item)
    -- raw (the step's option -- the upkeep's getting material): the item counts as all
    -- she holds of it (review: reservations made while she mined moved the target, and
    -- she mined far more than asked)
    if need.raw and item == need.item then return inv.get_item_count(item) end
    -- this task's own part of storage.reserved: its reservation less what its steps
    -- used up already (ledger.consume took that out of storage.reserved)
    local own = ((t.reserved or {})[item] or 0) - ((t.consumed or {})[item] or 0)
    local others = (storage.reserved[item] or 0) - math.max(0, own)
    return inv.get_item_count(item) - math.max(0, others)
  end
  if held(need.item) >= need.count then
    -- (a build shortage it reported is over -- review: it stayed listed KEEP_TICKS; its
    -- own wait first, so that it does not count as one still waiting)
    if t.ctx.raw_wait_deadline then t.ctx.raw_wait_deadline[need.item] = nil end
    Stores.clear(cid, need.item)
    return "satisfied"
  end
  if #stack > ENSURE_ITEM_MAX_DEPTH then
    return nil, "ensure_item recursion depth exceeded for " .. need.item ..
      " (likely a recipe-chain or naming problem, not a normal case)"
  end
  if need.item == "wood" and not need.no_pull then
    -- (Zdendys 2026-11-09: wood first from the stores -- the supply chests --, only then
    -- chopping)
    local fetched, got = fetch.start(c, t, need.item, need.count - held(need.item))
    if fetched == "fetch" then return "fetch" end
    if fetched == "taken" and got > 0 then
      if held(need.item) >= need.count then return "satisfied" end
      return "push"
    end
  end
  if need.item == "wood" then
    -- Wood has NO gather()-compatible resource-tile path (trees are type="tree",
    -- not type="resource" -- mirrors _chop_wood's own docstring in spatial_demo.py,
    -- factorio-ai repo, for the full "gather('wood',...) always returns 0" root
    -- cause this mirrors). Tracks its OWN small exclude set (t.ctx.wood_tried) so
    -- a tree that fails to reach isn't picked again -- same "no exclude" bug class
    -- already fixed once for _chop_wood itself (2026-07-17), applied here from the
    -- start rather than needing a second live-caught fix.
    t.ctx.wood_tried = t.ctx.wood_tried or {}
    t.ctx.wood_chop_count = t.ctx.wood_chop_count or 0
    if t.ctx.wood_chop_count >= WOOD_CHOP_MAX_TREES then
      return nil, "could not chop enough wood after " .. WOOD_CHOP_MAX_TREES .. " trees"
    end
    -- Expanding-radius search (2026-07-17, Zdendys's own follow-up after a live
    -- incident: coal_pair_upgrade's stage1 spent ~63,000 ticks chopping just 4
    -- trees -- a single flat radius=200 scan always considers the FULL 200-tile
    -- box, so on a map where the nearest patch of forest happens to sit right at
    -- the edge of that box (coal-rich areas are often tree-sparse), the
    -- "nearest" candidate found can still require a very long walk every single
    -- time this resolves. Trying progressively LARGER radii first -- starting
    -- close to the companion, only widening if genuinely nothing nearby -- means
    -- the common case (a tree within a normal few dozen tiles) resolves via a
    -- cheap, close search instead of always scanning (and potentially picking
    -- a candidate from) the full 200-tile radius. Does not change WHICH tree
    -- gets picked once a given radius has candidates (still nearest-first
    -- within that radius); it only avoids needlessly extending the SEARCH
    -- (and therefore the walk) beyond what the nearby area can already supply.
    local WOOD_SEARCH_RADII = {20, 50, 100, 200}
    local best, best_d = nil, math.huge
    for _, radius in ipairs(WOOD_SEARCH_RADII) do
      local trees = c.entity.surface.find_entities_filtered{
        type = "tree", position = c.entity.position, radius = radius}
      for _, tr in ipairs(trees) do
        local key = math.floor(tr.position.x) .. "," .. math.floor(tr.position.y)
        if tr.valid and not t.ctx.wood_tried[key] then
          local d = u.distance(c.entity.position, tr.position)
          if d < best_d then best, best_d = tr, d end
        end
      end
      if best then break end
    end
    if not best then return nil, "no reachable tree found for wood" end
    t.ctx.wood_target = {x = best.position.x, y = best.position.y}
    return "chop"
  end
  local recipe = resolve_recipe(need.item)
  if not recipe then
    -- Raw/minable resource (ore/coal/stone) -- delegate to the existing gather
    -- queue. from_task_pool=true bypasses start_gather's own active_step busy-
    -- guard (see that function's own docstring, queues.lua): WE are the
    -- active_step holder calling it here, not an external caller trying to
    -- steal the companion mid-task.
    --
    -- Bounded attempts (2026-07-17, independent-review-caught HIGH finding):
    -- a single start_gather call already retries internally within its own
    -- lifetime (tick_gather_queues' own "find" state re-blacklists and retries
    -- nearby patches before reporting "done"), but nothing previously bounded
    -- the OUTER loop of re-issuing a FRESH start_gather call if one full cycle
    -- still left a shortfall -- a genuinely scarce/partially-unreachable patch
    -- (a real, previously-observed scenario for coal specifically) would retry
    -- forever with no failure signal. Counts per-item so a task needing several
    -- DIFFERENT raw resources tracks each independently.
    local deficit = need.count - held(need.item)
    -- Zdendys 2026-11-09 (factorio-ai docs/no_hand_mining.md): from the stores first --
    -- the nearest place holding it she may take from, a drill's chest too
    -- (task_pool_fetch: within her reach at once, farther by a walk; the old 5-tile pull
    -- watched her hand-mine stone beside a full 800-stone chest farther off); with none
    -- and a drill of it to be had (commands/supply_stores.lua) she mines nothing: the
    -- shortage is reported for the controller and she waits RAW_WAIT_TICKS for its
    -- drills, then the step fails. Only while no drill of it can be had she mines it by
    -- hand (that shortage is reported too). no_pull (the step's option -- the upkeep's
    -- getting material, which chose mining after its own store search) skips both.
    if not need.no_pull then
      -- (no room for it: no store search -- review: a full inventory was reported as a
      -- supply shortage and a coal pair built for it)
      if inv.get_insertable_count(need.item) <= 0 then
        return nil, "no room in her inventory for " .. need.item
      end
      t.ctx.raw_wait_deadline = t.ctx.raw_wait_deadline or {}
      local fetched, got = fetch.start(c, t, need.item, deficit)
      -- (only a take starts the wait anew -- here, or a fetch walk's, task_pool_fetch.poll:
      -- review, a walk to an unreachable chest that reset it kept the wait for ever)
      if fetched == "fetch" then return "fetch" end
      if fetched == "taken" and got > 0 then
        t.ctx.raw_wait_deadline[need.item] = nil
        if held(need.item) >= need.count then return "satisfied" end
        return "push"      -- (the rest from the next place: judged again next tick)
      end
      if Stores.can_be_had(cid, c, need.item) then
        Stores.report(cid, need.item, deficit)
        local deadline = t.ctx.raw_wait_deadline[need.item]
        if not deadline then
          deadline = game.tick + RAW_WAIT_TICKS
          t.ctx.raw_wait_deadline[need.item] = deadline
          log("[ai-companion] [SUPPLY_SHORT] ensure_item: short of " .. deficit .. " "
              .. need.item .. ", no store holds it and a drill of it stands -- no hand "
              .. "mining: waiting for its drills (more drills with chests are needed)")
        end
        if game.tick < deadline then return "wait" end
        return nil, DRILL_WAIT_REASON .. need.item .. " within " .. RAW_WAIT_TICKS
          .. " ticks while a drill of it stands (no hand mining -- more drills with "
          .. "chests are needed)"
      end
      -- (no_mine: the controller mines itself while no drill of it can be had -- its
      -- own patch choice, e.g. away from its drills' ore; the step only fetches)
      if need.no_mine then
        -- (the controller's hand mining is a shortage too -- review: it was unseen)
        Stores.report(cid, need.item, deficit, true)
        return nil, NO_MINE_REASON .. need.item .. " (no store holds it, no drill of it "
          .. "with a chest)"
      end
      Stores.report(cid, need.item, deficit, true)
    end
    t.ctx.gather_attempts = t.ctx.gather_attempts or {}
    t.ctx.gather_attempts[need.item] = (t.ctx.gather_attempts[need.item] or 0) + 1
    if t.ctx.gather_attempts[need.item] > ENSURE_ITEM_GATHER_MAX_ATTEMPTS then
      return nil, "could not gather enough " .. need.item .. " after " ..
        ENSURE_ITEM_GATHER_MAX_ATTEMPTS .. " attempts (likely scarce/unreachable)"
    end
    local r = queues.start_gather(cid, need.item, deficit, nil, true)
    if r.error then return nil, r.error end
    return "gather"
  end
  if not recipe.hand_craftable then
    -- The companion itself NEVER attempts to smelt (2026-07-16 adversarial-review
    -- finding, still correct) -- a smelting recipe (iron-plate/copper-plate/...)
    -- has ingredients but the character can never craft it directly no matter how
    -- many ingredients it holds; attempting start_craft would just fail with
    -- "Missing ingredients" via get_craftable_count, a misleadingly generic error
    -- for a call that could NEVER have succeeded.
    --
    -- WAIT first, though (2026-07-27, see SMELT_WAIT_TICKS's own docstring above):
    -- an already-built, already-fueled furnace keeps smelting independently of
    -- this task, so a short bounded wait gives it a real chance to top up the
    -- stock before giving up outright. Tracks its own per-item deadline (t.ctx.
    -- smelt_wait_deadline), set ONCE the first time this need is seen, so retries
    -- share the SAME deadline instead of each resetting a fresh window.
    --
    -- FETCH from places first, at every pass of the wait (factorio-ai
    -- docs/mod_upkeep_supply.md D, task_pool_fetch.lua): the nearest machine
    -- output or chest holding it that no inserter picks from -- within her reach at
    -- once, farther by a walk (a furnace stuck at "full_output" with a stack of the
    -- product makes nothing more by itself -- 2026-07-27, live: a need failed so
    -- with 100 plates two tiles away; the earlier 5-tile pull took from any output,
    -- a plate row's too). The wait below only while no place holds it.
    -- (no_pull: the step takes nothing from places -- the upkeep's getting material)
    local fetched, got = nil, 0
    if not need.no_pull then
      fetched, got = fetch.start(c, t, need.item, need.count - held(need.item))
    end
    if fetched == "fetch" then return "fetch" end
    if fetched == "taken" and got > 0 then
      if held(need.item) >= need.count then return "satisfied" end
      return "push"      -- (the rest from the next place: judged again next tick)
    end
    t.ctx.smelt_wait_deadline = t.ctx.smelt_wait_deadline or {}
    local deadline = t.ctx.smelt_wait_deadline[need.item]
    if not deadline then
      deadline = game.tick + SMELT_WAIT_TICKS
      t.ctx.smelt_wait_deadline[need.item] = deadline
    end
    if game.tick < deadline then
      return "wait"
    end
    return nil, need.item .. " recipe is not hand-craftable and no furnace produced " ..
      "enough within " .. SMELT_WAIT_TICKS .. " ticks (needs a real machine, e.g. smelting)"
  end
  -- (crafts for the shortfall only, not the whole count -- live: holding 4 of 5 gears
  -- she crafted 5 more, her plates fetched for them)
  local craft_count = math.ceil((need.count - held(need.item)) / recipe.yield)
  for _, ing in ipairs(recipe.ingredients) do
    local needed_amount = craft_count * ing.amount
    if held(ing.name) < needed_amount then
      stack[#stack + 1] = {item = ing.name, count = needed_amount}
      return "push"
    end
  end
  local r = queues.start_craft(cid, need.item, craft_count)
  if r.error then return nil, r.error end
  return "craft"
end

return M
