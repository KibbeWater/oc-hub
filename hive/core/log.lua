-- log.lua: a small ring log with alert flagging for the hive.
-- Keeps the last N lines in RAM for the dashboard Log screen; alert() also raises
-- a counter the Fleet header shows. Install to /usr/lib/hive/core/log.lua.

local log = {}

function log.new(opts)
  opts = opts or {}
  local cap = opts.cap or 200
  local now = opts.now or function() return 0 end
  local echo = opts.echo -- optional fn(line) for console mirroring
  local ring, pos, n = {}, 1, 0
  local alerts = 0
  local self = {}

  local function push(level, msg)
    local line = { t = now(), level = level, msg = msg }
    ring[pos] = line
    pos = pos % cap + 1
    if n < cap then n = n + 1 end
    if echo then echo(("[%s] %s"):format(level, msg)) end
    return line
  end

  local function fmt(f, ...)
    if select("#", ...) == 0 then return f end
    return string.format(f, ...)
  end

  function self.info(f, ...) push("info", fmt(f, ...)) end
  function self.warn(f, ...) push("warn", fmt(f, ...)) end
  function self.alert(f, ...)
    alerts = alerts + 1
    push("alert", fmt(f, ...))
  end

  function self.alertCount() return alerts end
  function self.clearAlerts() alerts = 0 end

  -- Most recent `count` lines, oldest first.
  function self.recent(count)
    count = math.min(count or n, n)
    local out = {}
    for i = 0, count - 1 do
      local idx = (pos - 1 - i - 1) % cap + 1
      local line = ring[idx]
      if line then table.insert(out, 1, line) end
    end
    return out
  end

  return self
end

return log
