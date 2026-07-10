-- hivebot.lua: the OpenOS robot daemon.
-- Loads the node config + role and runs robot_sdk against the real robot API.
-- `hivebot pair` consumes a PIN-protected ticket from hxflash to provision this
-- robot; `hivebot update` pulls new code and reboots. Install to /usr/bin/hivebot.lua.
--
-- Usage:  hivebot [run] | pair | status | update

local component = require("component")
local computer = require("computer")
local serialization = require("serialization")
local fs = require("filesystem")

local hxnet = require("hxnet")
if hxnet.VERSION ~= 1 then package.loaded.hxnet = nil; hxnet = require("hxnet") end

local CFG = "/etc/hive/node.cfg"
local ROLE_NUM = { scout = 1, relay = 2, miner = 3, courier = 4, farmer = 5 }

local function loadCfg()
  local f = io.open(CFG, "rb")
  if not f then return nil end
  local d = f:read("*a"); f:close()
  return serialization.unserialize(d)
end

local function saveCfg(cfg)
  if not fs.exists("/etc/hive") then fs.makeDirectory("/etc/hive") end
  local f = assert(io.open(CFG, "wb"))
  f:write(serialization.serialize(cfg)); f:close()
end

-- --- run -------------------------------------------------------------------

local function cmdRun()
  local cfg = loadCfg()
  if not cfg then print("Not provisioned. Run 'hivebot pair' first."); return end
  if not component.isAvailable("modem") then error("a wireless card is required") end
  if not component.isAvailable("data") then error("a data card is required") end
  local role = require("hive.roles." .. cfg.role)
  local robotSdk = require("hive.sdk.robot_sdk")
  robotSdk.mainFromComponents(role, {
    id = cfg.id, key = cfg.key, role = ROLE_NUM[cfg.role] or 3, fw = cfg.fw or 0,
    port = cfg.port or hxnet.PORT, home = cfg.home, queen = cfg.queen,
    reboot = function() computer.shutdown(true) end,
  })
end

-- --- pair ------------------------------------------------------------------

local function cmdPair()
  if not component.isAvailable("modem") or not component.isAvailable("data") then
    print("Pairing needs a wireless card + data card."); return
  end
  local modem = component.modem
  local data = component.data
  local port = hxnet.PORT
  io.write("Enter the PIN shown by hxflash: ")
  local pin = (io.read() or ""):gsub("%s", "")
  if pin == "" then print("Aborted."); return end
  modem.open(port)
  if modem.setStrength then modem.setStrength(400) end
  print("Requesting pairing ticket (run hxflash option 3 on the queen)...")

  local role = "miner"
  local deadline = computer.uptime() + 60
  while computer.uptime() < deadline do
    modem.broadcast(port, "hxpreq")
    local sig = { computer.pullSignal(2) }
    if sig[1] == "modem_message" and sig[4] == port and type(sig[6]) == "string"
      and sig[6]:sub(1, 4) == "hxp1" then
      local body = sig[6]:sub(5)
      local nlen, p = string.unpack("<I2", body)
      local nonce = body:sub(p, p + nlen - 1); p = p + nlen
      local ilen; ilen, p = string.unpack("<I2", body, p)
      local iv = body:sub(p, p + ilen - 1); p = p + ilen
      local ct = body:sub(p)
      local kek = data.sha256(pin .. nonce):sub(1, 16)
      local ok, payload = pcall(data.decrypt, ct, kek, iv)
      if ok and payload and #payload >= 19 then
        local id, rc = string.unpack("<I2B", payload)
        local key = payload:sub(4, 19)
        role = ({ [3] = "miner", [4] = "courier", [5] = "farmer", [1] = "scout" })[rc] or "miner"
        saveCfg{ id = id, key = key, role = role, port = port, fw = 0 }
        print(("Paired as %s #%d. Enabling daemon..."):format(role, id))
        pcall(function() os.execute("rc hivebot enable") end)
        print("Run 'hivebot' or reboot to start.")
        return
      else
        print("Decryption failed (wrong PIN?). Retrying...")
      end
    end
  end
  print("Timed out waiting for a pairing ticket.")
end

-- --- update ----------------------------------------------------------------

local function cmdUpdate()
  -- Robots keep code on disk; pull the latest and reboot into it.
  if fs.exists("/usr/bin/ocgit.lua") then
    print("Pulling latest via ocgit...")
    os.execute("ocgit pull /home/hive-src")
    os.execute("ocgit install /home/hive-src")
  end
  print("Rebooting into updated code...")
  computer.shutdown(true)
end

-- --- dispatch --------------------------------------------------------------

local cmd = (({ ... })[1]) or "run"
if cmd == "run" then cmdRun()
elseif cmd == "pair" then cmdPair()
elseif cmd == "update" then cmdUpdate()
elseif cmd == "status" then
  local cfg = loadCfg()
  if cfg then print(("hivebot: %s #%d on port %d"):format(cfg.role, cfg.id, cfg.port or 4460))
  else print("hivebot: not provisioned") end
else
  print("hivebot - hive robot daemon")
  print("usage: hivebot [run] | pair | status | update")
end
