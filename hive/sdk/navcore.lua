-- navcore.lua: the device-side route executor (drones and robots).
-- Consumes packed NAV_ROUTE legs and drives motion one bounded step per tick(),
-- with geofence enforcement, stall/obstacle recovery ladders, and fluid/void
-- guards. Motion primitives are injected adapters so the same state machine runs
-- on a drone (async move + offset polling), a robot (blocking one-block steps),
-- and the desktop simulator. Install to /usr/lib/hive/sdk/navcore.lua.
--
-- Adapters (opts.io):
--   pos() -> x,y,z | nil            absolute position (nav upgrade); nil = out of range
--   energy() -> 0..1
--   now() -> seconds
--   report(subcode, payload)        emit an EVT to the queen
--   status(l1, l2, color)           optional status display
--   -- drone:
--   move(dx,dy,dz)                  add an offset to the async flight target
--   offset() -> number              distance remaining to the flight target
--   -- robot:
--   moveStep(dx,dy,dz) -> ok, why   attempt one blocking one-block move
--   dig(dx,dy,dz) -> ok             break the block in a direction (if allowed)
--   detect(dx,dy,dz) -> name        block name in a direction (exact)

local navcore = {}

local EVT = { LEG_OK = 2, ROUTE_DONE = 3, ROUTE_BLOCKED = 4, NO_LAND = 5,
  NAV_FAIL = 6, GEOFENCE_REJ = 7, DRIFT = 8 }
navcore.EVT = EVT

-- Leg opcodes (must match routes.OP).
local OP = { CLIMB_TO = 1, GOTO = 2, DESCEND_TO = 3, DOCK = 4, HOLD = 5,
  STEP_PATH = 6, CORRIDOR = 7, SITE_ENTER = 8 }

local defaults = {
  arriveTol = 0.7, dockTol = 0.4, stallWin = 1.5, stallEps = 0.15,
  geofence = 984, skyY = 224, floorY = 4, legRecoverCap = 60, holdTimeout = 10,
  descendStep = 8,
}

local function sign(v) return v > 0 and 1 or (v < 0 and -1 or 0) end

-- opts: kind ("drone"|"robot"), io (adapters), cfg (overrides), unpackLegs (fn).
function navcore.new(opts)
  local self = {}
  local kind = opts.kind or "drone"
  local io = assert(opts.io, "navcore needs io adapters")
  local unpackLegs = opts.unpackLegs
  local cfg = {}
  for k, v in pairs(defaults) do cfg[k] = v end
  for k, v in pairs(opts.cfg or {}) do cfg[k] = v end

  local legs, legIdx, routeId
  local state = "idle"
  local aim                 -- drone: our commanded absolute flight target
  local target              -- current leg's goal {x,y,z}
  local bestOffset, bestAt
  local recover = { stage = 0, climbs = 0, sides = 0, startedAt = 0 }
  local robotHist = {}      -- robot: recent successful moves for reversal

  self.state = function() return state end
  self.progress = function() return { legIdx = legIdx, of = legs and #legs or 0, state = state } end

  -- --- geofence ------------------------------------------------------------

  local function insideFence(x, z)
    return math.abs(x) <= cfg.geofence and math.abs(z) <= cfg.geofence
  end

  -- --- drone motion --------------------------------------------------------

  local function droneAimAt(t)
    local p = { io.pos() }
    if not p[1] then return false end
    if not aim then aim = { x = p[1], y = p[2], z = p[3] } end
    io.move(t.x - aim.x, t.y - aim.y, t.z - aim.z)
    aim = { x = t.x, y = t.y, z = t.z }
    return true
  end

  -- Re-command the target from a fresh position fix (heals a dropped move/drift).
  local function droneReaim(t)
    local x, y, z = io.pos()
    if not x then return false end
    aim = { x = x, y = y, z = z }
    io.move(t.x - x, t.y - y, t.z - z)
    aim = { x = t.x, y = t.y, z = t.z }
    return true
  end

  local function enterLeg()
    local l = legs[legIdx]
    if not l then return end
    target = { x = l.x, y = l.y, z = l.z }
    bestOffset, bestAt = nil, io.now()
    recover = { stage = 0, climbs = 0, sides = 0, startedAt = io.now() }
    if kind == "drone" then
      droneAimAt(target)
    end
    if io.status then io.status(("leg %d/%d"):format(legIdx, #legs), state) end
  end

  local function advance()
    if io.report then io.report(EVT.LEG_OK, { leg = legIdx }) end
    legIdx = legIdx + 1
    if legIdx > #legs then
      state = "arrived"
      if io.report then io.report(EVT.ROUTE_DONE, { routeId = routeId }) end
    else
      enterLeg()
    end
  end

  -- Drone stall recovery ladder. Returns true if it reported blocked (give up).
  local function droneRecover()
    local t = io.now()
    if (t - recover.startedAt) > cfg.legRecoverCap then
      state = "blocked"
      if io.report then io.report(EVT.ROUTE_BLOCKED, { routeId = routeId, leg = legIdx,
        x = target.x, y = target.y, z = target.z }) end
      return true
    end
    state = "recovering"
    if recover.stage == 0 then
      droneReaim(target); recover.stage = 1
    elseif recover.stage == 1 and recover.climbs < 3 then
      recover.climbs = recover.climbs + 1
      local ny = math.min(cfg.skyY, (aim and aim.y or target.y) + 4)
      droneReaim({ x = target.x, y = ny, z = target.z })
    elseif recover.sides < 2 then
      recover.sides = recover.sides + 1
      local off = (recover.sides % 2 == 1) and 4 or -4
      droneReaim({ x = target.x + off, y = (aim and aim.y or target.y), z = target.z })
      recover.stage = 2
    elseif io.energy() >= 0.25 then
      droneReaim({ x = target.x, y = cfg.skyY, z = target.z })
      recover.stage = 3
    else
      state = "blocked"
      if io.report then io.report(EVT.ROUTE_BLOCKED, { routeId = routeId, leg = legIdx,
        x = target.x, y = target.y, z = target.z }) end
      return true
    end
    bestOffset, bestAt = nil, io.now()
    return false
  end

  local function droneTick()
    local x, y, z = io.pos()
    if not x then
      state = "lost_fix"
      if io.report then io.report(EVT.NAV_FAIL, { reason = "no_fix" }) end
      return
    end
    local l = legs[legIdx]
    local tol = (l.op == OP.DOCK) and cfg.dockTol or cfg.arriveTol
    local off = io.offset()
    if off <= tol then
      -- final dock snap: reissue once from a fresh fix to land on the grid
      advance()
      return
    end
    -- stall detection
    if not bestOffset or off < bestOffset - cfg.stallEps then
      bestOffset, bestAt = off, io.now()
    elseif (io.now() - bestAt) >= cfg.stallWin then
      droneRecover()
      return
    end
    state = "enroute"
  end

  -- --- robot motion --------------------------------------------------------

  local function robotStepToward(l)
    local x, y, z = io.pos()
    if not x then
      state = "lost_fix"
      if io.report then io.report(EVT.NAV_FAIL, { reason = "no_fix" }) end
      return
    end
    if x == l.x and z == l.z then
      advance()
      return
    end
    -- prefer the larger remaining axis
    local dx, dz = l.x - x, l.z - z
    local sx, sz = sign(dx), sign(dz)
    local order
    if math.abs(dx) >= math.abs(dz) then
      order = { { sx, 0, 0 }, { 0, 0, sz } }
    else
      order = { { 0, 0, sz }, { sx, 0, 0 } }
    end
    for _, d in ipairs(order) do
      if d[1] ~= 0 or d[3] ~= 0 then
        -- refuse to walk into a fluid or too-deep drop
        local ahead = io.detect and io.detect(d[1], 0, d[3])
        if ahead == "water" or ahead == "lava" then
          if io.report then io.report(EVT.NO_LAND, { x = x + d[1], z = z + d[3] }) end
        else
          local ok = io.moveStep(d[1], 0, d[3])
          if ok then
            robotHist[#robotHist + 1] = { -d[1], 0, -d[3] }
            state = "enroute"
            return
          end
          -- blocked: dig if allowed, else try a step up (hover), else recover
          if l._dig and io.dig then
            if io.dig(d[1], 0, d[3]) and io.moveStep(d[1], 0, d[3]) then
              robotHist[#robotHist + 1] = { -d[1], 0, -d[3] }
              return
            end
          end
          if io.moveStep(0, 1, 0) then
            robotHist[#robotHist + 1] = { 0, -1, 0 }
            return
          end
        end
      end
    end
    -- fully blocked this tick
    recover.stage = recover.stage + 1
    if recover.stage > 12 then
      state = "blocked"
      if io.report then io.report(EVT.ROUTE_BLOCKED, { routeId = routeId, leg = legIdx,
        x = l.x, y = l.y, z = l.z }) end
    end
  end

  -- --- public --------------------------------------------------------------

  -- Load a route. Rejects any leg outside the geofence BEFORE moving.
  function self.setRoute(id, blobOrLegs)
    local parsed
    if type(blobOrLegs) == "string" then
      parsed = (unpackLegs or require("routes").unpackLegs)(blobOrLegs)
      routeId = parsed.routeId
      legs = parsed.legs
    else
      legs = blobOrLegs
      routeId = id
    end
    for _, l in ipairs(legs) do
      if not insideFence(l.x, l.z) then
        state = "blocked"
        if io.report then io.report(EVT.GEOFENCE_REJ, { x = l.x, z = l.z }) end
        return nil, "geofence"
      end
      if l._dig == nil then l._dig = false end
    end
    legIdx = 1
    state = "enroute"
    robotHist = {}
    aim = nil
    enterLeg()
    return true
  end

  function self.setDigAllowed(v)
    if legs then for _, l in ipairs(legs) do l._dig = v end end
  end

  function self.cancel(reason)
    state = "idle"
    legs, legIdx, target = nil, nil, nil
  end

  -- One bounded unit of work. Call repeatedly from the role loop (drones between
  -- ~0.25s sleeps for offset polling; robots as fast as steps complete).
  function self.tick()
    if not legs or state == "arrived" or state == "idle" or state == "blocked" then return state end
    if kind == "drone" then
      droneTick()
    else
      robotStepToward(legs[legIdx])
    end
    return state
  end

  self.arrived = function() return state == "arrived" end
  self.blocked = function() return state == "blocked" end

  return self
end

return navcore
