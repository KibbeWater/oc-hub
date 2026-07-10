-- shared.lua: in-VM handoff between hived and the dashboard.
-- OpenOS runs one Lua VM per computer and caches required modules across it, so
-- hived (an rc service) can publish its live service bundle here and the `hive`
-- dashboard (a foreground program) reads it without any IPC.
-- Install to /usr/lib/hive/core/shared.lua.
local shared = {}
-- shared.svc  -> the service bundle from bootstrap.bringUp (registry/tasker/...)
-- shared.net  -> the netshim instance (for dashboard-issued commands)
return shared
