-- hivesim.lua: desktop simulator for the hive.
-- Provides an in-memory filesystem (for store), seeded terrain generators, a
-- voxel-ish world model (surface height + fluids + ore + dug/placed tracking),
-- and mock OpenComputers components whose numbers match the verified OC source
-- (geolyzer noise, drone flight physics, robot move validity/cost). The queen's
-- core modules and the role SDK run UNCHANGED against these mocks.
--
-- Phase 2 provides: memfs, terrain, world, geolyzer. Drone/robot physics mocks
-- and the net bus are added in Phase 3.

local hivesim = {}

local floor = math.floor
local abs = math.abs

-- Deterministic value noise in [0,1); avoids math.random so runs are reproducible.
local function hash01(x, z, salt)
  local v = math.sin((x * 12.9898 + z * 78.233 + (salt or 0) * 37.719)) * 43758.5453
  return v - floor(v)
end
hivesim.hash01 = hash01

-- --------------------------------------------------------------------------
-- In-memory filesystem backend for store.new{ fs = hivesim.memfs() }.
-- --------------------------------------------------------------------------

function hivesim.memfs()
  local files = {}
  return {
    _files = files,
    read = function(path) return files[path] end,
    write = function(path, data) files[path] = data end,
    append = function(path, data) files[path] = (files[path] or "") .. data end,
    remove = function(path) files[path] = nil end,
    rename = function(from, to) files[to] = files[from]; files[from] = nil; return true end,
    exists = function(path) return files[path] ~= nil end,
  }
end

-- --------------------------------------------------------------------------
-- Terrain generators: (x,z) -> { y = surfaceY, fluid = bool, lava = bool }.
-- --------------------------------------------------------------------------

hivesim.terrain = {}

function hivesim.terrain.plains(base)
  base = base or 64
  return function() return { y = base, fluid = false } end
end

function hivesim.terrain.ridge(amp, period, base)
  amp, period, base = amp or 24, period or 40, base or 64
  return function(x, z)
    local y = base + floor(amp * (0.5 + 0.5 * math.sin(x / period) * math.cos(z / period)))
    return { y = y, fluid = false }
  end
end

function hivesim.terrain.cliffs(step, base)
  step, base = step or 20, base or 60
  return function(x, z)
    local level = floor(hash01(floor(x / 24), floor(z / 24), 3) * 4)
    return { y = base + level * (step // 2), fluid = false }
  end
end

function hivesim.terrain.archipelago(waterFrac, base, sea)
  waterFrac, base, sea = waterFrac or 0.55, base or 68, sea or 62
  return function(x, z)
    local h = 0.6 * hash01(floor(x / 20), floor(z / 20), 1)
      + 0.4 * hash01(floor(x / 7), floor(z / 7), 2)
    if h < waterFrac then
      return { y = sea, fluid = true }
    end
    return { y = base + floor((h - waterFrac) * 30), fluid = false }
  end
end

function hivesim.terrain.canyon(depth, width, base)
  depth, width, base = depth or 40, width or 8, base or 70
  return function(x, z)
    if abs(z) < width then
      return { y = base - depth, fluid = false }
    end
    return { y = base, fluid = false }
  end
end

-- karst: flat surface with air caves below (dug-like voids); surface unaffected.
function hivesim.terrain.karst(caveDensity, base)
  caveDensity, base = caveDensity or 0.15, base or 72
  return function() return { y = base, fluid = false, karst = caveDensity } end
end

-- --------------------------------------------------------------------------
-- World model. Blocks are derived from the surface function on demand; dug and
-- placed blocks override it. Hardness follows OC conventions (air 0, stone ~1.5,
-- ore ~3.0, fluid 100).
-- --------------------------------------------------------------------------

local HARD = { air = 0.0, dirt = 0.5, stone = 1.5, ore = 3.0, fluid = 100.0 }
hivesim.HARD = HARD

-- opts: surface (terrain fn), ore ({x,y,z}... list or fn(x,y,z)->bool), seed.
function hivesim.world(opts)
  opts = opts or {}
  local surf = opts.surface or hivesim.terrain.plains()
  local w = { dug = {}, placed = {}, chests = {} }

  local function key(x, y, z) return x .. "," .. y .. "," .. z end

  local oreFn
  if type(opts.ore) == "function" then
    oreFn = opts.ore
  elseif type(opts.ore) == "table" then
    local set = {}
    for _, o in ipairs(opts.ore) do set[key(o.x, o.y, o.z)] = true end
    oreFn = function(x, y, z) return set[key(x, y, z)] == true end
  else
    oreFn = function() return false end
  end

  function w.surfaceInfo(x, z) return surf(x, z) end
  function w.surfaceY(x, z) return surf(x, z).y end

  -- Block name at (x,y,z): "air"/"stone"/"dirt"/"ore"/"water"/"lava".
  function w.blockName(x, y, z)
    local k = key(x, y, z)
    if w.dug[k] then return "air" end
    if w.placed[k] then return w.placed[k] end
    local s = surf(x, z)
    if y > s.y then
      if s.fluid and y <= s.y + 0 then end -- fluids sit at surface level
      return "air"
    end
    if y == s.y and s.fluid then return s.lava and "lava" or "water" end
    if s.karst and y < s.y - 3 and hash01(x, y, z) < s.karst then return "air" end
    if oreFn(x, y, z) then return "ore" end
    if y >= s.y - 3 then return "dirt" end
    return "stone"
  end

  function w.hardness(x, y, z)
    local n = w.blockName(x, y, z)
    if n == "air" then return HARD.air end
    if n == "water" or n == "lava" then return HARD.fluid end
    if n == "ore" then return HARD.ore end
    if n == "dirt" then return HARD.dirt end
    return HARD.stone
  end

  function w.isSolid(x, y, z)
    local n = w.blockName(x, y, z)
    return n ~= "air" and n ~= "water" and n ~= "lava"
  end

  function w.isFluid(x, y, z)
    local n = w.blockName(x, y, z)
    return n == "water" or n == "lava"
  end

  function w.dig(x, y, z) w.dug[key(x, y, z)] = true end
  function w.place(x, y, z, name) w.placed[key(x, y, z)] = name or "stone" end

  return w
end

-- --------------------------------------------------------------------------
-- Geolyzer mock. scan(rx, rz [, ry, sw, sd, sh]) returns hardness values with
-- distance-scaled noise (air stays exact 0). Column form (sw=sd=1) yields 64
-- values bottom-up, matching OC's index = x + z*w + y*w*d ordering.
-- --------------------------------------------------------------------------

-- getPos() -> x, y, z (device block position). opts.noise (default 2), opts.rng.
function hivesim.geolyzer(world, getPos, opts)
  opts = opts or {}
  local noiseAmp = opts.noise or 2
  local calls = 0
  local function jitter(x, y, z)
    calls = calls + 1
    return (hash01(x + calls, y, z) * 2 - 1) -- U(-1,1)
  end
  return {
    scan = function(rx, rz, ry, sw, sd, sh)
      ry = ry or -32; sw = sw or 1; sd = sd or 1; sh = sh or 64
      local px, py, pz = getPos()
      local out = {}
      for yi = 0, sh - 1 do
        for zi = 0, sd - 1 do
          for xi = 0, sw - 1 do
            local x, y, z = px + rx + xi, py + ry + yi, pz + rz + zi
            local hard = world.hardness(x, y, z)
            if hard > 0 then
              local dist = math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2)
              hard = hard + jitter(x, y, z) * dist * noiseAmp / 33
            end
            out[#out + 1] = hard
          end
        end
      end
      return out
    end,
    analyze = function(side)
      -- side 0 = down; return exact adjacent block info.
      local px, py, pz = getPos()
      local dy = (side == 0) and -1 or (side == 1 and 1 or 0)
      local name = world.blockName(px, py + dy, pz)
      return { name = name, hardness = world.hardness(px, py + dy, pz) }
    end,
  }
end

-- --------------------------------------------------------------------------
-- Drone mock. move() adds to an async flight target (rounded to 0.25 like OC);
-- physics steps each 0.05s game tick with per-axis block collision (so a drone
-- pressed against a wall stalls instead of clipping), fluid contact kills it,
-- and running costs 0.4 energy/tick against a 5000 buffer.
-- --------------------------------------------------------------------------

local function r25(v) return floor(v * 4 + 0.5) / 4 end

function hivesim.drone(world, x, y, z, opts)
  opts = opts or {}
  local d = { x = x, y = y, z = z, tx = x, ty = y, tz = z,
    energy = opts.energy or 1.0, buffer = 5000, dead = false, alive = true }

  function d.move(dx, dy, dz)
    d.tx = r25(d.tx + dx); d.ty = r25(d.ty + dy); d.tz = r25(d.tz + dz)
  end
  function d.offset()
    return math.sqrt((d.tx - d.x) ^ 2 + (d.ty - d.y) ^ 2 + (d.tz - d.z) ^ 2)
  end
  function d.pos()
    if d.dead then return nil end
    return floor(d.x + 0.5), floor(d.y + 0.5), floor(d.z + 0.5)
  end
  function d.energyFrac() return d.energy end

  local function cellSolid(fx, fy, fz)
    return world.isSolid(floor(fx + 0.5), floor(fy + 0.5), floor(fz + 0.5))
  end

  -- one 0.05s game tick of flight
  function d.stepTick()
    if d.dead then return end
    d.energy = math.max(0, d.energy - 0.4 / d.buffer)
    if d.energy <= 0 then d.dead = true; d.alive = false; return end
    local function axis(comp)
      local tgt = d["t" .. comp]
      local step = math.max(-0.4, math.min(0.4, tgt - d[comp]))
      if math.abs(step) < 1e-4 then return end
      local nx, ny, nz = d.x, d.y, d.z
      if comp == "x" then nx = nx + step elseif comp == "y" then ny = ny + step else nz = nz + step end
      if not cellSolid(nx, ny, nz) then d[comp] = d[comp] + step end
    end
    axis("y"); axis("x"); axis("z") -- climb first so recovery can clear obstacles
    if world.isFluid(floor(d.x + 0.5), floor(d.y + 0.5), floor(d.z + 0.5)) then
      d.dead = true; d.alive = false
    end
  end

  return d
end

-- --------------------------------------------------------------------------
-- Robot mock. One-block blocking steps; a move is invalid into a solid or fluid
-- block; digging clears a block; costs 15 energy/move against a 20000 buffer.
-- (Hover is assumed, so floating steps are allowed -- terrain-follow is a robot
-- SDK concern.)
-- --------------------------------------------------------------------------

function hivesim.robot(world, x, y, z, opts)
  opts = opts or {}
  local r = { x = x, y = y, z = z, energy = opts.energy or 1.0, buffer = 20000, digAllowed = opts.dig }

  function r.pos() return r.x, r.y, r.z end
  function r.energyFrac() return r.energy end
  function r.detect(dx, dy, dz) return world.blockName(r.x + dx, r.y + dy, r.z + dz) end
  function r.moveStep(dx, dy, dz)
    local nx, ny, nz = r.x + dx, r.y + dy, r.z + dz
    local name = world.blockName(nx, ny, nz)
    if name == "water" or name == "lava" then return false, "liquid" end
    if world.isSolid(nx, ny, nz) then return false, "solid" end
    r.x, r.y, r.z = nx, ny, nz
    r.energy = math.max(0, r.energy - 15 / r.buffer)
    return true
  end
  function r.dig(dx, dy, dz)
    world.dig(r.x + dx, r.y + dy, r.z + dz)
    return true
  end
  return r
end

-- --------------------------------------------------------------------------
-- Scenario clock + runner for driving navcore against the mocks.
-- --------------------------------------------------------------------------

function hivesim.clock()
  local c = { t = 0 }
  function c.now() return c.t end
  function c.advance(dt) c.t = c.t + dt end
  return c
end

-- Drive a navcore drone to arrival/blocked/death. Returns "arrived"/"blocked"/
-- "dead"/"timeout". Runs 5 physics ticks (0.25s) per navcore poll.
function hivesim.flyDrone(nav, drone, clock, maxSeconds)
  maxSeconds = maxSeconds or 600
  while clock.now() < maxSeconds do
    local st = nav.tick()
    if st == "arrived" then return "arrived" end
    if st == "blocked" then return "blocked" end
    for _ = 1, 5 do drone.stepTick() end
    clock.advance(0.25)
    if drone.dead then return "dead" end
  end
  return "timeout"
end

-- Drive a navcore robot to arrival/blocked. 0.4s per step attempt.
function hivesim.walkRobot(nav, robot, clock, maxSeconds)
  maxSeconds = maxSeconds or 600
  while clock.now() < maxSeconds do
    local st = nav.tick()
    if st == "arrived" then return "arrived" end
    if st == "blocked" then return "blocked" end
    clock.advance(0.4)
  end
  return "timeout"
end

return hivesim
