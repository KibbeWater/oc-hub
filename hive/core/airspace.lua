-- airspace.lua: drone altitude planning.
-- Turns a from->to line and the world tile index into a "staircase" cruise
-- profile: a small list of altitude steps that clears the terrain beneath each
-- stretch of the route without one wastefully-high global cruise. Pure Lua with
-- an injected surface lookup. Install to /usr/lib/hive/core/airspace.lua.

local airspace = {}

local floor = math.floor
local function fdiv(a, b) return floor(a / b) end

airspace.defaults = {
  TILE = 16,
  GROUND_CLR = 8,    -- work/hover clearance above surface
  CRUISE_CLR = 16,   -- transit clearance above the max surface of a stretch
  LOCAL_MAX = 48,    -- hops shorter than this skip the cruise ceremony
  SKY = 224,         -- cruise altitude over unscanned/unknown terrain
  CEILING = 240,     -- hard vertical cap (leaves recovery headroom below y255)
  DEFAULT_CEIL = 100,-- assumed surface for unscanned tiles when merging
  MERGE = 6,         -- merge adjacent stretches whose cruise differs by less than this
  RUN = 4,           -- tiles per profile stretch
}

-- Tiles a straight line from (x1,z1) to (x2,z2) passes through (block sampling).
function airspace.supercover(x1, z1, x2, z2, tileW)
  tileW = tileW or airspace.defaults.TILE
  local seen, out = {}, {}
  local dx, dz = x2 - x1, z2 - z1
  local steps = math.max(1, floor(math.max(math.abs(dx), math.abs(dz))))
  for i = 0, steps do
    local t = i / steps
    local cx, cz = fdiv(x1 + dx * t, tileW), fdiv(z1 + dz * t, tileW)
    local k = cx .. ":" .. cz
    if not seen[k] then
      seen[k] = true
      out[#out + 1] = { cx = cx, cz = cz }
    end
  end
  return out
end

-- Build the cruise staircase. maxSurfaceFn(cx,cz) -> surfaceY or nil (unscanned).
-- Returns steps { {fromFrac, y}, ... } (fromFrac in [0,1] along the route) and
-- the peak cruise y. A fully-unscanned run flies at SKY.
function airspace.cruiseProfile(from, to, maxSurfaceFn, cfg)
  cfg = cfg or airspace.defaults
  local tiles = airspace.supercover(from.x, from.z, to.x, to.z, cfg.TILE)
  local n = #tiles
  local peak = 0
  -- per-run cruise y
  local runs = {}
  local i = 1
  while i <= n do
    local runEnd = math.min(n, i + cfg.RUN - 1)
    local maxS, unscanned = 0, false
    for j = i, runEnd do
      local s = maxSurfaceFn(tiles[j].cx, tiles[j].cz)
      if not s then unscanned = true else maxS = math.max(maxS, s) end
    end
    local y
    if unscanned then
      y = cfg.SKY
    else
      y = math.min(cfg.CEILING, maxS + cfg.CRUISE_CLR)
    end
    runs[#runs + 1] = { fromFrac = (i - 1) / n, y = y }
    peak = math.max(peak, y)
    i = runEnd + 1
  end
  -- merge adjacent runs whose y differs by less than MERGE (take the higher)
  local merged = {}
  for _, r in ipairs(runs) do
    local last = merged[#merged]
    if last and math.abs(last.y - r.y) < cfg.MERGE then
      last.y = math.max(last.y, r.y)
    else
      merged[#merged + 1] = { fromFrac = r.fromFrac, y = r.y }
    end
  end
  return merged, peak
end

-- Single conservative cruise ceiling for a route (max of the staircase).
function airspace.cruiseCeiling(from, to, maxSurfaceFn, cfg)
  local _, peak = airspace.cruiseProfile(from, to, maxSurfaceFn, cfg)
  return peak
end

-- Is this a short hop that can stay in the LOCAL band (skip full cruise)?
function airspace.isLocal(from, to, cfg)
  cfg = cfg or airspace.defaults
  local dx, dz = to.x - from.x, to.z - from.z
  return math.sqrt(dx * dx + dz * dz) < cfg.LOCAL_MAX
end

-- Vertical hold-stack slot altitude for a drone waiting on a charger.
function airspace.holdSlotY(chargerY, slot, cfg)
  cfg = cfg or airspace.defaults
  return chargerY + 4 + 2 * (slot or 0)
end

-- Cosmetic transit lane offset by heading (collisions are impossible; this only
-- keeps telemetry/map tracks legible). Returns 0..3.
function airspace.lane(from, to)
  local dx, dz = to.x - from.x, to.z - from.z
  if math.abs(dx) >= math.abs(dz) then
    return dx >= 0 and 0 or 1
  else
    return dz >= 0 and 2 or 3
  end
end

return airspace
