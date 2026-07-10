-- hxflash.lua: hxneyOS device provisioning wizard.
-- Flashes an inserted EEPROM as a drone/worker bootloader (boot0) or a mesh relay
-- (relay0), baking the device id, per-device key, home/position and port into the
-- data area; or issues a PIN-protected pairing ticket for an OpenOS robot. Run on
-- the queen with the target EEPROM inserted. Install to /usr/bin/hxflash.lua.

local component = require("component")
local hxnet = require("hxnet")
local boot = require("hive.core.bootstrap")
local shared = require("hive.core.shared")
local optimize = require("optimize")

local BOOT0 = "/usr/share/hxney/boot0.lua"
local RELAY0 = "/usr/share/hxney/relay0.lua"

local ROLE = { scout = 1, relay = 2, miner = 3, courier = 4, farmer = 5 }

local function ask(prompt, default)
  io.write(prompt .. (default and (" [" .. tostring(default) .. "]") or "") .. ": ")
  local v = io.read()
  if not v or v == "" then return default end
  return v
end

local function askNum(prompt, default)
  return tonumber(ask(prompt, default)) or default
end

local function readSource(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a"); f:close()
  return d
end

-- --- prerequisites ---------------------------------------------------------

if not component.isAvailable("eeprom") then
  print("Insert a blank EEPROM to flash, then re-run hxflash."); return
end
if not component.isAvailable("data") then
  print("A Data Card is required (key derivation / encryption)."); return
end
local eeprom = component.eeprom
local data = component.data

local master = boot.readFileRaw(boot.KEY_PATH)
if not master then print("Run 'hived init' first (no swarm key)."); return end
local hmac = function(m, k) return data.sha256(m, k) end

-- live services if hived is running, else a read-only bring-up for the registry
local svc = shared.svc or boot.bringUp(boot.loadConfig())
local cfg = svc.cfg or boot.loadConfig()

local function nextId()
  local m = 0
  for id in pairs(svc.registry.all()) do
    if type(id) == "number" and id < 1000 and id > m then m = id end
  end
  return m + 1
end

-- --- data-area packer ------------------------------------------------------

local function packData(id, role, port, key, home)
  return "hx" .. string.char(1)
    .. string.pack("<I2BI2", id, role, port)
    .. key
    .. string.pack("<i2i2i2", home.x, home.y, home.z)
    .. string.pack("<i2i2i2", home.x, home.y, home.z) -- coverage hint = home at flash time
    .. string.char(0)
end

local function flashEeprom(source, dataArea, label)
  local stripped = optimize.safeStrip(source)
  if #stripped > 4096 then
    print(("ERROR: image is %d bytes, over the 4096 EEPROM limit."):format(#stripped))
    return false
  end
  print(("Flashing %d bytes of code + %d bytes of config..."):format(#stripped, #dataArea))
  eeprom.set(stripped)      -- ~2s pause
  eeprom.setData(dataArea)  -- ~1s pause
  pcall(eeprom.setLabel, label)
  return true
end

-- --- flows -----------------------------------------------------------------

local function flashDrone()
  local role = ask("Role (scout/courier/miner)", "scout")
  local rc = ROLE[role] or 1
  local id = askNum("Device id", nextId())
  local o = cfg.origin or { x = 0, y = 64, z = 0 }
  local home = {
    x = askNum("Home X (charger/dock)", o.x),
    y = askNum("Home Y", o.y),
    z = askNum("Home Z", o.z),
  }
  local port = askNum("Port", cfg.port or hxnet.PORT)
  local src = readSource(BOOT0)
  if not src then print("Cannot read " .. BOOT0); return end
  local Kd = hxnet.deriveKey(master, id, hmac)
  if not flashEeprom(src, packData(id, rc, port, Kd, home), ("hxney d#%d %s"):format(id, role)) then return end
  svc.registry.join(id, { role = role, kind = "drone", caps = { role == "scout" and "scan" or role },
    fw = 0, home = home })
  svc.registry.save()
  print(("Done. Drone #%d (%s) provisioned. Assemble it with this EEPROM and power on in coverage.")
    :format(id, role))
end

local function flashRelay()
  local id = askNum("Relay id", nextId())
  local pos = {
    x = askNum("Relay X", 0), y = askNum("Relay Y", 70), z = askNum("Relay Z", 0),
  }
  local port = askNum("Port", cfg.port or hxnet.PORT)
  local src = readSource(RELAY0)
  if not src then print("Cannot read " .. RELAY0); return end
  local Kd = hxnet.deriveKey(master, id, hmac)
  if not flashEeprom(src, packData(id, ROLE.relay, port, Kd, pos), ("hxney relay#%d"):format(id)) then return end
  svc.registry.join(id, { role = "relay", kind = "mcu", caps = {}, fw = 0, home = pos })
  svc.registry.save()
  print(("Done. Relay #%d provisioned. Place the microcontroller and wire it to base power.")
    :format(id))
end

local function robotTicket()
  if not component.isAvailable("modem") then print("A wireless card is needed to broadcast the ticket."); return end
  local role = ask("Robot role (miner/farmer)", "miner")
  local rc = ROLE[role] or 3
  local id = askNum("Device id", nextId())
  local port = askNum("Port", cfg.port or hxnet.PORT)
  local Kd = hxnet.deriveKey(master, id, hmac)
  -- PIN-derived key wraps (id, Kd); the robot decrypts after the operator types the PIN.
  local pin = tostring(math.random(100000, 999999))
  local nonce = data.random(8)
  local kek = data.sha256(pin .. nonce, nil):sub(1, 16)
  local iv = data.random(16)
  local payload = string.pack("<I2B", id, rc) .. Kd
  local ct = data.encrypt(payload, kek, iv)
  local modem = component.modem
  modem.open(port)
  if modem.setStrength then modem.setStrength(400) end
  local offer = "hxp1" .. string.pack("<I2", #nonce) .. nonce .. string.pack("<I2", #iv) .. iv .. ct
  svc.registry.join(id, { role = role, kind = "robot", caps = { role, "mine" }, fw = 0 })
  svc.registry.save()
  print(("Robot #%d (%s) PIN: %s"):format(id, role, pin))
  print("On the robot run 'hivebot pair' and enter that PIN. Waiting for it...")
  -- Send the offer whenever the robot requests it (up to 60s).
  local computer = require("computer")
  local deadline = computer.uptime() + 60
  while computer.uptime() < deadline do
    local sig = { computer.pullSignal(2) }
    if sig[1] == "modem_message" and sig[4] == port and sig[6] == "hxpreq" then
      modem.send(sig[3], port, offer)
      modem.broadcast(port, offer)
      print("Ticket sent.")
      return
    end
  end
  print("Timed out; re-run to retry.")
end

-- --- menu ------------------------------------------------------------------

print("hxflash - hxneyOS provisioning")
print("  1) Flash drone/worker bootloader (boot0)")
print("  2) Flash mesh relay (relay0)")
print("  3) Issue robot pairing ticket (OpenOS)")
local choice = ask("Choose", "1")
if choice == "1" then flashDrone()
elseif choice == "2" then flashRelay()
elseif choice == "3" then robotTicket()
else print("Nothing to do.") end
