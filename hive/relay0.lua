-- relay0.lua: hxneyOS mesh relay firmware (EEPROM, <2500 B).
-- Self-contained: flood-forwards HXP frames with dedup, beacons its fixed position
-- with a hop count derived from the beacons it hears (distance-vector-lite), and
-- answers PING. Needs no data card (it forwards blindly; MACs are end-to-end) and
-- works with the queen down. Runs on a tier-2 microcontroller wired to base power.
--
-- EEPROM data area: "hx" ver | id u16 | role u8 | port u16 | (Kd 16, unused) |
--   position x,y,z i16 (bytes 25-30) | ...

local C = component
local eeprom = C.proxy(C.list("eeprom")())
local mo = C.list("modem")() and C.proxy(C.list("modem")())
if not mo then error("relay needs a wireless card", 0) end

local cfg = eeprom.getData() or ""
local id, role, port = string.unpack("<I2BI2", cfg, 4)
local px, py, pz = string.unpack("<i2i2i2", cfg, 25)
port = port ~= 0 and port or 4460
mo.open(port)
if mo.isWireless and mo.isWireless() then pcall(mo.setStrength, 400) end

local M, H = "hx", "<c2BBBI2I2I4"
local cap, seen, ring, rp = 128, {}, {}, 1
local function dup(key)
  if seen[key] then return true end
  local old = ring[rp]
  if old then seen[old] = nil end
  ring[rp] = key; seen[key] = true; rp = rp % cap + 1
  return false
end

local seq = 0
local bestHops, bestAt = 255, 0
local function beacon()
  seq = seq + 1
  local hops = math.min(255, bestHops + 1)
  mo.broadcast(port, string.pack(H, M, 16, 1, 0, id, 0xFFFF, seq)
    .. string.pack("<i2i2i2BB", px, py, pz, hops, 0))
end

local last = 0
while true do
  local sg = table.pack(computer.pullSignal(1))
  if sg[1] == "modem_message" and sg[4] == port and type(sg[6]) == "string" then
    local s = sg[6]
    if #s >= 13 and s:sub(1, 2) == M then
      local _, fl, ty, tt, src, dst, sq, p = string.unpack(H, s)
      local key = (src << 32) | sq
      if not dup(key) then
        if tt > 0 and dst ~= id then
          mo.broadcast(port, s:sub(1, 4) .. string.char(tt - 1) .. s:sub(6))
        end
        if ty == 1 then -- BEACON: learn hop distance to the queen
          local _, _, _, bh = string.unpack("<i2i2i2BB", s:sub(p))
          local now = computer.uptime()
          if bh < 255 and (bh < bestHops or now - bestAt > 15) then
            bestHops, bestAt = bh, now
          end
        elseif ty == 6 and (dst == id or dst == 0xFFFF) then -- PING -> PONG
          seq = seq + 1
          mo.broadcast(port, string.pack(H, M, 16, 7, 3, id, src, seq)
            .. string.pack("<I2B", 0, 1))
        end
      end
    end
  end
  local t = computer.uptime()
  if t - last >= 5 then
    if t - bestAt > 15 then bestHops = 255 end -- queen went silent
    beacon(); last = t
  end
end
