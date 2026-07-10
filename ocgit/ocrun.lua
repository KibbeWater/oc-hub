-- ocrun: run a dev script and hot-restart it whenever the code updates.
-- Pairs with tools/serve.py like ocdev does, but additionally manages a
-- running program: when any synced file changes, the program is killed and
-- restarted with the new version. Run one instance per computer.
--
-- Usage:
--   ocrun <host[:port] | url> <script> [dir] [--interval=<seconds>] [--args=<string>] [--optimize] [--token=<secret>]
--
-- The first argument is either a LAN host ("192.168.1.10:8064") or a full
-- URL such as an ngrok tunnel ("https://xxxx.ngrok-free.app"). --token must
-- match the --token the dev server was started with, if any.
--
-- <script> is the program to run, relative to dir (default ".").
-- If the program crashes or exits on its own it is NOT restarted until the
-- next file change, so a broken build won't spin. Ctrl+C stops everything.

local component = require("component")
local computer = require("computer")
local event = require("event")
local fs = require("filesystem")
local internet = require("internet")
local json = require("json")
local shell = require("shell")
local thread = require("thread")

local TIMEOUT = 10

local args, opts = shell.parse(...)

local function printf(fmt, ...) io.write(string.format(fmt, ...), "\n") end

local function fail(msg)
  io.stderr:write("ocrun: " .. tostring(msg) .. "\n")
  os.exit(1)
end

if not component.isAvailable("internet") then
  fail("an internet card is required")
end

local host, script = args[1], args[2]
if not host or not script then
  fail("usage: ocrun <host[:port] | url> <script> [dir] [--interval=<seconds>] [--args=<string>] [--token=<secret>]")
end
local base
if host:match("^https?://") then
  base = host:gsub("/+$", "") .. "/"
else
  if not host:find(":", 1, true) then host = host .. ":8064" end
  base = "http://" .. host .. "/"
end

-- ngrok-skip-browser-warning bypasses ngrok's free-tier interstitial page
local HEADERS = {
  ["User-Agent"] = "OCRun/1.0 (OpenComputers)",
  ["ngrok-skip-browser-warning"] = "1",
}
if type(opts.token) == "string" then HEADERS["X-Token"] = opts.token end
local dir = shell.resolve(args[3] or ".")
local interval = tonumber(opts.interval) or 2
local extraArgs = type(opts.args) == "string" and opts.args or ""

--------------------------------------------------------------- sync ------

local function fetch(url)
  local ok, req = pcall(internet.request, url, nil, HEADERS)
  if not ok then return nil, tostring(req) end
  local deadline = computer.uptime() + TIMEOUT
  while true do
    local connOk, connected, reason = pcall(req.finishConnect)
    if not connOk then return nil, tostring(connected) end
    if connected then break end
    if connected == nil then return nil, tostring(reason or "connection failed") end
    if computer.uptime() > deadline then return nil, "connection timed out" end
    os.sleep(0.05)
  end
  local code, message = req.response()
  local chunks = {}
  local readOk, readErr = pcall(function()
    for chunk in req do
      chunks[#chunks + 1] = chunk
    end
  end)
  if code and (code < 200 or code >= 300) then
    return nil, string.format("HTTP %d %s", code, tostring(message or ""))
  end
  if not readOk then return nil, tostring(readErr) end
  return table.concat(chunks)
end

local function encodePath(path)
  local parts = {}
  for segment in path:gmatch("[^/]+") do
    parts[#parts + 1] = (segment:gsub("[^%w%-%._~]", function(c)
      return string.format("%%%02X", c:byte())
    end))
  end
  return table.concat(parts, "/")
end

local haveOptimize, optimize = pcall(require, "optimize")
if opts.optimize and not haveOptimize then
  fail("--optimize requires the optimize library (/usr/lib/optimize.lua)")
end

local function writeFile(rel, body)
  if opts.optimize and rel:match("%.lua$") then
    body = (optimize.safeStrip(body))
  end
  local target = fs.concat(dir, rel)
  local parent = fs.path(target)
  if parent and parent ~= "" and not fs.exists(parent) then
    fs.makeDirectory(parent)
  end
  local f, err = io.open(target, "wb")
  if not f then return nil, tostring(err) end
  f:write(body)
  f:close()
  return true
end

local known = {}

local function syncOnce()
  local body, err = fetch(base .. "__manifest")
  if not body then return nil, err end
  local ok, data = pcall(json.decode, body)
  if not ok or type(data) ~= "table" or type(data.files) ~= "table" then
    return nil, "invalid manifest from server"
  end
  local changed = 0
  for rel, hash in pairs(data.files) do
    if known[rel] ~= hash then
      local content, derr = fetch(base .. encodePath(rel))
      if content then
        local wok, werr = writeFile(rel, content)
        if wok then
          known[rel] = hash
          changed = changed + 1
          printf("updated %s", rel)
        else
          printf("cannot write %s: %s", rel, werr)
        end
      else
        printf("failed to fetch %s: %s", rel, tostring(derr))
      end
    end
  end
  for rel in pairs(known) do
    if data.files[rel] == nil then
      fs.remove(fs.concat(dir, rel))
      known[rel] = nil
      changed = changed + 1
      printf("deleted %s", rel)
    end
  end
  return changed
end

------------------------------------------------------------- process -----

local proc
local generation = 0

local function stopScript()
  if proc and proc:status() ~= "dead" then
    proc:kill()
  end
  proc = nil
end

local function startScript()
  generation = generation + 1
  local command = fs.concat(dir, script)
  if extraArgs ~= "" then command = command .. " " .. extraArgs end
  printf("--- starting v%d: %s", generation, command)
  proc = thread.create(function()
    local ok, err = pcall(os.execute, command)
    if not ok then
      io.stderr:write("ocrun: script error: " .. tostring(err) .. "\n")
    end
  end)
end

---------------------------------------------------------------- main -----

-- sleep that honors Ctrl+C (os.sleep swallows the soft interrupt)
local function idle(seconds)
  local deadline = computer.uptime() + seconds
  repeat
    if event.pull(math.max(0.05, deadline - computer.uptime())) == "interrupted" then
      return false
    end
  until computer.uptime() >= deadline
  return true
end

printf("ocrun: %s -> %s, script %s (Ctrl+C to stop)", base, dir, script)
local ok, err = pcall(function()
  local changed, serr = syncOnce()
  if not changed then error("initial sync failed: " .. tostring(serr), 0) end
  startScript()
  local announcedDead = false
  while true do
    if not idle(interval) then break end
    local count, syncErr = syncOnce()
    if not count then
      printf("sync failed: %s", tostring(syncErr))
    elseif count > 0 then
      printf("--- %d file(s) changed, restarting", count)
      stopScript()
      startScript()
      announcedDead = false
    elseif proc and proc:status() == "dead" and not announcedDead then
      printf("--- script exited; waiting for the next update")
      announcedDead = true
    end
  end
end)
stopScript()
if not ok and err ~= nil and not tostring(err):match("interrupted") then
  fail(err)
end
print("ocrun stopped.")
