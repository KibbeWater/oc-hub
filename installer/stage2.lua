-- OC Installer stage 2, executed by installer/boot.lua.
-- Runs in a bare machine environment (no OpenOS libraries) and receives a
-- helper table from the bootstrap: owner/repo/branch, eeprom proxy, say(),
-- fail(), fetch(url, headers).
--
-- What it does, in order:
--   1. reads oc-manifest.cfg from the repository root
--   2. picks a target drive; installs OpenOS onto it if no drive has one
--      (from a local OpenOS floppy if present, otherwise from GitHub)
--   3. installs every file/dir listed in the manifest
--   4. flashes the EEPROM back to a standard Lua BIOS, points it at the
--      target drive and reboots

local env = ...
local say, fail, fetch = env.say, env.fail, env.fetch

local UA = { ["User-Agent"] = "OCInstaller/1.0 (OpenComputers)" }
local RAW = "https://raw.githubusercontent.com/"
local API = "https://api.github.com/repos/"
local rawBase = RAW .. env.owner .. "/" .. env.repo .. "/" .. env.branch .. "/"

local function yield()
  computer.pullSignal(0)
end

local function sleep(seconds)
  local deadline = computer.uptime() + seconds
  repeat
    computer.pullSignal(deadline - computer.uptime())
  until computer.uptime() >= deadline
end

----------------------------------------------------------------- json ----
-- Compact JSON decoder (objects, arrays, strings, numbers, literals).

local decodeValue

local ESCAPES = {
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
  b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

local function skipSpace(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return j + 1
end

local function decodeString(s, i)
  local buf = {}
  i = i + 1
  while true do
    local c = s:sub(i, i)
    if c == "" then
      fail("json: unterminated string")
    elseif c == '"' then
      return table.concat(buf), i + 1
    elseif c == "\\" then
      local e = s:sub(i + 1, i + 1)
      if e == "u" then
        local cp = tonumber(s:sub(i + 2, i + 5), 16) or fail("json: bad escape")
        if cp < 0x80 then
          buf[#buf + 1] = string.char(cp)
        elseif cp < 0x800 then
          buf[#buf + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
        else
          buf[#buf + 1] = string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
        end
        i = i + 6
      else
        buf[#buf + 1] = ESCAPES[e] or fail("json: bad escape")
        i = i + 2
      end
    else
      local j = s:find('["\\]', i) or fail("json: unterminated string")
      buf[#buf + 1] = s:sub(i, j - 1)
      i = j
    end
  end
end

decodeValue = function(s, i)
  local c = s:sub(i, i)
  if c == '"' then
    return decodeString(s, i)
  elseif c == "{" then
    local obj = {}
    i = skipSpace(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      local key, value
      key, i = decodeString(s, i)
      i = skipSpace(s, i)
      value, i = decodeValue(s, skipSpace(s, i + 1))
      obj[key] = value
      i = skipSpace(s, i)
      local d = s:sub(i, i)
      if d == "}" then return obj, i + 1 end
      i = skipSpace(s, i + 1)
    end
  elseif c == "[" then
    local arr = {}
    i = skipSpace(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
      local value
      value, i = decodeValue(s, i)
      arr[#arr + 1] = value
      i = skipSpace(s, i)
      local d = s:sub(i, i)
      if d == "]" then return arr, i + 1 end
      i = skipSpace(s, i + 1)
    end
  elseif c == "t" then
    return true, i + 4
  elseif c == "f" then
    return false, i + 5
  elseif c == "n" then
    return nil, i + 4
  else
    local j = i
    while j <= #s and s:sub(j, j):match("[%deE%.%+%-]") do j = j + 1 end
    local n = tonumber(s:sub(i, j - 1)) or fail("json: bad value at " .. i)
    return n, j
  end
end

local function jsonDecode(s)
  local value = decodeValue(s, skipSpace(s, 1))
  return value
end

------------------------------------------------------------- fs helpers --

local function encodePath(path)
  local parts = {}
  for segment in path:gmatch("[^/]+") do
    parts[#parts + 1] = (segment:gsub("[^%w%-%._~]", function(c)
      return string.format("%%%02X", c:byte())
    end))
  end
  return table.concat(parts, "/")
end

local function readAll(fsp, path)
  local handle, reason = fsp.open(path, "r")
  if not handle then fail("read " .. path .. ": " .. tostring(reason)) end
  local buf = {}
  while true do
    local chunk = fsp.read(handle, math.huge)
    if not chunk then break end
    buf[#buf + 1] = chunk
  end
  fsp.close(handle)
  return table.concat(buf)
end

local function ensureDir(fsp, dir)
  if dir == "" or fsp.exists(dir) then return end
  local pos = ""
  for segment in dir:gmatch("[^/]+") do
    pos = pos .. "/" .. segment
    if not fsp.exists(pos) then fsp.makeDirectory(pos) end
  end
end

local function writeAll(fsp, path, data)
  local dir = path:match("^(.+)/[^/]+$")
  if dir then ensureDir(fsp, dir) end
  local handle, reason = fsp.open(path, "w")
  if not handle then fail("write " .. path .. ": " .. tostring(reason)) end
  if #data > 0 then
    local ok, err = fsp.write(handle, data)
    if not ok then
      fsp.close(handle)
      fail("write " .. path .. ": " .. tostring(err))
    end
  end
  fsp.close(handle)
end

--------------------------------------------------------------- manifest --

say("fetching oc-manifest.cfg ...")
local manifestText = fetch(rawBase .. "oc-manifest.cfg", UA)

local plan = {
  files = {}, dirs = {}, label = nil,
  bios = "installer/luabios.lua",
  openos = {
    owner = "MightyPirates", repo = "OpenComputers",
    branch = "master-MC1.12.2",
    path = "src/main/resources/assets/opencomputers/loot/openos",
  },
}

for line in manifestText:gmatch("[^\r\n]+") do
  line = line:match("^%s*(.-)%s*$")
  if #line > 0 and line:sub(1, 1) ~= "#" then
    local cmd, rest = line:match("^(%S+)%s*(.-)%s*$")
    if cmd == "file" then
      local from, to = rest:match("^(%S+)%s+(%S+)$")
      if from then plan.files[#plan.files + 1] = { from = from, to = to } end
    elseif cmd == "dir" then
      local from, to = rest:match("^(%S+)%s+(%S+)$")
      if from then plan.dirs[#plan.dirs + 1] = { from = from, to = to } end
    elseif cmd == "label" then
      plan.label = rest
    elseif cmd == "bios" then
      plan.bios = rest
    elseif cmd == "openos" then
      local spec, branch, path = rest:match("^(%S+)%s+(%S+)%s+(%S+)$")
      local owner, repo = (spec or ""):match("^([^/]+)/(.+)$")
      if owner then
        plan.openos = { owner = owner, repo = repo, branch = branch, path = path }
      end
    end
  end
end

----------------------------------------------------------------- target --

local tmp = computer.tmpAddress()
local target, biggest
for address in component.list("filesystem") do
  if address ~= tmp then
    local p = component.proxy(address)
    if not p.isReadOnly() then
      if p.exists("/init.lua") then
        target = p
        break
      end
      if not biggest or p.spaceTotal() > biggest.spaceTotal() then biggest = p end
    end
  end
end
local hasOS = target ~= nil
target = target or biggest
if not target then fail("no writable drive found; install a hard drive") end
say("target drive: " .. target.address:sub(1, 8) .. "...")

----------------------------------------------------------- openos setup --

if hasOS then
  say("OpenOS already installed, skipping OS setup.")
else
  local floppy
  for address in component.list("filesystem") do
    local p = component.proxy(address)
    if p.isReadOnly() and p.exists("/init.lua") then
      floppy = p
      break
    end
  end
  if floppy then
    say("installing OpenOS from disk '" .. tostring(floppy.getLabel() or "?") .. "' ...")
    local function copyTree(path)
      local entries = floppy.list(path) or {}
      for i = 1, #entries do
        local name = entries[i]
        local sub = path .. name
        if name:sub(-1) == "/" then
          ensureDir(target, sub:sub(1, -2))
          copyTree(sub)
        else
          writeAll(target, sub, readAll(floppy, sub))
          say("  " .. sub)
        end
        yield()
      end
    end
    copyTree("/")
  else
    local src = plan.openos
    say("no OpenOS disk found; downloading OpenOS from")
    say("  " .. src.owner .. "/" .. src.repo .. "@" .. src.branch .. " ...")
    local parent = src.path:match("^(.*)/[^/]+$") or ""
    local leaf = src.path:match("([^/]+)$")
    local listing = jsonDecode(fetch(API .. src.owner .. "/" .. src.repo
      .. "/contents/" .. encodePath(parent) .. "?ref=" .. src.branch, UA))
    local sha
    for i = 1, #listing do
      if listing[i].name == leaf then
        sha = listing[i].sha
        break
      end
    end
    if not sha then fail("cannot locate OpenOS files in source repository") end
    local tree = jsonDecode(fetch(API .. src.owner .. "/" .. src.repo
      .. "/git/trees/" .. sha .. "?recursive=1", UA))
    if tree.truncated then fail("OpenOS file list was truncated by GitHub") end
    local osRaw = RAW .. src.owner .. "/" .. src.repo .. "/" .. src.branch
      .. "/" .. encodePath(src.path) .. "/"
    local entries = tree.tree
    local total = 0
    for i = 1, #entries do
      if entries[i].type == "blob" then total = total + 1 end
    end
    local done = 0
    for i = 1, #entries do
      local entry = entries[i]
      if entry.type == "blob" then
        done = done + 1
        say(string.format("  [%d/%d] %s", done, total, entry.path))
        writeAll(target, "/" .. entry.path, fetch(osRaw .. encodePath(entry.path), UA))
      end
      yield()
    end
  end
  say("OpenOS installed.")
end

------------------------------------------------------------------ tools --

for _, m in ipairs(plan.files) do
  say("installing " .. m.to)
  writeAll(target, m.to, fetch(rawBase .. encodePath(m.from), UA))
  yield()
end

if #plan.dirs > 0 then
  local tree = jsonDecode(fetch(API .. env.owner .. "/" .. env.repo
    .. "/git/trees/" .. env.branch .. "?recursive=1", UA))
  if tree.truncated then say("warning: repository tree truncated by GitHub") end
  for _, m in ipairs(plan.dirs) do
    local prefix = m.from .. "/"
    for _, entry in ipairs(tree.tree or {}) do
      if entry.type == "blob" and entry.path:sub(1, #prefix) == prefix then
        local to = m.to .. "/" .. entry.path:sub(#prefix + 1)
        say("installing " .. to)
        writeAll(target, to, fetch(rawBase .. encodePath(entry.path), UA))
        yield()
      end
    end
  end
end

if plan.label then
  pcall(target.setLabel, plan.label)
elseif not hasOS then
  pcall(target.setLabel, "OpenOS")
end

----------------------------------------------------------- restore bios --

say("restoring standard Lua BIOS to EEPROM ...")
local bios = fetch(rawBase .. encodePath(plan.bios), UA)
local check = load(bios, "=luabios")
if not check then fail("downloaded Lua BIOS does not compile") end
env.eeprom.set(bios)
pcall(env.eeprom.setLabel, "EEPROM (Lua BIOS)")
env.eeprom.setData(target.address)

say("")
say("installation complete - rebooting in 5 seconds")
if computer.beep then pcall(computer.beep, 1000, 0.2) end
sleep(5)
computer.shutdown(true)
