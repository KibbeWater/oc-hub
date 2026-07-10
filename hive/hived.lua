-- hived.lua: the hive queen daemon.
-- Wires the swarm network (hxnet/netshim) to the core services (registry, tasker,
-- worlddb, routes, navgraph, firmware) and runs them from a single cooperative
-- event loop: modem messages drive handlers, timers drive the scheduler, autosave,
-- lease sweep and chunked route search. Publishes its services to hive.core.shared
-- so the `hive` dashboard reads them live. Install to /usr/bin/hived.lua.
--
-- Usage:
--   hived init            generate the swarm key + empty state
--   hived run             run in the foreground (rc runs this too)
--   hived status          print fleet + task summary
--   hived survey          sweep waypoints near the queen into the nav graph

local component = require("component")
local computer = require("computer")
local event = require("event")
local fs = require("filesystem")
local serialization = require("serialization")

-- Self-heal a stale hxnet require cache (package.loaded persists until reboot).
local hxnet = require("hxnet")
if hxnet.VERSION ~= 1 then
  package.loaded.hxnet = nil
  hxnet = require("hxnet")
end
local netshim = require("hive.core.netshim")
local navgraphLib = require("hive.core.navgraph")
local boot = require("hive.core.bootstrap")
local shared = require("hive.core.shared")

local ROLE_NAME = { [1] = "scout", [2] = "relay", [3] = "miner", [4] = "courier", [5] = "farmer" }

local function dataCard()
  if not component.isAvailable("data") then
    error("a Data Card (tier 2+) is required for swarm authentication")
  end
  return component.data
end

-- hmac(data, key) via the data card's keyed SHA-256.
local function makeHmac()
  local data = dataCard()
  return function(msg, key) return data.sha256(msg, key) end
end

-- --- init ------------------------------------------------------------------

local function cmdInit()
  local data = dataCard()
  if not fs.exists("/etc/hive") then fs.makeDirectory("/etc/hive") end
  if not fs.exists(boot.STATE_DIR) then fs.makeDirectory(boot.STATE_DIR) end
  if fs.exists(boot.KEY_PATH) then
    io.write("Swarm key already exists. Regenerate and orphan every device? [y/N] ")
    if (io.read() or ""):lower():sub(1, 1) ~= "y" then print("Aborted."); return end
  end
  local key = data.random(32)
  local f = assert(io.open(boot.KEY_PATH, "wb")); f:write(key); f:close()
  local ef = assert(io.open(boot.EPOCH_PATH, "wb")); ef:write("1"); ef:close()
  if not fs.exists(boot.CFG_PATH) then
    local cf = assert(io.open(boot.CFG_PATH, "w"))
    cf:write(serialization.serialize({
      port = hxnet.PORT, origin = { x = 0, y = 64, z = 0 },
      worldRoots = { boot.STATE_DIR .. "/world" }, strength = 400,
    }))
    cf:close()
  end
  print("Swarm initialised. Key written to " .. boot.KEY_PATH)
  print("Edit " .. boot.CFG_PATH .. " to set the NAS world roots and queen origin.")
end

-- --- run -------------------------------------------------------------------

local function cmdRun()
  local cfg = boot.loadConfig()
  if not component.isAvailable("modem") then error("a wireless network card is required") end
  if not fs.exists(boot.KEY_PATH) then error("run 'hived init' first (no swarm key)") end
  local modem = component.modem
  local svc = boot.bringUp(cfg)
  svc.log.echo = print
  shared.svc = svc

  -- bump epoch each boot so a restarted queen never replays old (epoch,seq)
  svc.epoch = svc.epoch + 1
  local ef = assert(io.open(boot.EPOCH_PATH, "wb")); ef:write(tostring(svc.epoch)); ef:close()

  modem.open(cfg.port)
  if modem.setStrength then modem.setStrength(cfg.strength) end

  local net = netshim.new{ id = hxnet.QUEEN, master = svc.master, hmac = makeHmac(),
    now = boot.now, epoch = svc.epoch, chunkSize = 3996,
    send = function(wire, to)
      if to then modem.send(to, cfg.port, wire) else modem.broadcast(cfg.port, wire) end
    end,
    firmwareProvider = function(role, stage)
      if stage ~= 0 then return nil end
      return svc.firmware.build(role)
    end }
  net.enableFirmwareServer()
  shared.net = net

  net.onHello(function(id, info)
    local role = ROLE_NAME[info.role] or "scout"
    svc.registry.join(id, { role = role, kind = "drone", fw = info.fwVer })
    local o = cfg.origin
    net.welcome(id, info.nonce, id, svc.firmware.version(role), o.x, o.y, o.z, 1)
  end)
  net.onTelem(function(id, b) svc.registry.upsertBeacon(id, b) end)
  net.onEvt(function(id, e)
    if e.subcode == hxnet.EVT.ROUTE_BLOCKED then
      svc.log.info("device %d reported blocked", id)
    elseif e.subcode == hxnet.EVT.DONE then
      local d = svc.registry.get(id)
      if d and d.taskId then svc.tasker.complete(d.taskId, "ok") end
    elseif e.subcode == hxnet.EVT.FAILED then
      local d = svc.registry.get(id)
      if d and d.taskId then svc.tasker.fail(d.taskId, e.detail) end
    elseif e.subcode == hxnet.EVT.SCAN then
      svc.worlddb.ingest(e.detail)
      svc.routes.onIngest()
    end
  end)

  local o = cfg.origin
  local lastBeacon, lastSave, lastSweep = 0, 0, 0
  svc.log.info("hived up on port %d (epoch %d)", cfg.port, svc.epoch)

  local running = true
  while running do
    local sig = { event.pull(0.5) }
    local name = sig[1]
    if name == "modem_message" then
      local ra, port, dist, msg = sig[3], sig[4], sig[5], sig[6]
      if port == cfg.port and type(msg) == "string" then net.submit(ra, dist or 0, msg) end
    elseif name == "interrupted" then
      running = false
    end

    local t = boot.now()
    if t - lastBeacon >= 5 then net.beacon(o.x, o.y, o.z, 0, 0); lastBeacon = t end
    if t - lastSweep >= 5 then
      for _, id in ipairs(svc.registry.sweep()) do svc.tasker.onLost(id) end
      svc.tasker.sweep()
      -- assign queued work to idle devices
      for id, d in pairs(svc.registry.all()) do
        if d.state == "idle" or d.state == 1 then
          local task = svc.tasker.assignTo({ id = id, caps = d.caps or {}, pos = d.pos or o,
            energy = d.energy or 1 })
          if task then svc.registry.setTask(id, task.id) end
        end
      end
      lastSweep = t
    end
    svc.routes.tick(30)
    if t - lastSave >= 30 then
      svc.registry.save(); svc.worlddb.flush(); svc.navgraph.save()
      if svc.tasker.journalSize() > 65536 then svc.tasker.checkpoint() end
      lastSave = t
    end
  end

  svc.registry.save(); svc.worlddb.flush(); svc.navgraph.save(); svc.tasker.checkpoint()
  shared.svc, shared.net = nil, nil
  svc.log.info("hived stopped")
end

-- --- status ----------------------------------------------------------------

local function cmdStatus()
  local svc = shared.svc or boot.bringUp(boot.loadConfig())
  local n, online = svc.registry.count()
  print(string.format("Fleet: %d device(s), %d online", n, online))
  for id, d in pairs(svc.registry.all()) do
    print(string.format("  #%s  %-7s %-8s %s  e=%s%%", tostring(id),
      d.role or "?", d.state or "?",
      d.pos and string.format("(%d,%d,%d)", d.pos.x, d.pos.y, d.pos.z) or "(?)",
      d.energy and math.floor(d.energy * 100) or "?"))
  end
  print(string.format("Tasks: %d queued", #svc.tasker.queued()))
end

-- --- survey ----------------------------------------------------------------

local function cmdSurvey()
  if not component.isAvailable("navigation") then
    error("a Navigation Upgrade is required to survey waypoints")
  end
  local nav = component.navigation
  local svc = shared.svc or boot.bringUp(boot.loadConfig())
  local wps = nav.findWaypoints(400)
  local px, py, pz = 0, 0, 0
  if nav.getPosition then px, py, pz = nav.getPosition() end
  local added = 0
  for _, w in ipairs(wps or {}) do
    local label = w.label or ""
    if label:sub(1, 3) == "hx:" then
      local kind = navgraphLib.KIND.WAYPOINT
      if label:match("^hx:cr?:") then kind = navgraphLib.KIND.CHARGER
      elseif label:match("^hx:d:") then kind = navgraphLib.KIND.DEPOT end
      svc.navgraph.addNode{ kind = kind, x = (px or 0) + w.position[1],
        y = (py or 0) + w.position[2], z = (pz or 0) + w.position[3], label = label }
      added = added + 1
    end
  end
  svc.navgraph.save()
  print(string.format("Surveyed %d hx: waypoint(s).", added))
end

-- --- dispatch --------------------------------------------------------------

local cmd = ({ ... })[1]
if cmd == "init" then cmdInit()
elseif cmd == "run" then cmdRun()
elseif cmd == "status" then cmdStatus()
elseif cmd == "survey" then cmdSurvey()
else
  print("hived - hive queen daemon")
  print("usage: hived init | run | status | survey")
end
