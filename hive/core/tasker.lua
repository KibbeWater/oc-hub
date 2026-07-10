-- tasker.lua: the hive work queue.
-- Owns the task schema, decomposition of high-level jobs into device-sized leaves,
-- pull-triggered (queen-decided) assignment, leases, and crash-safe persistence
-- via a snapshot + append-only journal. Pure logic + an injected store/now/log,
-- so it runs unchanged on the queen and on the desktop harness.
-- Install to /usr/lib/hive/core/tasker.lua.

local tasker = {}

local TILE = 16
local DEFAULT_LEASE = 90
local floor = math.floor
local function fdiv(a, b) return floor(a / b) end

-- opts: store (required), dir (state dir), now (-> s), log (fn), idPrefix, lease.
function tasker.new(opts)
  local self = {}
  local st = assert(opts.store, "tasker needs a store")
  local dir = opts.dir or "/var/hive"
  local now = opts.now or function() return 0 end
  local logf = opts.log or function() end
  local idPrefix = opts.idPrefix or "T"
  local leaseSecs = opts.lease or DEFAULT_LEASE
  local snapPath = dir .. "/tasks.snapshot"
  local logPath = dir .. "/tasks.log"
  local journal = st.journal(logPath)

  local tasks = {}   -- id -> task
  local counter = 0

  local function newId()
    counter = counter + 1
    return string.format("%s%05d", idPrefix, counter)
  end

  -- --- decomposition -------------------------------------------------------

  -- A leaf task other roles execute directly. Non-leaf types fan out in expand().
  local LEAF = {
    scan_tile = true, mine_slab = true, mine_vein = true, ferry = true,
    farm_pass = true, craft = true, ["goto"] = true, dock = true, recall = true,
  }

  -- Returns { leafSpec, ... } for a submitted spec. Each leaf carries needs,
  -- params, priority and a startPos used by assignment scoring.
  function self.expand(spec)
    local p = spec.params or {}
    local pr = spec.priority or 5
    if spec.type == "scan_area" then
      local out = {}
      local cx1, cz1 = fdiv(math.min(p.x1, p.x2), TILE), fdiv(math.min(p.z1, p.z2), TILE)
      local cx2, cz2 = fdiv(math.max(p.x1, p.x2), TILE), fdiv(math.max(p.z1, p.z2), TILE)
      for cx = cx1, cx2 do
        for cz = cz1, cz2 do
          out[#out + 1] = {
            type = "scan_tile", needs = { "scan" }, priority = pr,
            params = { cx = cx, cz = cz },
            startPos = { x = cx * TILE + 8, y = 128, z = cz * TILE + 8 },
          }
        end
      end
      return out
    elseif spec.type == "mine_region" then
      local out = {}
      local xs, xe = math.min(p.x1, p.x2), math.max(p.x1, p.x2)
      local ys, ye = math.min(p.y1, p.y2), math.max(p.y1, p.y2)
      local zs, ze = math.min(p.z1, p.z2), math.max(p.z1, p.z2)
      -- top-down 3-high slabs, 16x16 footprint.
      local yTop = ye
      while yTop >= ys do
        local yBot = math.max(ys, yTop - 2)
        for bx = xs, xe, 16 do
          for bz = zs, ze, 16 do
            local x2 = math.min(xe, bx + 15)
            local z2 = math.min(ze, bz + 15)
            -- checkerboard order key: even-parity footprints run first.
            local parity = (fdiv(bx, 16) + fdiv(bz, 16)) % 2
            out[#out + 1] = {
              type = "mine_slab", needs = { "mine" }, priority = pr,
              params = { x1 = bx, y1 = yBot, z1 = bz, x2 = x2, y2 = yTop, z2 = z2, parity = parity },
              startPos = { x = bx, y = yTop, z = bz },
            }
          end
        end
        yTop = yBot - 1
      end
      return out
    else
      -- leaf or unknown-but-leaf: pass through with a startPos guess.
      local sp = spec.startPos
      if not sp then
        if p.seedPos then sp = p.seedPos
        elseif p.x then sp = { x = p.x, y = p.y or 128, z = p.z } end
      end
      local leaf = {
        type = spec.type, needs = spec.needs or {}, priority = pr,
        params = p, startPos = sp, recur = spec.recur,
      }
      return { leaf }
    end
  end

  -- --- persistence ---------------------------------------------------------

  local function record(op) journal.append(op) end

  local function add(task)
    tasks[task.id] = task
    record({ op = "add", task = task })
  end

  local function setState(task, state, extra)
    task.state = state
    if extra then for k, v in pairs(extra) do task[k] = v end end
    record({ op = "state", id = task.id, state = state,
      assignee = task.assignee, lease = task.lease, attempts = task.attempts,
      result = task.result })
  end

  -- --- public API ----------------------------------------------------------

  -- Submit a high-level job. Returns the list of created leaf tasks.
  function self.submit(spec)
    local leaves = self.expand(spec)
    local created = {}
    local parentId = (#leaves > 1) and newId() or nil
    if parentId then
      tasks[parentId] = { id = parentId, type = spec.type, state = "queued",
        priority = spec.priority or 5, params = spec.params, children = {}, created = now() }
      record({ op = "add", task = tasks[parentId] })
    end
    for _, leaf in ipairs(leaves) do
      local task = {
        id = newId(), type = leaf.type, state = "queued",
        priority = leaf.priority or 5, needs = leaf.needs or {},
        params = leaf.params or {}, startPos = leaf.startPos, parent = parentId,
        assignee = nil, lease = nil, attempts = 0, maxAttempts = 3,
        progress = { pct = 0 }, created = now(), recur = leaf.recur,
      }
      add(task)
      if parentId then tasks[parentId].children[#tasks[parentId].children + 1] = task.id end
      created[#created + 1] = task
    end
    return created, parentId
  end

  local function capsSatisfy(caps, needs)
    local set = {}
    for _, c in ipairs(caps or {}) do set[c] = true end
    for _, n in ipairs(needs or {}) do
      if not set[n] then return false end
    end
    return true
  end

  local function dist(a, b)
    if not a or not b then return 0 end
    local dx, dy, dz = a.x - b.x, (a.y or 0) - (b.y or 0), a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
  end

  -- Pick the best queued task for a device and assign it. device = {id, caps, pos, energy}.
  -- Returns the task or nil. energyEst(task, device) may veto (return nil) or bias.
  function self.assignTo(device, energyEst)
    local best, bestScore
    for _, t in pairs(tasks) do
      if t.state == "queued" and capsSatisfy(device.caps, t.needs) then
        local ok = true
        local penalty = 0
        if energyEst then
          local est = energyEst(t, device)
          if est == nil then ok = false else penalty = est end
        end
        if ok then
          local score = t.priority * 1000 - dist(device.pos, t.startPos) - penalty
          if not bestScore or score > bestScore then best, bestScore = t, score end
        end
      end
    end
    if not best then return nil end
    setState(best, "assigned", { assignee = device.id, lease = now() + leaseSecs })
    logf("assign %s -> %s", best.id, tostring(device.id))
    return best
  end

  -- Device reported progress; renews the lease and flips assigned->active.
  function self.report(id, progress)
    local t = tasks[id]
    if not t then return end
    t.progress = progress or t.progress
    t.lease = now() + leaseSecs
    if t.state == "assigned" then t.state = "active" end
    record({ op = "progress", id = id, progress = t.progress, lease = t.lease, state = t.state })
  end

  local function maybeCompleteParent(t)
    if not t.parent then return end
    local parent = tasks[t.parent]
    if not parent then return end
    for _, cid in ipairs(parent.children) do
      local c = tasks[cid]
      if c and c.state ~= "done" and c.state ~= "cancelled" then return end
    end
    setState(parent, "done", { finished = now() })
  end

  function self.complete(id, result)
    local t = tasks[id]
    if not t then return end
    setState(t, "done", { result = result, finished = now() })
    if t.recur and t.recur.every then
      -- Re-queue a fresh instance after the interval (recurring farm passes).
      local spec = { type = t.type, priority = t.priority, needs = t.needs,
        params = t.params, startPos = t.startPos, recur = t.recur }
      spec.params = spec.params or {}
      spec.params._notBefore = now() + t.recur.every
      self.submit(spec)
    end
    maybeCompleteParent(t)
  end

  function self.fail(id, err)
    local t = tasks[id]
    if not t then return end
    setState(t, "failed", { result = err, finished = now() })
    logf("task %s failed: %s", id, tostring(err))
  end

  function self.cancel(id)
    local t = tasks[id]
    if not t then return end
    setState(t, "cancelled", { finished = now() })
  end

  function self.block(id, detail)
    local t = tasks[id]
    if not t then return end
    setState(t, "blocked", { result = detail })
  end

  local function requeue(t, reason)
    t.attempts = (t.attempts or 0) + 1
    if t.attempts >= (t.maxAttempts or 3) then
      setState(t, "failed", { result = reason or "max attempts", finished = now() })
      logf("task %s failed after %d attempts", t.id, t.attempts)
    else
      -- Clear directly: nil-valued fields in a table literal would be dropped.
      t.assignee = nil
      t.lease = nil
      setState(t, "queued")
      logf("task %s requeued (%s)", t.id, tostring(reason))
    end
  end

  -- Requeue everything an offline/lost device was holding.
  function self.onLost(deviceId)
    for _, t in pairs(tasks) do
      if t.assignee == deviceId and (t.state == "assigned" or t.state == "active" or t.state == "blocked") then
        requeue(t, "device lost")
      end
    end
  end

  -- Periodic maintenance: expire stale leases; release _notBefore holds.
  function self.sweep()
    local t0 = now()
    for _, t in pairs(tasks) do
      if (t.state == "assigned" or t.state == "active") and t.lease and t0 > t.lease then
        requeue(t, "lease expired")
      end
    end
  end

  function self.get(id) return tasks[id] end
  function self.all() return tasks end
  function self.byState(state)
    local out = {}
    for _, t in pairs(tasks) do
      if t.state == state then out[#out + 1] = t end
    end
    return out
  end
  function self.queued() return self.byState("queued") end
  function self.counter() return counter end

  -- --- recovery ------------------------------------------------------------

  -- Load snapshot + replay the journal on top. Assigned/active tasks revert to
  -- queued (their holder must re-claim by beaconing the taskId).
  function self.load()
    local snap = st.load(snapPath, { tasks = {}, counter = 0 })
    tasks = snap.tasks or {}
    counter = snap.counter or 0
    journal.replay(function(rec)
      if rec.op == "add" then
        tasks[rec.task.id] = rec.task
        local nsuffix = tonumber(rec.task.id:match("(%d+)$"))
        if nsuffix and nsuffix > counter then counter = nsuffix end
      elseif rec.op == "state" then
        local t = tasks[rec.id]
        if t then
          t.state = rec.state
          t.assignee = rec.assignee
          t.lease = rec.lease
          t.attempts = rec.attempts
          t.result = rec.result
        end
      elseif rec.op == "progress" then
        local t = tasks[rec.id]
        if t then t.progress = rec.progress; t.lease = rec.lease; t.state = rec.state end
      end
    end)
    for _, t in pairs(tasks) do
      if t.state == "assigned" or t.state == "active" or t.state == "blocked" then
        t.state = "queued"
        t.assignee = nil
        t.lease = nil
      end
    end
    return self
  end

  -- Fold the journal into a fresh snapshot and truncate the log.
  function self.checkpoint()
    st.saveAtomic(snapPath, { tasks = tasks, counter = counter })
    journal.truncate()
  end

  function self.journalSize() return journal.size() end

  return self
end

return tasker
