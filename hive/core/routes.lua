-- routes.lua: the hive route planner.
-- Plans device paths in four modes -- drone bee-line staircase (BEE3), drone
-- tile-grid corridor A*, robot surface-column A*, and underground navgraph
-- Dijkstra -- and packs them into the compact NAV_ROUTE leg format the device
-- executor consumes. Heavy searches are chunked across scheduler ticks under a
-- millisecond budget with a hard touched-node cap. Pure Lua + injected world
-- lookups. Install to /usr/lib/hive/core/routes.lua.

local airspace = require("airspace")

local routes = {}

-- Leg opcodes (see NAV_ROUTE wire format).
local OP = { CLIMB_TO = 1, GOTO = 2, DESCEND_TO = 3, DOCK = 4, HOLD = 5,
  STEP_PATH = 6, CORRIDOR = 7, SITE_ENTER = 8 }
routes.OP = OP

local MODE = { BEE3 = 1, CORRIDOR = 2, SURFACE = 3, UNDERGROUND = 4 }
routes.MODE = MODE

local floor = math.floor
local huge = math.huge

-- --------------------------------------------------------------------------
-- Leg codec: 6-byte header + 8-byte legs.
-- --------------------------------------------------------------------------

function routes.packLegs(routeId, mode, legs, flags, cruiseHint)
  local out = { string.pack("<I2BBBB", routeId & 0xffff, mode, #legs, flags or 0, cruiseHint or 0) }
  for _, l in ipairs(legs) do
    local ts = ((l.tol or 3) & 0x0f) | (((l.speed or 8) & 0x0f) << 4)
    out[#out + 1] = string.pack("<Bi2Bi2BB", l.op, l.x or 0, (l.y or 0) & 0xff, l.z or 0, ts, l.param or 0)
  end
  return table.concat(out)
end

function routes.unpackLegs(blob)
  local routeId, mode, count, flags, cruiseHint, pos = string.unpack("<I2BBBB", blob)
  local legs = {}
  for _ = 1, count do
    local op, x, y, z, ts, param
    op, x, y, z, ts, param, pos = string.unpack("<Bi2Bi2BB", blob, pos)
    legs[#legs + 1] = { op = op, x = x, y = y, z = z, tol = ts & 0x0f, speed = (ts >> 4) & 0x0f, param = param }
  end
  return { routeId = routeId, mode = mode, flags = flags, cruiseHint = cruiseHint, legs = legs }
end

-- --------------------------------------------------------------------------
-- Chunked 2D-grid A* engine (shared by SURFACE and CORRIDOR modes).
-- Integer cell keys keep node state compact; the search can be stepped in slices.
-- --------------------------------------------------------------------------

local OFF, GRID = 2048, 4096
local function ckey(x, z) return (x + OFF) * GRID + (z + OFF) end
local function cunkey(k) return floor(k / GRID) - OFF, (k % GRID) - OFF end

local function heapPush(h, f, k, x, z)
  local n = h.n + 1
  h.n = n
  h[n] = { f = f, k = k, x = x, z = z }
  while n > 1 do
    local p = floor(n / 2)
    if h[p].f <= h[n].f then break end
    h[p], h[n] = h[n], h[p]
    n = p
  end
end

local function heapPop(h)
  local n = h.n
  if n == 0 then return nil end
  local top = h[1]
  h[1] = h[n]
  h[n] = nil
  h.n = n - 1
  n = n - 1
  local i = 1
  while true do
    local l, r, s = i * 2, i * 2 + 1, i
    if l <= n and h[l].f < h[s].f then s = l end
    if r <= n and h[r].f < h[s].f then s = r end
    if s == i then break end
    h[i], h[s] = h[s], h[i]
    i = s
  end
  return top
end

-- spec: start{x,z}, goal{x,z}, neighbors(x,z)->{{x,z},...}, stepCost(ax,az,bx,bz)->cost,
--       heuristic(x,z)->h, touchCap.
function routes.astarBegin(spec)
  local s = { spec = spec, open = { n = 0 }, g = {}, parent = {}, closed = {}, touched = 1 }
  local sk = ckey(spec.start.x, spec.start.z)
  s.g[sk] = 0
  heapPush(s.open, spec.heuristic(spec.start.x, spec.start.z), sk, spec.start.x, spec.start.z)
  return s
end

-- Returns "running" | "done", pathList | "fail". pathList is {{x,z},...} start..goal.
function routes.astarStep(s, nExp)
  local spec = s.spec
  local gx, gz = spec.goal.x, spec.goal.z
  for _ = 1, nExp do
    local top = heapPop(s.open)
    if not top then return "fail" end
    local k, x, z = top.k, top.x, top.z
    if not s.closed[k] then
      s.closed[k] = true
      if x == gx and z == gz then
        local path, cur = {}, k
        while cur do
          local cx, cz = cunkey(cur)
          table.insert(path, 1, { x = cx, z = cz })
          cur = s.parent[cur]
        end
        return "done", path
      end
      local gc = s.g[k]
      for _, nb in ipairs(spec.neighbors(x, z)) do
        local nk = ckey(nb.x, nb.z)
        if not s.closed[nk] then
          local step = spec.stepCost(x, z, nb.x, nb.z)
          if step < huge then
            local nd = gc + step
            if nd < (s.g[nk] or huge) then
              s.g[nk] = nd
              s.parent[nk] = k
              s.touched = s.touched + 1
              if s.touched > (spec.touchCap or 16384) then return "fail" end
              heapPush(s.open, nd + spec.heuristic(nb.x, nb.z), nk, nb.x, nb.z)
            end
          end
        end
      end
    end
  end
  return "running"
end

-- --------------------------------------------------------------------------
-- Neighbour + cost functions
-- --------------------------------------------------------------------------

local N4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local N8 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

local function neighborsFrom(deltas, bounds)
  return function(x, z)
    local out = {}
    for _, d in ipairs(deltas) do
      local nx, nz = x + d[1], z + d[2]
      if not bounds or (nx >= bounds.x1 and nx <= bounds.x2 and nz >= bounds.z1 and nz <= bounds.z2) then
        out[#out + 1] = { x = nx, z = nz }
      end
    end
    return out
  end
end

-- --------------------------------------------------------------------------
-- Instance
-- --------------------------------------------------------------------------

-- opts: env { maxSurface(cx,cz)->y|nil, surface(x,z)->y, column(x,z)->{surfaceY,fluid,lava,scanned} },
--       graph (navgraph), now, cfg (airspace.defaults), cacheCap.
function routes.new(opts)
  opts = opts or {}
  local self = {}
  local env = opts.env or {}
  local cfg = opts.cfg or airspace.defaults
  local now = opts.now or function() return 0 end
  local clockFn = opts.clock or os.clock -- high-res monotonic clock for slice budgeting
  local graph = opts.graph

  local overlay = {}      -- colKey -> {penalty, expiry}
  local cache = {}        -- key -> {legs, tiles={...}, used}
  local cacheCap = opts.cacheCap or 64
  local lru = 0
  local queue = {}        -- pending chunked requests
  local active = nil      -- current chunked search
  local nextReqId = 0
  local calibExp = nil    -- measured expansions/ms

  local function overlayPenalty(x, z)
    local o = overlay[ckey(x, z)]
    if o and o.expiry > now() then return o.penalty end
    return 0
  end

  function self.addObstacle(x, z, penalty, ttl)
    overlay[ckey(x, z)] = { penalty = penalty or 200, expiry = now() + (ttl or 900) }
  end

  -- --- BEE3: drone staircase ------------------------------------------------

  -- Returns legs, meta. meta.needsCorridor set if the straight path is unsuitable.
  function self.planBee3(from, to, dock)
    local maxFn = function(cx, cz) return env.maxSurface and env.maxSurface(cx, cz) end
    local steps, peak = airspace.cruiseProfile(from, to, maxFn, cfg)
    local legs = {}
    local n = #steps
    -- climb above the start column to the first stretch's cruise
    legs[#legs + 1] = { op = OP.CLIMB_TO, x = from.x, y = steps[1].y, z = from.z, tol = 3 }
    -- fly to the lateral point where each subsequent stretch begins, at its y
    for i = 2, n do
      local frac = steps[i].fromFrac
      local px = floor(from.x + (to.x - from.x) * frac)
      local pz = floor(from.z + (to.z - from.z) * frac)
      legs[#legs + 1] = { op = OP.GOTO, x = px, y = steps[i].y, z = pz, tol = 3 }
    end
    -- lateral to the goal column at the final cruise
    legs[#legs + 1] = { op = OP.GOTO, x = to.x, y = steps[n].y, z = to.z, tol = 3 }
    -- descend onto the target
    local goalSurf = (env.surface and env.surface(to.x, to.z)) or (to.y - cfg.GROUND_CLR)
    local descendY = math.max(cfg.GROUND_CLR, goalSurf + cfg.GROUND_CLR)
    if dock then
      legs[#legs + 1] = { op = OP.DOCK, x = to.x, y = descendY, z = to.z, tol = 1, param = dock & 0xff }
    else
      -- unscanned goal columns descend in steps (param) so the executor can probe
      local scanned = env.column and env.column(to.x, to.z)
      legs[#legs + 1] = { op = OP.DESCEND_TO, x = to.x, y = descendY, z = to.z, tol = 3,
        param = scanned and 0 or 8 }
    end
    return legs, { peak = peak }
  end

  -- --- SURFACE: robot column A* --------------------------------------------

  function self.beginSurface(from, to, digAllowed)
    local pad = 48
    local bounds = { x1 = math.min(from.x, to.x) - pad, x2 = math.max(from.x, to.x) + pad,
      z1 = math.min(from.z, to.z) - pad, z2 = math.max(from.z, to.z) + pad }
    local function col(x, z)
      return (env.column and env.column(x, z)) or { surfaceY = 64, scanned = false }
    end
    local stepCost = function(ax, az, bx, bz)
      local a, b = col(ax, az), col(bx, bz)
      if b.lava then return huge end
      local dh = math.abs((b.surfaceY or 64) - (a.surfaceY or 64))
      local c = 1
      if not b.scanned then c = c + 8 end
      if b.fluid then c = c + 50 end
      if (b.surfaceY or 64) > (a.surfaceY or 64) then c = c + 1.2 * dh else c = c + 0.6 * dh end
      c = c + overlayPenalty(bx, bz)
      return c
    end
    return routes.astarBegin{
      start = from, goal = to,
      neighbors = neighborsFrom(N4, bounds),
      stepCost = stepCost,
      heuristic = function(x, z) return math.abs(x - to.x) + math.abs(z - to.z) end,
      touchCap = opts.touchCap or 16384,
    }
  end

  -- Convert a surface path to run-length STEP_PATH legs (one per direction change).
  function self.surfaceLegs(path)
    local legs = {}
    if #path < 2 then return legs end
    local dirx, dirz, runStart = nil, nil, 1
    for i = 2, #path do
      local dx = (path[i].x > path[i - 1].x) and 1 or (path[i].x < path[i - 1].x and -1 or 0)
      local dz = (path[i].z > path[i - 1].z) and 1 or (path[i].z < path[i - 1].z and -1 or 0)
      if dirx == nil then dirx, dirz = dx, dz end
      if dx ~= dirx or dz ~= dirz then
        local p = path[i - 1]
        legs[#legs + 1] = { op = OP.STEP_PATH, x = p.x, y = (env.surface and env.surface(p.x, p.z)) or 64,
          z = p.z, param = math.min(255, i - runStart) }
        dirx, dirz, runStart = dx, dz, i - 1
      end
    end
    local p = path[#path]
    legs[#legs + 1] = { op = OP.STEP_PATH, x = p.x, y = (env.surface and env.surface(p.x, p.z)) or 64,
      z = p.z, param = math.min(255, #path - runStart) }
    return legs
  end

  -- --- CORRIDOR: drone tile-grid A* ----------------------------------------

  function self.beginCorridor(from, to)
    local TILE = cfg.TILE
    local fT = { x = floor(from.x / TILE), z = floor(from.z / TILE) }
    local tT = { x = floor(to.x / TILE), z = floor(to.z / TILE) }
    local stepCost = function(_, _, bx, bz)
      local s = env.maxSurface and env.maxSurface(bx, bz)
      local c = 16
      if not s then c = c + 16 * 5 end
      return c
    end
    return routes.astarBegin{
      start = fT, goal = tT,
      neighbors = neighborsFrom(N8),
      stepCost = stepCost,
      heuristic = function(x, z)
        return TILE * math.max(math.abs(x - tT.x), math.abs(z - tT.z))
      end,
      touchCap = opts.touchCap or 16384,
    }
  end

  -- --- UNDERGROUND: navgraph Dijkstra --------------------------------------

  function self.planUnderground(from, to, forDevice)
    if not graph then return nil, "no graph" end
    local a = graph.nearest(from.x, from.y or 64, from.z, nil, 24)
    local b = graph.nearest(to.x, to.y or 64, to.z, nil, 24)
    if not a or not b then return nil, "no portal" end
    local path = graph.route(a, b, graph.MODE.TUNNEL | graph.MODE.SHAFT, forDevice)
    if not path then return nil, "no graph path" end
    local legs = {}
    for i = 2, #path do
      local nd = graph.getNode(path[i])
      legs[#legs + 1] = { op = OP.CORRIDOR, x = nd.x, y = nd.y, z = nd.z, param = 0 }
    end
    return legs
  end

  -- --- request / tick orchestration ----------------------------------------

  local function cacheKey(spec)
    local TILE = cfg.TILE
    return string.format("%s:%d,%d:%d,%d:%s", spec.kind,
      floor(spec.from.x / TILE), floor(spec.from.z / TILE),
      floor(spec.to.x / TILE), floor(spec.to.z / TILE),
      spec.opts and spec.opts.digAllowed and "d" or "-")
  end

  local function cachePut(key, legs)
    lru = lru + 1
    cache[key] = { legs = legs, used = lru }
    local n = 0
    for _ in pairs(cache) do n = n + 1 end
    while n > cacheCap do
      local ok, ou
      for k, e in pairs(cache) do
        if not ou or e.used < ou then ok, ou = k, e.used end
      end
      cache[ok] = nil
      n = n - 1
    end
  end

  -- Invalidate cached routes when a tile is re-scanned (coarse: drop everything
  -- referencing that tile; v1 clears whole cache on ingest bursts is acceptable).
  function self.onIngest()
    cache = {}
  end

  -- spec: kind ("drone"|"robot"), from, to, opts{digAllowed, dock, priority, avoid},
  --       onDone(legsStr|nil, meta). Returns reqId.
  function self.request(spec)
    nextReqId = (nextReqId + 1) % 65536
    local reqId = nextReqId
    spec._id = reqId
    -- instant modes resolve now
    if spec.kind == "drone" then
      local legs, meta = self.planBee3(spec.from, spec.to, spec.opts and spec.opts.dock)
      local str = routes.packLegs(reqId, MODE.BEE3, legs, 0, floor((meta.peak or 0) / 4))
      if spec.onDone then spec.onDone(str, { mode = MODE.BEE3 }) end
      return reqId
    elseif spec.kind == "underground" then
      local legs = self.planUnderground(spec.from, spec.to, spec.deviceId)
      if legs then
        if spec.onDone then spec.onDone(routes.packLegs(reqId, MODE.UNDERGROUND, legs), { mode = MODE.UNDERGROUND }) end
      elseif spec.onDone then spec.onDone(nil, { error = "no graph path" })
      end
      return reqId
    end
    -- chunked (robot surface): cache then enqueue
    local key = cacheKey(spec)
    if cache[key] then
      cache[key].used = lru + 1
      if spec.onDone then spec.onDone(cache[key].legs, { mode = MODE.SURFACE, cached = true }) end
      return reqId
    end
    spec._key = key
    queue[#queue + 1] = spec
    return reqId
  end

  -- Advance the active chunked search under a wall-clock budget (ms). Autocalibrates
  -- expansions/ms on the first slice; conservative floor 2000 exp/tick.
  function self.tick(budgetMs)
    budgetMs = budgetMs or 30
    if not active then
      local spec = table.remove(queue, 1)
      if not spec then return end
      active = { spec = spec, ticks = 0,
        search = self.beginSurface(spec.from, spec.to, spec.opts and spec.opts.digAllowed) }
    end
    active.ticks = active.ticks + 1
    local slice = calibExp and math.max(128, floor(calibExp * budgetMs)) or 2000
    local t0 = clockFn()
    local status, path = routes.astarStep(active.search, slice)
    local dt = (clockFn() - t0) * 1000
    if dt > 0 and active.ticks == 1 then calibExp = slice / dt end
    if status == "running" then
      if active.ticks > 15 then -- SLO hard cap -> fallback to failure
        if active.spec.onDone then active.spec.onDone(nil, { error = "search timeout" }) end
        active = nil
      end
      return
    end
    local spec = active.spec
    if status == "done" then
      local legs = self.surfaceLegs(path)
      local str = routes.packLegs(spec._id, MODE.SURFACE, legs)
      if spec._key then cachePut(spec._key, str) end
      if spec.onDone then spec.onDone(str, { mode = MODE.SURFACE }) end
    else
      if spec.onDone then spec.onDone(nil, { error = "no path" }) end
    end
    active = nil
  end

  function self.pending() return #queue + (active and 1 or 0) end
  function self.calibration() return calibExp end

  -- --- frontier ------------------------------------------------------------

  -- Nearest interesting unscanned tile. indexFn(cx,cz) -> summary{scannedPct, flags} | nil.
  function self.frontierNext(center, radius, indexFn)
    local best, bestScore
    for r = 1, radius do
      for dx = -r, r do
        for dz = -r, r do
          if math.abs(dx) == r or math.abs(dz) == r then
            local cx, cz = center.cx + dx, center.cz + dz
            local s = indexFn(cx, cz)
            local pct = s and s.scannedPct or 0
            if pct < 90 then
              local unscannedNbrs = 0
              for _, d in ipairs(N4) do
                local ns = indexFn(cx + d[1], cz + d[2])
                if not ns or ns.scannedPct < 90 then unscannedNbrs = unscannedNbrs + 1 end
              end
              local score = 3 * unscannedNbrs - 0.01 * (dx * dx + dz * dz)
              if not bestScore or score > bestScore then
                best, bestScore = { cx = cx, cz = cz }, score
              end
            end
          end
        end
      end
      if best then return best end
    end
    return best
  end

  return self
end

return routes
