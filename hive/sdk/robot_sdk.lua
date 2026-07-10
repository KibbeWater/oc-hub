-- robot_sdk.lua: device-side runtime for OpenOS robot role firmware.
-- Same shape as drone_sdk (join -> idle <-> work, heartbeats, command dispatch,
-- energy dock, universal-frame triangulation) but for grounded robots: motion is
-- blocking one-block steps through navcore, plus dig/place helpers. Block-breaking
-- is gated by the queen's authorization grant (mode + area incl. the mining
-- Y-range), enforced even on navcore's own path-clearing digs. I/O is injected so
-- the miner role runs in the simulator; mainFromComponents wires the real robot API.
-- Install to /usr/lib/hive/sdk/robot_sdk.lua.

local hxnet = require("hxnet")
local navcore = require("navcore")

local sdk = {}

-- Task codec (queen ASSIGN <-> robot). type 3 = mine_slab; 4 = mine_vein.
local TASK = { MINE_SLAB = 3, MINE_VEIN = 4 }
sdk.TASK = TASK

function sdk.encodeTask(t)
  local p = t.params or t
  if t.type == "mine_slab" then
    return string.pack("<Bi2i2i2i2i2i2", TASK.MINE_SLAB, p.x1, p.y1, p.z1, p.x2, p.y2, p.z2)
  elseif t.type == "mine_vein" then
    local s = p.seedPos or p
    return string.pack("<Bi2i2i2", TASK.MINE_VEIN, s.x, s.y, s.z)
  end
  return string.pack("<B", 0)
end

local function decodeTask(payload)
  local tt = string.unpack("<B", payload)
  if tt == TASK.MINE_SLAB then
    local _, x1, y1, z1, x2, y2, z2 = string.unpack("<Bi2i2i2i2i2i2", payload)
    return { type = "mine_slab", x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2 }, 13
  elseif tt == TASK.MINE_VEIN then
    local _, x, y, z = string.unpack("<Bi2i2i2", payload)
    return { type = "mine_vein", x = x, y = y, z = z }, 7
  end
  return nil, 1
end

function sdk.main(role, ctx)
  local node = hxnet.new{ id = ctx.id, key = ctx.key, hmac = ctx.hmac, now = ctx.now, send = ctx.send }
  local queen = ctx.queen or { x = 0, y = 64, z = 0 }
  local state = { task = nil, aborted = false, reboot = false, otaVer = nil,
    lastHB = 0, hbInterval = 10, runState = hxnet.STATE.BOOT, joined = false, routeId = 0,
    grant = nil, offset = { x = 0, y = 0, z = 0 }, lastCal = 0 }

  local function pos()
    local x, y, z = ctx.navPos()
    if not x then return nil end
    return x + state.offset.x, y + state.offset.y, z + state.offset.z
  end

  local function sendEvt(sub, detail)
    node:cast(hxnet.QUEEN, hxnet.T.EVT, hxnet.pack.evt(0, sub, 0, detail or ""), { ttl = 3 })
  end

  -- authorization: block-breaking needs DESTRUCTION mode + a target inside the
  -- granted bbox (including its Y-range). Enforced for both role digs and the
  -- navcore path-clearing digs.
  local function inArea(a, x, z)
    return x >= math.min(a.x1, a.x2) and x <= math.max(a.x1, a.x2)
      and z >= math.min(a.z1, a.z2) and z <= math.max(a.z1, a.z2)
  end
  local function canOperate(x, z)
    local g = state.grant
    if not g then return false end
    if g.expiry and ctx.now() > g.expiry then return false end
    return inArea(g.area, x, z)
  end
  local function canDig(x, y, z)
    local g = state.grant
    if not g or g.mode ~= hxnet.MODE.DESTRUCTION or not canOperate(x, z) then return false end
    return y >= math.min(g.area.y1, g.area.y2) and y <= math.max(g.area.y1, g.area.y2)
  end
  local function enforcedDig(dx, dy, dz)
    local x, y, z = pos()
    if not x or not canDig(x + dx, y + dy, z + dz) then
      sendEvt(hxnet.EVT.UNAUTH, string.pack("<i2i2i2", (x or 0) + dx, (y or 0) + dy, (z or 0) + dz))
      return false
    end
    return ctx.dig and ctx.dig(dx, dy, dz)
  end

  local nav = navcore.new{ kind = "robot", io = {
    pos = pos, moveStep = ctx.moveStep, dig = enforcedDig, detect = ctx.detect,
    energy = ctx.energy, now = ctx.now, report = function(sc) sendEvt(sc) end } }

  local function pumpOnce(timeout)
    local ev = { ctx.pull(timeout or 0) }
    if ev[1] == "modem_message" then node:submit(ev[3], ev[5] or 0, ev[6]) end
    return ev[1]
  end

  local function heartbeat(force)
    local t = ctx.now()
    if force or (t - state.lastHB) >= state.hbInterval then
      local x, y, z = pos()
      node:cast(hxnet.QUEEN, hxnet.T.TELEM,
        hxnet.pack.telem(x or 0, y or 0, z or 0, math.floor((ctx.energy() or 0) * 100),
          state.runState, ctx.fw or 0, ctx.role or 3), { ttl = 3 })
      state.lastHB = t
    end
  end

  local function calibrate()
    if not ctx.findWaypoints then return end
    local x, y, z = ctx.navPos()
    if not x then return end
    local sights = ctx.findWaypoints()
    if sights and #sights > 0 then
      sendEvt(hxnet.EVT.CALIB, hxnet.pack.calib({ x = x, y = y, z = z }, sights))
    end
    state.lastCal = ctx.now()
  end

  -- --- api -----------------------------------------------------------------

  local api = {}
  function api.pos() return pos() end
  function api.energy() return ctx.energy() end
  function api.task() return state.task end
  function api.aborted() return state.aborted end
  function api.home() return ctx.home end
  function api.grant() return state.grant end
  function api.canOperate(x, z) return canOperate(x, z) end
  function api.canDig(x, y, z) return canDig(x, y, z) end
  function api.sleep(sec) pumpOnce(sec) end
  function api.status(l1, l2) if ctx.log then ctx.log((l1 or "") .. " " .. (l2 or "")) end end
  function api.report(pct, note) state.runState = hxnet.STATE.WORKING; heartbeat(true) end
  function api.step(dx, dy, dz) return ctx.moveStep(dx, dy, dz) end
  function api.dig(dx, dy, dz) return enforcedDig(dx, dy, dz) end
  function api.detect(dx, dy, dz) return ctx.detect and ctx.detect(dx, dy, dz) end
  function api.place(dx, dy, dz, slot) return ctx.place and ctx.place(dx, dy, dz, slot) end
  function api.reportCorridor(seg) sendEvt(hxnet.EVT.CORRIDOR_ADD, seg) end

  function api.stepTo(tx, ty, tz, digOk)
    state.routeId = (state.routeId + 1) % 65536
    local ok = nav.setRoute(state.routeId, { { op = 6, x = tx, y = ty, z = tz } })
    if not ok then return false end
    if digOk then nav.setDigAllowed(true) end
    while true do
      pumpOnce(0)
      if state.aborted then nav.cancel(); return false, "aborted" end
      local st = nav.tick()
      heartbeat()
      if st == "arrived" then return true end
      if st == "blocked" then return false, "blocked" end
    end
  end

  function api.dock()
    local h = ctx.home or queen
    state.runState = hxnet.STATE.DOCKING
    if h then api.stepTo(h.x, h.y, h.z, false) end
    if ctx.charge then ctx.charge() end -- sim refill; in-game the charger block does it
  end

  -- --- command dispatch ----------------------------------------------------

  local function setGrant(mode, area, ttl)
    state.grant = { mode = mode, area = area, expiry = (ttl and ttl > 0) and (ctx.now() + ttl) or nil }
  end
  local function dispatch(op, payload)
    if op == hxnet.CMD.ASSIGN then
      local task, n = decodeTask(payload)
      state.task = task
      if task and #payload > n then setGrant(hxnet.parse.grant(payload:sub(n + 1))) end
    elseif op == hxnet.CMD.GRANT then
      setGrant(hxnet.parse.grant(payload))
    elseif op == hxnet.CMD.CALIB then
      state.offset = hxnet.parse.caloff(payload)
    elseif op == hxnet.CMD.RECALL or op == hxnet.CMD.ABORT then
      state.aborted = true
    elseif op == hxnet.CMD.REBOOT then
      state.reboot = true; state.aborted = true
    end
  end

  node:on(hxnet.T.WELCOME, function(f)
    local nonce, dev, latestFw, qx, qy, qz = hxnet.parse.welcome(f.body)
    if ctx.nonce and nonce ~= ctx.nonce then return end
    queen = { x = qx, y = qy, z = qz }
    state.joined = true
    if latestFw and latestFw > (ctx.fw or 0) then state.otaVer = latestFw end
  end)
  node:on(hxnet.T.CMD, function(f) dispatch(hxnet.parse.cmd(f.body)) end)
  node:on(hxnet.T.FW_ANNOUNCE, function(f)
    local r, ver = hxnet.parse.announce(f.body)
    if r == ctx.role and ver > (ctx.fw or 0) then state.otaVer = ver end
  end)

  -- --- join + main loop ----------------------------------------------------

  if ctx.joined then
    state.joined = true
  else
    node:cast(hxnet.QUEEN, hxnet.T.HELLO, hxnet.pack.hello(ctx.nonce or "hxrobot0", ctx.role or 3, ctx.fw or 0), { ttl = 5 })
    local tries = 0
    while not state.joined and tries < 40 do pumpOnce(0.25); tries = tries + 1 end
  end
  state.runState = hxnet.STATE.IDLE
  calibrate()
  if role.onInit then role.onInit(api) end

  local LOW = 0.30
  local guard = 0
  while not state.reboot do
    guard = guard + 1
    if ctx.maxSteps and guard > ctx.maxSteps then break end
    pumpOnce(0.2)
    heartbeat()
    if ctx.findWaypoints and (ctx.now() - state.lastCal) >= 120 then calibrate() end
    local e = ctx.energy() or 1
    if state.otaVer and not state.task then
      if ctx.reboot then ctx.reboot() end
      break
    elseif state.task and e >= LOW then
      state.aborted = false
      state.runState = hxnet.STATE.WORKING
      local ok, detail = role.onTask(api, state.task)
      state.task = nil
      state.runState = hxnet.STATE.IDLE
      if ok == "done" or ok == true then sendEvt(hxnet.EVT.DONE)
      else sendEvt(hxnet.EVT.FAILED, tostring(detail or "")) end
    elseif e < LOW then
      state.task = nil
      if role.onLowEnergy then role.onLowEnergy(api) else api.dock() end
    elseif role.onIdle then
      role.onIdle(api)
    else
      api.sleep(0.5)
    end
  end
  if state.reboot and ctx.reboot then ctx.reboot() end
end

-- In-game entry: build ctx from the OpenOS robot API (facing-aware moveStep).
function sdk.mainFromComponents(role, cfg)
  local component = require("component")
  local computer = require("computer")
  local robot = require("robot")
  local nav = component.navigation
  local modem = component.modem
  local data = component.data
  local port = cfg.port or 4460
  modem.open(port)
  if modem.setStrength then modem.setStrength(400) end

  local facing = 0
  local function faceTo(dx, dz)
    local want = (dx == 1 and 1) or (dx == -1 and 3) or (dz == 1 and 2) or 0
    while facing ~= want do robot.turnRight(); facing = (facing + 1) % 4 end
  end

  local ctx = {
    id = cfg.id, key = cfg.key, role = cfg.role or 3, fw = cfg.fw or 0,
    queen = cfg.queen, home = cfg.home, port = port, nonce = cfg.nonce, joined = cfg.joined,
    hmac = function(m, k) return data.sha256(m, k) end,
    now = function() return computer.uptime() end,
    send = function(wire, to) if to then modem.send(to, port, wire) else modem.broadcast(port, wire) end end,
    pull = function(t) return computer.pullSignal(t) end,
    navPos = function() return nav.getPosition() end,
    findWaypoints = function()
      local out = {}
      for _, w in ipairs(nav.findWaypoints(400) or {}) do
        out[#out + 1] = { key = hxnet.hashAddr(w.address),
          rel = { x = w.position[1], y = w.position[2], z = w.position[3] } }
      end
      return out
    end,
    energy = function() return computer.energy() / computer.maxEnergy() end,
    log = function(s) end,
    reboot = function() computer.shutdown(true) end,
    moveStep = function(dx, dy, dz)
      if dy > 0 then return robot.up() elseif dy < 0 then return robot.down() end
      faceTo(dx, dz); return robot.forward()
    end,
    dig = function(dx, dy, dz)
      if dy > 0 then return robot.swingUp() elseif dy < 0 then return robot.swingDown() end
      faceTo(dx, dz); return robot.swing()
    end,
    detect = function(dx, dy, dz)
      if dy > 0 then local _, n = robot.detectUp(); return n
      elseif dy < 0 then local _, n = robot.detectDown(); return n end
      faceTo(dx, dz); local _, n = robot.detect(); return n
    end,
    place = function(dx, dy, dz) if dy < 0 then return robot.placeDown() else robot.place() end end,
  }
  return sdk.main(role, ctx)
end

return sdk
