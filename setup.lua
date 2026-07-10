-- setup.lua: one-shot interactive setup for the oc-hub toolkit.
-- Run this on any OpenOS computer with an internet card:
--
--   wget -f https://raw.githubusercontent.com/KibbeWater/oc-hub/main/setup.lua /tmp/setup.lua
--   /tmp/setup.lua
--
-- Presents a configuration wizard (windowed if a GPU + screen are
-- available, plain text prompts otherwise), then bootstraps ocgit and the
-- libraries, clones/updates the repository, applies oc-manifest.cfg, and
-- can optionally launch mkinstaller to flash an EEPROM at the end.

local component = require("component")
local computer = require("computer")
local fs = require("filesystem")
local shell = require("shell")
local term = require("term")

local function fail(msg)
  io.stderr:write("setup: " .. tostring(msg) .. "\n")
  os.exit(1)
end

if not component.isAvailable("internet") then
  fail("an internet card is required")
end
local internet = require("internet")

-- defaults -----------------------------------------------------------------

local cfg = {
  owner = "KibbeWater",
  repo = "oc-hub",
  branch = "main",
  dir = "/home/work",
  token = "",
  optimize = false,
}

local steps = {
  { key = "bootstrap", label = "Install core tools (ocgit + libraries)", on = true },
  { key = "clone",     label = "Clone/update the repository checkout",  on = true },
  { key = "install",   label = "Apply oc-manifest.cfg (programs)",      on = true },
  { key = "flash",     label = "Flash an EEPROM after (mkinstaller)",   on = false },
}

local function stepEnabled(key)
  for _, s in ipairs(steps) do
    if s.key == key then return s.on end
  end
end

--------------------------------------------------------------------- ui --

local useGpu = term.isAvailable() and component.isAvailable("gpu")
local gpu = useGpu and component.gpu or nil
local W, H, colored = 0, 0, false
if useGpu then
  W, H = gpu.getResolution()
  colored = gpu.getDepth() > 1
end

local ui = { w = 58 }

local function setColors(fg, bg)
  if colored then
    gpu.setForeground(fg)
    gpu.setBackground(bg)
  end
end

function ui.begin(title, innerHeight)
  if not useGpu then
    print("")
    print("== " .. title .. " ==")
    return
  end
  setColors(0xFFFFFF, 0x000000)
  term.clear()
  ui.h = innerHeight + 2
  ui.x = math.max(1, math.floor((W - ui.w) / 2) + 1)
  ui.y = math.max(1, math.floor((H - ui.h) / 2) + 1)
  gpu.fill(ui.x, ui.y, ui.w, ui.h, " ")
  gpu.set(ui.x, ui.y + ui.h - 1, "+" .. string.rep("-", ui.w - 2) .. "+")
  for i = 1, ui.h - 2 do
    gpu.set(ui.x, ui.y + i, "|")
    gpu.set(ui.x + ui.w - 1, ui.y + i, "|")
  end
  if colored then
    setColors(0x000000, 0xFFFFFF)
    gpu.fill(ui.x, ui.y, ui.w, 1, " ")
    gpu.set(ui.x + 2, ui.y, title:sub(1, ui.w - 4))
    setColors(0xFFFFFF, 0x000000)
  else
    gpu.set(ui.x, ui.y, "+" .. string.rep("-", ui.w - 2) .. "+")
    gpu.set(ui.x + 2, ui.y, "[ " .. title:sub(1, ui.w - 8) .. " ]")
  end
  ui.row = 1
end

function ui.line(text)
  text = text or ""
  if not useGpu then
    print(text)
    return
  end
  gpu.set(ui.x + 2, ui.y + ui.row, text:sub(1, ui.w - 4))
  ui.row = ui.row + 1
end

function ui.ask(label, default)
  local prompt = label
  if default and default ~= "" then
    prompt = prompt .. " [" .. default .. "]"
  end
  prompt = prompt .. ": "
  local input
  if useGpu then
    prompt = prompt:sub(1, ui.w - 6)
    gpu.set(ui.x + 2, ui.y + ui.row, prompt)
    term.setCursor(ui.x + 2 + #prompt, ui.y + ui.row)
    ui.row = ui.row + 1
    input = io.read()
  else
    io.write(prompt)
    input = io.read()
  end
  if input == nil then
    ui.done()
    fail("aborted")
  end
  input = input:gsub("^%s+", ""):gsub("%s+$", "")
  if input == "" then return default or "" end
  return input
end

function ui.yesno(label, default)
  local hint = default and "Y/n" or "y/N"
  local answer = ui.ask(label .. " (" .. hint .. ")", "")
  if answer == "" then return default end
  return answer:lower():sub(1, 1) == "y"
end

function ui.done()
  if useGpu then
    setColors(0xFFFFFF, 0x000000)
    term.clear()
  end
end

------------------------------------------------------------------- http --

local function fetch(url, headers)
  local ok, req = pcall(internet.request, url, nil, headers)
  if not ok then return nil, tostring(req) end
  local deadline = computer.uptime() + 20
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

local function writeFile(path, data)
  local parent = fs.path(path)
  if parent and parent ~= "" and not fs.exists(parent) then
    fs.makeDirectory(parent)
  end
  local f, err = io.open(path, "wb")
  if not f then fail("cannot write " .. path .. ": " .. tostring(err)) end
  f:write(data)
  f:close()
end

------------------------------------------------------------------ wizard --

ui.begin("oc-hub setup", 8)
ui.line("This sets up the OpenComputers dev toolkit.")
ui.line("")
ui.line("OS:       " .. (_OSVERSION or "unknown"))
ui.line("Memory:   " .. math.floor(computer.totalMemory() / 1024) .. "K")
ui.line("Internet: yes")
ui.line("Display:  " .. (useGpu and (W .. "x" .. H .. (colored and ", color" or ", mono")) or "text mode"))
ui.line("")
ui.ask("Press Enter to continue", "")

ui.begin("Configuration (Enter keeps the [default])", 8)
ui.line("")
cfg.owner = ui.ask("GitHub user/org", cfg.owner)
cfg.repo = ui.ask("Repository", cfg.repo)
cfg.branch = ui.ask("Branch", cfg.branch)
cfg.dir = shell.resolve(ui.ask("Checkout directory", cfg.dir))
cfg.token = ui.ask("GitHub token (optional)", cfg.token)
cfg.optimize = ui.yesno("Optimize .lua files on install", false)

while true do
  ui.begin("Steps", #steps + 4)
  ui.line("Choose what to do:")
  ui.line("")
  for i, s in ipairs(steps) do
    ui.line(string.format("  %d. [%s] %s", i, s.on and "x" or " ", s.label))
  end
  ui.line("")
  local answer = ui.ask("Toggle 1-" .. #steps .. ", Enter to continue", "")
  if answer == "" then break end
  local i = tonumber(answer)
  if i and steps[i] then steps[i].on = not steps[i].on end
end

local enabled = {}
for _, s in ipairs(steps) do
  if s.on then enabled[#enabled + 1] = s end
end
if #enabled == 0 then
  ui.done()
  fail("nothing to do")
end

ui.begin("Summary", #enabled + 6)
ui.line("Repo:    " .. cfg.owner .. "/" .. cfg.repo .. "@" .. cfg.branch)
ui.line("Dir:     " .. cfg.dir)
ui.line("Options: " .. (cfg.optimize and "optimize" or "plain")
  .. (cfg.token ~= "" and ", token" or ""))
ui.line("")
for _, s in ipairs(enabled) do
  ui.line("  * " .. s.label)
end
ui.line("")
local go = ui.yesno("Proceed", true)
ui.done()
if not go then fail("aborted, nothing changed") end

-------------------------------------------------------------------- run --

local RAW = string.format("https://raw.githubusercontent.com/%s/%s/%s/",
  cfg.owner, cfg.repo, cfg.branch)
local HEADERS = { ["User-Agent"] = "OCSetup/1.0 (OpenComputers)" }
if cfg.token ~= "" then HEADERS["Authorization"] = "token " .. cfg.token end

local stepNo, stepTotal = 0, #enabled
local function header(label)
  stepNo = stepNo + 1
  print(string.format("[%d/%d] %s", stepNo, stepTotal, label))
end

local function run(command)
  print("> " .. command)
  local ok = os.execute(command)
  if not ok then fail("command failed: " .. command) end
end

print("oc-hub setup starting...")

if stepEnabled("bootstrap") then
  header("installing core tools")
  for from, to in pairs({
    ["ocgit/json.lua"] = "/usr/lib/json.lua",
    ["ocgit/optimize.lua"] = "/usr/lib/optimize.lua",
    ["ocgit/ocgit.lua"] = "/usr/bin/ocgit.lua",
  }) do
    io.write("  " .. to .. " ... ")
    local body, err = fetch(RAW .. from, HEADERS)
    if not body then
      print("FAILED")
      fail(err)
    end
    writeFile(to, body)
    print("ok")
  end
end

if stepEnabled("clone") then
  header("fetching repository -> " .. cfg.dir)
  local extra = ""
  if cfg.token ~= "" then extra = extra .. " --token=" .. cfg.token end
  if cfg.optimize then extra = extra .. " --optimize" end
  if fs.exists(fs.concat(cfg.dir, ".ocgit")) then
    run("ocgit pull " .. cfg.dir .. extra)
  else
    run("ocgit clone " .. cfg.owner .. "/" .. cfg.repo .. " " .. cfg.dir
      .. " --branch=" .. cfg.branch .. extra)
  end
end

if stepEnabled("install") then
  header("applying oc-manifest.cfg")
  run("ocgit install " .. cfg.dir .. (cfg.optimize and " --optimize" or ""))
end

if stepEnabled("flash") then
  header("launching mkinstaller")
  if fs.exists("/usr/bin/mkinstaller.lua") then
    local old = shell.getWorkingDirectory()
    shell.setWorkingDirectory(cfg.dir)
    os.execute("mkinstaller")
    shell.setWorkingDirectory(old)
  else
    print("  mkinstaller is not installed (enable the manifest step); skipped")
  end
end

print("")
print("Setup complete! Quick reference:")
print("  ocgit pull " .. cfg.dir .. "      update after each git push")
print("  ocgit install " .. cfg.dir .. "   re-apply the manifest")
print("  ocdev <host|url> " .. cfg.dir .. "  live sync from your PC")
print("  ocpush <script> --watch     feed the wireless fleet")
print("  mkinstaller                 flash installer/listener EEPROMs")
