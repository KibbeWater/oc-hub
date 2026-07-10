-- rc/hivebot.lua: OpenOS rc service wrapper for the robot daemon.
-- Enable with:  rc hivebot enable    (starts the paired robot on boot).
-- Install to /etc/rc.d/hivebot.lua.

local thread = require("thread")
local shell = require("shell")

local daemon

function start()
  if daemon and daemon:status() ~= "dead" then return end
  daemon = thread.create(function() shell.execute("hivebot run") end)
  daemon:detach()
end

function stop()
  if daemon then daemon:kill(); daemon = nil end
  require("event").push("interrupted")
end

function status()
  return (daemon and daemon:status() ~= "dead") and "running" or "stopped"
end
