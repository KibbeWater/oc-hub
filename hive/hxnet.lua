-- hxnet.lua: HXP v1 — the hxneyOS swarm wire protocol core.
-- Pure Lua, dependency-injected (hmac / now / send are passed in), so the same
-- module runs on the queen, on robots (OpenOS), inside the RAM firmware bundle
-- delivered to drones, and on the desktop test harness. Install to /usr/lib/hxnet.lua.
--
-- Frame = ONE packed string (always a single modem packet part, <= 8190 bytes):
--   magic "hx"(2) | flags(1) | type(1) | ttl(1) | src u16 | dst u16 | seq u32   = 13 B
--   [ epoch u32 ]   -- present only on SIGNED frames
--   body ...        -- verb-specific, packed little-endian
--   [ mac 16 ]      -- present only on SIGNED frames; first 16 B of hmac-sha256
--
-- Auth: control verbs are HMAC-signed and UNICAST, verified with the receiver's
-- own per-device key Kd. The MAC covers the frame with the ttl byte zeroed, so a
-- relay can decrement ttl without re-signing. Replay is blocked by a strictly
-- increasing (epoch, seq) watermark per source. FW_ANNOUNCE is an UNSIGNED hint:
-- a device acts only on the signed, unicast FW_META that follows, so a forged
-- announce cannot force a reboot and no shared broadcast key is needed.
--
-- Mesh: flooding with dedup. A relay rebroadcasts any unseen frame with ttl>0
-- that is not addressed to itself, decrementing ttl. Beacons (ttl 0) are never
-- relayed; each relay emits its own with hops = min(heard)+1 (distance-vector-lite).

local hxnet = {}

-- Bumped when the wire format changes, so consumers can detect a stale require()
-- cache (package.loaded persists until reboot on OpenOS) and self-heal.
hxnet.VERSION = 1

local MAGIC = "hx"
local WIRE_VER = 1
local HDR = "<c2BBBI2I2I4" -- magic, flags, type, ttl, src, dst, seq
local HDR_LEN = 13
local EPOCH_FMT = "<I4"
local EPOCH_LEN = 4
local MAC_LEN = 16

local FLAG_SIGNED = 0x01
local FLAG_WANTACK = 0x02

hxnet.PORT = 4460
hxnet.QUEEN = 0
hxnet.BROADCAST = 0xFFFF
hxnet.UNASSIGNED = 0xFFFF
hxnet.MAX_BODY = 8190 - HDR_LEN - EPOCH_LEN - MAC_LEN

-- Verb codes.
local T = {
  BEACON = 0x01, HELLO = 0x02, WELCOME = 0x03,
  PING = 0x06, PONG = 0x07,
  TELEM = 0x10, EVT = 0x11, CMD = 0x20,
  FW_ANNOUNCE = 0x30, FW_REQ = 0x31, FW_META = 0x32, FW_CHUNK = 0x33, FW_NAK = 0x34,
}
hxnet.T = T
hxnet.TYPE_NAME = {}
for name, code in pairs(T) do hxnet.TYPE_NAME[code] = name end

-- EVT subcodes (device -> queen event stream).
hxnet.EVT = {
  ACK = 0, PROGRESS = 1, LEG_OK = 2, ROUTE_DONE = 3, ROUTE_BLOCKED = 4,
  NO_LAND = 5, NAV_FAIL = 6, GEOFENCE_REJ = 7, DRIFT = 8, DONE = 9, FAILED = 10,
  -- bulk uploads ride the EVT detail field (no extra verbs needed):
  SCAN = 20, CORRIDOR_ADD = 21,
  -- coverage + authorization notices:
  DEPART = 22, RETURN = 23, UNAUTH = 24,
  -- position triangulation request (device -> queen):
  CALIB = 25,
}

-- CMD opcodes (queen -> device control, carried in a signed CMD frame).
hxnet.CMD = {
  NAV_ROUTE = 1, NAV_CANCEL = 2, ASSIGN = 3, ABORT = 4, RECALL = 5,
  REBOOT = 6, PAUSE = 7, RESUME = 8, LOCATE = 9, DOCK = 10, GRANT = 11, CALIB = 12,
}

-- djb2 hash of a component address -> u32, so waypoint sightings can be matched
-- between a device and the queen without shipping full UUID strings.
function hxnet.hashAddr(s)
  local h = 5381
  for i = 1, #s do h = ((h * 33) + s:byte(i)) & 0xffffffff end
  return h
end

-- Operating modes a device must be authorized for. SCOUT = observe/scan only;
-- DESTRUCTION = may break blocks (mining); TRANSPORT = move items; FARM/BUILD as
-- named. A device refuses block-modifying actions without a matching grant.
hxnet.MODE = { NONE = 0, SCOUT = 1, DESTRUCTION = 2, TRANSPORT = 3, FARM = 4, BUILD = 5 }

-- Device run states (reported in TELEM/PONG).
hxnet.STATE = {
  BOOT = 0, IDLE = 1, WORKING = 2, DOCKING = 3, LOST = 4, LOWPWR = 5, ERROR = 6,
}

-- --------------------------------------------------------------------------
-- Codec
-- --------------------------------------------------------------------------

-- Build the unsigned wire bytes for a frame table. Fields: type, ttl, src, dst,
-- seq, body; signed, epoch, wantAck. Returns the string (call sign() to append a MAC).
function hxnet.encode(f)
  local flags = (WIRE_VER & 0x0f) << 4
  if f.signed then flags = flags | FLAG_SIGNED end
  if f.wantAck then flags = flags | FLAG_WANTACK end
  local hdr = string.pack(HDR, MAGIC, flags, f.type, f.ttl or 0,
    f.src or 0, f.dst or 0, f.seq or 0)
  local mid = f.signed and string.pack(EPOCH_FMT, f.epoch or 0) or ""
  return hdr .. mid .. (f.body or "")
end

-- Parse wire bytes into a frame table (keeps .raw for MAC verification), or nil, err.
function hxnet.decode(s)
  if #s < HDR_LEN then return nil, "short" end
  local magic, flags, typ, ttl, src, dst, seq, pos = string.unpack(HDR, s)
  if magic ~= MAGIC then return nil, "magic" end
  local f = {
    ver = (flags >> 4) & 0x0f,
    signed = (flags & FLAG_SIGNED) ~= 0,
    wantAck = (flags & FLAG_WANTACK) ~= 0,
    type = typ, ttl = ttl, src = src, dst = dst, seq = seq, raw = s,
  }
  if f.signed then
    if #s < HDR_LEN + EPOCH_LEN + MAC_LEN then return nil, "short-signed" end
    f.epoch, pos = string.unpack(EPOCH_FMT, s, pos)
    f.body = s:sub(pos, #s - MAC_LEN)
    f.mac = s:sub(#s - MAC_LEN + 1)
  else
    f.body = s:sub(pos)
  end
  return f
end

-- The byte range a MAC is computed over: the whole frame with the ttl byte
-- (offset 4, i.e. 1-indexed byte 5) zeroed and any trailing MAC removed.
local function signable(bytes)
  return bytes:sub(1, 4) .. "\0" .. bytes:sub(6)
end

-- Append a MAC to already-encoded (SIGNED-flagged, epoch-bearing) bytes.
function hxnet.sign(encoded, key, hmac)
  local mac = hmac(signable(encoded), key):sub(1, MAC_LEN)
  return encoded .. mac
end

-- Verify a decoded frame's MAC against key. Returns boolean.
function hxnet.verify(f, key, hmac)
  if not f.mac then return false end
  local body = f.raw:sub(1, #f.raw - MAC_LEN)
  return hmac(signable(body), key):sub(1, MAC_LEN) == f.mac
end

-- Rewrite the ttl byte of encoded wire bytes without touching anything else
-- (safe on signed frames: the MAC ignores ttl).
function hxnet.withTTL(bytes, ttl)
  return bytes:sub(1, 4) .. string.char(ttl & 0xff) .. bytes:sub(6)
end

-- Kd = first 16 B of hmac(master, "dev"..u16(id)). Per-device control key.
function hxnet.deriveKey(master, id, hmac)
  return hmac(master, "dev" .. string.pack("<I2", id)):sub(1, MAC_LEN)
end

-- --------------------------------------------------------------------------
-- Body codecs (packed little-endian; see header comment for layouts)
-- --------------------------------------------------------------------------

hxnet.pack = {}
hxnet.parse = {}

function hxnet.pack.beacon(x, y, z, hops, flags)
  return string.pack("<i2i2i2BB", x, y, z, hops or 255, flags or 0)
end
function hxnet.parse.beacon(b)
  local x, y, z, hops, flags = string.unpack("<i2i2i2BB", b)
  return x, y, z, hops, flags
end

function hxnet.pack.hello(nonce, role, fwVer)
  return string.pack("<c8BI2", nonce, role or 0, fwVer or 0)
end
function hxnet.parse.hello(b)
  local nonce, role, fwVer = string.unpack("<c8BI2", b)
  return nonce, role, fwVer
end

function hxnet.pack.welcome(nonce, devId, latestFw, qx, qy, qz, intervalCode)
  return string.pack("<c8I2I2i2i2i2B", nonce, devId, latestFw, qx, qy, qz, intervalCode or 0)
end
function hxnet.parse.welcome(b)
  local nonce, devId, latestFw, qx, qy, qz, ic = string.unpack("<c8I2I2i2i2i2B", b)
  return nonce, devId, latestFw, qx, qy, qz, ic
end

function hxnet.pack.telem(x, y, z, energyPct, state, fwVer, role, status)
  return string.pack("<i2i2i2BBI2B", x, y, z, energyPct or 0, state or 0, fwVer or 0, role or 0)
    .. (status or "")
end
function hxnet.parse.telem(b)
  local x, y, z, e, st, fw, role, pos = string.unpack("<i2i2i2BBI2B", b)
  return x, y, z, e, st, fw, role, b:sub(pos)
end

function hxnet.pack.pong(fwVer, state) return string.pack("<I2B", fwVer or 0, state or 0) end
function hxnet.parse.pong(b) return string.unpack("<I2B", b) end

function hxnet.pack.evt(cmdSeq, subcode, result, detail)
  return string.pack("<I4BB", cmdSeq or 0, subcode or 0, result or 0) .. (detail or "")
end
function hxnet.parse.evt(b)
  local seq, sub, res, pos = string.unpack("<I4BB", b)
  return seq, sub, res, b:sub(pos)
end

function hxnet.pack.cmd(opcode, payload) return string.pack("<B", opcode) .. (payload or "") end
function hxnet.parse.cmd(b)
  local op, pos = string.unpack("<B", b)
  return op, b:sub(pos)
end

function hxnet.pack.announce(role, ver) return string.pack("<BI2", role or 0, ver or 0) end
function hxnet.parse.announce(b) return string.unpack("<BI2", b) end

-- Authorization grant: operating mode + area bbox (x/z and a y-range) + ttl (s,
-- 0 = until revoked). Carried by CMD.GRANT and appended to CMD.ASSIGN payloads.
function hxnet.pack.grant(mode, a, ttl)
  return string.pack("<Bi2i2i2i2i2i2I2", mode, a.x1, a.z1, a.x2, a.z2,
    a.y1 or -32768, a.y2 or 32767, ttl or 0)
end
function hxnet.parse.grant(b)
  local mode, x1, z1, x2, z2, y1, y2, ttl = string.unpack("<Bi2i2i2i2i2i2I2", b)
  return mode, { x1 = x1, z1 = z1, x2 = x2, z2 = z2, y1 = y1, y2 = y2 }, ttl
end
hxnet.GRANT_LEN = 15

-- Calibration request: device raw fix + the waypoints it sees (addr-hash + the
-- position of the waypoint relative to the device). The queen solves a universal
-- frame offset from these.
function hxnet.pack.calib(raw, sightings)
  local parts = { string.pack("<i2i2i2B", raw.x, raw.y, raw.z, #sightings) }
  for _, s in ipairs(sightings) do
    parts[#parts + 1] = string.pack("<I4i2i2i2", s.key, s.rel.x, s.rel.y, s.rel.z)
  end
  return table.concat(parts)
end
function hxnet.parse.calib(b)
  local x, y, z, n, pos = string.unpack("<i2i2i2B", b)
  local sightings = {}
  for _ = 1, n do
    local key, rx, ry, rz
    key, rx, ry, rz, pos = string.unpack("<I4i2i2i2", b, pos)
    sightings[#sightings + 1] = { key = key, rel = { x = rx, y = ry, z = rz } }
  end
  return { x = x, y = y, z = z }, sightings
end

-- Calibration result: the universal-frame offset to add to the device's raw fix.
function hxnet.pack.caloff(off) return string.pack("<i2i2i2", off.x, off.y, off.z) end
function hxnet.parse.caloff(b)
  local x, y, z = string.unpack("<i2i2i2", b)
  return { x = x, y = y, z = z }
end

function hxnet.pack.fwreq(stage, role, haveVer)
  return string.pack("<BBI2", stage or 0, role or 0, haveVer or 0)
end
function hxnet.parse.fwreq(b) return string.unpack("<BBI2", b) end

-- FW_META: fixed head + 32-byte sha256 + optional appended file table (robot bundles).
function hxnet.pack.fwmeta(xferId, ver, size, count, chunkSize, sha, extra)
  assert(#sha == 32, "sha256 must be 32 bytes")
  return string.pack("<I2I2I4I2I2", xferId, ver, size, count, chunkSize) .. sha .. (extra or "")
end
function hxnet.parse.fwmeta(b)
  local xferId, ver, size, count, chunkSize, pos = string.unpack("<I2I2I4I2I2", b)
  local sha = b:sub(pos, pos + 31)
  return xferId, ver, size, count, chunkSize, sha, b:sub(pos + 32)
end

function hxnet.pack.fwchunk(xferId, idx, data)
  return string.pack("<I2I2", xferId, idx) .. data
end
function hxnet.parse.fwchunk(b)
  local xferId, idx, pos = string.unpack("<I2I2", b)
  return xferId, idx, b:sub(pos)
end

-- FW_NAK: xferId + count + count*u16 indices. count 0 = "complete & verified" ack.
function hxnet.pack.fwnak(xferId, missing)
  local parts = { string.pack("<I2I2", xferId, #missing) }
  for _, m in ipairs(missing) do parts[#parts + 1] = string.pack("<I2", m) end
  return table.concat(parts)
end
function hxnet.parse.fwnak(b)
  local xferId, count, pos = string.unpack("<I2I2", b)
  local m = {}
  for _ = 1, count do
    local v; v, pos = string.unpack("<I2", b, pos)
    m[#m + 1] = v
  end
  return xferId, m
end

-- --------------------------------------------------------------------------
-- Dedup ring: fixed-capacity FIFO set, O(1) seen-check with eviction.
-- --------------------------------------------------------------------------

function hxnet.dedup(cap)
  cap = cap or 128
  local set, ring, pos = {}, {}, 1
  return {
    -- Returns true if key was already present; otherwise records it and returns false.
    seen = function(self, key)
      if set[key] then return true end
      local old = ring[pos]
      if old ~= nil then set[old] = nil end
      ring[pos] = key
      set[key] = true
      pos = pos % cap + 1
      return false
    end,
    has = function(self, key) return set[key] == true end,
  }
end

-- --------------------------------------------------------------------------
-- Chunked transfer (firmware / large payloads)
-- --------------------------------------------------------------------------

-- Split an image into fixed-size chunks. chunk(i) is 0-indexed.
function hxnet.tx(image, chunkSize)
  chunkSize = chunkSize or 4096
  local count = math.max(1, math.ceil(#image / chunkSize))
  return {
    size = #image, chunkSize = chunkSize, count = count,
    chunk = function(i)
      local off = i * chunkSize
      return image:sub(off + 1, off + chunkSize)
    end,
  }
end

-- Digest a large image without tripping the data card's per-call size limit: the
-- card's sha256 is a DIRECT callback and can't pause, so inputs over the ~8 KB soft
-- limit return nil. Hash each <=blk block, then hash the concatenation of block
-- hashes. Deterministic given shaFn; the queen and boot0 compute it identically.
function hxnet.imageDigest(bytes, shaFn, blk)
  blk = blk or 4096
  local parts = {}
  for i = 1, #bytes, blk do parts[#parts + 1] = shaFn(bytes:sub(i, i + blk - 1)) end
  return shaFn(table.concat(parts))
end

-- Reassembler with NAK support. add() is 0-indexed and idempotent.
function hxnet.rx(count, chunkSize, size)
  local parts, have = {}, 0
  return {
    count = count, chunkSize = chunkSize, size = size,
    add = function(self, idx, data)
      if idx >= 0 and idx < count and not parts[idx] then
        parts[idx] = data
        have = have + 1
      end
    end,
    have = function(self) return have end,
    complete = function(self) return have >= count end,
    missing = function(self, cap)
      local m = {}
      for i = 0, count - 1 do
        if not parts[i] then
          m[#m + 1] = i
          if cap and #m >= cap then break end
        end
      end
      return m
    end,
    image = function(self)
      local t = {}
      for i = 0, count - 1 do t[#t + 1] = parts[i] or "" end
      return table.concat(t)
    end,
  }
end

-- --------------------------------------------------------------------------
-- Coverage tracker: which relay/queen beacons a mobile device has heard, so it
-- knows where to fly to re-establish contact when it drifts out of range.
-- --------------------------------------------------------------------------

function hxnet.coverage()
  local anchors = {} -- src -> {pos, hops, dist, at}
  local cov = {}
  function cov:update(src, pos, hops, dist, t)
    anchors[src] = { pos = pos, hops = hops, dist = dist, at = t }
  end
  -- Best queen-reachable anchor: fewest hops, then freshest.
  function cov:best()
    local best
    for _, a in pairs(anchors) do
      if a.hops < 255 then
        if not best or a.hops < best.hops
          or (a.hops == best.hops and a.at > best.at) then
          best = a
        end
      end
    end
    return best
  end
  function cov:anchor()
    local b = self:best()
    return b and b.pos or nil
  end
  -- No queen-reachable beacon within `timeout` seconds of `t` -> considered lost.
  function cov:isLost(t, timeout)
    local b = self:best()
    if not b then return true end
    return (t - b.at) > (timeout or 15)
  end
  function cov:all() return anchors end
  return cov
end

-- --------------------------------------------------------------------------
-- Node engine: dedup + relay + replay-guard + dispatch over an injected radio.
-- --------------------------------------------------------------------------

local Node = {}
Node.__index = Node

-- opts: id, key, hmac, now, send(wire, toAddr|nil), relay(bool), epoch,
--       seq0, dedupCap, keyFor(id)->key, beaconEvery, beaconFn()->x,y,z,hops,flags
function hxnet.new(opts)
  local n = setmetatable({}, Node)
  n.id = opts.id or hxnet.QUEEN
  n.key = opts.key
  n.hmac = opts.hmac
  n.now = opts.now or function() return 0 end
  n.send = assert(opts.send, "hxnet.new requires send")
  n.relay = opts.relay or false
  n.epoch = opts.epoch or 1
  n.seq = opts.seq0 or 0
  n.keyFor = opts.keyFor or function() return n.key end
  n.beaconEvery = opts.beaconEvery
  n.beaconFn = opts.beaconFn
  n.handlers = {}
  n.watermark = {} -- src -> {epoch, seq}
  n.dedup = hxnet.dedup(opts.dedupCap or 128)
  n.coverage = hxnet.coverage()
  n._nextBeacon = 0
  return n
end

function Node:on(typ, handler)
  self.handlers[typ] = handler
  return self
end

-- Build, optionally sign, and send a frame. opts: ttl, signed, wantAck, epoch,
-- key (override signing key), to (unicast modem address; nil = broadcast).
-- Returns the seq used.
function Node:cast(dst, typ, body, opts)
  opts = opts or {}
  self.seq = self.seq + 1
  local f = {
    type = typ, ttl = opts.ttl or 0, src = self.id, dst = dst,
    seq = self.seq, body = body or "", signed = opts.signed,
    wantAck = opts.wantAck,
    epoch = opts.signed and (opts.epoch or self.epoch) or nil,
  }
  local wire = hxnet.encode(f)
  if opts.signed then
    wire = hxnet.sign(wire, opts.key or self.keyFor(dst), self.hmac)
  end
  self.send(wire, opts.to)
  return self.seq
end

-- Feed one received packet. fromAddr = neighbor modem address, dist = distance
-- from that neighbor (metres), wire = packet bytes.
function Node:submit(fromAddr, dist, wire)
  local f = hxnet.decode(wire)
  if not f then return end
  if f.src == self.id then return end -- ignore our own flooded echo
  local key = (f.src << 32) | f.seq
  if self.dedup:seen(key) then return end -- already handled/relayed

  -- Flood relay happens before (and independent of) local processing, so relays
  -- forward frames they can't authenticate.
  if self.relay and f.ttl > 0 and f.dst ~= self.id then
    self.send(hxnet.withTTL(wire, f.ttl - 1), nil)
  end

  if f.dst ~= self.id and f.dst ~= hxnet.BROADCAST then return end

  if f.signed then
    if not (self.hmac and self.key and hxnet.verify(f, self.key, self.hmac)) then return end
    local wm = self.watermark[f.src]
    if wm and (f.epoch < wm.epoch or (f.epoch == wm.epoch and f.seq <= wm.seq)) then
      return -- replay
    end
    self.watermark[f.src] = { epoch = f.epoch, seq = f.seq }
  end

  if f.type == T.BEACON then
    local x, y, z, hops = hxnet.parse.beacon(f.body)
    self.coverage:update(f.src, { x = x, y = y, z = z }, hops, dist, self.now())
  end

  local h = self.handlers[f.type]
  if h then h(f, dist, fromAddr) end
end

-- Emit a due beacon (if configured) and report seconds until the next timer.
function Node:tick()
  if self.beaconEvery and self.beaconFn then
    local t = self.now()
    if t >= self._nextBeacon then
      local x, y, z, hops, flags = self.beaconFn()
      self:cast(hxnet.BROADCAST, T.BEACON, hxnet.pack.beacon(x, y, z, hops, flags), { ttl = 0 })
      self._nextBeacon = t + self.beaconEvery
    end
    return math.max(0, self._nextBeacon - self.now())
  end
  return math.huge
end

return hxnet
