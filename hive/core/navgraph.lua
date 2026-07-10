-- navgraph.lua: the hive's route graph over waypoints, chargers, depots, and
-- mined tunnels/shafts. Edges earn trust by being traversed cleanly and lose it
-- when they block; routing is Dijkstra over a mode-filtered subgraph. Single-track
-- tunnel occupancy is handled by leases. Pure Lua + injected store/now.
-- Install to /usr/lib/hive/core/navgraph.lua.

local navgraph = {}

-- Node kinds and edge modes.
local KIND = { WAYPOINT = 1, CHARGER = 2, DEPOT = 3, JUNCTION = 4,
  SHAFT_TOP = 5, SHAFT_BOT = 6, AIRHUB = 7 }
local MODE = { AIR = 1, SURFACE = 2, TUNNEL = 4, SHAFT = 8 }
local EFLAG = { TRUSTED = 1, SUSPECT = 2 }
navgraph.KIND = KIND
navgraph.MODE = MODE

-- Tunnel/shaft types: clearance (w x h, blocks) and throughput capacity (how many
-- devices may hold the edge at once). Holes are 3x3 vertical shafts shared by
-- several devices ascending/descending; trunks are the high-capacity arteries.
local TTYPE = { CRAWL = 1, STANDARD = 2, HIGHWAY = 3, TRUNK = 4, HOLE3 = 5 }
local SPEC = {
  [1] = { name = "crawl", w = 1, h = 2, cap = 1 },
  [2] = { name = "standard", w = 2, h = 3, cap = 1 },
  [3] = { name = "highway", w = 3, h = 3, cap = 2 },
  [4] = { name = "trunk", w = 3, h = 4, cap = 3 },
  [5] = { name = "hole3", w = 3, h = 3, cap = 3 },
}
navgraph.TTYPE = TTYPE
navgraph.SPEC = SPEC

local NODE_FMT = "<I2Bi2Bi2BI4"    -- id, kind, x, y, z, flags, addrHash  (13 bytes)
local EDGE_FMT = "<I2I2BI2BBI2BB"  -- a, b, mode, cost, trav, fails, lastOkH, flags, ttype (13)

local function dist3(a, b)
  local dx, dy, dz = a.x - b.x, (a.y or 0) - (b.y or 0), a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- opts: store, path, now (-> s).
function navgraph.new(opts)
  opts = opts or {}
  local self = {}
  local st = opts.store
  local path = opts.path
  local now = opts.now or function() return 0 end

  local nodes = {}   -- id -> {id, kind, x, y, z, flags, label}
  local edges = {}   -- edgeId -> {a, b, mode, cost, trav, fails, lastOk, flags}
  local adj = {}     -- nodeId -> { {edgeId, other}, ... }
  local leases = {}  -- edgeId -> {device, until}
  local nextNode, nextEdge = 1, 1

  local function addAdj(edgeId, e)
    adj[e.a] = adj[e.a] or {}
    adj[e.b] = adj[e.b] or {}
    adj[e.a][#adj[e.a] + 1] = { edgeId = edgeId, other = e.b }
    adj[e.b][#adj[e.b] + 1] = { edgeId = edgeId, other = e.a }
  end

  -- Add a node; JUNCTION/SHAFT nodes within 1 block of an existing same-kind
  -- node fuse into it (miners re-reporting the same tunnel mouth).
  function self.addNode(spec)
    if spec.kind == KIND.JUNCTION or spec.kind == KIND.SHAFT_TOP or spec.kind == KIND.SHAFT_BOT then
      for _, nd in pairs(nodes) do
        if nd.kind == spec.kind and dist3(nd, spec) <= 1.5 then
          return nd.id
        end
      end
    end
    local id = nextNode
    nextNode = nextNode + 1
    nodes[id] = { id = id, kind = spec.kind, x = spec.x, y = spec.y or 0, z = spec.z,
      flags = spec.flags or 0, label = spec.label, addr = spec.addr or 0 }
    return id
  end

  -- Universal-frame references for triangulation: addrHash -> {x,y,z} for every
  -- node that carries a waypoint address (the queen frame is the universal frame).
  function self.calRefs()
    local refs = {}
    for _, nd in pairs(nodes) do
      if nd.addr and nd.addr ~= 0 then refs[nd.addr] = { x = nd.x, y = nd.y, z = nd.z } end
    end
    return refs
  end

  function self.getNode(id) return nodes[id] end
  function self.nodes() return nodes end
  function self.edges() return edges end

  -- Create or extend an edge between two nodes. Re-linking merges the mode mask
  -- and keeps the cheaper cost. ttype sets the clearance/throughput class.
  function self.link(a, b, mode, cost, ttype)
    for eid, e in pairs(edges) do
      if (e.a == a and e.b == b) or (e.a == b and e.b == a) then
        e.mode = e.mode | (mode or MODE.SURFACE)
        if cost and cost < e.cost then e.cost = cost end
        if ttype then e.ttype = ttype end
        return eid
      end
    end
    local id = nextEdge
    nextEdge = nextEdge + 1
    local c = cost or math.floor(dist3(nodes[a], nodes[b]) * 10)
    edges[id] = { a = a, b = b, mode = mode or MODE.SURFACE, cost = c,
      trav = 0, fails = 0, lastOk = 0, flags = 0, ttype = ttype or TTYPE.STANDARD }
    addAdj(id, edges[id])
    return id
  end

  -- A "hole": a 3x3 vertical shaft between yTop and yBot at (x,z). Multiple devices
  -- can share it (capacity from the hole's type), so it serves as a network entry.
  -- Returns topId, botId, edgeId.
  function self.addHole(spec)
    local topId = self.addNode{ kind = KIND.SHAFT_TOP, x = spec.x, y = spec.yTop, z = spec.z,
      label = spec.label, addr = spec.addr }
    local botId = self.addNode{ kind = KIND.SHAFT_BOT, x = spec.x, y = spec.yBot, z = spec.z }
    local ttype = spec.ttype or TTYPE.HOLE3
    local eid = self.link(topId, botId, MODE.SHAFT, math.abs(spec.yTop - spec.yBot) * 10, ttype)
    return topId, botId, eid
  end

  -- Record a traversal outcome. Clean traversals promote to TRUSTED; blocks demote.
  function self.observe(edgeId, ok, actualCost)
    local e = edges[edgeId]
    if not e then return end
    if ok then
      e.trav = math.min(255, e.trav + 1)
      e.fails = 0
      e.lastOk = math.floor(now() / 60) % 65536
      if actualCost then e.cost = math.floor(e.cost * 0.75 + actualCost * 0.25) end
      if e.trav >= 3 then e.flags = (e.flags & ~EFLAG.SUSPECT) | EFLAG.TRUSTED end
    else
      e.fails = e.fails + 1
      e.flags = (e.flags & ~EFLAG.TRUSTED) | EFLAG.SUSPECT
      if e.fails >= 3 then self.dropEdge(edgeId) end
    end
  end

  function self.dropEdge(edgeId)
    local e = edges[edgeId]
    if not e then return end
    edges[edgeId] = nil
    for _, side in ipairs({ e.a, e.b }) do
      local list = adj[side]
      if list then
        for i = #list, 1, -1 do
          if list[i].edgeId == edgeId then table.remove(list, i) end
        end
      end
    end
    leases[edgeId] = nil
  end

  local function capOf(e)
    local s = SPEC[e.ttype or TTYPE.STANDARD]
    return s and s.cap or 1
  end
  -- Count current lease holders on an edge, pruning expired ones.
  local function holders(edgeId, t)
    local L = leases[edgeId]
    if not L then return 0 end
    local n = 0
    for d, u in pairs(L) do
      if u > t then n = n + 1 else L[d] = nil end
    end
    return n
  end

  -- Effective routing cost: trusted edges cheaper, suspect dearer, and an edge at
  -- its throughput capacity (all lanes taken by others) is expensive so routing
  -- prefers a less-congested path.
  local function edgeCost(e, edgeId, forDevice, t)
    local c = e.cost
    if (e.flags & EFLAG.TRUSTED) ~= 0 then c = math.floor(c * 0.7) end
    if (e.flags & EFLAG.SUSPECT) ~= 0 then c = c * 4 end
    local L = leases[edgeId]
    local mine = L and L[forDevice] and L[forDevice] > t
    if not mine and holders(edgeId, t) >= capOf(e) then c = c * 8 end
    return c
  end

  -- Dijkstra over edges whose mode intersects modeMask. Returns {nodeIds...}, cost.
  function self.route(fromId, toId, modeMask, forDevice)
    modeMask = modeMask or 0xff
    local t = now()
    local distv, prev, done = {}, {}, {}
    distv[fromId] = 0
    while true do
      -- pick nearest unfinished
      local u, best
      for id, d in pairs(distv) do
        if not done[id] and (not best or d < best) then u, best = id, d end
      end
      if not u then break end
      if u == toId then break end
      done[u] = true
      for _, link in ipairs(adj[u] or {}) do
        local e = edges[link.edgeId]
        if e and (e.mode & modeMask) ~= 0 and not done[link.other] then
          local nd = best + edgeCost(e, link.edgeId, forDevice, t)
          if not distv[link.other] or nd < distv[link.other] then
            distv[link.other] = nd
            prev[link.other] = u
          end
        end
      end
    end
    if not distv[toId] then return nil end
    local pathIds, cur = {}, toId
    while cur do
      table.insert(pathIds, 1, cur)
      cur = prev[cur]
    end
    return pathIds, distv[toId]
  end

  -- Nearest node to a point (optionally filtered by kind), within maxDist.
  function self.nearest(x, y, z, kind, maxDist)
    local p = { x = x, y = y, z = z }
    local bestId, bestD
    for id, nd in pairs(nodes) do
      if not kind or nd.kind == kind then
        local d = dist3(nd, p)
        if (not maxDist or d <= maxDist) and (not bestD or d < bestD) then
          bestId, bestD = id, d
        end
      end
    end
    return bestId, bestD
  end

  function self.capacity(edgeId)
    local e = edges[edgeId]
    return e and capOf(e) or 0
  end

  -- Lease a lane on an edge. Grants (or renews) while holders < capacity, so a
  -- highway/trunk/hole carries several devices at once; a crawl/standard is single-track.
  function self.lease(edgeId, device, ttl)
    local e = edges[edgeId]
    if not e then return false end
    local t = now()
    local L = leases[edgeId] or {}
    leases[edgeId] = L
    if L[device] and L[device] > t then L[device] = t + (ttl or 30); return true end
    if holders(edgeId, t) >= capOf(e) then return false end
    L[device] = t + (ttl or 30)
    return true
  end
  -- Current lease holders (device ids) on an edge.
  function self.leased(edgeId)
    local t, out, L = now(), {}, leases[edgeId]
    if L then for d, u in pairs(L) do if u > t then out[#out + 1] = d end end end
    return out
  end
  function self.freeLanes(edgeId)
    local e = edges[edgeId]
    if not e then return 0 end
    return capOf(e) - holders(edgeId, now())
  end
  function self.release(edgeId, device)
    local L = leases[edgeId]
    if not L then return end
    if device then L[device] = nil else leases[edgeId] = nil end
  end

  -- --- persistence / wire --------------------------------------------------

  function self.pack()
    local parts = { string.pack("<I2I2", nextNode, nextEdge) }
    local nc, ec = 0, 0
    for _ in pairs(nodes) do nc = nc + 1 end
    for _ in pairs(edges) do ec = ec + 1 end
    parts[#parts + 1] = string.pack("<I2I2", nc, ec)
    for id, nd in pairs(nodes) do
      parts[#parts + 1] = string.pack(NODE_FMT, id, nd.kind, nd.x, nd.y, nd.z, nd.flags, nd.addr or 0)
      parts[#parts + 1] = string.pack("<s2", nd.label or "")
    end
    for id, e in pairs(edges) do
      parts[#parts + 1] = string.pack("<I2", id)
        .. string.pack(EDGE_FMT, e.a, e.b, e.mode, e.cost, e.trav, e.fails, e.lastOk, e.flags,
          e.ttype or TTYPE.STANDARD)
    end
    return table.concat(parts)
  end

  function self.unpack(blob)
    nodes, edges, adj, leases = {}, {}, {}, {}
    local nn, ne, pos = string.unpack("<I2I2", blob)
    nextNode, nextEdge = nn, ne
    local nc, ec
    nc, ec, pos = string.unpack("<I2I2", blob, pos)
    for _ = 1, nc do
      local id, kind, x, y, z, flags, addr
      id, kind, x, y, z, flags, addr, pos = string.unpack(NODE_FMT, blob, pos)
      local label
      label, pos = string.unpack("<s2", blob, pos)
      nodes[id] = { id = id, kind = kind, x = x, y = y, z = z, flags = flags,
        addr = addr, label = (#label > 0) and label or nil }
    end
    for _ = 1, ec do
      local id
      id, pos = string.unpack("<I2", blob, pos)
      local a, b, mode, cost, trav, fails, lastOk, flags, ttype
      a, b, mode, cost, trav, fails, lastOk, flags, ttype, pos = string.unpack(EDGE_FMT, blob, pos)
      edges[id] = { a = a, b = b, mode = mode, cost = cost, trav = trav,
        fails = fails, lastOk = lastOk, flags = flags, ttype = ttype }
      addAdj(id, edges[id])
    end
  end

  function self.save()
    if st and path then st.saveRaw(path, self.pack()) end
  end
  function self.load()
    if st and path then
      local blob = st.loadRaw(path)
      if blob then self.unpack(blob) end
    end
    return self
  end

  return self
end

return navgraph
