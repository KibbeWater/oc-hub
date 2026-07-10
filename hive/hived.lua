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

-- Resolve bare sibling requires (airspace, navcore, worldscan, ...) from the
-- installed hive lib dirs; OpenOS only searches /usr/lib/?.lua by default.
package.path = "/usr/lib/hive/core/?.lua;/usr/lib/hive/sdk/?.lua;/usr/lib/hive/roles/?.lua;" .. package.path

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
local gpsfix = require("hive.core.gpsfix")
local boot = require("hive.core.bootstrap")
local shared = require("hive.core.shared")

local SAFEZONE_Y = 16 -- mining must stay this many blocks below the surface

local droneSdk = require("hive.sdk.drone_sdk")
local robotSdk = require("hive.sdk.robot_sdk")

local ROLE_NAME = { [1] = "scout", [2] = "relay", [3] = "miner", [4] = "courier", [5] = "farmer" }

-- Bundle the operating grant (mode + area, incl. the mining Y-range) with an
-- assignment, so the device can only act where and how the queen authorized.
local function encodeAssignment(d, task)
  local p = task.params or {}
  if task.type == "mine_slab" then
    local area = { x1 = p.x1, z1 = p.z1, x2 = p.x2, z2 = p.z2, y1 = p.y1, y2 = p.y2 }
    return robotSdk.encodeTask(task) .. hxnet.pack.grant(hxnet.MODE.DESTRUCTION, area, 600)
  elseif task.type == "mine_vein" then
    local area = { x1 = p.x - 8, z1 = p.z - 8, x2 = p.x + 8, z2 = p.z + 8, y1 = p.y - 8, y2 = p.y + 8 }
    return robotSdk.encodeTask(task) .. hxnet.pack.grant(hxnet.MODE.DESTRUCTION, area, 600)
  elseif task.type == "farm_pass" then
    local area = { x1 = p.x, z1 = p.z, x2 = p.x + p.w - 1, z2 = p.z + p.l - 1, y1 = p.y, y2 = p.y }
    return robotSdk.encodeTask(task) .. hxnet.pack.grant(hxnet.MODE.FARM, area, 900)
  elseif task.type == "ferry" then
    local f, to = p.from, p.to
    local area = { x1 = math.min(f.x, to.x), z1 = math.min(f.z, to.z),
      x2 = math.max(f.x, to.x), z2 = math.max(f.z, to.z) }
    return droneSdk.encodeTask(task) .. hxnet.pack.grant(hxnet.MODE.TRANSPORT, area, 600)
  end
  -- scan_tile (drone): SCOUT over the whole tile column
  local cx, cz = p.cx or 0, p.cz or 0
  local area = { x1 = cx * 16, z1 = cz * 16, x2 = cx * 16 + 15, z2 = cz * 16 + 15 }
  return droneSdk.encodeTask(task) .. hxnet.pack.grant(hxnet.MODE.SCOUT, area, 600)
end

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
    firmwareProvider = function(roleNum, stage)
      if stage ~= 0 then return nil end
      local name = ROLE_NAME[roleNum] or "scout"
      local img, ver, sha = svc.firmware.build(name)
      if not img then
        svc.log.alert("firmware build failed for %s: %s", name, tostring(ver))
        return nil
      end
      svc.log.info("serving %s v%s (%d B)", name, tostring(ver), #img)
      return img, ver, sha
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
    elseif e.subcode == hxnet.EVT.CALIB then
      local raw, sightings = hxnet.parse.calib(e.detail)
      local off, n, spread = gpsfix.solve(raw, sightings, svc.navgraph.calRefs())
      if off and (not spread or spread <= 2) then
        net.cmd(id, hxnet.CMD.CALIB, hxnet.pack.caloff(off))
        svc.log.info("device %d calibrated (%d refs, spread %d)", id, n, spread or 0)
      end
    elseif e.subcode == hxnet.EVT.DEPART then
      svc.log.info("device %d left the signaled area", id)
    elseif e.subcode == hxnet.EVT.UNAUTH then
      svc.log.alert("device %d attempted an unauthorized action", id)
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
      svc.poi.sweepChargers()
      -- assign queued work to idle devices, bundling the operating grant with it
      for id, d in pairs(svc.registry.all()) do
        if d.state == "idle" or d.state == hxnet.STATE.IDLE then
          local task = svc.tasker.assignTo({ id = id, caps = d.caps or {}, pos = d.pos or o,
            energy = d.energy or 1 })
          if task then
            svc.registry.setTask(id, task.id)
            net.cmd(id, hxnet.CMD.ASSIGN, encodeAssignment(d, task))
          end
        end
      end
      lastSweep = t
    end
    svc.routes.tick(30)
    if t - lastSave >= 30 then
      svc.registry.save(); svc.worlddb.flush(); svc.navgraph.save(); svc.poi.save()
      if svc.tasker.journalSize() > 65536 then svc.tasker.checkpoint() end
      lastSave = t
    end
  end

  svc.registry.save(); svc.worlddb.flush(); svc.navgraph.save(); svc.poi.save(); svc.tasker.checkpoint()
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
    print("No navigation component here. A server rack (or any non-rotatable host)")
    print("cannot use a navigation upgrade, so register points another way:")
    print("  * By hand:  hived poi <kind> <x> <y> <z> [label]")
    print("  * From a robot/drone/tablet that has a navigation upgrade")
    print("  * Scouts auto-register waypoints they fly past")
    return
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
      local wp = { x = (px or 0) + w.position[1], y = (py or 0) + w.position[2],
        z = (pz or 0) + w.position[3] }
      svc.navgraph.addNode{ kind = kind, x = wp.x, y = wp.y, z = wp.z, label = label,
        addr = hxnet.hashAddr(w.address or label) }
      -- also register chargers/depots as POIs for reservations + the dashboard
      local poiKind = ({ [navgraphLib.KIND.CHARGER] = label:match("^hx:cr:") and "charger_robot" or "charger_drone",
        [navgraphLib.KIND.DEPOT] = "depot" })[kind] or "waypoint"
      svc.poi.add{ kind = poiKind, pos = wp, label = label, active = (w.redstone or 0) == 0 or true }
      added = added + 1
    end
  end
  svc.navgraph.save(); svc.poi.save()
  print(string.format("Surveyed %d hx: waypoint(s).", added))
end

-- --- queue work ------------------------------------------------------------

local function svcHandle()
  return shared.svc or boot.bringUp(boot.loadConfig())
end

local function cmdScan(a)
  local svc = svcHandle()
  local x1, z1, x2, z2 = tonumber(a[2]), tonumber(a[3]), tonumber(a[4]), tonumber(a[5])
  if not (x1 and z1 and x2 and z2) then print("usage: hived scan <x1> <z1> <x2> <z2>"); return end
  local leaves = svc.tasker.submit{ type = "scan_area", params = { x1 = x1, z1 = z1, x2 = x2, z2 = z2 } }
  if not shared.svc then svc.tasker.checkpoint() end
  print(("Queued %d scan tile(s)."):format(#leaves))
end

local function cmdMine(a)
  local svc = svcHandle()
  local x1, y1, z1, x2, y2, z2 = tonumber(a[2]), tonumber(a[3]), tonumber(a[4]),
    tonumber(a[5]), tonumber(a[6]), tonumber(a[7])
  if not (x1 and y1 and z1 and x2 and y2 and z2) then
    print("usage: hived mine <x1> <y1> <z1> <x2> <y2> <z2>"); return
  end
  local leaves = svc.tasker.submit{ type = "mine_region",
    params = { x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2 } }
  if not shared.svc then svc.tasker.checkpoint() end
  if #leaves == 0 then
    print("No slabs queued -- the area is unscanned or entirely inside the 16-block surface safezone.")
  else
    print(("Queued %d mining slab(s) (clamped to keep 16 blocks below the surface)."):format(#leaves))
  end
end

local function cmdFerry(a)
  local svc = svcHandle()
  local n = {}
  for i = 2, 8 do n[i] = tonumber(a[i]) end
  if not (n[2] and n[3] and n[4] and n[5] and n[6] and n[7]) then
    print("usage: hived ferry <fromX fromY fromZ> <toX toY toZ> [count]"); return
  end
  svc.tasker.submit{ type = "ferry", needs = { "courier" },
    params = { from = { x = n[2], y = n[3], z = n[4] }, to = { x = n[5], y = n[6], z = n[7] },
      count = tonumber(a[8]) or 64 },
    startPos = { x = n[2], y = n[3], z = n[4] } }
  if not shared.svc then svc.tasker.checkpoint() end
  print("Queued a ferry job.")
end

local function cmdFarm(a)
  local svc = svcHandle()
  local x, y, z, w, l = tonumber(a[2]), tonumber(a[3]), tonumber(a[4]), tonumber(a[5]), tonumber(a[6])
  if not (x and y and z and w and l) then print("usage: hived farm <cornerX cropY cornerZ> <w> <l>"); return end
  svc.tasker.submit{ type = "farm_pass", needs = { "farm" }, recur = { every = 1800 },
    params = { x = x, y = y, z = z, w = w, l = l }, startPos = { x = x, y = y + 1, z = z } }
  if not shared.svc then svc.tasker.checkpoint() end
  print("Queued a recurring farm pass (every 30 min).")
end

local function cmdHole(a)
  local svc = svcHandle()
  local x, z, yTop, yBot = tonumber(a[2]), tonumber(a[3]), tonumber(a[4]), tonumber(a[5])
  if not (x and z and yTop and yBot) then print("usage: hived hole <x> <z> <yTop> <yBot> [type]"); return end
  local ttype = svc.navgraph.TTYPE and svc.navgraph.TTYPE[(a[6] or "hole3"):upper()] or nil
  local top, bot = svc.navgraph.addHole{ x = x, z = z, yTop = yTop, yBot = yBot, ttype = ttype }
  svc.navgraph.save()
  print(("Added a %s hole entry (nodes %d/%d) at %d,%d down to y=%d."):format(
    a[6] or "hole3", top, bot, x, z, yBot))
end

local function cmdPoi(a)
  local svc = svcHandle()
  local kind, x, y, z, label = a[2], tonumber(a[3]), tonumber(a[4]), tonumber(a[5]), a[6]
  local valid = { charger_drone = true, charger_robot = true, depot = true,
    waypoint = true, hub = true, home = true, field = true }
  if not (kind and valid[kind] and x and y and z) then
    print("usage: hived poi <charger_drone|charger_robot|depot|waypoint|hub|home|field> <x> <y> <z> [label]")
    return
  end
  svc.poi.add{ kind = kind, pos = { x = x, y = y, z = z }, label = label }
  local ngKind = ({ charger_drone = navgraphLib.KIND.CHARGER, charger_robot = navgraphLib.KIND.CHARGER,
    depot = navgraphLib.KIND.DEPOT })[kind] or navgraphLib.KIND.WAYPOINT
  svc.navgraph.addNode{ kind = ngKind, x = x, y = y, z = z, label = label }
  svc.poi.save(); svc.navgraph.save()
  print(("Registered %s POI at %d,%d,%d."):format(kind, x, y, z))
end

local function cmdTunnel(a)
  local svc = svcHandle()
  local ng = svc.navgraph
  local n = {}
  for i = 2, 7 do n[i] = tonumber(a[i]) end
  if not (n[2] and n[4] and n[5] and n[7]) then
    print("usage: hived tunnel <x1 y1 z1> <x2 y2 z2> [type]"); return
  end
  local A = ng.addNode{ kind = ng.KIND.JUNCTION, x = n[2], y = n[3], z = n[4] }
  local B = ng.addNode{ kind = ng.KIND.JUNCTION, x = n[5], y = n[6], z = n[7] }
  local ttype = ng.TTYPE[(a[8] or "standard"):upper()]
  ng.link(A, B, ng.MODE.TUNNEL, nil, ttype)
  ng.save()
  print(("Linked a %s tunnel between junctions %d and %d."):format(a[8] or "standard", A, B))
end

-- --- dispatch --------------------------------------------------------------

local args = { ... }
local cmd = args[1]
if cmd == "init" then cmdInit()
elseif cmd == "run" then cmdRun()
elseif cmd == "status" then cmdStatus()
elseif cmd == "survey" then cmdSurvey()
elseif cmd == "scan" then cmdScan(args)
elseif cmd == "mine" then cmdMine(args)
elseif cmd == "ferry" then cmdFerry(args)
elseif cmd == "farm" then cmdFarm(args)
elseif cmd == "hole" then cmdHole(args)
elseif cmd == "tunnel" then cmdTunnel(args)
elseif cmd == "poi" then cmdPoi(args)
else
  print("hived - hive queen daemon")
  print("usage: hived init | run | status | survey")
  print("       scan <x1 z1 x2 z2> | mine <x1 y1 z1 x2 y2 z2>")
  print("       ferry <fx fy fz tx ty tz [n]> | farm <x y z w l>")
  print("       poi <kind x y z [label]>")
  print("       hole <x z yTop yBot [type]> | tunnel <x1 y1 z1 x2 y2 z2 [type]>")
end
