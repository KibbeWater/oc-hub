-- firmware.lua: builds and versions role firmware images for the swarm.
-- A drone image is a single self-contained chunk (the netboot sandbox has no
-- require): the shared libs and the role file are concatenated behind a tiny
-- module shim, ending in a call to the SDK entry point. Versions bump whenever
-- the built bytes change, so OTA can tell "newer" from "same".
-- Install to /usr/lib/hive/core/firmware.lua.

local firmware = {}

-- Wrap module sources + an entry expression into one loadable chunk. Each module
-- source ends in `return M`; we capture that behind a local require() shim so the
-- modules resolve each other without the real require (absent on drones).
function firmware.bundle(modules, entrySrc)
  local parts = {
    "local __m = {}\n",
    "local function require(n) local v = __m[n]; if v == nil then error('no module '..n) end; return v end\n",
  }
  for _, mod in ipairs(modules) do
    parts[#parts + 1] = ("__m[%q] = (function()\n"):format(mod.name)
    parts[#parts + 1] = mod.src
    parts[#parts + 1] = "\nend)()\n"
  end
  parts[#parts + 1] = entrySrc .. "\n"
  return table.concat(parts)
end

-- opts: readFile(path)->src, optimize(src)->src,stats, sha(str)->32B, store, verPath,
--       libDir (/usr/lib/hive), sdkModules (list of {name, path}), entry.
function firmware.new(opts)
  local self = {}
  local readFile = opts.readFile or function(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local d = f:read("*a"); f:close(); return d
  end
  local optimize = opts.optimize or function(s) return s, { before = #s, after = #s } end
  local sha = opts.sha or function(s) return (s:rep(1):sub(1, 32) .. ("\0"):rep(32)):sub(1, 32) end
  local store = opts.store
  local verPath = opts.verPath or "/var/hive/fwver.db"

  -- source modules common to every drone image, in dependency order
  local libDir = opts.libDir or "/usr/lib"
  local common = opts.common or {
    { name = "hxnet", path = libDir .. "/hxnet.lua" },
    { name = "worldscan", path = libDir .. "/worldscan.lua" },
    { name = "navcore", path = libDir .. "/hive/sdk/navcore.lua" },
    { name = "drone_sdk", path = libDir .. "/hive/sdk/drone_sdk.lua" },
  }
  local roleDir = opts.roleDir or (libDir .. "/hive/roles")
  local entry = opts.entry or 'return require("drone_sdk").mainFromComponents(require("__role"))'

  local versions = store and store.load(verPath, {}) or {}

  -- Build the drone image for a role. Returns bytes, version, sha32, stats.
  function self.build(role)
    local modules = {}
    for _, m in ipairs(common) do
      local src = readFile(m.path)
      if not src then return nil, "missing " .. m.path end
      modules[#modules + 1] = { name = m.name, src = src }
    end
    local roleSrc = readFile(roleDir .. "/" .. role .. ".lua")
    if not roleSrc then return nil, "missing role " .. role end
    modules[#modules + 1] = { name = "__role", src = roleSrc }

    local bundled = firmware.bundle(modules, entry)
    local stripped, stats = optimize(bundled)
    local digest = sha(stripped)

    -- bump version if the bytes changed
    local rec = versions[role]
    if not rec or rec.sha ~= digest then
      versions[role] = { version = (rec and rec.version or 0) + 1, sha = digest }
      if store then store.saveAtomic(verPath, versions) end
    end
    return stripped, versions[role].version, digest, stats
  end

  function self.version(role)
    return versions[role] and versions[role].version or 0
  end

  -- Validate a built image actually compiles (build gate helper).
  function self.check(src)
    local fn, err = load(src, "=fwimage")
    return fn ~= nil, err
  end

  return self
end

return firmware
