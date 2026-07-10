-- hive.lua: the queen dashboard (touch GUI over ocui).
-- Reads the live service bundle hived publishes to hive.core.shared (same VM),
-- or brings services up read-only for a standalone snapshot. Phase 4 ships the
-- Fleet, Device and Log screens; Tasks/Map/POIs arrive in later phases.
-- Install to /usr/bin/hive.lua.

local component = require("component")
local hxnet = require("hxnet")
local ocui = require("ocui")
local shared = require("hive.core.shared")
local boot = require("hive.core.bootstrap")

if not component.isAvailable("gpu") then
  print("hive dashboard needs a GPU + screen. Use 'hived status' for text output.")
  return
end

local svc = shared.svc
local net = shared.net
if not svc then
  print("hived is not running in this session; showing a read-only snapshot.")
  svc = boot.bringUp(boot.loadConfig())
end

local ui = ocui.new(component.gpu)
local nav = ocui.navigator(ui)

local STATE_NAME = { [0] = "boot", [1] = "idle", [2] = "work", [3] = "dock",
  [4] = "lost", [5] = "lowpwr", [6] = "error" }
local function stateStr(d)
  if type(d.state) == "number" then return STATE_NAME[d.state] or "?" end
  return d.state or "?"
end

local function deviceList()
  local list = {}
  for id, d in pairs(svc.registry.all()) do
    list[#list + 1] = { id = id, d = d }
  end
  table.sort(list, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return list
end

-- send a signed command if hived's network is live
local function command(id, opcode, payload)
  if net then net.cmd(id, opcode, payload or "") end
end

-- --- Log screen ------------------------------------------------------------

local function logScreen()
  return {
    build = function(self, n, u)
      u:add(ocui.label{ x = 1, y = 1, text = "Hive Log", w = u.w, fg = ocui.theme.accent })
      local rows = {}
      for _, line in ipairs(svc.log.recent(200)) do
        rows[#rows + 1] = line
      end
      self.list = ocui.list{ x = 1, y = 3, w = u.w, h = u.h - 4, items = rows,
        render = function(item)
          return string.format("[%s] %s", item.level, item.msg)
        end }
      u:add(self.list)
      u:add(ocui.button{ x = 1, y = u.h, text = "Back", onTap = function() n:pop() end })
    end,
    tick = function(self)
      if self.list then self.list:setItems(svc.log.recent(200)) end
    end,
    onKey = function(_, n) end,
  }
end

-- --- Device screen ---------------------------------------------------------

local function deviceScreen(id)
  return {
    build = function(self, n, u)
      local d = svc.registry.get(id) or {}
      u:add(ocui.label{ x = 1, y = 1, w = u.w, fg = ocui.theme.accent,
        text = ("Device #%s  %s"):format(tostring(id), d.role or "?") })
      local lines = {
        "state:   " .. stateStr(d),
        "fw:      " .. tostring(d.fw or "?"),
        "energy:  " .. (d.energy and (math.floor(d.energy * 100) .. "%") or "?"),
        "pos:     " .. (d.pos and ("%d,%d,%d"):format(d.pos.x, d.pos.y, d.pos.z) or "?"),
        "task:    " .. tostring(d.taskId or "-"),
      }
      for i, ln in ipairs(lines) do
        u:add(ocui.label{ x = 2, y = 2 + i, text = ln, w = u.w - 2 })
      end
      local by = u.h - 2
      u:add(ocui.button{ x = 1, y = by, text = "Recall", primary = true,
        onTap = function() command(id, hxnet.CMD.RECALL) end })
      u:add(ocui.button{ x = 11, y = by, text = "Reboot",
        onTap = function() command(id, hxnet.CMD.REBOOT) end })
      u:add(ocui.button{ x = 21, y = by, text = "Locate",
        onTap = function() command(id, hxnet.CMD.LOCATE) end })
      u:add(ocui.button{ x = 31, y = by, text = "Forget",
        onTap = function() svc.registry.forget(id); n:pop() end })
      u:add(ocui.button{ x = 1, y = u.h, text = "Back", onTap = function() n:pop() end })
    end,
    tick = function(self, n) self.dirty = true end,
  }
end

-- --- Map screen ------------------------------------------------------------

local function mapScreen()
  local o = svc.cfg and svc.cfg.origin or { x = 0, z = 0 }
  local scr = {
    cx = math.floor((o.x or 0) / 16), cz = math.floor((o.z or 0) / 16),
  }
  local RAMP = " .:-=+*#"
  function scr.redraw(self, u)
    local cx0 = self.cx - math.floor(u.w / 2)
    local cz0 = self.cz - math.floor((u.h - 3) / 2)
    for row = 0, u.h - 4 do
      for col = 0, u.w - 1 do
        local s = svc.worlddb.tileSummary(cx0 + col, cz0 + row)
        local ch = "."
        if s and s.scannedPct > 0 then
          if s.oreCount > 0 then
            ch = "^"
          elseif (s.flags & 1) ~= 0 then
            ch = "~"
          else
            local b = math.max(1, math.min(#RAMP, math.floor((s.maxSurface - 40) / 12) + 1))
            ch = RAMP:sub(b, b)
          end
        end
        u:blit(col + 1, row + 2, ch, ocui.theme.text, ocui.theme.panel)
      end
    end
    for id, d in pairs(svc.registry.all()) do
      if d.pos then
        local col = math.floor(d.pos.x / 16) - cx0
        local row = math.floor(d.pos.z / 16) - cz0
        if col >= 0 and col < u.w and row >= 0 and row <= u.h - 4 then
          u:blit(col + 1, row + 2, d.kind == "robot" and "R" or "D",
            ocui.theme.accent, ocui.theme.panel)
        end
      end
    end
  end
  scr.build = function(self, n, u)
    u:add(ocui.label{ x = 1, y = 1, w = u.w, fg = ocui.theme.accent,
      text = ("Map @tile %d,%d  (wasd to pan)"):format(self.cx, self.cz) })
    u:box(1, 2, u.w, u.h - 3, ocui.theme.panel)
    self:redraw(u)
    u:add(ocui.button{ x = 1, y = u.h, text = "Back", onTap = function() n:pop() end })
  end
  scr.tick = function(self) self:redraw(ui) end
  scr.onKey = function(self, n, ch)
    if ch == string.byte("w") then self.cz = self.cz - 3
    elseif ch == string.byte("s") then self.cz = self.cz + 3
    elseif ch == string.byte("a") then self.cx = self.cx - 3
    elseif ch == string.byte("d") then self.cx = self.cx + 3 end
    n:rebuild()
  end
  return scr
end

-- --- Fleet screen (home) ---------------------------------------------------

local function fleetScreen()
  return {
    build = function(self, n, u)
      self.header = ocui.label{ x = 1, y = 1, w = u.w, fg = ocui.theme.accent, text = "Hive" }
      u:add(self.header)
      self.list = ocui.list{ x = 1, y = 3, w = u.w, h = u.h - 4, items = deviceList(),
        render = function(item)
          local d = item.d
          local left = ("#%s %-7s %-6s"):format(tostring(item.id), d.role or "?", stateStr(d))
          local right = ("%s%%  %s"):format(d.energy and math.floor(d.energy * 100) or "?",
            d.pos and ("%d,%d"):format(d.pos.x, d.pos.z) or "?")
          return left, right
        end,
        onSelect = function(_, item) n:push(deviceScreen(item.id)) end }
      u:add(self.list)
      u:add(ocui.button{ x = 1, y = u.h, text = "Map", onTap = function() n:push(mapScreen()) end })
      u:add(ocui.button{ x = 9, y = u.h, text = "Log", onTap = function() n:push(logScreen()) end })
      u:add(ocui.button{ x = 17, y = u.h, text = "Quit", onTap = function() n.done = true end })
    end,
    tick = function(self)
      local total, online = svc.registry.count()
      self.header:setText(("Hive  %d/%d online  %d queued  %d alerts  %dKB free")
        :format(online, total, #svc.tasker.queued(), svc.log.alertCount(),
          math.floor((require("computer").freeMemory()) / 1024)))
      self.list:setItems(deviceList())
    end,
  }
end

nav:push(fleetScreen())
nav:run(0.5)
ui:clear()
component.gpu.setBackground(0x000000)
component.gpu.setForeground(0xFFFFFF)
require("term").clear()
