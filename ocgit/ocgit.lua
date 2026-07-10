-- ocgit: a minimal, pull-only git client for OpenComputers (OpenOS).
-- Syncs a GitHub repository (or a subdirectory of one) onto the local disk
-- using the GitHub REST API. Only changed files are downloaded on pull, by
-- comparing git blob SHAs against the manifest saved in the .ocgit file.
--
-- Usage:
--   ocgit clone <owner>/<repo> [dir] [--branch=<name>] [--path=<subdir>] [--token=<pat>] [--optimize]
--   ocgit pull [dir] [--force] [--token=<pat>] [--optimize]
--   ocgit status [dir]
--   ocgit install [dir] [--optimize]
--
-- 'install' reads oc-manifest.cfg in the checkout and copies files to their
-- declared targets (e.g. /usr/bin). --optimize strips comments/whitespace
-- from .lua files before writing (requires /usr/lib/optimize.lua).
--
-- Requires: an internet card and /usr/lib/json.lua.

local component = require("component")
local computer = require("computer")
local fs = require("filesystem")
local internet = require("internet")
local json = require("json")
local serialization = require("serialization")
local shell = require("shell")

local MANIFEST = ".ocgit"
local TIMEOUT = 20

local args, opts = shell.parse(...)

local function printf(fmt, ...) io.write(string.format(fmt, ...), "\n") end

local function fail(msg)
  io.stderr:write("ocgit: " .. tostring(msg) .. "\n")
  os.exit(1)
end

-- 'install' copies local files only; everything else talks to GitHub
if args[1] ~= "install" and not component.isAvailable("internet") then
  fail("an internet card is required")
end

local haveOptimize, optimize = pcall(require, "optimize")

local function maybeOptimize(body, path)
  if not opts.optimize or not path:match("%.lua$") then return body end
  if not haveOptimize then
    fail("--optimize requires the optimize library (/usr/lib/optimize.lua)")
  end
  return (optimize.safeStrip(body))
end

------------------------------------------------------------------- http --

local function fetch(url, headers)
  local ok, req = pcall(internet.request, url, nil, headers)
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

local function encodeSegment(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local function encodePath(path)
  local parts = {}
  for segment in path:gmatch("[^/]+") do
    parts[#parts + 1] = encodeSegment(segment)
  end
  return table.concat(parts, "/")
end

----------------------------------------------------------------- github --

local function ghHeaders(token)
  local headers = {
    ["User-Agent"] = "OCGit/1.0 (OpenComputers)",
    ["Accept"] = "application/vnd.github.v3+json",
  }
  if token then headers["Authorization"] = "token " .. token end
  return headers
end

local function ghJson(url, token)
  local body, err = fetch(url, ghHeaders(token))
  if not body then return nil, err end
  local ok, data = pcall(json.decode, body)
  if not ok then return nil, "could not parse GitHub response: " .. tostring(data) end
  if type(data) == "table" and data.message then
    return nil, "GitHub: " .. tostring(data.message)
  end
  return data
end

-- Returns { [relativePath] = blobSha } for every file under repo.prefix.
local function fetchRemoteFiles(repo)
  local url = string.format(
    "https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1",
    repo.owner, repo.repo, encodeSegment(repo.branch))
  local tree, err = ghJson(url, repo.token)
  if not tree then return nil, err end
  if tree.truncated then
    printf("warning: GitHub truncated the file list; the sync may be incomplete")
  end
  local files = {}
  for _, entry in ipairs(tree.tree or {}) do
    if entry.type == "blob" then
      local path = entry.path
      if repo.prefix == "" then
        files[path] = entry.sha
      elseif path:sub(1, #repo.prefix + 1) == repo.prefix .. "/" then
        files[path:sub(#repo.prefix + 2)] = entry.sha
      end
    end
  end
  return files
end

local function downloadFile(repo, rel, dir)
  local remotePath = repo.prefix == "" and rel or (repo.prefix .. "/" .. rel)
  local url = string.format(
    "https://raw.githubusercontent.com/%s/%s/%s/%s",
    repo.owner, repo.repo, encodeSegment(repo.branch), encodePath(remotePath))
  local body, err = fetch(url, ghHeaders(repo.token))
  if not body then return nil, err end
  body = maybeOptimize(body, rel)
  local target = fs.concat(dir, rel)
  local parent = fs.path(target)
  if parent and parent ~= "" and not fs.exists(parent) then
    fs.makeDirectory(parent)
  end
  local f, ferr = io.open(target, "wb")
  if not f then return nil, "cannot write " .. target .. ": " .. tostring(ferr) end
  f:write(body)
  f:close()
  return true
end

--------------------------------------------------------------- manifest --

local function loadRepo(dir)
  local f = io.open(fs.concat(dir, MANIFEST), "r")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  local repo = serialization.unserialize(data)
  if type(repo) ~= "table" or not repo.owner then return nil end
  repo.files = repo.files or {}
  repo.prefix = repo.prefix or ""
  return repo
end

local function saveRepo(dir, repo)
  local f, err = io.open(fs.concat(dir, MANIFEST), "w")
  if not f then fail("cannot save manifest: " .. tostring(err)) end
  f:write(serialization.serialize(repo))
  f:close()
end

------------------------------------------------------------------- sync --

local function computeChanges(repo, remote, dir)
  local download, delete = {}, {}
  for rel, sha in pairs(remote) do
    if opts.force or repo.files[rel] ~= sha or not fs.exists(fs.concat(dir, rel)) then
      download[#download + 1] = rel
    end
  end
  for rel in pairs(repo.files) do
    if remote[rel] == nil then delete[#delete + 1] = rel end
  end
  table.sort(download)
  table.sort(delete)
  return download, delete
end

local function sync(dir, repo, dryRun)
  printf("%s/%s@%s%s: fetching file list...",
    repo.owner, repo.repo, repo.branch,
    repo.prefix ~= "" and (" (" .. repo.prefix .. ")") or "")
  local remote, err = fetchRemoteFiles(repo)
  if not remote then fail(err) end
  local download, delete = computeChanges(repo, remote, dir)
  if #download == 0 and #delete == 0 then
    printf("Already up to date.")
    return
  end
  if dryRun then
    for _, rel in ipairs(download) do printf("  ~ %s", rel) end
    for _, rel in ipairs(delete) do printf("  - %s", rel) end
    printf("%d to update, %d to delete (run 'ocgit pull' to apply)", #download, #delete)
    return
  end
  local failed = 0
  for _, rel in ipairs(download) do
    io.write("  " .. rel .. " ... ")
    local ok, derr = downloadFile(repo, rel, dir)
    if ok then
      repo.files[rel] = remote[rel]
      printf("ok")
    else
      failed = failed + 1
      printf("FAILED (%s)", tostring(derr))
    end
  end
  for _, rel in ipairs(delete) do
    fs.remove(fs.concat(dir, rel))
    repo.files[rel] = nil
    printf("  %s ... deleted", rel)
  end
  saveRepo(dir, repo)
  if failed > 0 then
    fail(string.format("%d file(s) failed to download; run 'ocgit pull' to retry", failed))
  end
  printf("Done: %d updated, %d deleted.", #download, #delete)
end

--------------------------------------------------------------- commands --

local function commandClone()
  local spec = args[2]
  if not spec then
    fail("usage: ocgit clone <owner>/<repo> [dir] [--branch=<name>] [--path=<subdir>] [--token=<pat>]")
  end
  local owner, name = spec:match("^([%w%-%._]+)/([%w%-%._]+)$")
  if not owner then fail("repository must be written as <owner>/<repo>") end
  local dir = shell.resolve(args[3] or name)
  if fs.exists(fs.concat(dir, MANIFEST)) then
    fail("'" .. dir .. "' is already a checkout; use 'ocgit pull'")
  end
  local token = type(opts.token) == "string" and opts.token or nil
  local branch = type(opts.branch) == "string" and opts.branch or nil
  if not branch then
    local info, err = ghJson(
      string.format("https://api.github.com/repos/%s/%s", owner, name), token)
    if not info then fail(err) end
    branch = info.default_branch or "main"
  end
  fs.makeDirectory(dir)
  local repo = {
    owner = owner,
    repo = name,
    branch = branch,
    prefix = type(opts.path) == "string" and opts.path:gsub("^/+", ""):gsub("/+$", "") or "",
    token = token,
    files = {},
  }
  saveRepo(dir, repo)
  sync(dir, repo, false)
end

-- Copies files from a checkout to the targets declared in oc-manifest.cfg.
local function commandInstall()
  local dir = shell.resolve(args[2] or ".")
  local f = io.open(fs.concat(dir, "oc-manifest.cfg"), "r")
  if not f then fail("no oc-manifest.cfg in " .. dir) end
  local text = f:read("*a")
  f:close()

  local installed, missing = 0, 0
  local function put(from, to)
    local src = fs.concat(dir, from)
    local sf = io.open(src, "rb")
    if not sf then
      printf("  missing %s (skipped)", from)
      missing = missing + 1
      return
    end
    local body = sf:read("*a")
    sf:close()
    body = maybeOptimize(body, to)
    local parent = fs.path(to)
    if parent and parent ~= "" and not fs.exists(parent) then
      fs.makeDirectory(parent)
    end
    local tf, err = io.open(to, "wb")
    if not tf then fail("cannot write " .. to .. ": " .. tostring(err)) end
    tf:write(body)
    tf:close()
    printf("  %s -> %s", from, to)
    installed = installed + 1
  end

  local function walk(root, prefix, callback)
    for entry in fs.list(root) do
      local name = entry:gsub("/$", "")
      local full = fs.concat(root, name)
      local rel = prefix == "" and name or (prefix .. "/" .. name)
      if fs.isDirectory(full) then
        walk(full, rel, callback)
      else
        callback(rel)
      end
    end
  end

  for line in text:gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$")
    if #line > 0 and line:sub(1, 1) ~= "#" then
      local cmd, rest = line:match("^(%S+)%s*(.-)%s*$")
      if cmd == "file" then
        local from, to = rest:match("^(%S+)%s+(%S+)$")
        if from then put(from, to) end
      elseif cmd == "dir" then
        local from, to = rest:match("^(%S+)%s+(%S+)$")
        if from and fs.isDirectory(fs.concat(dir, from)) then
          walk(fs.concat(dir, from), "", function(rel)
            put(from .. "/" .. rel, to .. "/" .. rel)
          end)
        elseif from then
          printf("  missing directory %s (skipped)", from)
          missing = missing + 1
        end
      end
      -- label/bios/openos only concern the EEPROM installer
    end
  end
  printf("%d file(s) installed%s.", installed,
    missing > 0 and (", " .. missing .. " missing") or "")
end

local function repoAndDir()
  local dir = shell.resolve(args[2] or ".")
  local repo = loadRepo(dir)
  if not repo then
    fail("'" .. dir .. "' is not an ocgit checkout (no " .. MANIFEST .. " file); use 'ocgit clone' first")
  end
  if type(opts.token) == "string" then repo.token = opts.token end
  if type(opts.branch) == "string" then repo.branch = opts.branch end
  return dir, repo
end

local command = args[1]
if command == "clone" then
  commandClone()
elseif command == "pull" then
  local dir, repo = repoAndDir()
  sync(dir, repo, false)
elseif command == "status" then
  local dir, repo = repoAndDir()
  sync(dir, repo, true)
elseif command == "install" then
  commandInstall()
else
  print("ocgit - minimal pull-only git client for OpenComputers")
  print("Usage:")
  print("  ocgit clone <owner>/<repo> [dir] [--branch=<name>] [--path=<subdir>] [--token=<pat>]")
  print("  ocgit pull [dir] [--force] [--token=<pat>]")
  print("  ocgit status [dir]")
  print("  ocgit install [dir]")
  print("Notes:")
  print("  --path syncs only a subdirectory of the repository.")
  print("  --token is needed for private repos (GitHub personal access token).")
  print("  --optimize strips comments/whitespace from .lua files when writing.")
  print("  install copies files to the targets listed in oc-manifest.cfg.")
  os.exit(command == nil and 0 or 1)
end
