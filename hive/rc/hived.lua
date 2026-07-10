-- rc/hived.lua: OpenOS rc service wrapper for the hive queen daemon.
-- Enable with:  rc hived enable   (starts hived on boot in a background thread,
-- sharing the VM so the `hive` dashboard reads its live services).
-- Install to /etc/rc.d/hived.lua.

local thread = require("thread")
local shell = require("shell")

local daemon

function start()
  if daemon and daemon:status() ~= "dead" then return end
  daemon = thread.create(function()
    shell.execute("hived run")
  end)
  daemon:detach()
end

function stop()
  if daemon then
    daemon:kill()
    daemon = nil
  end
  -- also nudge a foreground hived to exit
  require("event").push("interrupted")
end

function status()
  return (daemon and daemon:status() ~= "dead") and "running" or "stopped"
end
