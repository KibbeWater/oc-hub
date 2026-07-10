-- drone_sdk.lua: the device-side runtime for drone role firmware.
-- Provides hive.main(role, ctx): the outer state machine (join -> idle <-> work),
-- heartbeats, command dispatch, watchdog-safe pacing, and the api helpers roles
-- call (goTo/scanColumn/report/status/sleep/aborted). All I/O is injected via ctx
-- so the same code runs in the netboot sandbox and in the desktop simulator.
-- Bundled into every drone image; install source to /usr/lib/hive/sdk/drone_sdk.lua.
--
-- ctx fields:
--   id, key, hmac(msg,key), now()->s, send(wire,to), pull(timeout)->signal tuple,
--   queen {x,y,z}, port, fw, role (numeric), nonce, home {x,y,z},
--   navPos()->x,y,z | nil, droneMove(dx,dy,dz), droneOffset()->n,
--   geoScan(rx,rz,ry,w,d,h)->{hardness...}, energy()->0..1,
--   setStatus(l1,l2) [opt], setLight(rgb) [opt], reboot() [opt],
--   suckBelow()/dropBelow() [courier, opt].

local hxnet = require("hxnet")
local navcore = require("navcore")
local worldscan = require("worldscan")

local sdk = {}

-- Task payload codec (queen ASSIGN <-> device). Keep tiny -- no serialization lib
-- on a drone. type 1 = scan_tile{cx,cz}; type 2 = ferry{fx,fz,tx,tz}.
local TASK = { SCAN_TILE = 1, FERRY = 2 }
sdk.TASK = TASK

function sdk.encodeTask(t)
  local p = t.params or t
  if t.type == "scan_tile" then
    return string.pack("<Bi2i2", TASK.SCAN_TILE, t.cx or p.cx, t.cz or p.cz)
  elseif t.type == "ferry" then
    local f, to = p.from, p.to
    return string.pack("<Bi2i2i2i2i2i2I2", TASK.FERRY, f.x, f.y, f.z, to.x, to.y, to.z, p.count or 64)
  end
  return string.pack("<B", 0)
end

-- Returns task, bytesConsumed (so an appended grant can be split off).
local function decodeTask(payload)
  local tt = string.unpack("<B", payload)
  if tt == TASK.SCAN_TILE then
    local _, cx, cz = string.unpack("<Bi2i2", payload)
    return { type = "scan_tile", cx = cx, cz = cz }, 5
  elseif tt == TASK.FERRY then
    local _, fx, fy, fz, tx, ty, tz, count = string.unpack("<Bi2i2i2i2i2i2I2", payload)
    return { type = "ferry", from = { x = fx, y = fy, z = fz }, to = { x = tx, y = ty, z = tz },
      count = count }, 15
  end
  return nil, 1
end

local floor = math.floor

function sdk.main(role, ctx)
  local node = hxnet.new{ id = ctx.id, key = ctx.key, hmac = ctx.hmac, now = ctx.now, send = ctx.send }
  local queen = ctx.queen or { x = 0, y = 64, z = 0 }
  local state = { task = nil, aborted = false, recall = false, reboot = false,
    otaVer = nil, lastHB = 0, hbInterval = 10, runState = hxnet.STATE.BOOT,
    latestFw = ctx.fw or 0, joined = false, routeId = 0,
    offset = { x = 0, y = 0, z = 0 }, lastCal = 0 }

  -- Position in the swarm's UNIVERSAL frame = raw nav fix + triangulated offset.
  -- Deltas are frame-invariant, so navcore can move in the device frame while we
  -- reason in universal coordinates.
  local function pos()
    local x, y, z = ctx.navPos()
    if not x then return nil end
    return x + state.offset.x, y + state.offset.y, z + state.offset.z
  end

  local function sendEvt(sub, detail)
    node:cast(hxnet.QUEEN, hxnet.T.EVT, hxnet.pack.evt(0, sub, 0, detail or ""), { ttl = 3 })
  end

  -- Ask the queen to solve our universal-frame offset from the waypoints we see.
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

  local nav = navcore.new{ kind = "drone", io = {
    pos = pos, move = ctx.droneMove, offset = ctx.droneOffset,
    energy = ctx.energy, now = ctx.now,
    report = function(sc) sendEvt(sc) end,
    status = ctx.setStatus,
  } }

  -- --- message pump --------------------------------------------------------

  local function pumpOnce(timeout)
    local ev = { ctx.pull(timeout or 0) }
    if ev[1] == "modem_message" then
      -- (name, localAddr, remoteAddr, port, distance, message)
      node:submit(ev[3], ev[5] or 0, ev[6])
    end
    if node.coverage:best() then state.everCov = true end -- latch: had coverage once
    -- Announce crossing the coverage boundary (best-effort). We do NOT force a
    -- return on loss -- the device keeps working and returns only when it needs to.
    if state.everCov then
      local inside = not node.coverage:isLost(ctx.now(), 15)
      if state.inCov == nil then state.inCov = inside end
      if state.inCov and not inside then
        local x, y, z = pos()
        sendEvt(hxnet.EVT.DEPART, string.pack("<i2i2i2", x or 0, y or 0, z or 0))
        state.inCov = false
      elseif not state.inCov and inside then
        sendEvt(hxnet.EVT.RETURN)
        state.inCov = true
      end
    end
    return ev[1]
  end

  local function heartbeat(force)
    local t = ctx.now()
    if force or (t - state.lastHB) >= state.hbInterval then
      local x, y, z = pos()
      node:cast(hxnet.QUEEN, hxnet.T.TELEM,
        hxnet.pack.telem(x or 0, y or 0, z or 0, floor((ctx.energy() or 0) * 100),
          state.runState, ctx.fw or 0, ctx.role or 0), { ttl = 3 })
      state.lastHB = t
    end
  end

  -- --- api -----------------------------------------------------------------

  local api = {}
  function api.pos() return pos() end
  function api.energy() return ctx.energy() end
  function api.task() return state.task end
  function api.aborted() return state.aborted end
  function api.queen() return queen end
  function api.home() return ctx.home end
  function api.sleep(sec) pumpOnce(sec) end
  function api.status(l1, l2)
    if ctx.setStatus then ctx.setStatus(l1 or "", l2 or "") end
  end
  function api.report(pct, note)
    state.runState = hxnet.STATE.WORKING
    heartbeat(true)
  end

  -- Drive navcore to arrival/blocked while pumping messages and pacing the CPU.
  -- Bails early on abort, critical energy, or a prolonged coverage loss (orphan).
  local function runNav()
    while true do
      pumpOnce(0.25)
      if state.aborted then nav.cancel("aborted"); return false, "aborted" end
      if (ctx.energy() or 1) < 0.10 then nav.cancel("critical"); return false, "critical" end
      if state.everCov and node.coverage:isLost(ctx.now(), 60) then
        nav.cancel("orphan"); return false, "orphan"
      end
      local st = nav.tick()
      heartbeat()
      if st == "arrived" then return true end
      if st == "blocked" then return false, "blocked" end
    end
  end

  -- Fly to (x,y,z). opts.cruise sets transit altitude; opts.scanDescend probes
  -- unknown columns on the way down. Returns true | false, reason.
  function api.goTo(tx, ty, tz, opts)
    opts = opts or {}
    local px, py, pz = pos()
    if not px then return false, "no_fix" end
    local cruise = opts.cruise or (math.max(py, ty) + 8)
    state.routeId = (state.routeId + 1) % 65536
    -- leg ops: 1 CLIMB_TO, 2 GOTO, 3 DESCEND_TO (must match routes.OP / navcore)
    local ok, err = nav.setRoute(state.routeId, {
      { op = 1, x = px, y = cruise, z = pz },
      { op = 2, x = tx, y = cruise, z = tz },
      { op = 3, x = tx, y = ty, z = tz, param = opts.scanDescend and 8 or 0 },
    })
    if not ok then return false, err end
    return runNav()
  end

  -- Short same-altitude hop (single GOTO leg) -- used for column-to-column scanning.
  function api.moveTo(tx, ty, tz)
    state.routeId = (state.routeId + 1) % 65536
    local ok, err = nav.setRoute(state.routeId, { { op = 2, x = tx, y = ty, z = tz } })
    if not ok then return false, err end
    return runNav()
  end

  -- Coverage helpers (fed by beacons the node hears).
  function api.coverageLost(secs) return node.coverage:isLost(ctx.now(), secs or 15) end
  function api.coverageAnchor() return node.coverage:anchor() end

  -- Controlled descent to the floor + idle beacon, so a dying drone ends up
  -- findable on the ground instead of free-falling mid-task.
  local function landInPlace()
    local x, y, z = pos()
    if not x then return end
    state.routeId = (state.routeId + 1) % 65536
    nav.setRoute(state.routeId, { { op = 3, x = x, y = 4, z = z, param = 8 } })
    for _ = 1, 40 do
      pumpOnce(0.25)
      local st = nav.tick()
      if st == "arrived" or st == "blocked" then break end
    end
  end

  -- authorization: a grant fixes the operating area + mode. Scanning is allowed
  -- inside any granted area; block-modifying actions would need DESTRUCTION.
  local function inArea(a, x, z)
    return x >= math.min(a.x1, a.x2) and x <= math.max(a.x1, a.x2)
      and z >= math.min(a.z1, a.z2) and z <= math.max(a.z1, a.z2)
  end
  function api.canOperate(x, z)
    local g = state.grant
    if not g then return false end
    if g.expiry and ctx.now() > g.expiry then return false end
    return inArea(g.area, x, z)
  end
  function api.grant() return state.grant end

  -- Scan the column beneath the drone and return a packed uplink record, or nil
  -- if the column is outside the authorized operating area.
  function api.scanColumn()
    local px, py, pz = pos()
    if not px then return nil end -- lost the fix this instant; skip the column
    if state.grant and not api.canOperate(px, pz) then
      sendEvt(hxnet.EVT.UNAUTH, string.pack("<i2i2", px, pz))
      return nil
    end
    local col = ctx.geoScan(0, 0, -32, 1, 1, 64) -- 64 values, yBase = py-32
    local surfaceY, flags, oreY, oreConf = worldscan.reduceColumn(col, (py or 64) - 32, 32)
    return worldscan.packUplink(px, pz, surfaceY, flags, oreY, oreConf)
  end

  function api.uploadScan(batch) if batch and #batch > 0 then sendEvt(hxnet.EVT.SCAN, batch) end end

  -- courier inventory helpers (drone hovers 1 above the target inventory)
  function api.suckBelow() return ctx.suck and ctx.suck() or 0 end
  function api.dropBelow() return ctx.drop and ctx.drop() or 0 end
  function api.invCount() return ctx.invCount and ctx.invCount() or 0 end

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
    elseif op == hxnet.CMD.RECALL then
      state.recall = true; state.aborted = true
    elseif op == hxnet.CMD.ABORT then
      state.aborted = true
    elseif op == hxnet.CMD.REBOOT then
      state.reboot = true; state.aborted = true
    elseif op == hxnet.CMD.LOCATE then
      if ctx.setLight then ctx.setLight(0x00FF88) end
    elseif op == hxnet.CMD.CALIB then
      state.offset = hxnet.parse.caloff(payload) -- universal-frame offset from the queen
    elseif op == hxnet.CMD.NAV_ROUTE then
      nav.setRoute(0, payload) -- queen-planned route blob
    end
  end

  node:on(hxnet.T.WELCOME, function(f)
    -- If the bootloader already joined, ignore stray/rebroadcast welcomes: acting
    -- on them (e.g. an OTA trigger) with no matching HELLO nonce caused reboots.
    if ctx.joined then return end
    local nonce, dev, latestFw, qx, qy, qz = hxnet.parse.welcome(f.body)
    if ctx.nonce and nonce ~= ctx.nonce then return end -- bind to our HELLO
    queen = { x = qx, y = qy, z = qz }
    state.latestFw = latestFw
    state.joined = true
    if latestFw and latestFw > (ctx.fw or 0) then state.otaVer = latestFw end
  end)
  node:on(hxnet.T.CMD, function(f)
    local op, payload = hxnet.parse.cmd(f.body)
    dispatch(op, payload)
  end)
  node:on(hxnet.T.FW_ANNOUNCE, function(f)
    local r, ver = hxnet.parse.announce(f.body)
    if r == ctx.role and ver > (ctx.fw or 0) then state.otaVer = ver end
  end)
  node:on(hxnet.T.PING, function() node:cast(hxnet.QUEEN, hxnet.T.PONG,
    hxnet.pack.pong(ctx.fw or 0, state.runState), { ttl = 3 }) end)

  -- --- join + main loop ----------------------------------------------------

  if ctx.joined then
    -- the bootloader already authenticated + learned the queen; skip re-join
    state.joined = true
  else
    node:cast(hxnet.QUEEN, hxnet.T.HELLO,
      hxnet.pack.hello(ctx.nonce or "hxdrone0", ctx.role or 1, ctx.fw or 0), { ttl = 5 })
    local tries = 0
    while not state.joined and tries < 40 do
      pumpOnce(0.25); tries = tries + 1
    end
  end
  state.runState = hxnet.STATE.IDLE
  calibrate() -- establish the universal-frame offset from visible waypoints
  if role.onInit then pcall(role.onInit, api) end

  local LOW, CRIT = 0.40, 0.10
  local guard = 0
  -- One loop iteration, wrapped so ANY error is reported to the queen and retried
  -- rather than unwinding into a silent boot0 reboot.
  local function tick()
    pumpOnce(0.25)
    heartbeat()
    if ctx.findWaypoints and (ctx.now() - state.lastCal) >= 120 then calibrate() end
    local e = ctx.energy() or 1
    if node.coverage:best() then state.everCov = true end -- latch: had coverage at least once

    if e < CRIT then
      -- critical: stop taking work, land, and idle-beacon so we die findable
      state.runState = hxnet.STATE.LOWPWR
      if ctx.setLight then ctx.setLight(0xFF0000) end
      if not state.landed then state.landed = true; landInPlace() end
      heartbeat(true)
      api.sleep(1)
    elseif state.otaVer and not state.task then
      sendEvt(hxnet.EVT.NAV_FAIL, "ota " .. tostring(ctx.fw) .. "->" .. tostring(state.otaVer))
      state.reboot = true
      return
    elseif state.task and e >= LOW then
      state.aborted = false
      state.runState = hxnet.STATE.WORKING
      -- pcall the role so a bug fails the task (with the error reported) instead
      -- of propagating out and rebooting the whole drone.
      local safe, r, detail = pcall(role.onTask, api, state.task)
      state.task = nil
      state.runState = hxnet.STATE.IDLE
      -- if we drifted out of coverage while working, fly back so the report lands
      if state.everCov and api.coverageLost(15) then
        local a = api.coverageAnchor() or ctx.home
        if a then pcall(api.goTo, a.x, (a.y or 64) + 4, a.z) end
      end
      if not safe then sendEvt(hxnet.EVT.FAILED, tostring(r))
      elseif r == "done" or r == true then sendEvt(hxnet.EVT.DONE)
      else sendEvt(hxnet.EVT.FAILED, tostring(detail or "")) end
      if state.recall then
        state.recall = false; state.aborted = false
        if role.onLowEnergy then pcall(role.onLowEnergy, api) end
      end
    elseif e < LOW then
      -- low battery: drop any task and recharge (role default: dock/home)
      state.task = nil
      state.runState = hxnet.STATE.LOWPWR
      if role.onLowEnergy then pcall(role.onLowEnergy, api) else
        local h = ctx.home
        if h then pcall(api.goTo, h.x, (h.y or 64) + 1, h.z) end -- +1 = inside the charge field
      end
      api.sleep(1)
    elseif role.onIdle then
      pcall(role.onIdle, api)
    else
      api.sleep(0.5)
    end
  end

  while not state.reboot do
    guard = guard + 1
    if ctx.maxSteps and guard > ctx.maxSteps then break end -- sim safety
    local ok, err = pcall(tick)
    if not ok then
      sendEvt(hxnet.EVT.NAV_FAIL, "loop:" .. tostring(err):sub(1, 90))
      pcall(api.sleep, 0.5)
    end
  end
  if state.reboot and ctx.reboot then ctx.reboot() end
end

-- In-game entry point: build ctx from the bare-sandbox globals (component,
-- computer) and the boot0 handoff table _HX, then run. Called by the firmware
-- bundle's entry line. Not used by the desktop harness (which calls main directly).
function sdk.mainFromComponents(role)
  local hx = _HX or {}
  local drone = component.proxy(component.list("drone")())
  local nav = component.proxy(component.list("navigation")())
  local geo = component.list("geolyzer")() and component.proxy(component.list("geolyzer")())
  local modem = component.proxy(component.list("modem")())
  local data = component.proxy(component.list("data")())
  local port = hx.port or 4460
  modem.open(port)
  if modem.isWireless and modem.isWireless() then pcall(modem.setStrength, 400) end

  local ctx = {
    id = hx.id, key = hx.key, role = hx.role or 1, fw = hx.fw or 0,
    queen = hx.queen or { x = 0, y = 64, z = 0 }, home = hx.home, joined = hx.joined,
    hmac = function(msg, key) return data.sha256(msg, key) end,
    now = function() return computer.uptime() end,
    send = function(wire, to)
      if to then modem.send(to, port, wire) else modem.broadcast(port, wire) end
    end,
    pull = function(timeout) return computer.pullSignal(timeout) end,
    navPos = function() return nav.getPosition() end,
    findWaypoints = function()
      local out = {}
      for _, w in ipairs(nav.findWaypoints(400) or {}) do
        out[#out + 1] = { key = hxnet.hashAddr(w.address),
          rel = { x = w.position[1], y = w.position[2], z = w.position[3] } }
      end
      return out
    end,
    droneMove = function(dx, dy, dz) drone.move(dx, dy, dz) end,
    droneOffset = function() return drone.getOffset() end,
    geoScan = function(rx, rz, ry, w, d, h) return geo and geo.scan(rx, rz, ry, w, d, h) or {} end,
    -- inventory upgrade: suck from / drop to the block below (side 0 = down)
    suck = function() local inv = component.list("inventory_controller")(); if inv then
      local before = drone.count and drone.count() or 0
      drone.suck(0); return (drone.count and drone.count() or 0) - before
    end return drone.suck and drone.suck(0) or 0 end,
    drop = function() return drone.drop and drone.drop(0) or 0 end,
    invCount = function() return drone.count and drone.count() or 0 end,
    energy = function() return computer.energy() / computer.maxEnergy() end,
    setStatus = function(l1, l2) pcall(drone.setStatusText, ((l1 or "") .. "\n" .. (l2 or "")):sub(1, 21)) end,
    setLight = function(rgb) pcall(drone.setLightColor, rgb) end,
    reboot = function() computer.shutdown(true) end,
  }
  return sdk.main(role, ctx)
end

return sdk
