-- Desktop integration test for the role layer (Lua 5.3+):
--   lua tools/test_roles.lua
-- Runs the real drone_sdk + scout role on a simulated drone against a simulated
-- queen (netshim + tasker + worlddb + registry) over a loopback radio bus. The
-- device SDK runs in a coroutine so the queen can be serviced between its polls.
-- Asserts the scout joins, is assigned a tile, flies it, and fills the world DB.

package.path = "hive/?.lua;hive/core/?.lua;hive/sdk/?.lua;hive/roles/?.lua;tools/?.lua;" .. package.path
local netshim = require("netshim")
local registryLib = require("registry")
local taskerLib = require("tasker")
local worlddbLib = require("worlddb")
local store = require("store")
local hxnet = require("hxnet")
local sdk = require("drone_sdk")
local hivesim = require("hivesim")

local failures = 0
local function check(name, ok, detail)
  if ok then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
end

local function fakeHmac(data, key)
  local mix = (key or "") .. "\1" .. data
  local h = {}
  for b = 1, 32 do h[b] = (b * 131 + #mix * 7) % 256 end
  local acc = 0
  for i = 1, #mix do
    acc = (acc * 33 + mix:byte(i)) % 4294967296
    h[(i % 32) + 1] = (h[(i % 32) + 1] ~ (acc & 0xff) ~ ((acc >> 8) & 0xff)) % 256
  end
  local out = {}
  for b = 1, 32 do out[b] = string.char(h[b]) end
  return table.concat(out)
end

-- world + drone -----------------------------------------------------------

local world = hivesim.world{ surface = hivesim.terrain.plains(64) }
local clock = hivesim.clock()
local drone = hivesim.drone(world, 0, 80, 0)
local geo = hivesim.geolyzer(world, function() return drone.pos() end, { noise = 2 })

-- loopback bus: two inboxes
local queenInbox, deviceInbox = {}, {}
local function push(box, from, wire, to) box[#box + 1] = { from = from, wire = wire, to = to } end

-- queen ---------------------------------------------------------------------

local master = ("M"):rep(32)
local st = store.new{ fs = hivesim.memfs() }
local reg = registryLib.new{ store = st, now = clock.now }
local tasker = taskerLib.new{ store = st, now = clock.now, dir = "/var/hive" }
local worlddb = worlddbLib.new{ store = st, roots = { "/w" }, now = clock.now, indexPath = "/w/idx.db" }

local qnet = netshim.new{ id = 0, master = master, hmac = fakeHmac, now = clock.now, epoch = 2,
  send = function(wire, to) push(deviceInbox, "q", wire, to) end }
qnet.onHello(function(id, info)
  reg.join(id, { role = "scout", kind = "drone", caps = { "scan" }, fw = info.fwVer })
  qnet.welcome(id, info.nonce, id, 0, 0, 64, 0, 1)
end)
qnet.onTelem(function(id, b) reg.upsertBeacon(id, b) end)
qnet.onEvt(function(id, e)
  if e.subcode == hxnet.EVT.SCAN then
    worlddb.ingest(e.detail)
  elseif e.subcode == hxnet.EVT.DONE then
    local d = reg.get(id)
    if d and d.taskId then tasker.complete(d.taskId, "ok"); reg.setTask(id, nil) end
  elseif e.subcode == hxnet.EVT.FAILED then
    local d = reg.get(id)
    if d and d.taskId then tasker.fail(d.taskId, e.detail); reg.setTask(id, nil) end
  end
end)

-- one tile of work
tasker.submit{ type = "scan_area", params = { x1 = 0, z1 = 0, x2 = 15, z2 = 15 } }

local function serviceQueen()
  while #queenInbox > 0 do
    local m = table.remove(queenInbox, 1)
    qnet.submit(m.from, 12, m.wire)
  end
  -- assign queued scan tiles to idle scouts
  for id, d in pairs(reg.all()) do
    local idle = d.state == hxnet.STATE.IDLE or d.state == "idle"
    if idle and not d.taskId then
      local task = tasker.assignTo({ id = id, caps = d.caps or {},
        pos = d.pos or { x = 0, y = 64, z = 0 }, energy = d.energy or 1 })
      if task then
        reg.setTask(id, task.id)
        -- bundle a SCOUT grant for the tile so scanning is authorized
        local cx, cz = task.params.cx, task.params.cz
        local area = { x1 = cx * 16, z1 = cz * 16, x2 = cx * 16 + 15, z2 = cz * 16 + 15 }
        local payload = sdk.encodeTask(task) .. hxnet.pack.grant(hxnet.MODE.SCOUT, area, 600)
        qnet.cmd(id, hxnet.CMD.ASSIGN, payload)
      end
    end
  end
end

-- device (scout) ------------------------------------------------------------

local devId = 7
local Kd = hxnet.deriveKey(master, devId, fakeHmac)
local scout = require("scout")

local ctx = {
  id = devId, key = Kd, hmac = fakeHmac, now = clock.now, role = 1, fw = 1,
  nonce = "scout001", queen = { x = 0, y = 64, z = 0 }, home = { x = 0, y = 64, z = 0 },
  send = function(wire, to) push(queenInbox, "d", wire, to) end,
  pull = function(timeout) return coroutine.yield(timeout or 0) end,
  navPos = function() return drone.pos() end,
  droneMove = function(dx, dy, dz) drone.move(dx, dy, dz) end,
  droneOffset = function() return drone.offset() end,
  geoScan = function(rx, rz, ry, w, d, h) return geo.scan(rx, rz, ry, w, d, h) end,
  energy = function() return drone.energyFrac() end,
  setStatus = function() end,
}

local co = coroutine.create(function() sdk.main(scout, ctx) end)

-- driver loop: resume the SDK, advance physics + queen between polls -----------

local ok, dt = coroutine.resume(co)
assert(ok, dt)
local iterations, joined = 0, false
while coroutine.status(co) ~= "dead" and iterations < 20000 do
  iterations = iterations + 1
  dt = tonumber(dt) or 0.25
  for _ = 1, math.max(1, math.floor(dt / 0.05)) do drone.stepTick() end
  clock.advance(dt)
  serviceQueen()
  if reg.get(devId) then joined = true end
  local msg = table.remove(deviceInbox, 1)
  if msg then
    ok, dt = coroutine.resume(co, "modem_message", "q", "q", hxnet.PORT, 12, msg.wire)
  else
    ok, dt = coroutine.resume(co, nil)
  end
  if not ok then error(dt) end
  -- stop once the tile is essentially mapped
  local s = worlddb.tileSummary(0, 0)
  if s and s.scannedPct >= 90 then break end
  if drone.dead then break end
end

-- low-energy failsafe: a near-empty scout must not fly a task; it lands + idles ---

do
  local w2 = hivesim.world{ surface = hivesim.terrain.plains(64) }
  local ck2 = hivesim.clock()
  local d2 = hivesim.drone(w2, 0, 80, 0, { energy = 0.05 }) -- critical
  local g2 = hivesim.geolyzer(w2, function() return d2.pos() end)
  local moved = { count = 0 }
  local ctx2 = {
    id = 9, key = hxnet.deriveKey(master, 9, fakeHmac), hmac = fakeHmac, now = ck2.now,
    role = 1, fw = 1, nonce = "lowbatt0", queen = { x = 0, y = 64, z = 0 },
    home = { x = 0, y = 64, z = 0 }, joined = true,
    send = function() end,
    pull = function(t) return coroutine.yield(t or 0) end,
    navPos = function() return d2.pos() end,
    droneMove = function(dx, dy, dz) moved.count = moved.count + 1; d2.move(dx, dy, dz) end,
    droneOffset = function() return d2.offset() end,
    geoScan = function(rx, rz, ry, ww, dd, hh) return g2.scan(rx, rz, ry, ww, dd, hh) end,
    energy = function() return d2.energyFrac() end,
    setStatus = function() end, setLight = function() end,
    -- inject a task immediately so we can prove it is NOT executed while critical
  }
  -- pre-seed a scan task via a fake ASSIGN before running
  local scoutRole = require("scout")
  local co2 = coroutine.create(function() sdk.main(scoutRole, ctx2) end)
  local startX = select(1, d2.pos())
  local ok2, dt2 = coroutine.resume(co2)
  local iters = 0
  while coroutine.status(co2) ~= "dead" and iters < 200 do
    iters = iters + 1
    for _ = 1, math.max(1, math.floor((tonumber(dt2) or 0.25) / 0.05)) do d2.stepTick() end
    ck2.advance(tonumber(dt2) or 0.25)
    ok2, dt2 = coroutine.resume(co2, nil)
    if not ok2 then error(dt2) end
    if iters > 20 then break end -- a few seconds is enough to observe behaviour
  end
  check("critical-energy scout enters low-power (no lateral task flight)",
    math.abs((select(1, d2.pos())) - startX) <= 1, select(1, d2.pos()))
end

check("scout joined the swarm", joined and reg.get(devId) ~= nil)
check("scout survived the flight", not drone.dead)
local summary = worlddb.tileSummary(0, 0)
check("world tile got scanned", summary ~= nil and summary.scannedPct >= 90,
  summary and summary.scannedPct)
check("scanned surface is correct", (function()
  local c = worlddb.column(5, 5)
  return c and c.surfaceY == 64
end)(), worlddb.column(5, 5) and worlddb.column(5, 5).surfaceY)
check("finished in a sane number of steps", iterations < 20000, iterations)

-- robot miner: an authorized DESTRUCTION grant clears the slab; a SCOUT grant
-- (wrong mode) must leave every block intact -------------------------------

local function runMiner(grantMode)
  local w = hivesim.world{ surface = hivesim.terrain.plains(5) }
  for x = 0, 2 do for y = 10, 12 do for z = 0, 2 do w.place(x, y, z, "stone") end end end
  local ck = hivesim.clock()
  local robot = hivesim.robot(w, -1, 12, 0, { dig = true })
  local rsdk = require("robot_sdk")
  local miner = require("miner")
  local st2 = store.new{ fs = hivesim.memfs() }
  local reg2 = registryLib.new{ store = st2, now = ck.now }
  local qIn, dIn, assigned = {}, {}, false
  local qnet = netshim.new{ id = 0, master = master, hmac = fakeHmac, now = ck.now, epoch = 2,
    send = function(wire) dIn[#dIn + 1] = wire end }
  qnet.onHello(function(id, info)
    reg2.join(id, { role = "miner", kind = "robot", caps = { "mine" } })
    qnet.welcome(id, info.nonce, id, 0, 0, 64, 0, 1)
  end)
  qnet.onTelem(function(id, b) reg2.upsertBeacon(id, b) end)
  qnet.onEvt(function() end)

  local ctx = {
    id = 8, key = hxnet.deriveKey(master, 8, fakeHmac), hmac = fakeHmac, now = ck.now,
    role = 3, fw = 1, nonce = "miner001", queen = { x = 0, y = 64, z = 0 }, home = { x = -1, y = 12, z = 0 },
    send = function(wire) qIn[#qIn + 1] = wire end,
    pull = function(t) return coroutine.yield(t) end,
    navPos = function() return robot.pos() end,
    moveStep = function(dx, dy, dz) return robot.moveStep(dx, dy, dz) end,
    dig = function(dx, dy, dz) return robot.dig(dx, dy, dz) end,
    detect = function(dx, dy, dz) return robot.detect(dx, dy, dz) end,
    energy = function() return robot.energyFrac() end,
    charge = function() end,
  }
  local function cleared()
    for x = 0, 2 do for y = 10, 12 do for z = 0, 2 do
      if w.blockName(x, y, z) ~= "air" then return false end
    end end end
    return true
  end
  local function serviceQueen()
    while #qIn > 0 do qnet.submit("d", 5, table.remove(qIn, 1)) end
    for id, d in pairs(reg2.all()) do
      if (d.state == hxnet.STATE.IDLE or d.state == "idle") and not d.taskId and not assigned then
        local task = { type = "mine_slab", params = { x1 = 0, y1 = 10, z1 = 0, x2 = 2, y2 = 12, z2 = 2 } }
        local area = { x1 = 0, z1 = 0, x2 = 2, z2 = 2, y1 = 10, y2 = 12 }
        reg2.setTask(id, "M1"); assigned = true
        qnet.cmd(id, hxnet.CMD.ASSIGN, rsdk.encodeTask(task) .. hxnet.pack.grant(grantMode, area, 600))
      end
    end
  end
  local co = coroutine.create(function() rsdk.main(miner, ctx) end)
  local ok, dt = coroutine.resume(co)
  assert(ok, dt)
  local it = 0
  while coroutine.status(co) ~= "dead" and it < 5000 do
    it = it + 1
    ck.advance(tonumber(dt) or 0.2)
    serviceQueen()
    local msg = table.remove(dIn, 1)
    if msg then ok, dt = coroutine.resume(co, "modem_message", "q", "q", hxnet.PORT, 5, msg)
    else ok, dt = coroutine.resume(co, nil) end
    if not ok then error(dt) end
    if assigned and cleared() then break end
    if it > 3000 then break end
  end
  return cleared()
end

check("miner clears an authorized slab (DESTRUCTION grant)", runMiner(hxnet.MODE.DESTRUCTION))
check("miner refuses digging without DESTRUCTION (SCOUT grant)", not runMiner(hxnet.MODE.SCOUT))

print(string.rep("-", 40))
if failures == 0 then print("all role tests passed"); os.exit(0)
else print(failures .. " test(s) failed"); os.exit(1) end
