-- ocpush: broadcast a script to ocnet listener nodes (EEPROMs flashed with
-- installer/netboot.lua via mkinstaller) and hot-restart them on updates.
-- Run this on the master computer; it needs a (wireless) network card on
-- the same port as the nodes.
--
-- Usage:
--   ocpush <script> [--port=2412] [--watch] [--interval=<s>] [--force]
--          [--optimize] [--strength=<n>]
--   ocpush --ping [--port=2412]     list listening nodes
--   ocpush --stop [--port=2412]     stop the script on all nodes
--
-- --watch keeps running: re-pushes when the file changes (pairs well with
-- ocdev keeping the file fresh) and answers "hello" requests from nodes
-- that (re)boot, so late joiners get the current script automatically.
-- --force restarts nodes even if the script content is unchanged.

local component = require("component")
local computer = require("computer")
local event = require("event")
local fs = require("filesystem")
local shell = require("shell")

local args, opts = shell.parse(...)

local function printf(fmt, ...) io.write(string.format(fmt, ...), "\n") end

local function fail(msg)
  io.stderr:write("ocpush: " .. tostring(msg) .. "\n")
  os.exit(1)
end

if not component.isAvailable("modem") then
  fail("a network card is required")
end
local modem = component.modem
local port = tonumber(opts.port) or 2412
local CHUNK = 2048

modem.open(port)
if modem.isWireless() then
  pcall(modem.setStrength, tonumber(opts.strength) or 400)
end

local haveOptimize, optimize = pcall(require, "optimize")
if opts.optimize and not haveOptimize then
  fail("--optimize requires the optimize library (/usr/lib/optimize.lua)")
end

--------------------------------------------------- script-less commands --

if opts.stop then
  modem.broadcast(port, "ocnet:stop")
  print("stop broadcast sent on port " .. port)
  os.exit(0)
end

if opts.ping then
  modem.broadcast(port, "ocnet:ping")
  print("nodes answering on port " .. port .. ":")
  local count = 0
  local deadline = computer.uptime() + 2
  while computer.uptime() < deadline do
    local e = table.pack(event.pull(deadline - computer.uptime(), "modem_message"))
    if e[1] == "modem_message" and e[4] == port and e[6] == "ocnet:pong" then
      count = count + 1
      printf("  %s  version %s  script %s",
        tostring(e[3]):sub(1, 8), tostring(e[7]):sub(1, 8), tostring(e[8]))
    end
  end
  printf("%d node(s).", count)
  os.exit(0)
end

------------------------------------------------------------------ push --

local script = args[1]
if not script then
  fail("usage: ocpush <script> [--watch] [--port=N] [--force] [--optimize] | --ping | --stop")
end
local path = shell.resolve(script)
local name = path:match("([^/]+)%.lua$") or path:match("([^/]+)$") or "script"

local function readScript()
  local f, err = io.open(path, "rb")
  if not f then fail("cannot read " .. path .. ": " .. tostring(err)) end
  local code = f:read("*a")
  f:close()
  if opts.optimize then code = (optimize.safeStrip(code)) end
  return code
end

local function hash(s)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + s:byte(i)) % 4294967296
  end
  return string.format("%08x-%x", h, #s)
end

local lastPushed = -math.huge

local function push(code)
  local id = hash(code)
  if opts.force then
    id = id .. "-" .. tostring(math.floor(computer.uptime() * 100))
  end
  local total = math.ceil(#code / CHUNK)
  modem.broadcast(port, "ocnet:begin", id, name, total)
  for i = 1, total do
    modem.broadcast(port, "ocnet:chunk", id, i,
      code:sub((i - 1) * CHUNK + 1, i * CHUNK))
    os.sleep(0.05)
  end
  modem.broadcast(port, "ocnet:done", id)
  lastPushed = computer.uptime()
  printf("pushed %s: %d byte(s), %d chunk(s), id %s", name, #code, total, id:sub(1, 8))
end

push(readScript())

if not opts.watch then os.exit(0) end

local interval = tonumber(opts.interval) or 2
printf("watching %s on port %d (Ctrl+C to stop)", path, port)
local last = fs.lastModified(path)
local ok, err = pcall(function()
  while true do
    local e = table.pack(event.pull(interval, "modem_message"))
    local wantPush = false
    if e[1] == "modem_message" and e[4] == port and e[6] == "ocnet:hello" then
      -- a node (re)booted; re-push unless we just did (debounce boot storms)
      if computer.uptime() - lastPushed > 3 then
        printf("node %s asked for the script", tostring(e[3]):sub(1, 8))
        wantPush = true
      end
    end
    local modified = fs.lastModified(path)
    if modified ~= last then
      last = modified
      wantPush = true
    end
    if wantPush then push(readScript()) end
  end
end)
if not ok and err ~= nil and not tostring(err):match("interrupted") then
  fail(err)
end
print("ocpush stopped.")
