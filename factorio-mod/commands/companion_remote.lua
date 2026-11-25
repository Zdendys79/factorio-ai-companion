-- The companions for a read-only console command (factorio-ai): where a companion stands, by id.
-- "The first character without a player" is any companion -- the scout (commands/scout.lua)
-- too, far from the base.
-- remote.call("fac_companions", "position", cid) -> {x, y} or nil.
remote.add_interface("fac_companions", {
  position = function(cid)
    -- (the record itself: init.get_companion books a death, a read must change nothing)
    local c = storage.companions and storage.companions[cid]
    if c and c.entity and c.entity.valid then
      return {x = c.entity.position.x, y = c.entity.position.y}
    end
    return nil
  end,
})
