-- registry.lua: the hive fleet registry.
-- One record per device (role, kind, position, energy, state, firmware version,
-- last-heard time, coverage anchor, capabilities). Fed by joins/telemetry, read
-- by the dashboard and the task assigner. Persisted via store; change callbacks
-- let the GUI refresh. Install to /usr/lib/hive/core/registry.lua.

local registry = {}

-- opts: store, path, now, log, staleAfter (s), lostAfter (s).
function registry.new(opts)
  opts = opts or {}
  local self = {}
  local st = opts.store
  local path = opts.path or "/var/hive/fleet.db"
  local now = opts.now or function() return 0 end
  local logf = opts.log
  local staleAfter = opts.staleAfter or 30
  local lostAfter = opts.lostAfter or 60

  local devices = {}      -- id -> record
  local dirty = false
  local listeners = {}

  local function notify(id)
    dirty = true
    for _, fn in ipairs(listeners) do fn(id, devices[id]) end
  end

  function self.onChange(fn) listeners[#listeners + 1] = fn end

  function self.all() return devices end
  function self.get(id) return devices[id] end
  function self.count()
    local n, online = 0, 0
    for _, d in pairs(devices) do
      n = n + 1
      if d.state ~= "offline" and d.state ~= "lost" then online = online + 1 end
    end
    return n, online
  end

  -- Register or update a device from a join. caps/role/kind set once at join.
  function self.join(id, info)
    local d = devices[id] or { id = id, state = "idle", first = now() }
    d.role = info.role or d.role
    d.kind = info.kind or d.kind
    d.caps = info.caps or d.caps or {}
    d.fw = info.fw or d.fw
    d.home = info.home or d.home
    d.lastSeen = now()
    if d.state == "offline" or d.state == "lost" then d.state = "idle" end
    devices[id] = d
    if logf then logf("device %s joined (%s/%s)", tostring(id), d.role or "?", d.kind or "?") end
    notify(id)
    return d
  end

  -- Fold a telemetry beacon into the record.
  function self.upsertBeacon(id, b)
    local d = devices[id]
    if not d then d = self.join(id, { role = b.role, kind = b.kind }) end
    if b.pos then d.pos = b.pos; d.lastCoverage = b.pos end
    if b.energy ~= nil then d.energy = b.energy end
    if b.state then d.state = b.state end
    if b.fw then d.fw = b.fw end
    if b.taskId ~= nil then d.taskId = b.taskId end
    d.lastSeen = now()
    notify(id)
    return d
  end

  function self.setState(id, s)
    local d = devices[id]
    if d and d.state ~= s then d.state = s; notify(id) end
  end

  function self.setTask(id, taskId)
    local d = devices[id]
    if d then d.taskId = taskId; notify(id) end
  end

  function self.lastCoveragePos(id)
    local d = devices[id]
    return d and (d.lastCoverage or d.pos) or nil
  end

  function self.forget(id)
    devices[id] = nil
    notify(id)
  end

  -- Age out silent devices. Returns a list of ids that transitioned to lost, so
  -- the caller can requeue their tasks.
  function self.sweep()
    local t = now()
    local lost = {}
    for id, d in pairs(devices) do
      local silent = t - (d.lastSeen or 0)
      if silent > lostAfter and d.state ~= "lost" and d.state ~= "offline" then
        d.state = "lost"
        notify(id)
        lost[#lost + 1] = id
        if logf then logf("device %s lost (silent %ds)", tostring(id), math.floor(silent)) end
      elseif silent > staleAfter and d.state ~= "lost" and d.state ~= "offline" then
        d.stale = true
      else
        d.stale = false
      end
    end
    return lost
  end

  -- --- persistence ---------------------------------------------------------

  function self.load()
    if not st then return self end
    local saved = st.load(path, { devices = {} })
    devices = saved.devices or {}
    -- everything starts offline until it beacons again
    for _, d in pairs(devices) do d.state = "offline"; d.stale = false end
    return self
  end

  function self.save()
    if st and dirty then
      st.saveAtomic(path, { devices = devices })
      dirty = false
    end
  end

  function self.dirty() return dirty end

  return self
end

return registry
