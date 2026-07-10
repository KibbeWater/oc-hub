-- Desktop test harness for hive/hxnet.lua (run with Lua 5.3+):
--   lua tools/test_hxnet.lua
-- Exercises the codec, HMAC sign/verify (ttl-invariant MAC), replay watermark,
-- dedup eviction, chunked transfer with injected loss, and a mini radio simulator
-- for multi-hop flooding + coverage-anchor convergence. No OpenComputers needed.

package.path = "hive/?.lua;" .. package.path
local hx = require("hxnet")

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("OK   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or ""))
  end
end

-- A deterministic keyed digest for tests (NOT cryptographic). Two mixing passes
-- give avalanche in both directions so every byte of key+data affects every
-- output byte -- enough to catch tampering in verify tests.
local function fakeHmac(data, key)
  local mix = key .. "\1" .. data
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
    local idx = ((#mix - i) % 32) + 1
    h[idx] = (h[idx] ~ (acc & 0xff)) % 256
  end
  local out = {}
  for b = 1, 32 do out[b] = string.char(h[b]) end
  return table.concat(out)
end

-- codec roundtrips --------------------------------------------------------

do
  local f = { type = hx.T.TELEM, ttl = 3, src = 42, dst = hx.QUEEN, seq = 7,
    body = hx.pack.telem(10, 64, -20, 88, hx.STATE.WORKING, 5, 2, "mining") }
  local g = hx.decode(hx.encode(f))
  check("codec header roundtrip", g and g.type == f.type and g.ttl == 3
    and g.src == 42 and g.dst == hx.QUEEN and g.seq == 7, g and g.seq)
  check("codec body preserved", g and g.body == f.body)
  local x, y, z, e, st, fw, role, status = hx.parse.telem(g.body)
  check("telem body fields", x == 10 and y == 64 and z == -20 and e == 88
    and st == hx.STATE.WORKING and fw == 5 and role == 2 and status == "mining",
    string.format("%d,%d,%d e=%d st=%d fw=%d role=%d %q", x, y, z, e, st, fw, role, status))

  check("decode rejects short", hx.decode("hx") == nil)
  check("decode rejects bad magic", hx.decode(("Z"):rep(20)) == nil)

  -- beacon negatives (signed coords)
  local b = hx.pack.beacon(-500, 200, 900, 2, 1)
  local bx, by, bz, bh, bfl = hx.parse.beacon(b)
  check("beacon signed coords", bx == -500 and by == 200 and bz == 900 and bh == 2 and bfl == 1)

  -- max-size body survives a roundtrip in one part
  local big = ("Q"):rep(hx.MAX_BODY)
  local gb = hx.decode(hx.encode({ type = hx.T.CMD, src = 1, dst = 2, seq = 1, body = big }))
  check("max body roundtrip", gb and gb.body == big, gb and #gb.body)
end

-- sign / verify (ttl-invariant MAC) --------------------------------------

do
  local key = hx.deriveKey(("K"):rep(32), 7, fakeHmac)
  local wire = hx.sign(hx.encode({ type = hx.T.CMD, ttl = 5, src = hx.QUEEN, dst = 7,
    seq = 3, signed = true, epoch = 9, body = hx.pack.cmd(1, "recall") }), key, fakeHmac)

  local f = hx.decode(wire)
  check("verify accepts genuine", hx.verify(f, key, fakeHmac))
  check("epoch parsed", f.epoch == 9, f.epoch)

  -- Relay decremented ttl -> MAC must still verify (ttl is zeroed for the MAC).
  local relayed = hx.decode(hx.withTTL(wire, 4))
  check("verify survives ttl decrement", hx.verify(relayed, key, fakeHmac) and relayed.ttl == 4)

  -- Body tamper -> reject.
  local tampered = hx.decode(wire:sub(1, #wire - 17) .. string.char((wire:byte(#wire - 16) + 1) % 256)
    .. wire:sub(#wire - 15))
  check("verify rejects body tamper", not hx.verify(tampered, key, fakeHmac))

  -- Wrong key -> reject.
  local other = hx.deriveKey(("K"):rep(32), 8, fakeHmac)
  check("verify rejects wrong key", not hx.verify(f, other, fakeHmac))
end

-- dedup ring --------------------------------------------------------------

do
  local d = hx.dedup(4)
  check("dedup new keys", not d:seen(1) and not d:seen(2) and not d:seen(3) and not d:seen(4))
  check("dedup repeat caught", d:seen(1) == true)
  d:seen(5) -- evicts oldest (1)
  check("dedup evicts oldest", not d:seen(1))
  check("dedup keeps recent", d:seen(4) == true)
end

-- replay watermark (through the node engine) ------------------------------

do
  local devId = 7
  local key = hx.deriveKey(("M"):rep(32), devId, fakeHmac)
  local delivered = {}
  local dev = hx.new{ id = devId, key = key, hmac = fakeHmac, now = function() return 0 end,
    send = function() end }
  dev:on(hx.T.CMD, function(f) delivered[#delivered + 1] = { epoch = f.epoch, seq = f.seq } end)

  local function queenSend(epoch, seq)
    local wire = hx.sign(hx.encode({ type = hx.T.CMD, ttl = 5, src = hx.QUEEN, dst = devId,
      seq = seq, signed = true, epoch = epoch, body = hx.pack.cmd(1, "") }), key, fakeHmac)
    dev:submit("queen", 10, wire)
  end

  queenSend(5, 10) -- accept
  queenSend(5, 9)  -- older seq, same epoch -> reject
  queenSend(5, 11) -- newer seq -> accept
  queenSend(4, 99) -- older epoch -> reject
  queenSend(6, 1)  -- newer epoch resets watermark -> accept
  check("watermark accepts only forward frames", #delivered == 3,
    #delivered .. " delivered")
  check("watermark last accepted is epoch6", delivered[3] and delivered[3].epoch == 6)

  -- Unsigned frame with an unknown key still delivers (telemetry plane is open).
  local openDev = hx.new{ id = 8, hmac = fakeHmac, send = function() end }
  local got = 0
  openDev:on(hx.T.TELEM, function() got = got + 1 end)
  openDev:submit("x", 5, hx.encode({ type = hx.T.TELEM, ttl = 3, src = 9, dst = hx.BROADCAST,
    seq = 1, body = hx.pack.telem(0, 0, 0, 50, 1, 0, 0, "") }))
  check("unsigned telemetry delivered", got == 1)
end

-- chunked transfer with injected loss -------------------------------------

do
  local image = ("noteblocks-and-drones-"):rep(1500) .. "TAIL" -- not a chunk multiple
  local tx = hx.tx(image, 4096)
  local rx = hx.rx(tx.count, tx.chunkSize, tx.size)
  -- Deliver every chunk except 0, 3, and the last -> then NAK-repair them.
  local drop = { [0] = true, [3] = true, [tx.count - 1] = true }
  for i = 0, tx.count - 1 do
    if not drop[i] then rx:add(i, tx.chunk(i)) end
  end
  check("rx incomplete before repair", not rx:complete())
  local miss = rx:missing()
  table.sort(miss)
  check("missing list correct", #miss == 3 and miss[1] == 0 and miss[2] == 3
    and miss[3] == tx.count - 1, table.concat(miss, ","))
  for _, i in ipairs(miss) do rx:add(i, tx.chunk(i)) end
  check("rx complete after repair", rx:complete())
  check("reassembled image identical", rx:image() == image,
    #rx:image() .. " vs " .. #image)

  -- NAK codec roundtrip.
  local xid, back = hx.parse.fwnak(hx.pack.fwnak(4242, miss))
  check("fwnak roundtrip", xid == 4242 and #back == 3 and back[1] == 0)
  -- meta codec roundtrip.
  local sha = ("s"):rep(32)
  local a, b, c, dch, e, gsha = hx.parse.fwmeta(hx.pack.fwmeta(1, 12, tx.size, tx.count, 4096, sha))
  check("fwmeta roundtrip", a == 1 and b == 12 and c == tx.size and dch == tx.count
    and e == 4096 and gsha == sha)
end

-- mini radio simulator: multi-hop flood + coverage convergence ------------

do
  -- Store-and-forward bus: broadcasts reach every node within `range`; a flood
  -- converges because each node relays a given (src,seq) at most once (dedup).
  local function newBus(range)
    local entries, byAddr, queue = {}, {}, {}
    local clock = 0
    local bus = { now = function() return clock end }
    function bus.advance(dt) clock = clock + dt end
    function bus.add(addr, pos, mk)
      local e = { addr = addr, pos = pos }
      e.node = mk(function(wire, to) queue[#queue + 1] = { from = e, wire = wire, to = to } end)
      entries[#entries + 1] = e
      byAddr[addr] = e
      return e
    end
    local function dist(a, b)
      local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
      return math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    function bus.pump()
      local guard = 0
      while #queue > 0 do
        guard = guard + 1
        assert(guard < 100000, "flood did not converge")
        local m = table.remove(queue, 1)
        for _, o in ipairs(entries) do
          if o ~= m.from then
            local d = dist(m.from.pos, o.pos)
            if d <= range and (m.to == nil or m.to == o.addr) then
              o.node:submit(m.from.addr, d, m.wire)
            end
          end
        end
      end
    end
    return bus, byAddr
  end

  local bus, byAddr = newBus(400)
  -- Chain: queen -- relay1 -- relay2 -- drone, each hop ~300 blocks apart so only
  -- adjacent nodes are in range. The drone can only reach the queen via 2 relays.
  local function mkNode(id, relay, beaconFn)
    return function(send)
      return hx.new{ id = id, hmac = fakeHmac, now = bus.now, send = send,
        relay = relay, beaconEvery = beaconFn and 1 or nil, beaconFn = beaconFn }
    end
  end

  local qEntry = bus.add("q", { x = 0, y = 70, z = 0 },
    mkNode(hx.QUEEN, true, function() return 0, 70, 0, 0, 0 end))
  local r1, r2, dr
  r1 = bus.add("r1", { x = 300, y = 70, z = 0 }, mkNode(101, true, function()
    local b = r1.node.coverage:best(); return 300, 70, 0, b and b.hops + 1 or 255, 0 end))
  r2 = bus.add("r2", { x = 600, y = 70, z = 0 }, mkNode(102, true, function()
    local b = r2.node.coverage:best(); return 600, 70, 0, b and b.hops + 1 or 255, 0 end))
  dr = bus.add("d", { x = 900, y = 70, z = 0 }, mkNode(7, false, nil))

  -- Run enough beacon rounds for the hop metric to propagate down the chain.
  for _ = 1, 8 do
    bus.advance(1)
    qEntry.node:tick(); r1.node:tick(); r2.node:tick()
    bus.pump()
  end

  local best = dr.node.coverage:best()
  check("drone found coverage", best ~= nil)
  check("drone hop count is 2", best and best.hops == 2, best and best.hops)
  check("drone anchor is relay2", best and best.pos.x == 600, best and best.pos.x)
  check("drone not lost while fresh", not dr.node.coverage:isLost(bus.now()))

  -- Let beacons go stale -> coverage reports lost.
  bus.advance(30)
  check("drone lost after silence", dr.node.coverage:isLost(bus.now()))

  -- A unicast CMD from the queen floods 2 hops and reaches the drone.
  local key7 = hx.deriveKey(("M"):rep(32), 7, fakeHmac)
  dr.node.key = key7
  local recalled = 0
  dr.node:on(hx.T.CMD, function() recalled = recalled + 1 end)
  -- queen must sign with the drone's Kd
  qEntry.node.keyFor = function(id) return hx.deriveKey(("M"):rep(32), id, fakeHmac) end
  qEntry.node.epoch = 3
  qEntry.node:cast(7, hx.T.CMD, hx.pack.cmd(2, ""), { ttl = 5, signed = true })
  bus.pump()
  check("signed unicast reaches drone via flood", recalled == 1, recalled)
end

print(string.rep("-", 40))
if failures == 0 then
  print("all tests passed")
  os.exit(0)
else
  print(failures .. " test(s) failed")
  os.exit(1)
end
