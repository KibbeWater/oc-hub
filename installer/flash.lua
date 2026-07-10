-- mkinstaller: build an auto-installer EEPROM (run on a "master" computer).
-- Presents a configuration window where you load a saved profile, the
-- default (last used) configuration, or enter a new one, then flashes the
-- currently inserted EEPROM with installer/boot.lua plus that configuration
-- baked into the EEPROM data area.
--
-- A computer booted from the flashed EEPROM installs OpenOS (if no drive
-- has it) and everything listed in the repo's oc-manifest.cfg, then turns
-- the EEPROM back into a standard Lua BIOS and reboots.
--
-- Usage: mkinstaller [--bios=<path to boot.lua>]

local component = require("component")
local fs = require("filesystem")
local serialization = require("serialization")
local shell = require("shell")
local term = require("term")

local args, opts = shell.parse(...)

local PROFILE_DIR = "/etc/ocinstaller"
local BACKUP_PATH = "/home/eeprom-backup.lua"

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

------------------------------------------------------------- bios source --

local function findBios()
  if type(opts.bios) == "string" then
    local path = shell.resolve(opts.bios)
    if not fs.exists(path) then fail("no such file: " .. path) end
    return path
  end
  for _, candidate in ipairs({
    "/usr/share/ocinstaller/boot.lua",
    shell.resolve("boot.lua"),
    shell.resolve("installer/boot.lua"),
  }) do
    if fs.exists(candidate) then return candidate end
  end
  fail("cannot find boot.lua; pass --bios=<path>")
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

------------------------------------------------------------------- flow --

-- step 1: pick a configuration
local profiles = listProfiles()
ui.begin("mkinstaller - EEPROM auto-installer", #profiles + 5)
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
local biosPath = findBios()
local code = shrink(readFile(biosPath))
local data = string.format("%s/%s|%s|%s", cfg.owner, cfg.repo, cfg.branch, cfg.stage2)
local maxCode = eeprom.getSize and eeprom.getSize() or 4096
local maxData = eeprom.getDataSize and eeprom.getDataSize() or 256
if #code > maxCode then
  term.clear()
  fail(string.format("boot.lua is too large: %d > %d bytes", #code, maxCode))
end
if #data > maxData then
  term.clear()
  fail("configuration string too long for the EEPROM data area")
end

local current = eeprom.get() or ""
local looksNormal = current:find("getBootAddress", 1, true) ~= nil

ui.begin("Flash EEPROM", 11)
ui.line("Repo:    " .. cfg.owner .. "/" .. cfg.repo .. "@" .. cfg.branch)
ui.line("Stage-2: " .. cfg.stage2)
ui.line(string.format("BIOS:    %d/%d bytes", #code, maxCode))
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
pcall(eeprom.setLabel, "OC Installer")
eeprom.setData(data)

print(string.format("Flashed 'OC Installer' (%d/%d bytes, data %d/%d).",
  #code, maxCode, #data, maxData))
print("Previous EEPROM code backed up to " .. BACKUP_PATH .. ".")
print("")
print("Put the EEPROM into a computer with an internet card and power on.")
print("Note: THIS computer now holds the installer EEPROM too. Rebooting")
print("with it is harmless (it reinstalls the tools and restores the BIOS),")
print("but swap EEPROMs now if that is not what you want.")
