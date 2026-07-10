-- Desktop tests for hive/core/store.lua + worlddb.lua (Lua 5.3+):
--   lua tools/test_worlddb.lua
-- Covers column packing, geolyzer reduction, ingest/query, tile summaries,
-- sparse region-file persistence + reload, LRU eviction, sharding, and a mock
-- scout -> geolyzer -> reduce -> ingest integration on a simulated world.

package.path = "hive/core/?.lua;hive/sdk/?.lua;tools/?.lua;" .. package.path
local store = require("store")
local worlddb = require("worlddb")
local hivesim = require("hivesim")

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("OK   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
  end
end

local F = worlddb.F

-- column pack roundtrip ---------------------------------------------------

do
  local blob = worlddb.packColumn(72, F.SCANNED | F.ORE, 40, 200, 5)
  local c = worlddb.unpackColumn(blob, 1)
  check("column pack roundtrip", c.surfaceY == 72 and c.oreY == 40 and c.oreConf == 200
    and c.scanAge == 5 and (c.flags & F.ORE) ~= 0, c.surfaceY)
  check("column record is 6 bytes", #blob == 6, #blob)
end

-- reduceColumn ------------------------------------------------------------

do
  -- yBase 58; surface stone at y=64; ore at y=61; air above 64.
  local h = {}
  for k = 1, 64 do
    local y = 58 + (k - 1)
    if y > 64 then h[k] = 0.0
    elseif y == 61 then h[k] = 3.0
    else h[k] = 1.5 end
  end
  local surfaceY, flags, oreY, oreConf = worlddb.reduceColumn(h, 58, 0)
  check("reduce finds surface", surfaceY == 64, surfaceY)
  check("reduce finds ore", (flags & F.ORE) ~= 0 and oreY == 61 and oreConf == 255,
    string.format("oreY=%d conf=%d", oreY, oreConf))
  check("reduce not fluid", (flags & F.FLUID_SURF) == 0)

  -- fluid surface
  local hf = {}
  for k = 1, 64 do
    local y = 58 + (k - 1)
    hf[k] = (y > 64) and 0.0 or (y == 64 and 100.0 or 1.5)
  end
  local sy, ff = worlddb.reduceColumn(hf, 58, 0)
  check("reduce fluid surface", sy == 64 and (ff & F.FLUID_SURF) ~= 0 and (ff & F.NO_LAND) ~= 0)
end

-- ingest / query / summary ------------------------------------------------

local function newDB(fs, roots)
  local st = store.new{ fs = fs }
  return worlddb.new{ store = st, roots = roots or { "/w" }, cacheCap = 24,
    indexPath = "/w/index.db", now = function() return 4800 end }, st
end

do
  local fs = hivesim.memfs()
  local db = newDB(fs)
  -- Build a batch: a 4x4 patch of columns at surface 70, one ore column.
  local recs = {}
  for x = 0, 3 do
    for z = 0, 3 do
      local flags = 0
      local oreY, oreConf = 0, 0
      if x == 2 and z == 1 then flags = F.ORE; oreY = 55; oreConf = 240 end
      recs[#recs + 1] = worlddb.packUplink(x, z, 70, flags, oreY, oreConf)
    end
  end
  local touched = db.ingest(table.concat(recs))
  check("ingest reports one tile touched", #touched == 1, #touched)

  local c = db.column(2, 1)
  check("query scanned column", c and c.surfaceY == 70 and (c.flags & F.ORE) ~= 0, c and c.surfaceY)
  check("unscanned column is nil", db.column(50, 50) == nil)

  local s = db.tileSummary(0, 0)
  check("tile summary maxSurface", s and s.maxSurface == 70, s and s.maxSurface)
  check("tile summary oreCount", s and s.oreCount == 1, s and s.oreCount)
  check("tile summary scannedPct", s and s.scannedPct == math.floor(16 * 100 / 256),
    s and s.scannedPct)

  local ms = db.maxSurface(0, 0, 3, 3, 100)
  check("maxSurface scanned", ms == 70, ms)
  local msu = db.maxSurface(500, 500, 510, 510, 100)
  check("maxSurface unscanned -> ceiling", msu == 100, msu)

  local ore = db.oreCandidates(0, 0, 3, 3, 100)
  check("oreCandidates finds planted ore", #ore == 1 and ore[1].x == 2 and ore[1].z == 1
    and ore[1].y == 55, #ore)

  db.markMined(2, 55, 1)
  local c2 = db.column(2, 1)
  check("markMined clears ore", c2 and (c2.flags & F.ORE) == 0 and (c2.flags & F.HAS_PATCH) ~= 0)
end

-- region persistence + reload (sparse, index survives) --------------------

do
  local fs = hivesim.memfs()
  local db = newDB(fs)
  local recs = {}
  for x = 100, 103 do recs[#recs + 1] = worlddb.packUplink(x, 200, 88, 0, 0, 0) end
  db.ingest(table.concat(recs))
  db.flush()

  -- exactly one region file written, plus the index
  local regionFiles, hasIndex = 0, false
  for path in pairs(fs._files) do
    if path:match("%.hxr$") then regionFiles = regionFiles + 1 end
    if path == "/w/index.db" then hasIndex = true end
  end
  check("one region file written", regionFiles == 1, regionFiles)
  check("index persisted", hasIndex)

  -- fresh instance on the same store reads back column + summary
  local db2 = newDB(fs)
  local c = db2.column(101, 200)
  check("reload reads column from region", c and c.surfaceY == 88, c and c.surfaceY)
  local s = db2.tileSummary(math.floor(100 / 16), math.floor(200 / 16))
  check("reload restores tile summary", s and s.maxSurface == 88, s and s.maxSurface)
end

-- LRU eviction persists data ----------------------------------------------

do
  local fs = hivesim.memfs()
  local st = store.new{ fs = fs }
  local db = worlddb.new{ store = st, roots = { "/w" }, cacheCap = 2,
    indexPath = "/w/index.db", now = function() return 0 end }
  -- Touch 6 distinct tiles (>cacheCap) so eviction+flush happens mid-run.
  for t = 0, 5 do
    db.ingest(worlddb.packUplink(t * 16, 0, 60 + t, 0, 0, 0))
  end
  db.flush()
  local db2 = worlddb.new{ store = st, roots = { "/w" }, cacheCap = 2, indexPath = "/w/index.db" }
  local okAll = true
  for t = 0, 5 do
    local c = db2.column(t * 16, 0)
    if not (c and c.surfaceY == 60 + t) then okAll = false end
  end
  check("LRU eviction preserves all tiles", okAll)
end

-- sharding across multiple roots ------------------------------------------

do
  local fs = hivesim.memfs()
  local st = store.new{ fs = fs }
  local db = worlddb.new{ store = st, roots = { "/a", "/b", "/c" }, cacheCap = 24 }
  -- Columns far apart land in different regions -> different shards.
  db.ingest(worlddb.packUplink(0, 0, 60, 0, 0, 0))
  db.ingest(worlddb.packUplink(32 * 16, 0, 61, 0, 0, 0))     -- region (32,0)
  db.ingest(worlddb.packUplink(0, 32 * 16, 62, 0, 0, 0))     -- region (0,32)
  db.flush()
  local roots = {}
  for path in pairs(fs._files) do
    local root = path:match("^(/%a)/")
    if root then roots[root] = true end
  end
  local n = 0
  for _ in pairs(roots) do n = n + 1 end
  check("regions distributed across shards", n >= 2, n)
end

-- integration: mock scout scans a plains world and fills the DB -------------

do
  local fs = hivesim.memfs()
  local db = newDB(fs)
  local world = hivesim.world{ surface = hivesim.terrain.plains(64),
    ore = { { x = 5, y = 60, z = 5 } } }
  -- Low, deliberate probe altitude: ore classification confidence scales with
  -- distance, so a scout that wants reliable ore reads drops close (surf+3).
  local scoutY = 64 + 3
  local px, pz = 0, 0
  local geo = hivesim.geolyzer(world, function() return px, scoutY, pz end, { noise = 2 })

  local recs = {}
  for x = 0, 7 do
    for z = 0, 7 do
      px, pz = x, z
      local col = geo.scan(0, 0, -32, 1, 1, 64) -- 64 values, yBase = scoutY-32
      local dist = scoutY - 64
      local surfaceY, flags, oreY, oreConf = worlddb.reduceColumn(col, scoutY - 32, dist)
      recs[#recs + 1] = worlddb.packUplink(x, z, surfaceY, flags, oreY, oreConf)
    end
  end
  db.ingest(table.concat(recs))
  check("scout mapped plains surface", db.column(3, 3).surfaceY == 64, db.column(3, 3).surfaceY)
  check("scout mapped full tile", db.tileSummary(0, 0).scannedPct == math.floor(64 * 100 / 256),
    db.tileSummary(0, 0).scannedPct)
  -- ore column detected directly beneath (low distance -> high confidence)
  px, pz = 5, 5
  local col = geo.scan(0, 0, -32, 1, 1, 64)
  local _, flags, oreY = worlddb.reduceColumn(col, scoutY - 32, scoutY - 64)
  check("scout detected ore beneath", (flags & F.ORE) ~= 0 and oreY == 60,
    string.format("flags=%d oreY=%d", flags, oreY))
end

print(string.rep("-", 40))
if failures == 0 then
  print("all worlddb tests passed")
  os.exit(0)
else
  print(failures .. " test(s) failed")
  os.exit(1)
end
