-- OC Installer bootstrap BIOS.
-- Flashed onto an EEPROM by installer/flash.lua (mkinstaller). Reads its
-- configuration from the EEPROM data area ("owner/repo|branch|stage2path"),
-- downloads the stage-2 installer from GitHub raw and runs it.
-- Runs in a bare machine environment: no OpenOS, only component/computer.
-- Must stay under 4096 bytes; full-line comments are stripped when flashing.

local function proxy(kind)
  local address = component.list(kind)()
  return address and component.proxy(address)
end

local eeprom = proxy("eeprom")
local inet = proxy("internet")

local gpu, W, H, y = proxy("gpu"), 0, 0, 1
local screen = component.list("screen")()
if gpu and screen then
  gpu.bind(screen)
  W, H = gpu.getResolution()
  gpu.setBackground(0x000000)
  gpu.setForeground(0xFFFFFF)
  gpu.fill(1, 1, W, H, " ")
else
  gpu = nil
end

local function say(text)
  if not gpu then return end
  if y > H then
    gpu.copy(1, 2, W, H - 1, 0, -1)
    gpu.fill(1, H, W, 1, " ")
    y = H
  end
  gpu.set(1, y, tostring(text))
  y = y + 1
end

local function fail(msg)
  msg = tostring(msg)
  say("ERROR: " .. msg)
  if computer.beep then pcall(computer.beep, 200, 0.4) end
  error(msg, 0)
end

if not eeprom then fail("no eeprom") end
if not inet then fail("an internet card is required") end

local cfg = eeprom.getData() or ""
local owner, repo, branch, stage2 = cfg:match("^([^/|]+)/([^|]+)|([^|]+)|(.+)$")
if not owner then fail("installer eeprom is not configured") end

local function fetch(url, headers)
  local handle, reason = inet.request(url, nil, headers)
  if not handle then fail(reason or ("request failed: " .. url)) end
  local deadline = computer.uptime() + 30
  while true do
    local ok, err = handle.finishConnect()
    if ok then break end
    if ok == nil then
      handle.close()
      fail((err or "connection failed") .. ": " .. url)
    end
    if computer.uptime() > deadline then
      handle.close()
      fail("timeout: " .. url)
    end
    computer.pullSignal(0.05)
  end
  local status = handle.response()
  if status and (status < 200 or status >= 300) then
    handle.close()
    fail("HTTP " .. status .. ": " .. url)
  end
  local buf = {}
  while true do
    local chunk, err = handle.read()
    if chunk then
      if #chunk > 0 then
        buf[#buf + 1] = chunk
      else
        computer.pullSignal(0.05)
      end
    elseif err then
      handle.close()
      fail(err .. ": " .. url)
    else
      break
    end
  end
  handle.close()
  return table.concat(buf)
end

say("OC Installer  " .. owner .. "/" .. repo .. "@" .. branch)
say("downloading " .. stage2 .. " ...")
local source = fetch("https://raw.githubusercontent.com/"
  .. owner .. "/" .. repo .. "/" .. branch .. "/" .. stage2)
local main, err = load(source, "=stage2")
if not main then fail(err) end
main({
  owner = owner, repo = repo, branch = branch,
  eeprom = eeprom, inet = inet, gpu = gpu,
  say = say, fail = fail, fetch = fetch,
})
