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
        qnet.cmd(id, hxnet.CMD.ASSIGN, sdk.encodeTask(task))
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

print(string.rep("-", 40))
if failures == 0 then print("all role tests passed"); os.exit(0)
else print(failures .. " test(s) failed"); os.exit(1) end
