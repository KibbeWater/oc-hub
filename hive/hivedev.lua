-- hivedev.lua: developer helpers for the hive.
-- Build/inspect role firmware, trigger an OTA announce, and spawn fake devices
-- so the dashboard can be worked on without hardware. Install to /usr/bin/hivedev.lua.
--
-- Usage:
--   hivedev build <role>         build the drone image, print size + version
--   hivedev push  <role>         build, bump version, broadcast FW_ANNOUNCE (OTA)
--   hivedev fake  <n>            inject N fake devices into the registry
--   hivedev clearfake            remove fake devices (ids >= 1000)

package.path = "/usr/lib/hive/core/?.lua;/usr/lib/hive/sdk/?.lua;/usr/lib/hive/roles/?.lua;" .. package.path

local hxnet = require("hxnet")
local boot = require("hive.core.bootstrap")
local shared = require("hive.core.shared")

local cmd, arg1 = ...

local function svcOrLoad()
  return shared.svc or boot.bringUp(boot.loadConfig())
end

if cmd == "build" then
  local role = arg1 or "scout"
  local svc = svcOrLoad()
  local img, ver, sha, stats = svc.firmware.build(role)
  if not img then print("build failed: " .. tostring(ver)); return end
  print(string.format("role %s  v%d  %d bytes (from %d)  sha %s",
    role, ver, #img, stats and stats.before or #img,
    (sha or ""):sub(1, 6):gsub(".", function(c) return string.format("%02x", c:byte()) end)))
elseif cmd == "push" then
  local role = arg1 or "scout"
  local svc = svcOrLoad()
  local _, ver = svc.firmware.build(role)
  if not shared.net then
    print("hived is not running; cannot announce. Devices will fetch v" .. tostring(ver)
      .. " on their next boot.")
    return
  end
  for _ = 1, 3 do shared.net.announce(({ scout = 1, relay = 2, miner = 3,
    courier = 4, farmer = 5 })[role] or 1, ver) end
  print(string.format("announced %s v%d to the fleet", role, ver))
elseif cmd == "fake" then
  local n = tonumber(arg1) or 3
  local svc = svcOrLoad()
  local roles = { "scout", "courier", "miner", "farmer" }
  for i = 1, n do
    local id = 1000 + i
    local role = roles[(i - 1) % #roles + 1]
    svc.registry.join(id, { role = role, kind = (role == "miner" or role == "farmer")
      and "robot" or "drone", caps = { role == "scout" and "scan" or role }, fw = 1 })
    svc.registry.upsertBeacon(id, {
      pos = { x = math.random(-300, 300), y = 70, z = math.random(-300, 300) },
      energy = 0.3 + math.random() * 0.7, state = math.random(1, 2) })
  end
  svc.registry.save()
  print(("injected %d fake device(s)"):format(n))
elseif cmd == "clearfake" then
  local svc = svcOrLoad()
  local removed = 0
  for id in pairs(svc.registry.all()) do
    if type(id) == "number" and id >= 1000 then svc.registry.forget(id); removed = removed + 1 end
  end
  svc.registry.save()
  print(("removed %d fake device(s)"):format(removed))
else
  print("hivedev - hive developer helpers")
  print("usage: hivedev build <role> | push <role> | fake <n> | clearfake")
end
