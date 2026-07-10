-- courier.lua: logistics drone role.
-- Ferries items from a source inventory to a destination inventory, hovering one
-- block above each (drones suck/drop below), looping trips until the requested
-- count is moved or the source runs dry. Source at /usr/lib/hive/roles/courier.lua.

return {
  name = "courier",
  version = 1,
  caps = { "courier" },

  onInit = function(api) api.status("courier", "idle") end,

  -- task = { type = "ferry", from = {x,y,z}, to = {x,y,z}, count }
  onTask = function(api, task)
    if task.type ~= "ferry" then return "failed", "unsupported" end
    local from, to, count = task.from, task.to, task.count or 64
    local moved, dry = 0, 0
    while moved < count do
      if api.aborted() then return "failed", "aborted" end
      api.status("pickup", ("%d/%d"):format(moved, count))
      if not api.goTo(from.x, from.y + 1, from.z, { cruise = from.y + 16 }) then
        return "failed", "to_source"
      end
      local got = api.suckBelow()
      if not got or got == 0 then
        dry = dry + 1
        if dry >= 2 then break end -- source empty
        api.sleep(2)
      else
        dry = 0
        api.status("deliver", ("%d/%d"):format(moved, count))
        if not api.goTo(to.x, to.y + 1, to.z, { cruise = to.y + 16 }) then
          return "failed", "to_dest"
        end
        api.dropBelow()
        moved = moved + got
        api.report(moved / count, ("moved %d"):format(moved))
      end
    end
    return "done"
  end,

  onIdle = function(api) api.sleep(1) end,
  onLowEnergy = function(api)
    local h = api.home() or api.queen()
    if h then api.goTo(h.x, (h.y or 64) + 1, h.z, { cruise = (h.y or 64) + 20 }) end
  end,
}
