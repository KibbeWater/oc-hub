-- miner.lua: excavation robot role.
-- Clears a mine_slab by serpentining the footprint at the slab's top level and
-- digging each column down to the floor. Every dig is checked against the queen's
-- DESTRUCTION grant (mode + area incl. the Y-range), so it can only break blocks
-- it is authorized to. Bundled behavior; source at /usr/lib/hive/roles/miner.lua.

return {
  name = "miner",
  version = 1,
  caps = { "mine" },

  onInit = function(api) api.status("miner", "idle") end,

  onTask = function(api, task)
    if task.type ~= "mine_slab" then return "failed", "unsupported" end
    local x1, x2 = math.min(task.x1, task.x2), math.max(task.x1, task.x2)
    local z1, z2 = math.min(task.z1, task.z2), math.max(task.z1, task.z2)
    local yTop, yBot = math.max(task.y1, task.y2), math.min(task.y1, task.y2)
    local depth = yTop - yBot + 1
    local workY = yTop -- travel through the slab's top layer (inside the grant)

    api.status("mine", ("%d,%d"):format(x1, z1))
    if not api.stepTo(x1, workY, z1, true) then return "failed", "approach" end

    local total = (x2 - x1 + 1) * (z2 - z1 + 1)
    local done = 0
    for iz = z1, z2 do
      if api.aborted() then return "failed", "aborted" end
      local xs, xe, step = x1, x2, 1
      if (iz - z1) % 2 == 1 then xs, xe, step = x2, x1, -1 end
      for ix = xs, xe, step do
        if api.aborted() then return "failed", "aborted" end
        -- move into the next top cell (digs it if solid, subject to the grant)
        if not api.stepTo(ix, workY, iz, true) then return "failed", "blocked" end
        -- clear the rest of the column by descending, then climb back to the top
        for _ = 1, depth - 1 do
          if not api.dig(0, -1, 0) then break end
          if not api.step(0, -1, 0) then break end
        end
        for _ = 1, depth - 1 do api.step(0, 1, 0) end
        done = done + 1
        if done % 8 == 0 then api.report(done / total, ("%d/%d"):format(done, total)) end
      end
    end
    return "done"
  end,

  onIdle = function(api) api.sleep(1) end,
  onLowEnergy = function(api) api.dock() end,
}
