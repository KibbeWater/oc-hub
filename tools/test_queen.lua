-- Desktop tests for the queen network/services layer (Lua 5.3+):
--   lua tools/test_queen.lua
-- Covers firmware bundling, registry lifecycle + persistence, and a netshim
-- loopback: join -> welcome -> signed cmd -> evt, plus a firmware transfer with
-- injected chunk loss and NAK repair.

package.path = "hive/core/?.lua;hive/?.lua;tools/?.lua;" .. package.path
local firmware = require("firmware")
local registry = require("registry")
local netshim = require("netshim")
local store = require("store")
local hxnet = require("hxnet")
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
    local idx = (i % 32) + 1
    h[idx] = (h[idx] ~ (acc & 0xff) ~ ((acc >> 8) & 0xff)) % 256
  end
  for i = #mix, 1, -1 do
    acc = (acc * 17 + mix:byte(i)) % 4294967296
    h[((#mix - i) % 32) + 1] = (h[((#mix - i) % 32) + 1] ~ (acc & 0xff)) % 256
  end
  local out = {}
  for b = 1, 32 do out[b] = string.char(h[b]) end
  return table.concat(out)
end
local function fakeSha(s) return fakeHmac(s, "sha") end

-- firmware.bundle ---------------------------------------------------------

do
  local modules = {
    { name = "a", src = "local a = {}\nfunction a.n() return 40 end\nreturn a" },
    { name = "b", src = "local a = require('a')\nlocal b = {}\nfunction b.n() return a.n() + 2 end\nreturn b" },
  }
  local src = firmware.bundle(modules, "return require('b').n()")
  local fn, err = load(src, "=bundle")
  check("bundle compiles", fn ~= nil, err)
  check("bundle module shim resolves deps", fn and fn() == 42)
end

do
  -- firmware.new build path with synthetic files in memory
  local files = {
    ["/lib/hxnet.lua"] = "local m={} m.tag='hx' return m",
    ["/lib/navcore.lua"] = "local m={} m.tag='nav' return m",
    ["/lib/drone_sdk.lua"] = "local m={} function m.main(r) return r.name end return m",
    ["/roles/scout.lua"] = "return { name='scout' }",
  }
  local st = store.new{ fs = hivesim.memfs() }
  local fw = firmware.new{
    readFile = function(p) return files[p] end,
    optimize = function(s) return s, { before = #s, after = #s } end,
    sha = fakeSha, store = st, verPath = "/fwver.db",
    common = { { name = "hxnet", path = "/lib/hxnet.lua" },
      { name = "navcore", path = "/lib/navcore.lua" },
      { name = "drone_sdk", path = "/lib/drone_sdk.lua" } },
    roleDir = "/roles",
    entry = 'return require("drone_sdk").main(require("__role"))',
  }
  local img, ver, sha = fw.build("scout")
  check("firmware build succeeds", img ~= nil, ver)
  check("firmware version starts at 1", ver == 1, ver)
  check("firmware image compiles + entry works", (function()
    local f = load(img, "=img"); return f and f() == "scout"
  end)())
  -- rebuild unchanged -> same version
  local _, ver2 = fw.build("scout")
  check("unchanged rebuild keeps version", ver2 == 1, ver2)
  -- change the role -> version bumps
  files["/roles/scout.lua"] = "return { name='scout2' }"
  local _, ver3 = fw.build("scout")
  check("changed source bumps version", ver3 == 2, ver3)
end

-- registry ----------------------------------------------------------------

do
  local clock = 0
  local st = store.new{ fs = hivesim.memfs() }
  local changes = 0
  local reg = registry.new{ store = st, now = function() return clock end,
    staleAfter = 10, lostAfter = 30 }
  reg.onChange(function() changes = changes + 1 end)

  reg.join(7, { role = "scout", kind = "drone", caps = { "scan" }, fw = 1 })
  check("registry join", reg.get(7) and reg.get(7).role == "scout")
  check("onChange fired", changes > 0)

  reg.upsertBeacon(7, { pos = { x = 10, y = 64, z = 20 }, energy = 0.8, state = 2, fw = 1 })
  check("beacon updates pos/energy", reg.get(7).pos.x == 10 and reg.get(7).energy == 0.8)
  check("coverage recorded", reg.lastCoveragePos(7).x == 10)

  local n, online = reg.count()
  check("counts online", n == 1 and online == 1, n .. "/" .. online)

  clock = 40
  local lost = reg.sweep()
  check("sweep marks silent device lost", #lost == 1 and reg.get(7).state == "lost")

  -- persistence: reload starts devices offline
  reg.save()
  local reg2 = registry.new{ store = st, now = function() return 100 end }
  reg2.load()
  check("registry persists across reload", reg2.get(7) and reg2.get(7).role == "scout")
  check("reloaded devices start offline", reg2.get(7).state == "offline")
end

-- netshim loopback integration --------------------------------------------

do
  local master = ("M"):rep(32)
  local clock = { t = 0 }
  local now = function() return clock.t end

  -- loopback bus
  local nodes, queue = {}, {}
  local function busSend(from) return function(wire, to) queue[#queue + 1] = { from = from, wire = wire, to = to } end end
  local function pump()
    local guard = 0
    while #queue > 0 do
      guard = guard + 1; assert(guard < 100000, "no converge")
      local m = table.remove(queue, 1)
      for _, e in ipairs(nodes) do
        if e.addr ~= m.from and (m.to == nil or m.to == e.addr) then
          e.submit(m.from, 12, m.wire)
        end
      end
    end
  end

  -- firmware image the queen serves
  local image = ("firmware-bytes-"):rep(700) .. "END" -- multi-chunk
  local imgSha = fakeSha(image)

  local qn = netshim.new{ id = 0, master = master, hmac = fakeHmac, now = now,
    send = busSend("q"), epoch = 3, chunkSize = 4096,
    firmwareProvider = function(role) return image, 5, imgSha end }
  qn.enableFirmwareServer()
  nodes[#nodes + 1] = { addr = "q", submit = function(a, d, w) qn.submit(a, d, w) end }

  -- events observed on the queen
  local joined, evtGot
  qn.onHello(function(id, info)
    joined = { id = id, role = info.role }
    -- assign a device id + welcome (echo nonce)
    qn.welcome(id, info.nonce, id, 5, 0, 64, 0, 1)
  end)
  qn.onEvt(function(id, e) evtGot = { id = id, sub = e.subcode } end)

  -- device (id 7) with its derived key
  local devId = 7
  local Kd = hxnet.deriveKey(master, devId, fakeHmac)
  local dev = hxnet.new{ id = devId, key = Kd, hmac = fakeHmac, now = now, send = busSend("d") }
  local devState = { welcomed = false, cmd = nil, rx = nil, meta = nil, dropped = false }
  dev:on(hxnet.T.WELCOME, function(f)
    local nonce, assigned, latestFw = hxnet.parse.welcome(f.body)
    devState.welcomed = { nonce = nonce, assigned = assigned, latestFw = latestFw }
  end)
  dev:on(hxnet.T.CMD, function(f)
    local op, payload = hxnet.parse.cmd(f.body)
    devState.cmd = { op = op, payload = payload }
    -- ack
    dev:cast(hxnet.QUEEN, hxnet.T.EVT, hxnet.pack.evt(f.seq, hxnet.EVT.ACK, 0), { ttl = 5 })
  end)
  dev:on(hxnet.T.FW_META, function(f)
    local xferId, ver, size, count, csize, sha = hxnet.parse.fwmeta(f.body)
    devState.meta = { xferId = xferId, sha = sha, count = count }
    devState.rx = hxnet.rx(count, csize, size)
  end)
  dev:on(hxnet.T.FW_CHUNK, function(f)
    local xferId, idx, data = hxnet.parse.fwchunk(f.body)
    -- simulate losing chunk 1 the first time it is offered
    if idx == 1 and not devState.dropped then devState.dropped = true; return end
    if devState.rx then devState.rx:add(idx, data) end
  end)
  nodes[#nodes + 1] = { addr = "d", submit = function(a, di, w) dev:submit(a, di, w) end }

  -- device joins
  local nonce = "abcd1234"
  dev:cast(hxnet.QUEEN, hxnet.T.HELLO, hxnet.pack.hello(nonce, 1, 0), { ttl = 5 })
  pump()
  check("queen saw HELLO", joined and joined.id == 7)
  check("device got signed WELCOME (nonce echo)", devState.welcomed
    and devState.welcomed.nonce == nonce, devState.welcomed and devState.welcomed.nonce)
  check("welcome carried latest fw", devState.welcomed and devState.welcomed.latestFw == 5)

  -- queen commands the device
  qn.cmd(7, 42, "recall")
  pump()
  check("device ran signed CMD", devState.cmd and devState.cmd.op == 42
    and devState.cmd.payload == "recall")
  check("queen received EVT ack", evtGot and evtGot.id == 7 and evtGot.sub == hxnet.EVT.ACK)

  -- device requests firmware; one chunk is dropped, NAK repairs it
  dev:cast(hxnet.QUEEN, hxnet.T.FW_REQ, hxnet.pack.fwreq(0, 1, 0), { ttl = 5 })
  pump()
  check("device received META", devState.meta and devState.meta.count > 1)
  check("transfer incomplete after drop", not devState.rx:complete())
  -- device NAKs the missing chunk
  dev:cast(hxnet.QUEEN, hxnet.T.FW_NAK, hxnet.pack.fwnak(devState.meta.xferId, devState.rx:missing()), { ttl = 5 })
  pump()
  check("transfer complete after NAK repair", devState.rx:complete())
  check("assembled image matches", devState.rx:image() == image)
  check("image sha matches META", fakeSha(devState.rx:image()) == devState.meta.sha)
end

print(string.rep("-", 40))
if failures == 0 then print("all queen tests passed"); os.exit(0)
else print(failures .. " test(s) failed"); os.exit(1) end
