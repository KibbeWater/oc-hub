-- scout.lua: mapping drone role.
-- Executes scan_tile tasks by flying a 16x16 boustrophedon over the tile at scan
-- altitude, reading the column beneath each block with the geolyzer, and uploading
-- a reduced record per row. Bundled into the scout image (concatenated behind the
-- SDK); source at /usr/lib/hive/roles/scout.lua.

local TILE = 16
local SCAN_ALT = 26 -- blocks above the assumed surface (geolyzer reaches +-32)

return {
  name = "scout",
  version = 1,
  caps = { "scan" },

  onInit = function(api)
    api.status("scout", "idle")
  end,

  -- task = { type = "scan_tile", cx, cz }
  onTask = function(api, task)
    if task.type ~= "scan_tile" then return "failed", "unsupported" end
    local baseX, baseZ = task.cx * TILE, task.cz * TILE
    -- assume surface near the queen's altitude for the initial approach; the
    -- descend guard handles the actual terrain.
    local q = api.queen()
    local scanY = (q and q.y or 64) + SCAN_ALT

    api.status("scan", ("%d,%d"):format(task.cx, task.cz))
    local ok, err = api.goTo(baseX, scanY, baseZ, { cruise = scanY })
    if not ok then return "failed", err end

    for row = 0, TILE - 1 do
      if api.aborted() then return "failed", "aborted" end
      local z = baseZ + row
      local batch = {}
      -- serpentine: even rows left->right, odd rows right->left
      local xs, xe, step = 0, TILE - 1, 1
      if row % 2 == 1 then xs, xe, step = TILE - 1, 0, -1 end
      for lx = xs, xe, step do
        local x = baseX + lx
        local moved = api.moveTo(x, scanY, z)
        if not moved and api.aborted() then return "failed", "aborted" end
        batch[#batch + 1] = api.scanColumn()
      end
      api.uploadScan(table.concat(batch))
      api.report(row / TILE, ("row %d/%d"):format(row + 1, TILE))
    end
    return "done"
  end,

  onIdle = function(api)
    api.status("scout", "idle")
    api.sleep(1)
  end,

  onLowEnergy = function(api)
    local home = api.home() or api.queen()
    -- descend to home+1: one block above the charger, inside its 3x3x3 charge field
    if home then api.goTo(home.x, home.y + 1, home.z, { cruise = (home.y or 64) + 20 }) end
  end,
}
