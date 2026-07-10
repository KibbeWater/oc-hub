-- boot0.lua: the hxneyOS drone/worker secure bootloader (EEPROM, <4096 B).
-- Authenticates to the queen, downloads its role firmware into RAM, verifies the
-- sha256, and runs it -- re-fetching on every reboot (netboot model), so OTA is
-- just "reboot into the latest". No OpenOS; bare BIOS environment. Flashed by hxflash.
--
-- EEPROM data area (packed LE):
--   "hx" ver | id u16 | role u8 | port u16 | Kd(16) | home x,y,z i16 | hint x,y,z i16 | flags u8

local C = component
local eeprom = C.proxy(C.list("eeprom")())
local dat = C.list("data")() and C.proxy(C.list("data")())
local mo = C.list("modem")() and C.proxy(C.list("modem")())
local dr = C.list("drone")() and C.proxy(C.list("drone")())
local function st(s) if dr then pcall(dr.setStatusText, s) end end
if not mo or not dat then st("NO NET/DATA") error("need modem+data", 0) end

local cfg = eeprom.getData() or ""
local id, role, port = string.unpack("<I2BI2", cfg, 4)
local k = cfg:sub(9, 24)
local hx, hy, hz = string.unpack("<i2i2i2", cfg, 25)
port = port ~= 0 and port or 4460
mo.open(port)
if mo.isWireless and mo.isWireless() then pcall(mo.setStrength, 400) end

local M, ML, H = "hx", 16, "<c2BBBI2I2I4"
local sq = 0
local function snd(ty, dst, body, sg)
  sq = sq + 1
  local w = string.pack(H, M, 16 | (sg and 1 or 0), ty, 5, id, dst, sq)
    .. (sg and string.pack("<I4", 0) or "") .. (body or "")
  if sg then w = w .. dat.sha256(w:sub(1, 4) .. "\0" .. w:sub(6), k):sub(1, ML) end
  mo.broadcast(port, w)
end
local function dec(s)
  if type(s) ~= "string" or #s < 13 or s:sub(1, 2) ~= M then return end
  local _, fl, ty, _, _, dst, _, p = string.unpack(H, s)
  local f = { t = ty, dst = dst, sg = (fl & 1) ~= 0, raw = s }
  if f.sg then
    if #s < 33 then return end
    _, p = string.unpack("<I4", s, p)
    f.b, f.mac = s:sub(p, #s - ML), s:sub(#s - ML + 1)
  else
    f.b = s:sub(p)
  end
  return f
end
local function ver(f)
  if not f.mac then return end
  local b = f.raw:sub(1, #f.raw - ML)
  return dat.sha256(b:sub(1, 4) .. "\0" .. b:sub(6), k):sub(1, ML) == f.mac
end

st("JOIN...")
local qn = { x = 0, y = 64, z = 0 }
local no = dat.random(8)
local function hello() snd(2, 0, string.pack("<c8BI2", no, role, 0)) end
local function req() snd(0x31, 0, string.pack("<BBI2", 0, role, 0)) end
hello()

local rx, meta, jn = nil, nil, false
local lh, lr = computer.uptime(), 0
while true do
  local sg = table.pack(computer.pullSignal(1))
  if sg[1] == "modem_message" and sg[4] == port then
    local f = dec(sg[6])
    if f and (f.dst == id or f.dst == 0xFFFF) then
      if f.t == 3 and f.sg and ver(f) then
        local n, _, lfw, qx, qy, qz = string.unpack("<c8I2I2i2i2i2B", f.b)
        if n == no then qn = { x = qx, y = qy, z = qz }; jn = true; st("DL..."); req(); lr = computer.uptime() end
      elseif f.t == 0x32 and f.sg and ver(f) then
        local xi, vr, sz, ct, cs, p = string.unpack("<I2I2I4I2I2", f.b)
        meta = { xi = xi, vr = vr, ct = ct, sha = f.b:sub(p, p + 31) }; rx = {}
      elseif f.t == 0x33 and meta then
        local xi, ix, p = string.unpack("<I2I2", f.b)
        if xi == meta.xi and not rx[ix] then rx[ix] = f.b:sub(p) end
      end
    end
  end
  local t = computer.uptime()
  if not jn and t - lh >= 2 then hello(); lh = t end
  if jn and not meta and t - lr >= 3 then req(); lr = t end -- retry the fw request
  if meta and t - lr >= 1 then
    local mi = {}
    for i = 0, meta.ct - 1 do if not rx[i] then mi[#mi + 1] = i end end
    if #mi == 0 then
      local pt = {}
      for i = 0, meta.ct - 1 do pt[#pt + 1] = rx[i] end
      local img = table.concat(pt)
      if dat.sha256(img) == meta.sha then
        st("RUN v" .. meta.vr)
        _HX = { id = id, key = k, role = role, port = port, queen = qn,
          home = { x = hx, y = hy, z = hz }, fw = meta.vr, joined = true }
        local fn = load(img, "=hxfw")
        if fn then pcall(fn) end
        computer.shutdown(true) -- ran, crashed or exited -> reboot + refetch latest
      else
        st("SHA?"); meta = nil; rx = nil; req()
      end
    else
      local pt = { string.pack("<I2I2", meta.xi, #mi) }
      for _, m in ipairs(mi) do pt[#pt + 1] = string.pack("<I2", m) end
      snd(0x34, 0, table.concat(pt))
    end
    lr = t
  end
end
