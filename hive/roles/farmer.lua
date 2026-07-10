-- farmer.lua: crop-tending robot role.
-- Serpentines a field one block above the crops, harvesting mature plants and
-- replanting. Runs as a recurring task (the queen re-queues it on completion).
-- Harvest digs are authorized by a FARM-mode grant over the field.
-- Source at /usr/lib/hive/roles/farmer.lua.

return {
  name = "farmer",
  version = 1,
  caps = { "farm" },

  onInit = function(api) api.status("farmer", "idle") end,

  -- task = { type = "farm_pass", x, y, z (field corner + crop level), w, l }
  onTask = function(api, task)
    if task.type ~= "farm_pass" then return "failed", "unsupported" end
    local baseX, cropY, baseZ = task.x, task.y, task.z
    local workY = cropY + 1
    if not api.stepTo(baseX, workY, baseZ, false) then return "failed", "approach" end
    local harvested = 0
    for row = 0, task.l - 1 do
      if api.aborted() then return "failed", "aborted" end
      local z = baseZ + row
      local xs, xe, step = 0, task.w - 1, 1
      if row % 2 == 1 then xs, xe, step = task.w - 1, 0, -1 end
      for cx = xs, xe, step do
        local x = baseX + cx
        api.stepTo(x, workY, z, false)
        local below = api.detect(0, -1, 0)
        if below == "wheat_ready" or below == "crop_ready" then
          api.dig(0, -1, 0)          -- harvest (FARM-authorized)
          api.place(0, -1, 0)        -- replant
          harvested = harvested + 1
        end
      end
      api.report(row / task.l, ("row %d/%d"):format(row + 1, task.l))
    end
    return "done"
  end,

  onIdle = function(api) api.sleep(1) end,
  onLowEnergy = function(api) api.dock() end,
}
