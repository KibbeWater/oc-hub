-- ocnet listener BIOS ("netboot"): flashed by mkinstaller. As soon as the
-- computer boots it listens on a wireless modem for scripts pushed with
-- 'ocpush', runs them, and hot-restarts whenever a new version arrives.
-- Nodes need no hard drive or OpenOS - the script runs from RAM.
--
-- EEPROM data area holds the port number (default 2412).
--
-- Pushed scripts run in a bare environment (component/computer, no OpenOS)
-- and MUST call computer.pullSignal now and then (e.g. as their sleep), so
-- the supervisor can deliver updates. pullSignal is transparently proxied.
-- Must stay under 4096 bytes; comments are stripped when flashing.

local function P(t)
  local a = component.list(t)()
  return a and component.proxy(a)
end

local gpu = P("gpu")
local scr = component.list("screen")()
local W, H, y = 0, 0, 1
if gpu and scr then
  gpu.bind(scr)
  W, H = gpu.getResolution()
  gpu.fill(1, 1, W, H, " ")
else
  gpu = nil
end

local function say(s)
  if not gpu then return end
  if y > H then
    gpu.fill(1, 1, W, H, " ")
    y = 1
  end
  gpu.set(1, y, tostring(s))
  y = y + 1
end

local modem = P("modem")
if not modem then
  say("ERROR: no network card")
  error("no network card", 0)
end

local eeprom = P("eeprom")
local port = tonumber(eeprom and eeprom.getData() or "") or 2412
modem.open(port)
if modem.isWireless() then pcall(modem.setStrength, 400) end
say("ocnet: listening on port " .. port)
modem.broadcast(port, "ocnet:hello")

local cur, curName, co
local deadline = 0
local rid, rname, rcount, rchunks

local function start(id, name, code)
  local sandbox = setmetatable({
    computer = setmetatable({
      pullSignal = function(t) return coroutine.yield(t) end,
    }, { __index = computer }),
  }, { __index = _G })
  local fn, err = load(code, "=" .. name, "t", sandbox)
  if not fn then
    say("compile error: " .. tostring(err))
    return
  end
  cur, curName, co = id, name, coroutine.create(fn)
  deadline = 0
  say("run " .. name .. " #" .. id:sub(1, 8))
end

while true do
  local timeout = math.huge
  if co then
    timeout = deadline - computer.uptime()
    if timeout < 0 then timeout = 0 end
  end
  local sig = table.pack(computer.pullSignal(timeout))
  local proto = false
  if sig[1] == "modem_message" and sig[4] == port
      and type(sig[6]) == "string" and sig[6]:sub(1, 6) == "ocnet:" then
    proto = true
    local cmd = sig[6]
    if cmd == "ocnet:begin" and sig[7] ~= cur then
      rid, rname, rcount, rchunks = sig[7], sig[8], sig[9], {}
    elseif cmd == "ocnet:chunk" and rid and sig[7] == rid then
      rchunks[sig[8]] = sig[9]
    elseif cmd == "ocnet:done" and rid and sig[7] == rid then
      local full = true
      for i = 1, rcount do
        if not rchunks[i] then full = false end
      end
      if full then
        start(rid, rname, table.concat(rchunks))
      else
        say("incomplete transfer, waiting for resend")
      end
      rid = nil
    elseif cmd == "ocnet:ping" then
      modem.send(sig[3], port, "ocnet:pong", cur or "-", curName or "-")
    elseif cmd == "ocnet:stop" then
      co, cur, curName = nil, nil, nil
      say("stopped by master")
    end
  end
  if co and not proto then
    local r
    if sig.n > 0 and sig[1] ~= nil then
      r = table.pack(coroutine.resume(co, table.unpack(sig, 1, sig.n)))
    elseif computer.uptime() >= deadline then
      r = table.pack(coroutine.resume(co))
    end
    if r then
      if not r[1] then
        say("script error: " .. tostring(r[2]))
        co = nil
      elseif coroutine.status(co) == "dead" then
        say("script finished")
        co = nil
      else
        deadline = computer.uptime() + (tonumber(r[2]) or math.huge)
      end
    end
  end
end
