-- bootstrap.lua: shared queen bring-up for hived and the dashboard.
-- Builds the store + service bundle (registry, tasker, worlddb, navgraph, routes,
-- firmware, log) from config on disk. The network layer (netshim, which needs a
-- data card) is added separately by hived; the dashboard can bring up the same
-- services read-only for a standalone view. Install to /usr/lib/hive/core/bootstrap.lua.

local computer = require("computer")
local fs = require("filesystem")
local serialization = require("serialization")

local storeLib = require("hive.core.store")
local registryLib = require("hive.core.registry")
local taskerLib = require("hive.core.tasker")
local worlddbLib = require("hive.core.worlddb")
local routesLib = require("hive.core.routes")
local navgraphLib = require("hive.core.navgraph")
local firmwareLib = require("hive.core.firmware")
local logLib = require("hive.core.log")
local optimize = require("optimize")
local component = require("component")

local bootstrap = {}

bootstrap.CFG_PATH = "/etc/hive.cfg"
bootstrap.KEY_PATH = "/etc/hive/secret.key"
bootstrap.EPOCH_PATH = "/etc/hive/epoch"
bootstrap.STATE_DIR = "/var/hive"

function bootstrap.now() return computer.uptime() end

-- OpenOS filesystem backend for store (io + filesystem; avoids os.rename).
function bootstrap.openosFs()
  return {
    read = function(path)
      local f = io.open(path, "rb"); if not f then return nil end
      local d = f:read("*a"); f:close(); return d
    end,
    write = function(path, data)
      local dir = fs.path(path)
      if dir and not fs.exists(dir) then fs.makeDirectory(dir) end
      local f = assert(io.open(path, "wb")); f:write(data); f:close()
    end,
    append = function(path, data)
      local f = assert(io.open(path, "ab")); f:write(data); f:close()
    end,
    remove = function(path) if fs.exists(path) then fs.remove(path) end end,
    rename = function(from, to)
      if fs.exists(to) then fs.remove(to) end
      return fs.rename(from, to)
    end,
    exists = function(path) return fs.exists(path) end,
  }
end

function bootstrap.readFileRaw(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local d = f:read("*a"); f:close(); return d
end

function bootstrap.loadConfig()
  local raw = bootstrap.readFileRaw(bootstrap.CFG_PATH)
  local cfg = raw and serialization.unserialize(raw) or {}
  cfg.port = cfg.port or require("hxnet").PORT
  cfg.strength = cfg.strength or 400
  cfg.origin = cfg.origin or { x = 0, y = 64, z = 0 }
  cfg.worldRoots = cfg.worldRoots or { bootstrap.STATE_DIR .. "/world" }
  return cfg
end

-- Build the service bundle. `mutable` controls whether world dirs are created.
function bootstrap.bringUp(cfg)
  local now = bootstrap.now
  local store = storeLib.new{ fs = bootstrap.openosFs(),
    serialize = serialization.serialize, unserialize = serialization.unserialize }
  local log = logLib.new{ now = now }
  local master = bootstrap.readFileRaw(bootstrap.KEY_PATH)
  local epoch = tonumber(bootstrap.readFileRaw(bootstrap.EPOCH_PATH) or "1") or 1

  for _, root in ipairs(cfg.worldRoots) do
    if not fs.exists(root) then fs.makeDirectory(root) end
  end

  local registry = registryLib.new{ store = store, now = now, log = log.info,
    path = bootstrap.STATE_DIR .. "/fleet.db" }
  registry.load()
  local tasker = taskerLib.new{ store = store, now = now, log = log.info, dir = bootstrap.STATE_DIR }
  tasker.load()
  local worlddb = worlddbLib.new{ store = store, roots = cfg.worldRoots, now = now,
    indexPath = cfg.worldRoots[1] .. "/index.db",
    mkdir = function(p) if not fs.exists(p) then fs.makeDirectory(p) end end }
  local navgraph = navgraphLib.new{ store = store, now = now,
    path = bootstrap.STATE_DIR .. "/navgraph.db" }
  navgraph.load()
  local routes = routesLib.new{ now = now, clock = computer.uptime, graph = navgraph, env = {
    maxSurface = function(cx, cz) local s = worlddb.tileSummary(cx, cz); return s and s.maxSurface end,
    surface = function(x, z) local c = worlddb.column(x, z); return c and c.surfaceY end,
    column = function(x, z) return worlddb.column(x, z) end } }
  local firmware = firmwareLib.new{ store = store,
    sha = function(s) return component.data.sha256(s) end, optimize = optimize.safeStrip }

  return { store = store, log = log, master = master, epoch = epoch, cfg = cfg,
    registry = registry, tasker = tasker, worlddb = worlddb, navgraph = navgraph,
    routes = routes, firmware = firmware }
end

return bootstrap
