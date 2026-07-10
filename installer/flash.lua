-- mkinstaller: build special-purpose EEPROMs (run on a "master" computer).
-- Presents a configuration window and flashes the currently inserted EEPROM
-- as one of:
--
--   1. auto-installer  (installer/boot.lua) - boots a computer, installs
--      OpenOS if needed plus everything in oc-manifest.cfg, then turns
--      itself back into a standard Lua BIOS.
--   2. ocnet listener  (installer/netboot.lua) - boots straight into a
--      wireless receiver that runs scripts pushed with 'ocpush' and
--      hot-restarts them on every update. No OpenOS/drive needed on nodes.
--
-- Installer configurations (repo/branch/...) can be loaded from saved
-- profiles, the default (last used), or entered fresh.
--
-- Usage: mkinstaller [--bios=<path to boot source>]

local component = require("component")
local fs = require("filesystem")
local serialization = require("serialization")
local shell = require("shell")
local term = require("term")

local args, opts = shell.parse(...)

local PROFILE_DIR = "/etc/ocinstaller"
local BACKUP_PATH = "/home/eeprom-backup.lua"

local function printf(fmt, ...) io.write(string.format(fmt, ...), "\n") end

local function fail(msg)
  io.stderr:write("mkinstaller: " .. tostring(msg) .. "\n")
  os.exit(1)
end

if not component.isAvailable("eeprom") then fail("no EEPROM inserted") end
if not component.isAvailable("gpu") then fail("a GPU and screen are required") end

local gpu = component.gpu
local eeprom = component.eeprom
local W, H = gpu.getResolution()

--------------------------------------------------------------------- ui --

local ui = { w = 58 }

function ui.begin(title, innerHeight)
  term.clear()
  ui.h = innerHeight + 2
  ui.x = math.max(1, math.floor((W - ui.w) / 2) + 1)
  ui.y = math.max(1, math.floor((H - ui.h) / 2) + 1)
  gpu.fill(ui.x, ui.y, ui.w, ui.h, " ")
  gpu.set(ui.x, ui.y, "+" .. string.rep("-", ui.w - 2) .. "+")
  gpu.set(ui.x, ui.y + ui.h - 1, "+" .. string.rep("-", ui.w - 2) .. "+")
  for i = 1, ui.h - 2 do
    gpu.set(ui.x, ui.y + i, "|")
    gpu.set(ui.x + ui.w - 1, ui.y + i, "|")
  end
  gpu.set(ui.x + 2, ui.y, "[ " .. title .. " ]")
  ui.row = 1
end

function ui.line(text)
  gpu.set(ui.x + 2, ui.y + ui.row, (text or ""):sub(1, ui.w - 4))
  ui.row = ui.row + 1
end

function ui.ask(label, default)
  local prompt = label
  if default and default ~= "" then
    prompt = prompt .. " [" .. default .. "]"
  end
  prompt = (prompt .. ": "):sub(1, ui.w - 6)
  gpu.set(ui.x + 2, ui.y + ui.row, prompt)
  term.setCursor(ui.x + 2 + #prompt, ui.y + ui.row)
  ui.row = ui.row + 1
  local input = io.read()
  if input == nil then
    term.clear()
    fail("aborted")
  end
  input = input:gsub("^%s+", ""):gsub("%s+$", "")
  if input == "" then return default or "" end
  return input
end

--------------------------------------------------------------- profiles --

local function profilePath(name)
  return fs.concat(PROFILE_DIR, name .. ".cfg")
end

local function loadProfile(name)
  local f = io.open(profilePath(name), "r")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  local cfg = serialization.unserialize(data or "")
  return type(cfg) == "table" and cfg or nil
end

local function saveProfile(name, cfg)
  fs.makeDirectory(PROFILE_DIR)
  local f, err = io.open(profilePath(name), "w")
  if not f then fail("cannot save profile: " .. tostring(err)) end
  f:write(serialization.serialize(cfg))
  f:close()
end

local function listProfiles()
  local names = {}
  if fs.isDirectory(PROFILE_DIR) then
    for entry in fs.list(PROFILE_DIR) do
      local name = entry:match("^(.+)%.cfg$")
      if name and name ~= "default" then names[#names + 1] = name end
    end
  end
  table.sort(names)
  return names
end

-- Default = last used config; first run prefills from an ocgit checkout
-- in the current directory, if there is one.
local function defaultConfig()
  local cfg = loadProfile("default") or {}
  if not cfg.owner then
    local f = io.open(shell.resolve(".ocgit"), "r")
    if f then
      local checkout = serialization.unserialize(f:read("*a") or "") or {}
      f:close()
      cfg.owner, cfg.repo, cfg.branch = checkout.owner, checkout.repo, checkout.branch
    end
  end
  cfg.branch = cfg.branch or "main"
  cfg.stage2 = cfg.stage2 or "installer/stage2.lua"
  return cfg
end

------------------------------------------------------------ bios source --

local function findSource(filename)
  if type(opts.bios) == "string" then
    local path = shell.resolve(opts.bios)
    if not fs.exists(path) then fail("no such file: " .. path) end
    return path
  end
  for _, candidate in ipairs({
    "/usr/share/ocinstaller/" .. filename,
    shell.resolve(filename),
    shell.resolve("installer/" .. filename),
  }) do
    if fs.exists(candidate) then return candidate end
  end
  fail("cannot find " .. filename .. "; pass --bios=<path>")
end

local function readFile(path)
  local f, err = io.open(path, "r")
  if not f then fail("cannot read " .. path .. ": " .. tostring(err)) end
  local data = f:read("*a")
  f:close()
  return data
end

-- Shrink the BIOS so it fits in 4KB: use the optimize library if installed,
-- otherwise fall back to stripping full-line comments and indentation.
local haveOptimize, optimize = pcall(require, "optimize")
local function shrink(code)
  if haveOptimize then
    return (optimize.safeStrip(code))
  end
  local out = {}
  for line in (code .. "\n"):gmatch("(.-)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and trimmed:sub(1, 2) ~= "--" then
      out[#out + 1] = trimmed
    end
  end
  return table.concat(out, "\n")
end

------------------------------------------------------------------ flash --

local function confirmAndFlash(summary, code, data, label)
  local maxCode = eeprom.getSize and eeprom.getSize() or 4096
  local maxData = eeprom.getDataSize and eeprom.getDataSize() or 256
  if #code > maxCode then
    term.clear()
    fail(string.format("BIOS is too large: %d > %d bytes", #code, maxCode))
  end
  if #data > maxData then
    term.clear()
    fail("configuration string too long for the EEPROM data area")
  end

  local current = eeprom.get() or ""
  local looksNormal = current:find("getBootAddress", 1, true) ~= nil

  ui.begin("Flash EEPROM", #summary + 7)
  for _, s in ipairs(summary) do ui.line(s) end
  ui.line(string.format("Size:    %d/%d bytes", #code, maxCode))
  ui.line("EEPROM:  " .. (eeprom.getLabel() or "unlabeled"))
  ui.line("")
  if looksNormal then
    ui.line("Current EEPROM looks like a standard Lua BIOS.")
  else
    ui.line("WARNING: current EEPROM is NOT a standard Lua BIOS!")
  end
  ui.line("A backup is written to " .. BACKUP_PATH .. ".")
  ui.line("")
  local answer = ui.ask("Type FLASH to write", "")
  term.clear()
  if answer ~= "FLASH" then fail("aborted, nothing written") end

  if #current > 0 then
    local f = io.open(BACKUP_PATH, "w")
    if f then
      f:write(current)
      f:close()
    end
  end
  eeprom.set(code)
  pcall(eeprom.setLabel, label)
  eeprom.setData(data)

  printf("Flashed '%s' (%d/%d bytes, data %d/%d).",
    label, #code, maxCode, #data, maxData)
  printf("Previous EEPROM code backed up to %s.", BACKUP_PATH)
end

------------------------------------------------------------------- flow --

ui.begin("mkinstaller - EEPROM flasher", 6)
ui.line("What kind of EEPROM do you want to make?")
ui.line("")
ui.line("  1. auto-installer (OpenOS + oc-manifest.cfg)")
ui.line("  2. ocnet listener (wireless script runner)")
ui.line("")
local kind = ui.ask("Choice", "1")

if kind == "2" then
  -- ocnet listener: only needs a port
  ui.begin("ocnet listener", 5)
  ui.line("Nodes listen on this port for ocpush broadcasts.")
  ui.line("Use different ports for separate fleets.")
  ui.line("")
  local port = ui.ask("Port", "2412")
  if not tonumber(port) then
    term.clear()
    fail("port must be a number")
  end
  local code = shrink(readFile(findSource("netboot.lua")))
  confirmAndFlash({
    "Type:    ocnet listener",
    "Port:    " .. port,
    "",
  }, code, port, "OCNet Listener")
  print("")
  print("Put the EEPROM in a computer with a wireless network card and")
  print("power on. Push scripts to it with: ocpush <script> --watch")
  return
end

-- auto-installer ------------------------------------------------------------

-- step 1: pick a configuration
local profiles = listProfiles()
ui.begin("Auto-installer configuration", #profiles + 5)
ui.line("Select a configuration:")
ui.line("")
ui.line("  0. default (last used / new)")
for i, name in ipairs(profiles) do
  ui.line(string.format("  %d. %s", i, name))
end
ui.line("")
local choice = tonumber(ui.ask("Choice", "0")) or 0
local cfg
if choice >= 1 and choice <= #profiles then
  cfg = loadProfile(profiles[choice]) or defaultConfig()
else
  cfg = defaultConfig()
end

-- step 2: review / edit fields
ui.begin("Configuration (Enter keeps the [default])", 7)
ui.line("")
cfg.owner = ui.ask("GitHub user/org", cfg.owner or "")
cfg.repo = ui.ask("Repository", cfg.repo or "")
cfg.branch = ui.ask("Branch", cfg.branch or "main")
cfg.stage2 = ui.ask("Stage-2 path", cfg.stage2 or "installer/stage2.lua")
if cfg.owner == "" or cfg.repo == "" then
  term.clear()
  fail("GitHub user and repository are required")
end

-- step 3: optionally save as a named profile
ui.begin("Save profile", 4)
ui.line("Save this configuration for reuse?")
ui.line("")
local profileName = ui.ask("Profile name (empty = skip)", "")
if profileName ~= "" then saveProfile(profileName, cfg) end
saveProfile("default", cfg)

-- step 4: confirm and flash
local code = shrink(readFile(findSource("boot.lua")))
local data = string.format("%s/%s|%s|%s", cfg.owner, cfg.repo, cfg.branch, cfg.stage2)
confirmAndFlash({
  "Type:    auto-installer",
  "Repo:    " .. cfg.owner .. "/" .. cfg.repo .. "@" .. cfg.branch,
  "Stage-2: " .. cfg.stage2,
  "",
}, code, data, "OC Installer")

print("")
print("Put the EEPROM into a computer with an internet card and power on.")
print("Note: THIS computer now holds the installer EEPROM too. Rebooting")
print("with it is harmless (it reinstalls the tools and restores the BIOS),")
print("but swap EEPROMs now if that is not what you want.")
