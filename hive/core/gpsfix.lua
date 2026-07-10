-- gpsfix.lua: universal-frame triangulation for the queen.
-- OpenComputers navigation upgrades report positions relative to the center of
-- the map they were crafted from, so two devices with different map copies live
-- in different coordinate frames. This solves the pure translation offset between
-- a device's raw frame and the swarm's universal frame from the known-position
-- waypoints the device can see. Because all swarm motion is delta-based, a single
-- translation is enough to unify everyone. Pure Lua. Install to /usr/lib/hive/core/gpsfix.lua.

local gpsfix = {}

-- Solve the offset to ADD to a device's raw fix to get universal coordinates.
--   rawPos: the device's navigation.getPosition() {x,y,z}.
--   sightings: { {key=<addrHash>, rel={x,y,z}}, ... } from findWaypoints
--              (rel = waypoint position relative to the device; frame-invariant).
--   known: map addrHash -> universal {x,y,z} (the queen's surveyed waypoints).
-- Returns offset {x,y,z}, n (references used), spread (max per-axis disagreement,
-- for sanity), or nil if no waypoint matched.
function gpsfix.solve(rawPos, sightings, known)
  local sx, sy, sz, n, ests = 0, 0, 0, 0, {}
  for _, s in ipairs(sightings) do
    local u = known[s.key]
    if u then
      local ox = u.x - (rawPos.x + s.rel.x)
      local oy = u.y - (rawPos.y + s.rel.y)
      local oz = u.z - (rawPos.z + s.rel.z)
      ests[#ests + 1] = { ox, oy, oz }
      sx, sy, sz, n = sx + ox, sy + oy, sz + oz, n + 1
    end
  end
  if n == 0 then return nil end
  local mx, my, mz = sx / n, sy / n, sz / n
  local spread = 0
  for _, o in ipairs(ests) do
    spread = math.max(spread, math.abs(o[1] - mx), math.abs(o[2] - my), math.abs(o[3] - mz))
  end
  return { x = math.floor(mx + 0.5), y = math.floor(my + 0.5), z = math.floor(mz + 0.5) }, n, spread
end

function gpsfix.toUniversal(rawPos, off)
  return { x = rawPos.x + off.x, y = rawPos.y + off.y, z = rawPos.z + off.z }
end

return gpsfix
