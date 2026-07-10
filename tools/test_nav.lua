-- Desktop tests for the hive navigation engine (Lua 5.3+):
--   lua tools/test_nav.lua
-- Covers leg codec, BEE3 staircase, surface A* fixtures (cliff/water/dig/unscanned),
-- heuristic admissibility, chunked-search determinism, touched-node cap, corridor
-- A*, navgraph (fusion/merge/Dijkstra/promotion/demotion/lease/pack), obstacle
-- overlay, route cache + invalidation, and frontier scoring.

package.path = "hive/core/?.lua;hive/sdk/?.lua;tools/?.lua;" .. package.path
local routes = require("routes")
local navgraph = require("navgraph")
local airspace = require("airspace")
local navcore = require("navcore")
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

local OP = routes.OP

-- runs a chunked search to completion; returns status, path
local function runSearch(search, nExp)
  local status, path
  repeat
    status, path = routes.astarStep(search, nExp or 10000)
  until status ~= "running"
  return status, path
end

-- cost of a monotone path under the surface cost model (for admissibility checks)
local function pathCost(colFn, path)
  local c = 0
  for i = 2, #path do
    local a, b = colFn(path[i - 1].x, path[i - 1].z), colFn(path[i].x, path[i].z)
    if b.lava then return math.huge end
    local dh = math.abs(b.surfaceY - a.surfaceY)
    c = c + 1
    if not b.scanned then c = c + 8 end
    if b.fluid then c = c + 50 end
    if b.surfaceY > a.surfaceY then c = c + 1.2 * dh else c = c + 0.6 * dh end
  end
  return c
end

-- leg codec --------------------------------------------------------------

do
  local legs = {
    { op = OP.CLIMB_TO, x = -500, y = 200, z = 900, tol = 3, speed = 8, param = 0 },
    { op = OP.GOTO, x = 100, y = 96, z = -100, tol = 2, speed = 15, param = 0 },
    { op = OP.DESCEND_TO, x = 100, y = 72, z = -100, tol = 3, speed = 4, param = 8 },
  }
  local blob = routes.packLegs(4242, routes.MODE.BEE3, legs, 0, 50)
  local dec = routes.unpackLegs(blob)
  check("leg header roundtrip", dec.routeId == 4242 and dec.mode == routes.MODE.BEE3
    and #dec.legs == 3 and dec.cruiseHint == 50)
  check("leg fields roundtrip", dec.legs[1].x == -500 and dec.legs[1].y == 200
    and dec.legs[1].z == 900 and dec.legs[2].speed == 15 and dec.legs[3].param == 8,
    dec.legs[1].x)
end

-- BEE3 staircase ----------------------------------------------------------

do
  local flat = routes.new{ env = {
    maxSurface = function() return 64 end,
    surface = function() return 64 end,
    column = function() return { surfaceY = 64, scanned = true } end } }
  local legs = flat.planBee3({ x = 0, y = 72, z = 0 }, { x = 200, y = 72, z = 0 })
  check("bee3 flat -> 3 legs", #legs == 3, #legs)
  check("bee3 climb first", legs[1].op == OP.CLIMB_TO and legs[1].y == 64 + 16, legs[1].y)
  check("bee3 goto to goal", legs[2].op == OP.GOTO and legs[2].x == 200)
  check("bee3 descend last", legs[#legs].op == OP.DESCEND_TO and legs[#legs].y == 64 + 8)

  -- a tall ridge midway forces a higher cruise stretch
  local hill = routes.new{ env = {
    maxSurface = function(cx) return (cx >= 5 and cx <= 7) and 150 or 64 end,
    surface = function() return 64 end,
    column = function() return { surfaceY = 64, scanned = true } end } }
  local legs2 = hill.planBee3({ x = 0, y = 72, z = 0 }, { x = 240, y = 72, z = 0 })
  local peak = 0
  for _, l in ipairs(legs2) do peak = math.max(peak, l.y) end
  check("bee3 staircase clears ridge", peak >= 150 + 16, peak)
  check("bee3 staircase has extra legs", #legs2 > 3, #legs2)
end

-- surface A* fixtures -----------------------------------------------------

local function envGrid(h, w, scanned)
  return {
    column = function(x, z)
      return { surfaceY = h(x, z), fluid = w and w(x, z) or false,
        lava = false, scanned = scanned == nil or scanned(x, z) }
    end,
    surface = function(x, z) return h(x, z) end,
    maxSurface = function() return 64 end,
  }
end

do
  -- flat: straight-line-length path (Manhattan optimal)
  local flat = routes.new{ env = envGrid(function() return 64 end) }
  local st = flat.beginSurface({ x = 0, z = 0 }, { x = 5, z = 0 })
  local status, path = runSearch(st)
  check("surface flat solvable", status == "done", status)
  check("surface flat straight", #path == 6, #path) -- 0..5 inclusive

  -- cliff wall at x==2 (very tall) with digging disallowed -> must detour in z
  local cliffH = function(x, z)
    if x == 2 and z >= -1 and z <= 1 then return 150 end
    return 64
  end
  local cliff = routes.new{ env = envGrid(cliffH) }
  local s2, p2 = runSearch(cliff.beginSurface({ x = 0, z = 0 }, { x = 4, z = 0 }))
  check("surface cliff solvable", s2 == "done")
  local touchedWall = false
  for _, c in ipairs(p2) do if c.x == 2 and c.z == 0 then touchedWall = true end end
  check("surface routes around cliff", not touchedWall)

  -- water lake: path prefers dry detour over the +50 water penalty
  local lake = function(x, z) return (x >= 1 and x <= 3 and z == 0) end
  local wenv = routes.new{ env = envGrid(function() return 64 end, lake) }
  local s3, p3 = runSearch(wenv.beginSurface({ x = 0, z = 0 }, { x = 4, z = 0 }))
  local wet = 0
  for _, c in ipairs(p3) do if lake(c.x, c.z) then wet = wet + 1 end end
  check("surface avoids water", s3 == "done" and wet == 0, wet)

  -- unscanned penalty: prefer a longer scanned route over a short unscanned one
  local scannedFn = function(x, z) return not (x == 1 and z == 0) end
  local uenv = routes.new{ env = envGrid(function() return 64 end, nil, scannedFn) }
  local _, p4 = runSearch(uenv.beginSurface({ x = 0, z = 0 }, { x = 2, z = 0 }))
  local hitUnscanned = false
  for _, c in ipairs(p4) do if not scannedFn(c.x, c.z) then hitUnscanned = true end end
  check("surface avoids unscanned when detour is cheaper", not hitUnscanned)
end

-- heuristic admissibility (A* cost <= any valid path) ---------------------

do
  local function h(x, z) return 64 + ((x * 7 + z * 13) % 5) end -- deterministic bumpy terrain
  local colFn = function(x, z) return { surfaceY = h(x, z), scanned = true, fluid = false } end
  local env = routes.new{ env = { column = colFn, surface = h, maxSurface = function() return 70 end } }
  local from, to = { x = 0, z = 0 }, { x = 6, z = 4 }
  local _, best = runSearch(env.beginSurface(from, to))
  local optimal = pathCost(colFn, best)
  -- an L-shaped path is a valid alternative; A* must be no worse
  local L = {}
  for x = 0, 6 do L[#L + 1] = { x = x, z = 0 } end
  for z = 1, 4 do L[#L + 1] = { x = 6, z = z } end
  check("A* no worse than L-path", optimal <= pathCost(colFn, L) + 1e-6,
    string.format("A*=%.1f L=%.1f", optimal, pathCost(colFn, L)))
end

-- chunked determinism -----------------------------------------------------

do
  local h = function(x, z) return 64 + ((x + z) % 3) end
  local env = routes.new{ env = envGrid(h) }
  local _, pA = runSearch(env.beginSurface({ x = 0, z = 0 }, { x = 8, z = 6 }), 1)
  local _, pB = runSearch(env.beginSurface({ x = 0, z = 0 }, { x = 8, z = 6 }), 100000)
  local same = #pA == #pB
  if same then
    for i = 1, #pA do if pA[i].x ~= pB[i].x or pA[i].z ~= pB[i].z then same = false end end
  end
  check("chunked search deterministic (nExp 1 vs huge)", same, #pA .. " vs " .. #pB)
end

-- touched-node cap --------------------------------------------------------

do
  local env = routes.new{ env = envGrid(function() return 64 end), touchCap = 30 }
  local status = runSearch(env.beginSurface({ x = 0, z = 0 }, { x = 60, z = 60 }))
  check("touched-node cap aborts to fail", status == "fail", status)
end

-- corridor A* -------------------------------------------------------------

do
  -- scanned everywhere except a finite unscanned patch at cx==3, cz in [-1,1];
  -- the corridor should detour around it rather than pay the unscanned penalty.
  local env = routes.new{ env = {
    maxSurface = function(cx, cz) return (cx == 3 and cz >= -1 and cz <= 1) and nil or 64 end,
    surface = function() return 64 end, column = function() return { surfaceY = 64, scanned = true } end } }
  local s, p = runSearch(env.beginCorridor({ x = 0, z = 0 }, { x = 96, z = 0 }))
  check("corridor solvable", s == "done")
  local crossedUnscanned = false
  for _, c in ipairs(p) do if c.x == 3 and c.z >= -1 and c.z <= 1 then crossedUnscanned = true end end
  check("corridor avoids unscanned tiles", not crossedUnscanned)
end

-- navgraph ----------------------------------------------------------------

do
  local g = navgraph.new{ now = function() return 100 end }
  local a = g.addNode{ kind = navgraph.KIND.CHARGER, x = 0, y = 64, z = 0, label = "hx:c:base" }
  local b = g.addNode{ kind = navgraph.KIND.WAYPOINT, x = 100, y = 64, z = 0 }
  local c = g.addNode{ kind = navgraph.KIND.WAYPOINT, x = 100, y = 64, z = 100 }

  -- junction fusion: a near-duplicate JUNCTION returns the same id
  local j1 = g.addNode{ kind = navgraph.KIND.JUNCTION, x = 50, y = 30, z = 50 }
  local j2 = g.addNode{ kind = navgraph.KIND.JUNCTION, x = 50, y = 30, z = 51 }
  check("junction fusion within 1 block", j1 == j2, j1 .. " vs " .. j2)

  local e1 = g.link(a, b, navgraph.MODE.AIR, 1000)
  g.link(b, c, navgraph.MODE.AIR, 1000)
  local eDirect = g.link(a, c, navgraph.MODE.AIR, 2500) -- longer direct

  -- link merge: relinking merges mode + keeps cheaper cost
  g.link(a, b, navgraph.MODE.SURFACE, 900)
  check("link merges mode + cheaper cost", (g.edges()[e1].mode & navgraph.MODE.SURFACE) ~= 0
    and g.edges()[e1].cost == 900, g.edges()[e1].cost)

  local path, cost = g.route(a, c, navgraph.MODE.AIR | navgraph.MODE.SURFACE)
  check("dijkstra finds a-b-c cheaper than direct", path and #path == 3 and cost < 2500,
    cost)

  -- promotion: 3 clean traversals -> trusted -> cheaper effective cost
  for _ = 1, 3 do g.observe(e1, true) end
  check("edge promoted to trusted", (g.edges()[e1].flags & 1) ~= 0)

  -- demotion: 3 fails drops the edge
  g.observe(eDirect, false); g.observe(eDirect, false); g.observe(eDirect, false)
  check("edge dropped after 3 fails", g.edges()[eDirect] == nil)

  -- nearest
  local nid = g.nearest(2, 64, 2, navgraph.KIND.CHARGER, 50)
  check("nearest charger", nid == a)

  -- lease conflict
  check("lease grants", g.lease(e1, "d1", 30))
  check("lease conflict blocks other device", g.lease(e1, "d2", 30) == false)
  check("same device re-lease ok", g.lease(e1, "d1", 30))

  -- pack/unpack roundtrip
  local blob = g.pack()
  local g2 = navgraph.new{ now = function() return 100 end }
  g2.unpack(blob)
  local p2, c2 = g2.route(a, c, navgraph.MODE.AIR | navgraph.MODE.SURFACE)
  check("navgraph pack/unpack preserves routing", p2 and #p2 == 3, p2 and #p2)
  check("navgraph pack/unpack preserves labels", g2.getNode(a).label == "hx:c:base")
end

-- obstacle overlay --------------------------------------------------------

do
  local env = routes.new{ env = envGrid(function() return 64 end), now = function() return 0 end }
  -- straight path would go through (1,0),(2,0); block them heavily
  env.addObstacle(1, 0, 500, 900)
  env.addObstacle(2, 0, 500, 900)
  local _, p = runSearch(env.beginSurface({ x = 0, z = 0 }, { x = 3, z = 0 }))
  local hit = false
  for _, c in ipairs(p) do if (c.x == 1 or c.x == 2) and c.z == 0 then hit = true end end
  check("obstacle overlay diverts path", not hit)
end

-- route cache + invalidation (via request/tick) ---------------------------

do
  local env = routes.new{ env = envGrid(function() return 64 end), clock = os.clock }
  local results = {}
  env.request{ kind = "robot", from = { x = 0, z = 0 }, to = { x = 6, z = 0 },
    onDone = function(str, meta) results[#results + 1] = { str = str, meta = meta } end }
  -- drive the search to completion
  for _ = 1, 20 do env.tick(30); if #results > 0 then break end end
  check("robot request completes", results[1] and results[1].str ~= nil)
  check("first result not cached", results[1] and not results[1].meta.cached)

  -- identical request should hit the cache immediately
  env.request{ kind = "robot", from = { x = 0, z = 0 }, to = { x = 6, z = 0 },
    onDone = function(str, meta) results[#results + 1] = { str = str, meta = meta } end }
  check("second identical request cached", results[2] and results[2].meta.cached)

  -- ingest invalidates the cache
  env.onIngest()
  local cachedAfter = false
  env.request{ kind = "robot", from = { x = 0, z = 0 }, to = { x = 6, z = 0 },
    onDone = function(_, meta) cachedAfter = meta.cached end }
  for _ = 1, 20 do env.tick(30); if cachedAfter ~= false then break end end
  check("cache invalidated on ingest", cachedAfter ~= true)
end

-- drone request (instant BEE3) --------------------------------------------

do
  local env = routes.new{ env = {
    maxSurface = function() return 64 end, surface = function() return 64 end,
    column = function() return { surfaceY = 64, scanned = true } end } }
  local got
  env.request{ kind = "drone", from = { x = 0, y = 72, z = 0 }, to = { x = 100, y = 72, z = 0 },
    onDone = function(str, meta) got = { str = str, meta = meta } end }
  check("drone request resolves instantly", got and got.meta.mode == routes.MODE.BEE3)
  local dec = routes.unpackLegs(got.str)
  check("drone route decodes", dec.legs[1].op == OP.CLIMB_TO)
end

-- frontier ----------------------------------------------------------------

do
  local env = routes.new{ env = {} }
  -- everything scanned except a cluster around (5,5)
  local indexFn = function(cx, cz)
    if cx >= 4 and cx <= 6 and cz >= 4 and cz <= 6 then return { scannedPct = 0 } end
    return { scannedPct = 100 }
  end
  local f = env.frontierNext({ cx = 0, cz = 0 }, 12, indexFn)
  check("frontier finds unscanned cluster", f ~= nil and f.cx >= 3 and f.cz >= 3,
    f and (f.cx .. "," .. f.cz))
end

-- executor scenarios (navcore driven against physics mocks) -----------------

local function droneNav(drone, clock, events)
  return navcore.new{ kind = "drone", unpackLegs = routes.unpackLegs, io = {
    pos = drone.pos, move = drone.move, offset = drone.offset,
    energy = drone.energyFrac, now = clock.now,
    report = function(sc, p) events[#events + 1] = { sc = sc, p = p } end,
  } }
end

do
  -- flat cruise A->B arrives, survives, ends near the goal column
  local world = hivesim.world{ surface = hivesim.terrain.plains(64) }
  local clock = hivesim.clock()
  local drone = hivesim.drone(world, 0, 80, 0)
  local ev = {}
  local nav = droneNav(drone, clock, ev)
  nav.setRoute(1, {
    { op = OP.CLIMB_TO, x = 0, y = 80, z = 0 },
    { op = OP.GOTO, x = 100, y = 80, z = 0 },
    { op = OP.DESCEND_TO, x = 100, y = 72, z = 0 },
  })
  local r = hivesim.flyDrone(nav, drone, clock, 120)
  check("drone flat flight arrives", r == "arrived", r)
  check("drone survived", drone.alive)
  local px, _, pz = drone.pos()
  check("drone reached goal column", math.abs(px - 100) <= 1 and math.abs(pz) <= 1,
    px and (px .. "," .. pz))
end

do
  -- wall across the cruise altitude -> stall -> climb over -> arrive
  local world = hivesim.world{ surface = hivesim.terrain.plains(64) }
  for yy = 65, 85 do world.place(50, yy, 0, "stone") end
  local clock = hivesim.clock()
  local drone = hivesim.drone(world, 0, 80, 0)
  local ev = {}
  local nav = droneNav(drone, clock, ev)
  nav.setRoute(2, {
    { op = OP.CLIMB_TO, x = 0, y = 80, z = 0 },
    { op = OP.GOTO, x = 100, y = 80, z = 0 },
  })
  local r = hivesim.flyDrone(nav, drone, clock, 180)
  check("drone climbs over wall obstacle", r == "arrived", r)
  check("drone alive after obstacle", drone.alive)
end

do
  -- cruising over a water channel at altitude is safe (never touches fluid)
  local surf = function(x)
    if x >= 40 and x <= 60 then return { y = 62, fluid = true } end
    return { y = 68, fluid = false }
  end
  local world = hivesim.world{ surface = surf }
  local clock = hivesim.clock()
  local drone = hivesim.drone(world, 0, 84, 0)
  local nav = droneNav(drone, clock, {})
  nav.setRoute(3, {
    { op = OP.CLIMB_TO, x = 0, y = 84, z = 0 },
    { op = OP.GOTO, x = 100, y = 84, z = 0 },
    { op = OP.DESCEND_TO, x = 100, y = 76, z = 0 },
  })
  local r = hivesim.flyDrone(nav, drone, clock, 120)
  check("drone survives cruise over water", r == "arrived" and drone.alive, r)
end

do
  -- geofence: a leg beyond +-984 is refused before any motion
  local world = hivesim.world{ surface = hivesim.terrain.plains(64) }
  local clock = hivesim.clock()
  local drone = hivesim.drone(world, 0, 80, 0)
  local ev = {}
  local nav = droneNav(drone, clock, ev)
  local ok, err = nav.setRoute(4, { { op = OP.GOTO, x = 2000, y = 80, z = 0 } })
  check("geofence rejects out-of-range leg", ok == nil and err == "geofence")
  check("geofence emits EVT", ev[1] and ev[1].sc == navcore.EVT.GEOFENCE_REJ)
end

local function robotNav(robot, clock, events)
  return navcore.new{ kind = "robot", unpackLegs = routes.unpackLegs, io = {
    pos = robot.pos, moveStep = robot.moveStep, dig = robot.dig, detect = robot.detect,
    energy = robot.energyFrac, now = clock.now,
    report = function(sc, p) events[#events + 1] = { sc = sc, p = p } end,
  } }
end

do
  -- flat walk
  local world = hivesim.world{ surface = hivesim.terrain.plains(64) }
  local clock = hivesim.clock()
  local robot = hivesim.robot(world, 0, 65, 0)
  local nav = robotNav(robot, clock, {})
  nav.setRoute(5, { { op = OP.STEP_PATH, x = 10, y = 65, z = 0, param = 10 } })
  local r = hivesim.walkRobot(nav, robot, clock, 60)
  check("robot flat walk arrives", r == "arrived" and robot.x == 10, r .. " x=" .. robot.x)
end

do
  -- wall it must dig through
  local world = hivesim.world{ surface = hivesim.terrain.plains(64) }
  world.place(5, 65, 0, "stone")
  local clock = hivesim.clock()
  local robot = hivesim.robot(world, 0, 65, 0)
  local nav = robotNav(robot, clock, {})
  nav.setRoute(6, { { op = OP.STEP_PATH, x = 10, y = 65, z = 0 } })
  nav.setDigAllowed(true)
  local r = hivesim.walkRobot(nav, robot, clock, 60)
  check("robot digs through wall", r == "arrived" and robot.x == 10, r .. " x=" .. robot.x)
end

do
  -- one-high wall, no digging -> climb over via hover
  local world = hivesim.world{ surface = hivesim.terrain.plains(64) }
  world.place(5, 65, 0, "stone")
  local clock = hivesim.clock()
  local robot = hivesim.robot(world, 0, 65, 0)
  local nav = robotNav(robot, clock, {})
  nav.setRoute(7, { { op = OP.STEP_PATH, x = 10, y = 65, z = 0 } })
  local r = hivesim.walkRobot(nav, robot, clock, 80)
  check("robot climbs over low wall", r == "arrived" and robot.x == 10, r .. " x=" .. robot.x)
end

print(string.rep("-", 40))
if failures == 0 then
  print("all nav tests passed")
  os.exit(0)
else
  print(failures .. " test(s) failed")
  os.exit(1)
end
