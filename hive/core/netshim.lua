-- netshim.lua: the queen's network face over hxnet.
-- Wraps an hxnet node with convenience senders (welcome/cmd/announce/beacon),
-- parsed inbound handlers (hello/telemetry/events), and a firmware transfer
-- server that answers FW_REQ with a signed META + chunks and repairs FW_NAKs.
-- Desktop tests drive it over a loopback bus; hived wires it to component.modem.
-- Install to /usr/lib/hive/core/netshim.lua.

local hxnet = require("hxnet")

local netshim = {}

-- opts: id (0 queen), master (32B key), hmac, now, send(wire,toAddr), epoch,
--       relay, firmwareProvider(role, stage) -> image, version, sha32 (optional),
--       chunkSize.
function netshim.new(opts)
  local self = {}
  local master = opts.master
  local hmac = opts.hmac
  local chunkSize = opts.chunkSize or 4096
  local provider = opts.firmwareProvider
  local pace = opts.pace or function() end   -- optional inter-chunk delay
  local logf = opts.log or function() end

  local node = hxnet.new{
    id = opts.id or hxnet.QUEEN,
    hmac = hmac,
    now = opts.now,
    send = opts.send,
    relay = opts.relay ~= false,
    epoch = opts.epoch or 1,
    keyFor = function(id) return hxnet.deriveKey(master, id, hmac) end,
  }
  self.node = node
  self.T = hxnet.T

  -- outbound transfers: devId -> { tx, meta, xferId }
  local transfers = {}
  local nextXfer = 1

  -- --- convenience senders -------------------------------------------------

  function self.beacon(x, y, z, hops, flags)
    node:cast(hxnet.BROADCAST, hxnet.T.BEACON, hxnet.pack.beacon(x, y, z, hops or 0, flags or 0), { ttl = 0 })
  end

  function self.welcome(devId, nonce, assignedId, latestFw, qx, qy, qz, intervalCode)
    node:cast(devId, hxnet.T.WELCOME,
      hxnet.pack.welcome(nonce, assignedId, latestFw or 0, qx or 0, qy or 0, qz or 0, intervalCode or 0),
      { ttl = 5, signed = true })
  end

  -- Signed unicast command. Returns the cmdSeq (for matching EVT acks).
  function self.cmd(devId, opcode, payload)
    return node:cast(devId, hxnet.T.CMD, hxnet.pack.cmd(opcode, payload), { ttl = 5, signed = true })
  end

  function self.announce(role, version)
    node:cast(hxnet.BROADCAST, hxnet.T.FW_ANNOUNCE, hxnet.pack.announce(role, version), { ttl = 5 })
  end

  function self.ping(devId) node:cast(devId, hxnet.T.PING, "", { ttl = 3 }) end

  -- --- inbound -------------------------------------------------------------

  function self.on(verb, fn) node:on(verb, fn) end

  function self.onHello(fn)
    node:on(hxnet.T.HELLO, function(f, dist)
      local nonce, role, fwVer = hxnet.parse.hello(f.body)
      fn(f.src, { nonce = nonce, role = role, fwVer = fwVer }, dist)
    end)
  end

  function self.onTelem(fn)
    node:on(hxnet.T.TELEM, function(f, dist)
      local x, y, z, e, st, fw, role, status = hxnet.parse.telem(f.body)
      fn(f.src, { pos = { x = x, y = y, z = z }, energy = e / 100, state = st,
        fw = fw, role = role, status = status }, dist)
    end)
  end

  function self.onEvt(fn)
    node:on(hxnet.T.EVT, function(f, dist)
      local seq, sub, res, detail = hxnet.parse.evt(f.body)
      fn(f.src, { cmdSeq = seq, subcode = sub, result = res, detail = detail }, dist)
    end)
  end

  -- --- firmware transfer server --------------------------------------------

  -- Send META + every chunk of an image to a device. Records the tx for NAK repair.
  local function beginTransfer(devId, image, version, sha)
    local tx = hxnet.tx(image, chunkSize)
    local xferId = nextXfer
    nextXfer = (nextXfer + 1) % 65536
    transfers[devId] = { tx = tx, xferId = xferId, version = version, sha = sha }
    logf("transfer to %d: %d chunks, %d B", devId, tx.count, tx.size)
    node:cast(devId, hxnet.T.FW_META,
      hxnet.pack.fwmeta(xferId, version, tx.size, tx.count, chunkSize, sha),
      { ttl = 5, signed = true })
    for i = 0, tx.count - 1 do
      node:cast(devId, hxnet.T.FW_CHUNK, hxnet.pack.fwchunk(xferId, i, tx.chunk(i)), { ttl = 5 })
      pace() -- space chunks so a burst doesn't overrun the receiver
    end
  end

  -- Auto-answer FW_REQ (needs a provider) and FW_NAK repairs.
  function self.enableFirmwareServer()
    node:on(hxnet.T.FW_REQ, function(f)
      if not provider then return end
      local stage, role = hxnet.parse.fwreq(f.body)
      local image, version, sha = provider(role, stage)
      if image then beginTransfer(f.src, image, version, sha) end
    end)
    node:on(hxnet.T.FW_NAK, function(f)
      local xferId, missing = hxnet.parse.fwnak(f.body)
      local t = transfers[f.src]
      if not t or t.xferId ~= xferId then return end
      if #missing == 0 then
        transfers[f.src] = nil -- verified-complete ack
        logf("transfer to %d complete", f.src)
        return
      end
      logf("resend %d chunk(s) to %d", #missing, f.src)
      for _, idx in ipairs(missing) do
        node:cast(f.src, hxnet.T.FW_CHUNK, hxnet.pack.fwchunk(xferId, idx, t.tx.chunk(idx)), { ttl = 5 })
        pace()
      end
    end)
  end

  -- --- pump ----------------------------------------------------------------

  function self.submit(fromAddr, dist, wire) node:submit(fromAddr, dist, wire) end
  function self.tick() return node:tick() end
  function self.setEpoch(e) node.epoch = e end

  return self
end

return netshim
