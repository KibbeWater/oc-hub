-- poi.lua: points of interest + charger reservations.
-- Tracks chargers, depots, docks and fields (populated by hived survey / dashboard),
-- and arbitrates charger access: one occupant per charger with a FIFO queue and
-- low-energy priority, so many drones don't pile onto the same charge box. Pure
-- Lua + injected store/now. Install to /usr/lib/hive/core/poi.lua.

local poi = {}

-- opts: store, path, now.
function poi.new(opts)
  opts = opts or {}
  local self = {}
  local st = opts.store
  local path = opts.path or "/var/hive/poi.db"
  local now = opts.now or function() return 0 end
  local ARRIVE_TTL = opts.arriveTtl or 120

  local items = {}   -- id -> poi
  local nextId = 1
  local dirty = false

  local function dist(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.x - b.x, (a.y or 0) - (b.y or 0), a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
  end

  function self.add(p)
    -- de-dup by label if provided
    if p.label then
      for _, e in pairs(items) do
        if e.label == p.label then
          e.pos, e.kind, e.meta = p.pos, p.kind, p.meta or e.meta
          dirty = true
          return e.id
        end
      end
    end
    local id = "poi:" .. nextId
    nextId = nextId + 1
    items[id] = { id = id, kind = p.kind, pos = p.pos, label = p.label, meta = p.meta or {},
      active = p.active ~= false, occupant = nil, queue = {} }
    dirty = true
    return id
  end

  function self.get(id) return items[id] end
  function self.remove(id) items[id] = nil; dirty = true end
  function self.all() return items end

  function self.list(kind)
    local out = {}
    for _, e in pairs(items) do
      if not kind or e.kind == kind then out[#out + 1] = e end
    end
    return out
  end

  function self.nearest(kind, pos, requireActive)
    local best, bestD
    for _, e in pairs(items) do
      if e.kind == kind and (not requireActive or e.active) then
        local d = dist(e.pos, pos)
        if not bestD or d < bestD then best, bestD = e, d end
      end
    end
    return best, bestD
  end

  -- Redstone-derived liveness from a re-survey (unpowered charger -> inactive).
  function self.setActive(id, active)
    local e = items[id]
    if e then e.active = active; dirty = true end
  end

  -- --- charger reservations ------------------------------------------------

  -- Request the nearest active charger of a kind. Returns chargerId, granted(bool).
  -- If the charger is busy the device is queued (low energy first); granted=false
  -- means "wait, you're in the queue".
  function self.reserveCharger(deviceId, kind, nearPos, energy)
    local charger = self.nearest(kind, nearPos, true)
    if not charger then return nil, false end
    if charger.occupant == deviceId then
      charger.grantedAt = now()
      return charger.id, true
    end
    if not charger.occupant then
      charger.occupant = deviceId
      charger.grantedAt = now()
      dirty = true
      return charger.id, true
    end
    -- enqueue (skip if already queued), sorted by energy ascending on read
    local queued = false
    for _, q in ipairs(charger.queue) do if q.id == deviceId then queued = true end end
    if not queued then
      charger.queue[#charger.queue + 1] = { id = deviceId, energy = energy or 1, at = now() }
      dirty = true
    end
    return charger.id, false
  end

  function self.releaseCharger(chargerId, deviceId)
    local c = items[chargerId]
    if not c then return end
    if c.occupant == deviceId or not deviceId then
      c.occupant = nil
      c.grantedAt = nil
      -- promote the lowest-energy waiter
      if #c.queue > 0 then
        table.sort(c.queue, function(a, b) return a.energy < b.energy end)
        local nextDev = table.remove(c.queue, 1)
        c.occupant = nextDev.id
        c.grantedAt = now()
      end
      dirty = true
    end
  end

  -- Reclaim a grant if the device never arrived within ARRIVE_TTL.
  function self.sweepChargers()
    local t = now()
    for _, c in pairs(items) do
      if c.occupant and c.grantedAt and (t - c.grantedAt) > ARRIVE_TTL and c.arrived ~= true then
        self.releaseCharger(c.id, c.occupant)
      end
    end
  end

  function self.markArrived(chargerId, deviceId)
    local c = items[chargerId]
    if c and c.occupant == deviceId then c.arrived = true end
  end

  function self.queueDepth(chargerId)
    local c = items[chargerId]
    return c and #c.queue or 0
  end

  -- --- persistence ---------------------------------------------------------

  function self.load()
    if not st then return self end
    local saved = st.load(path, { items = {}, nextId = 1 })
    items = saved.items or {}
    nextId = saved.nextId or 1
    -- reservations are runtime-only; clear on load
    for _, e in pairs(items) do e.occupant = nil; e.queue = {}; e.arrived = nil end
    return self
  end

  function self.save()
    if st and dirty then
      st.saveAtomic(path, { items = items, nextId = nextId })
      dirty = false
    end
  end

  return self
end

return poi
