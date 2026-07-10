-- worldscan.lua: geolyzer column reduction, shared by the queen world DB and the
-- drone scout firmware so both agree on flags, the ore heuristic, and the uplink
-- record format. Pure Lua, no deps -> safe to bundle into a drone image and to
-- require on the queen. Install to /usr/lib/hive/sdk/worldscan.lua.

local worldscan = {}

-- Column flag bits (stored column v2 + uplink share these).
worldscan.F = {
  SCANNED = 1, FLUID_SURF = 2, FLUID_LAVA = 4, NO_LAND = 8,
  ORE = 16, HAS_PATCH = 32, HAZARD = 64,
}
local F = worldscan.F
local floor = math.floor

-- Reduce a geolyzer hardness column (bottom-up: hardness[k] is the block at
-- y = yBase + (k-1)) into stored column fields. Surface is the highest non-air
-- block (air reads exactly 0; a noise-negated solid still has magnitude, so we
-- test |hardness|). A fluid surface (~100) marks NO_LAND; an ore candidate is
-- the first hardness in (2.5, 4.5) below the surface, with confidence falling
-- off with distance (geolyzer noise grows with range).
-- Returns surfaceY, flags, oreY, oreConf.
function worldscan.reduceColumn(hardness, yBase, dist)
  local n = #hardness
  local i = n
  while i >= 1 and math.abs(hardness[i]) <= 0.1 do i = i - 1 end
  if i < 1 then return 0, 0, 0, 0 end
  local surfaceY = yBase + (i - 1)
  local flags = 0
  if hardness[i] > 50 then flags = flags | F.FLUID_SURF | F.NO_LAND end
  local oreY, oreConf = 0, 0
  local conf = math.max(0, math.min(255, floor((1 - (dist or 0) / 32) * 255)))
  for k = i, 1, -1 do
    local h = hardness[k]
    if h > 2.5 and h < 4.5 then
      oreY = yBase + (k - 1)
      oreConf = conf
      flags = flags | F.ORE
      break
    end
  end
  return surfaceY, flags, oreY, oreConf
end

-- Scout uplink record: <i2 i2 B B B B> = x, z, surfaceY, flags, oreY, oreConf.
function worldscan.packUplink(x, z, surfaceY, flags, oreY, oreConf)
  return string.pack("<i2i2BBBB", x, z, surfaceY & 0xff, flags & 0xff, oreY & 0xff, oreConf & 0xff)
end

return worldscan
