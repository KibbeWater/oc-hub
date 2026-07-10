-- worlddb.lua: the hive's 2.5D world model.
-- Terrain is stored as a COLUMN model (surface height + flags + best ore candidate
-- per x,z), never a voxel grid. Columns are grouped into 16x16 tiles, and tiles
-- into sparse 32x32 region files on the NAS. An always-in-RAM per-tile summary
-- (one u64 int/tile) answers cruise-altitude, map-zoom and frontier queries without
-- touching the NAS. Install to /usr/lib/hive/core/worlddb.lua.
--
-- Column v2 record (6 bytes): surfaceY u8 | flags u8 | oreY u8 | oreConf u8 | scanAge u8 | rsv u8
-- Tile: 16-byte header + 256 columns (row-major z*16+x) = 1552 bytes.
-- Region file "r<rx>_<rz>.hxr": "hR" ver rx rz + 128-byte presence bitmap +
--   present tiles (1552 B each) in slot order. Sparse: absent tiles cost nothing.

local worldscan = require("worldscan")

local worlddb = {}

local TILE_W = 16
local COL = 6
local TILE_HDR = 16
local TILE_BYTES = TILE_HDR + TILE_W * TILE_W * COL -- 1552
local REGION_W = 32
local REGION_TILES = REGION_W * REGION_W          -- 1024
local BITMAP_BYTES = REGION_TILES // 8            -- 128
local REGION_HDR = "<c2Bi2i2"                     -- magic, ver, rx, rz  (7 bytes)

-- Column flag bits + reduction/uplink codec are shared with the drone firmware.
local F = worldscan.F
worlddb.F = F
worlddb.reduceColumn = worldscan.reduceColumn
worlddb.packUplink = worldscan.packUplink

-- Summary flag bits (in the RAM tile index u64, byte 6).
local S = { HAS_WATER = 1, HAS_LAVA = 2, NO_FLY = 4, HAS_PATCH = 8 }
worlddb.S = S

local floor = math.floor
local function fdiv(a, b) return floor(a / b) end

-- --- packing helpers -------------------------------------------------------

function worlddb.packColumn(surfaceY, flags, oreY, oreConf, scanAge)
  return string.pack("<BBBBBB", surfaceY & 0xff, flags & 0xff, oreY & 0xff,
    oreConf & 0xff, scanAge & 0xff, 0)
end

function worlddb.unpackColumn(blob, off)
  local surfaceY, flags, oreY, oreConf, scanAge = string.unpack("<BBBBB", blob, off)
  return { surfaceY = surfaceY, flags = flags, oreY = oreY, oreConf = oreConf, scanAge = scanAge }
end

-- --- instance --------------------------------------------------------------

-- opts: store (required), roots (list of world dirs to shard across),
--       cacheCap (tiles), now (-> seconds), mkdir (path -> void, optional).
function worlddb.new(opts)
  local self = {}
  local st = assert(opts.store, "worlddb needs a store")
  local roots = opts.roots or { "/var/hive/world" }
  local cacheCap = opts.cacheCap or 24
  local now = opts.now or function() return 0 end
  local mkdir = opts.mkdir

  local indexPath = opts.indexPath -- optional: persist the RAM tile index here
  local index = {}            -- tileKey -> u64 summary
  local cache = {}            -- tileKey -> {blob, dirty, used, cx, cz}
  local lru = 0

  if indexPath then
    local saved = st.load(indexPath, nil)
    if type(saved) == "table" then index = saved end
  end

  local function tileKey(cx, cz) return cx .. ":" .. cz end
  local function regionOf(cx, cz) return fdiv(cx, REGION_W), fdiv(cz, REGION_W) end
  local function slotOf(cx, cz, rx, rz)
    return (cz - rz * REGION_W) * REGION_W + (cx - rx * REGION_W)
  end
  local function regionPath(rx, rz)
    local shard = ((rx % #roots) + rz % #roots) % #roots
    return roots[shard + 1] .. "/r" .. rx .. "_" .. rz .. ".hxr"
  end

  -- region blob <-> { slot -> tileBlob }
  local function decodeRegion(blob)
    local tiles = {}
    if not blob or #blob < 7 + BITMAP_BYTES then return tiles end
    local magic, _, _, _, pos = string.unpack(REGION_HDR, blob)
    if magic ~= "hR" then return tiles end
    local bitmap = blob:sub(pos, pos + BITMAP_BYTES - 1)
    pos = pos + BITMAP_BYTES
    for slot = 0, REGION_TILES - 1 do
      local byte = bitmap:byte(fdiv(slot, 8) + 1) or 0
      if (byte & (1 << (slot % 8))) ~= 0 then
        tiles[slot] = blob:sub(pos, pos + TILE_BYTES - 1)
        pos = pos + TILE_BYTES
      end
    end
    return tiles
  end

  local function encodeRegion(rx, rz, tiles)
    local bitmap = {}
    for i = 1, BITMAP_BYTES do bitmap[i] = 0 end
    local body = {}
    for slot = 0, REGION_TILES - 1 do
      if tiles[slot] then
        local bi = fdiv(slot, 8) + 1
        bitmap[bi] = bitmap[bi] | (1 << (slot % 8))
        body[#body + 1] = tiles[slot]
      end
    end
    local bm = {}
    for i = 1, BITMAP_BYTES do bm[i] = string.char(bitmap[i]) end
    return string.pack(REGION_HDR, "hR", 1, rx, rz) .. table.concat(bm) .. table.concat(body)
  end

  local function readRegionTile(cx, cz)
    local rx, rz = regionOf(cx, cz)
    local blob = st.loadRaw(regionPath(rx, rz))
    if not blob then return nil end
    local tiles = decodeRegion(blob)
    return tiles[slotOf(cx, cz, rx, rz)]
  end

  -- Build a blank tile blob (16-byte header + 256 unscanned columns = 1552 bytes).
  -- Header: magic "hT" u16 | ver u8 | flags u8 | cx i2 | cz i2 | epoch u32 | patchCnt u16 | rsv u16.
  local function blankTile(cx, cz)
    local hdr = string.pack("<I2BBi2i2I4I2I2", 0x5468, 1, 0, cx, cz, 0, 0, 0)
    return hdr .. ("\0"):rep(TILE_W * TILE_W * COL)
  end

  local function summarizeTile(blob)
    local maxS, minS, scanned, ore = 0, 255, 0, 0
    local flags = 0
    for i = 0, TILE_W * TILE_W - 1 do
      local off = TILE_HDR + i * COL + 1
      local surfaceY, fl = string.unpack("<BB", blob, off)
      if (fl & F.SCANNED) ~= 0 then
        scanned = scanned + 1
        if surfaceY > maxS then maxS = surfaceY end
        if surfaceY < minS then minS = surfaceY end
        if (fl & F.ORE) ~= 0 then ore = ore + 1 end
        if (fl & F.FLUID_SURF) ~= 0 then flags = flags | S.HAS_WATER end
        if (fl & F.FLUID_LAVA) ~= 0 then flags = flags | S.HAS_LAVA end
      end
    end
    if minS > maxS then minS = 0 end
    local pct = floor(scanned * 100 / (TILE_W * TILE_W))
    if pct >= 30 and (flags & S.HAS_WATER) ~= 0 then flags = flags | S.NO_FLY end
    return { maxSurface = maxS, minSurface = minS, scannedPct = pct, oreCount = ore, flags = flags }
  end

  local function packSummary(s)
    return (s.maxSurface & 0xff)
      | ((s.minSurface & 0xff) << 8)
      | ((s.scannedPct & 0xff) << 16)
      | ((math.min(255, s.oreCount) & 0xff) << 24)
      | ((s.flags & 0xff) << 48)
  end

  local function unpackSummary(u)
    if not u then return nil end
    return {
      maxSurface = u & 0xff,
      minSurface = (u >> 8) & 0xff,
      scannedPct = (u >> 16) & 0xff,
      oreCount = (u >> 24) & 0xff,
      flags = (u >> 48) & 0xff,
    }
  end

  local function loadTile(cx, cz, create)
    local key = tileKey(cx, cz)
    local e = cache[key]
    if e then
      lru = lru + 1
      e.used = lru
      return e
    end
    local blob = readRegionTile(cx, cz)
    if not blob and not create then return nil end
    if not blob then blob = blankTile(cx, cz) end
    lru = lru + 1
    e = { blob = blob, dirty = false, used = lru, cx = cx, cz = cz }
    cache[key] = e
    self.evictIfNeeded()
    return e
  end

  -- Write all dirty regions (grouped so each region file is rewritten once).
  function self.flush()
    local dirtyRegions = {}
    for _, e in pairs(cache) do
      if e.dirty then
        local rx, rz = regionOf(e.cx, e.cz)
        local rk = rx .. ":" .. rz
        dirtyRegions[rk] = dirtyRegions[rk] or { rx = rx, rz = rz }
      end
    end
    for _, r in pairs(dirtyRegions) do
      local path = regionPath(r.rx, r.rz)
      local tiles = decodeRegion(st.loadRaw(path))
      for _, e in pairs(cache) do
        local erx, erz = regionOf(e.cx, e.cz)
        if erx == r.rx and erz == r.rz then
          tiles[slotOf(e.cx, e.cz, r.rx, r.rz)] = e.blob
          e.dirty = false
        end
      end
      if mkdir then mkdir(roots[(((r.rx % #roots) + r.rz % #roots) % #roots) + 1]) end
      st.saveRaw(path, encodeRegion(r.rx, r.rz, tiles))
    end
    if indexPath then st.saveAtomic(indexPath, index) end
  end

  function self.evictIfNeeded()
    local n = 0
    for _ in pairs(cache) do n = n + 1 end
    while n > cacheCap do
      local oldKey, oldUsed
      for k, e in pairs(cache) do
        if not oldUsed or e.used < oldUsed then oldKey, oldUsed = k, e.used end
      end
      if not oldKey then break end
      local e = cache[oldKey]
      if e.dirty then self.flush() end
      cache[oldKey] = nil
      n = n - 1
    end
  end

  -- Apply one column into its tile (patches bytes in place, marks dirty).
  local function setColumn(x, z, surfaceY, flags, oreY, oreConf, scanAge)
    local cx, cz = fdiv(x, TILE_W), fdiv(z, TILE_W)
    local e = loadTile(cx, cz, true)
    local lx, lz = x - cx * TILE_W, z - cz * TILE_W
    local off = TILE_HDR + (lz * TILE_W + lx) * COL
    local rec = worlddb.packColumn(surfaceY, flags | F.SCANNED, oreY, oreConf, scanAge)
    e.blob = e.blob:sub(1, off) .. rec .. e.blob:sub(off + COL + 1)
    e.dirty = true
    return cx, cz
  end

  -- Ingest a scout uplink batch (concatenated 8-byte uplink records).
  -- Returns the set of touched tile keys (for route-cache invalidation).
  function self.ingest(batch)
    local pos, touched = 1, {}
    local age = floor(now() / 480) % 256 -- 8-minute units
    while pos + 8 <= #batch + 1 do
      local x, z, surfaceY, flags, oreY, oreConf = string.unpack("<i2i2BBBB", batch, pos)
      pos = pos + 8
      local cx, cz = setColumn(x, z, surfaceY, flags, oreY, oreConf, age)
      touched[tileKey(cx, cz)] = { cx = cx, cz = cz }
    end
    for _, t in pairs(touched) do
      local e = cache[tileKey(t.cx, t.cz)]
      index[tileKey(t.cx, t.cz)] = packSummary(summarizeTile(e.blob))
    end
    local list = {}
    for _, t in pairs(touched) do list[#list + 1] = t end
    return list
  end

  -- Query one column. Returns a column table (with .scanned flag) or nil if unscanned.
  function self.column(x, z)
    local cx, cz = fdiv(x, TILE_W), fdiv(z, TILE_W)
    local e = loadTile(cx, cz, false)
    if not e then return nil end
    local lx, lz = x - cx * TILE_W, z - cz * TILE_W
    local off = TILE_HDR + (lz * TILE_W + lx) * COL + 1
    local c = worlddb.unpackColumn(e.blob, off)
    c.scanned = (c.flags & F.SCANNED) ~= 0
    if not c.scanned then return nil end
    return c
  end

  function self.tileSummary(cx, cz) return unpackSummary(index[tileKey(cx, cz)]) end

  -- Highest known surface within a block-space bbox (for cruise altitude).
  -- Unscanned tiles contribute the caller's defaultCeiling.
  function self.maxSurface(x1, z1, x2, z2, defaultCeiling)
    defaultCeiling = defaultCeiling or 100
    local cx1, cz1 = fdiv(math.min(x1, x2), TILE_W), fdiv(math.min(z1, z2), TILE_W)
    local cx2, cz2 = fdiv(math.max(x1, x2), TILE_W), fdiv(math.max(z1, z2), TILE_W)
    local best = 0
    for cx = cx1, cx2 do
      for cz = cz1, cz2 do
        local s = self.tileSummary(cx, cz)
        if not s or s.scannedPct == 0 then
          best = math.max(best, defaultCeiling)
        else
          best = math.max(best, s.maxSurface)
        end
      end
    end
    return best
  end

  -- Iterate ore-candidate columns in a bbox with confidence >= minConf.
  function self.oreCandidates(x1, z1, x2, z2, minConf)
    minConf = minConf or 0
    local xs, xe = math.min(x1, x2), math.max(x1, x2)
    local zs, ze = math.min(z1, z2), math.max(z1, z2)
    local results = {}
    for z = zs, ze do
      for x = xs, xe do
        local c = self.column(x, z)
        if c and (c.flags & F.ORE) ~= 0 and c.oreConf >= minConf then
          results[#results + 1] = { x = x, y = c.oreY, z = z, conf = c.oreConf }
        end
      end
    end
    return results
  end

  -- Unscanned/low-coverage tiles within tile-radius r of a center tile.
  function self.unscannedTiles(cx, cz, r)
    local out = {}
    for dx = -r, r do
      for dz = -r, r do
        local s = self.tileSummary(cx + dx, cz + dz)
        if not s or s.scannedPct < 90 then
          out[#out + 1] = { cx = cx + dx, cz = cz + dz, pct = s and s.scannedPct or 0 }
        end
      end
    end
    return out
  end

  -- Mark a mined-out column (clears ORE, sets HAS_PATCH so nav knows there's a working).
  function self.markMined(x, y, z)
    local c = self.column(x, z)
    if not c then return end
    setColumn(x, z, c.surfaceY, (c.flags & ~F.ORE) | F.HAS_PATCH, 0, 0,
      floor(now() / 480) % 256)
    local cx, cz = fdiv(x, TILE_W), fdiv(z, TILE_W)
    local e = cache[tileKey(cx, cz)]
    index[tileKey(cx, cz)] = packSummary(summarizeTile(e.blob))
  end

  function self.setNoLand(x, z)
    local c = self.column(x, z)
    local surfaceY = c and c.surfaceY or 0
    local flags = ((c and c.flags) or 0) | F.NO_LAND | F.FLUID_SURF
    setColumn(x, z, surfaceY, flags, 0, 0, floor(now() / 480) % 256)
  end

  -- Expose the raw index (for the dashboard map + frontier scans).
  function self.index() return index end
  function self.tileKey(cx, cz) return tileKey(cx, cz) end
  self.TILE_W = TILE_W

  return self
end

return worlddb
