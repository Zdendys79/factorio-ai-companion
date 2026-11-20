-- The reservation ledger of the task pool, PER COMPANION (the helpers are interchangeable and
-- each has its own inventory -- docs second_helper_serine S1): what open tasks of a helper hold
-- of an item is taken out of THAT helper's free count and of no other's. Before, one global
-- number per item (storage.reserved[item]) -- a second helper's reservations would have been
-- taken from the first's stock.
--
-- storage.reserved_by[cid][item] = count. A save from before (storage.reserved: global
-- numbers) is migrated on first use: each active task's unused part (reserved - consumed)
-- goes to its own companion.
local M = {}

local function book()
  if not storage.reserved_by then
    local by = {}
    for _, t in pairs(storage.tasks or {}) do
      if t.cid and t.reserved then
        by[t.cid] = by[t.cid] or {}
        for item, n in pairs(t.reserved) do
          local left = n - ((t.consumed or {})[item] or 0)
          if left > 0 then by[t.cid][item] = (by[t.cid][item] or 0) + left end
        end
      end
    end
    storage.reserved_by = by
    storage.reserved = nil
  end
  return storage.reserved_by
end

-- What helper `cid`'s open tasks hold of `item`.
function M.get(cid, item)
  local b = book()[cid]
  return (b and b[item]) or 0
end

-- Hold (n > 0) or give back (n < 0) `n` of `item` for helper `cid`; never below 0.
function M.add(cid, item, n)
  local by = book()
  by[cid] = by[cid] or {}
  by[cid][item] = math.max(0, (by[cid][item] or 0) + n)
end

-- The companion id owning a character entity (an inventory's entity_owner), or nil.
function M.cid_of(entity)
  for cid, c in pairs(storage.companions or {}) do
    if c.entity == entity then return cid end
  end
  return nil
end

-- What the helper owning character `entity` has reserved of `item`.
function M.get_of(entity, item)
  local cid = M.cid_of(entity)
  return cid and M.get(cid, item) or 0
end

return M
