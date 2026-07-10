-- setup.lua: one-shot interactive setup for an OpenComputers git-based toolkit.
-- Project-agnostic: you tell it which GitHub repo to bootstrap from; it fetches
-- ocgit + the shared libraries, clones/updates the checkout, applies the repo's
-- oc-manifest.cfg, and can flash an EEPROM afterwards. Choices are remembered in
-- /etc/ocsetup.cfg. The wizard uses the ocui touch GUI when it is installed and a
-- GPU is present; on a bare machine it falls back to plain text prompts (and
-- installs ocui during bootstrap, so later runs are graphical).
--
--   wget -f https://raw.githubusercontent.com/<owner>/<repo>/<branch>/setup.lua /tmp/setup.lua
--   /tmp/setup.lua

local component = require("component")
local computer = require("computer")
local fs = require("filesystem")
local shell = require("shell")
local serialization = require("serialization")

local function fail(msg)
  io.stderr:write("setup: " .. tostring(msg) .. "\n")
  os.exit(1)
end

if not component.isAvailable("internet") then fail("an internet card is required") end
local internet = require("internet")

local CFG_PATH = "/etc/ocsetup.cfg"

-- config: generic defaults, no baked-in project ----------------------------

local cfg = { owner = "", repo = "", branch = "main", dir = "/home/work", token = "", optimize = false }
do
  local f = io.open(CFG_PATH, "rb")
  if f then
    local saved = serialization.unserialize(f:read("*a") or "")
    f:close()
    if type(saved) == "table" then for k, v in pairs(saved) do cfg[k] = v end end
  end
end

-- allow non-interactive overrides: setup.lua --owner=X --repo=Y ...
local args, opts = shell.parse(...)
for k, v in pairs(opts) do
  if cfg[k] ~= nil then
    if type(cfg[k]) == "boolean" then cfg[k] = (v == true or v == "true") else cfg[k] = v end
  end
end

local steps = {
  { key = "bootstrap", label = "Install core tools (ocgit + libraries)", on = true },
  { key = "clone", label = "Clone/update the repository checkout", on = true },
  { key = "install", label = "Apply oc-manifest.cfg (programs)", on = true },
  { key = "flash", label = "Flash an EEPROM after (mkinstaller)", on = false },
}
local function stepEnabled(key)
  for _, s in ipairs(steps) do if s.key == key then return s.on end end
end

local function saveCfg()
  local f = io.open(CFG_PATH, "wb")
  if f then f:write(serialization.serialize(cfg)); f:close() end
end

-- http ----------------------------------------------------------------------

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
  local readOk, readErr = pcall(function() for chunk in req do chunks[#chunks + 1] = chunk end end)
  if code and (code < 200 or code >= 300) then
    return nil, string.format("HTTP %d %s", code, tostring(message or ""))
  end
  if not readOk then return nil, tostring(readErr) end
  return table.concat(chunks)
end

local function writeFile(path, data)
  local parent = fs.path(path)
  if parent and parent ~= "" and not fs.exists(parent) then fs.makeDirectory(parent) end
  local f, err = io.open(path, "wb")
  if not f then fail("cannot write " .. path .. ": " .. tostring(err)) end
  f:write(data); f:close()
end

-- run steps -----------------------------------------------------------------

-- report(line) is a sink so both the text and GUI paths can show progress.
local function runSteps(report)
  if cfg.owner == "" or cfg.repo == "" then fail("owner and repo are required") end
  cfg.dir = shell.resolve(cfg.dir)
  saveCfg()
  local RAW = string.format("https://raw.githubusercontent.com/%s/%s/%s/", cfg.owner, cfg.repo, cfg.branch)
  local HEADERS = { ["User-Agent"] = "OCSetup/2.0 (OpenComputers)" }
  if cfg.token ~= "" then HEADERS["Authorization"] = "token " .. cfg.token end
  local extra = (cfg.token ~= "" and (" --token=" .. cfg.token) or "") .. (cfg.optimize and " --optimize" or "")

  local function sh(command)
    report("> " .. command)
    if not os.execute(command) then fail("command failed: " .. command) end
  end

  if stepEnabled("bootstrap") then
    report("Installing core tools...")
    -- ocui is fetched too so future runs of setup are graphical.
    for _, m in ipairs({
      { "ocgit/json.lua", "/usr/lib/json.lua" },
      { "ocgit/optimize.lua", "/usr/lib/optimize.lua" },
      { "gui/ocui.lua", "/usr/lib/ocui.lua" },
      { "ocgit/ocgit.lua", "/usr/bin/ocgit.lua" },
    }) do
      local body, err = fetch(RAW .. m[1], HEADERS)
      if not body then report("  " .. m[2] .. " FAILED (" .. tostring(err) .. ")")
      else writeFile(m[2], body); report("  " .. m[2]) end
    end
  end
  if stepEnabled("clone") then
    report("Fetching repository -> " .. cfg.dir)
    if fs.exists(fs.concat(cfg.dir, ".ocgit")) then
      sh("ocgit pull " .. cfg.dir .. extra)
    else
      sh("ocgit clone " .. cfg.owner .. "/" .. cfg.repo .. " " .. cfg.dir .. " --branch=" .. cfg.branch .. extra)
    end
  end
  if stepEnabled("install") then
    report("Applying oc-manifest.cfg")
    sh("ocgit install " .. cfg.dir .. (cfg.optimize and " --optimize" or ""))
  end
  if stepEnabled("flash") then
    if fs.exists("/usr/bin/mkinstaller.lua") then
      report("Launching mkinstaller...")
      local old = shell.getWorkingDirectory()
      shell.setWorkingDirectory(cfg.dir)
      os.execute("mkinstaller")
      shell.setWorkingDirectory(old)
    else
      report("mkinstaller not installed (enable the manifest step); skipped")
    end
  end
  report("")
  report("Setup complete. Update later with: ocgit pull " .. cfg.dir)
end

-- text wizard ---------------------------------------------------------------

local function textWizard()
  local function ask(label, default)
    io.write(label .. (default ~= "" and (" [" .. tostring(default) .. "]") or "") .. ": ")
    local v = io.read()
    if v == nil then fail("aborted") end
    v = v:gsub("^%s+", ""):gsub("%s+$", "")
    return v == "" and default or v
  end
  print("OpenComputers toolkit setup")
  cfg.owner = ask("GitHub user/org", cfg.owner)
  cfg.repo = ask("Repository", cfg.repo)
  cfg.branch = ask("Branch", cfg.branch)
  cfg.dir = ask("Checkout directory", cfg.dir)
  cfg.token = ask("GitHub token (optional)", cfg.token)
  cfg.optimize = ask("Optimize .lua files? (y/N)", cfg.optimize and "y" or "n"):lower():sub(1, 1) == "y"
  for _, s in ipairs(steps) do
    s.on = ask((s.label .. "?"), s.on and "Y" or "n"):lower():sub(1, 1) ~= "n"
  end
  runSteps(print)
end

-- ocui wizard ---------------------------------------------------------------

local function guiWizard(ocui)
  local ui = ocui.new(component.gpu)
  local nav = ocui.navigator(ui)

  local function fieldRows()
    return {
      { k = "owner", label = "GitHub user/org" },
      { k = "repo", label = "Repository" },
      { k = "branch", label = "Branch" },
      { k = "dir", label = "Checkout dir" },
      { k = "token", label = "Token (optional)" },
      { k = "optimize", label = "Optimize .lua", bool = true },
    }
  end

  local function runScreen()
    return {
      build = function(self, n, u)
        u:add(ocui.label{ x = 1, y = 1, w = u.w, fg = ocui.theme.accent, text = "Running setup" })
        u:draw()
        local y = 3
        runSteps(function(line)
          u:blit(2, y, tostring(line):sub(1, u.w - 2), ocui.theme.text, ocui.theme.background)
          y = y + 1
          if y >= u.h - 1 then y = 3; u:box(1, 3, u.w, u.h - 4, ocui.theme.background) end
          u:draw()
        end)
        u:add(ocui.button{ x = 1, y = u.h, text = "Done", primary = true, onTap = function() n.done = true end })
      end,
    }
  end

  local function configScreen()
    return {
      build = function(self, n, u)
        u:add(ocui.label{ x = 1, y = 1, w = u.w, fg = ocui.theme.accent,
          text = "OpenComputers toolkit setup" })
        local rows = {}
        for _, f in ipairs(fieldRows()) do rows[#rows + 1] = { kind = "field", f = f } end
        for _, s in ipairs(steps) do rows[#rows + 1] = { kind = "step", s = s } end
        self.list = ocui.list{ x = 1, y = 3, w = u.w, h = u.h - 4, items = rows,
          render = function(r)
            if r.kind == "field" then
              local v = cfg[r.f.k]
              if r.f.bool then v = v and "yes" or "no" end
              if r.f.k == "token" and v ~= "" then v = "(set)" end
              return r.f.label, tostring(v == "" and "-" or v)
            else
              return "[" .. (r.s.on and "x" or " ") .. "] " .. r.s.label
            end
          end,
          onSelect = function(_, r)
            if r.kind == "step" then
              r.s.on = not r.s.on
            elseif r.f.bool then
              cfg[r.f.k] = not cfg[r.f.k]
            else
              local v = ocui.prompt(ui, r.f.label)
              if v then cfg[r.f.k] = v end
            end
            n:rebuild()
          end }
        u:add(self.list)
        u:add(ocui.button{ x = 1, y = u.h, text = "Run", primary = true,
          onTap = function()
            if cfg.owner == "" or cfg.repo == "" then return end
            n:push(runScreen())
          end })
        u:add(ocui.button{ x = 7, y = u.h, text = "Quit", onTap = function() n.done = true end })
      end,
    }
  end

  nav:push(configScreen())
  nav:run(0.2)
  ui:clear()
  component.gpu.setBackground(0x000000)
  component.gpu.setForeground(0xFFFFFF)
  require("term").clear()
end

-- entry ---------------------------------------------------------------------

local hasUi, ocui = pcall(require, "ocui")
if hasUi and component.isAvailable("gpu") and component.isAvailable("screen") then
  guiWizard(ocui)
else
  textWizard()
end
