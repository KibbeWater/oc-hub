-- ocui.lua: a small touch-first GUI toolkit for OpenComputers (OpenOS).
-- Install to /usr/lib/ocui.lua.
--
-- Widgets are plain tables with x/y/w/h, a :draw() and optional touch
-- handlers; the screen dispatches touch/drag/drop/scroll signals to the
-- topmost widget under the pointer. Tier 2+ screens send touch events;
-- keyboards keep working through the pump's "key" result, so every UI
-- built on this stays usable without a mouse.
--
--   local ocui = require("ocui")
--   local ui = ocui.new(component.gpu)
--   ui:clear()
--   ui:add(ocui.button{x=2, y=2, text="Play", primary=true,
--     onTap=function() ... end})
--   ui:draw()
--   while true do
--     local kind, a, b = ui:pump(0.5)   -- "quit"|"key"|"tap"|...
--     if kind == "quit" then break end
--   end
--
-- Colors degrade automatically on monochrome (tier 1) GPUs.

local event = require("event")
local unicode = require("unicode")

local ocui = {}

ocui.theme = {
  background = 0x101018,
  panel      = 0x1C1C28,
  text       = 0xE8E8E8,
  dim        = 0x909098,
  accent     = 0x2E9EF4,
  accentText = 0xFFFFFF,
  button     = 0x2A2A38,
  buttonText = 0xE8E8E8,
  good       = 0x36C24D,
  warn       = 0xE8B33A,
  bad        = 0xE04848,
}

local Screen = {}
Screen.__index = Screen

function ocui.new(gpu)
  local w, h = gpu.getResolution()
  return setmetatable({
    gpu = gpu,
    w = w,
    h = h,
    color = gpu.getDepth() > 1,
    widgets = {},
  }, Screen)
end

-- Maps theme colors onto monochrome displays: anything drawn on a
-- non-background surface becomes inverted so it stays visible.
function Screen:colors(fg, bg)
  fg = fg or ocui.theme.text
  bg = bg or ocui.theme.background
  if self.color then return fg, bg end
  if bg ~= ocui.theme.background and bg ~= ocui.theme.panel then
    return 0x000000, 0xFFFFFF
  end
  return 0xFFFFFF, 0x000000
end

function Screen:blit(x, y, text, fg, bg)
  local rfg, rbg = self:colors(fg, bg)
  self.gpu.setForeground(rfg)
  self.gpu.setBackground(rbg)
  self.gpu.set(x, y, text)
end

function Screen:box(x, y, w, h, bg)
  local _, rbg = self:colors(nil, bg)
  self.gpu.setBackground(rbg)
  self.gpu.fill(x, y, w, h, " ")
end

function Screen:add(widget)
  widget.screen = self
  self.widgets[#self.widgets + 1] = widget
  return widget
end

-- Removes all widgets and repaints the background.
function Screen:clear()
  self.widgets = {}
  self:box(1, 1, self.w, self.h, ocui.theme.background)
end

function Screen:draw()
  for _, widget in ipairs(self.widgets) do
    if not widget.hidden and widget.draw then widget:draw() end
  end
end

local function contains(widget, x, y)
  return x >= widget.x and x < widget.x + (widget.w or 1)
    and y >= widget.y and y < widget.y + (widget.h or 1)
end

-- Waits for one event (up to timeout seconds) and dispatches it.
-- Returns: "quit"           on Ctrl+C
--          "key", char,code on keyboard input
--          "tap"/"drag"/"drop"/"scroll" after a widget handled it
--          "other", signal  for anything else (including timeout: nil)
function Screen:pump(timeout)
  local sig = table.pack(event.pull(timeout))
  local name = sig[1]
  if name == nil then return nil end
  if name == "interrupted" then return "quit" end
  if name == "key_down" then return "key", sig[3], sig[4] end
  if name == "touch" or name == "drag" or name == "drop"
    or name == "scroll" then
    local x, y = sig[3], sig[4]
    for i = #self.widgets, 1, -1 do
      local widget = self.widgets[i]
      if not widget.hidden and contains(widget, x, y) then
        if name == "touch" and widget.onTouch then
          widget:onTouch(x, y)
          return "tap", widget
        elseif name == "drag" and widget.onDrag then
          widget:onDrag(x, y)
          return "drag", widget
        elseif name == "drop" and widget.onDrop then
          widget:onDrop(x, y)
          return "drop", widget
        elseif name == "scroll" and widget.onScroll then
          widget:onScroll(sig[5])
          return "scroll", widget
        end
      end
    end
    return "other", sig
  end
  return "other", sig
end

--------------------------------------------------------------- widgets ---

local function pad(text, width)
  local len = unicode.len(text)
  if len > width then
    return unicode.sub(text, 1, math.max(0, width - 1)) .. "…"
  end
  return text .. string.rep(" ", width - len)
end
ocui.pad = pad

-- label{x, y, text, fg, bg, w} - single line of text, padded to w.
function ocui.label(o)
  o.h = 1
  o.w = o.w or unicode.len(o.text or "")
  o.draw = function(self)
    self.screen:blit(self.x, self.y, pad(self.text or "", self.w),
      self.fg, self.bg)
  end
  o.setText = function(self, text)
    self.text = text
    if self.screen then self:draw() end
  end
  return o
end

-- button{x, y, text, w, onTap, primary, disabled} - tappable, centered.
function ocui.button(o)
  o.h = o.h or 1
  o.w = o.w or unicode.len(o.text) + 2
  o.draw = function(self)
    local theme = ocui.theme
    local bg = self.primary and theme.accent or theme.button
    local fg = self.primary and theme.accentText or theme.buttonText
    if self.disabled then fg = theme.dim end
    self.screen:box(self.x, self.y, self.w, self.h, bg)
    local tx = self.x
      + math.max(0, math.floor((self.w - unicode.len(self.text)) / 2))
    local ty = self.y + math.floor((self.h - 1) / 2)
    self.screen:blit(tx, ty, self.text, fg, bg)
  end
  o.onTouch = function(self, x, y)
    if not self.disabled and self.onTap then self:onTap(x, y) end
  end
  o.setText = function(self, text)
    self.text = text
    if self.screen then self:draw() end
  end
  return o
end

-- list{x, y, w, h, items, render=function(item,idx)->left[,right],
--      onSelect=function(self,item,idx)} - scrollable via drag/scroll
-- wheel/taps; tapping a row (without dragging) selects it on release.
function ocui.list(o)
  o.top = 1
  o.draw = function(self)
    local theme = ocui.theme
    self.screen:box(self.x, self.y, self.w, self.h, theme.panel)
    local usable = self.w - 2
    for row = 0, self.h - 1 do
      local idx = self.top + row
      local item = self.items[idx]
      if item then
        local left, right = self.render(item, idx)
        right = right or ""
        local rightLen = unicode.len(right)
        local leftWidth = usable - rightLen - (rightLen > 0 and 1 or 0)
        self.screen:blit(self.x + 1, self.y + row,
          pad(left, math.max(0, leftWidth)), theme.text, theme.panel)
        if rightLen > 0 then
          self.screen:blit(self.x + usable - rightLen + 1, self.y + row,
            right, theme.dim, theme.panel)
        end
      end
    end
    if #self.items > self.h then
      local barH = math.max(1, math.floor(self.h * self.h / #self.items))
      local barY = math.floor((self.top - 1)
        / math.max(1, #self.items - self.h) * (self.h - barH) + 0.5)
      for row = 0, self.h - 1 do
        local mark = (row >= barY and row < barY + barH) and "█" or "│"
        self.screen:blit(self.x + self.w - 1, self.y + row, mark,
          theme.dim, theme.panel)
      end
    end
  end
  o.scrollBy = function(self, delta)
    local maxTop = math.max(1, #self.items - self.h + 1)
    local top = math.max(1, math.min(maxTop, self.top + delta))
    if top ~= self.top then
      self.top = top
      self:draw()
    end
  end
  o.setItems = function(self, items)
    self.items = items
    self.top = 1
    if self.screen then self:draw() end
  end
  o.onTouch = function(self, x, y)
    self.dragged = false
    self.lastDragY = y
  end
  o.onDrag = function(self, x, y)
    self.dragged = true
    if self.lastDragY and y ~= self.lastDragY then
      self:scrollBy(self.lastDragY - y)
    end
    self.lastDragY = y
  end
  o.onDrop = function(self, x, y)
    if self.dragged then return end
    local idx = self.top + (y - self.y)
    local item = self.items[idx]
    if item and self.onSelect then self:onSelect(item, idx) end
  end
  o.onScroll = function(self, direction)
    self:scrollBy(-direction * 2)
  end
  return o
end

-- progress{x, y, w, value=0..1} - horizontal bar.
function ocui.progress(o)
  o.h = 1
  o.value = o.value or 0
  o.draw = function(self)
    local theme = ocui.theme
    local filled = math.floor(self.w
      * math.max(0, math.min(1, self.value)) + 0.5)
    if self.screen.color then
      if filled > 0 then
        self.screen:box(self.x, self.y, filled, 1, theme.accent)
      end
      if filled < self.w then
        self.screen:box(self.x + filled, self.y, self.w - filled, 1,
          theme.button)
      end
    else
      self.screen:blit(self.x, self.y,
        string.rep("█", filled) .. string.rep("░", self.w - filled))
    end
  end
  o.setValue = function(self, value)
    value = math.max(0, math.min(1, value or 0))
    if math.floor(value * self.w) ~= math.floor(self.value * self.w) then
      self.value = value
      if self.screen then self:draw() end
    else
      self.value = value
    end
  end
  return o
end

------------------------------------------------------------ navigation ---

-- A stack of screens with back navigation. A screen is a table with:
--   build(self, nav, ui)          required: create widgets (screen is
--                                 already cleared) and populate content
--   tick(self, nav)               optional: called every pump interval
--   onKey(self, nav, char, code)  optional: keyboard input
-- nav:push/pop/replace rebuild the top screen; popping the last screen
-- (or Ctrl+C) ends nav:run().
local Nav = {}
Nav.__index = Nav

function ocui.navigator(ui)
  return setmetatable({ ui = ui, stack = {} }, Nav)
end

function Nav:rebuild()
  local screen = self.stack[#self.stack]
  self.ui:clear()
  if screen then
    screen:build(self, self.ui)
    self.ui:draw()
  end
end

function Nav:push(screen)
  self.stack[#self.stack + 1] = screen
  self:rebuild()
end

function Nav:pop()
  if #self.stack <= 1 then
    self.done = true
    return
  end
  self.stack[#self.stack] = nil
  self:rebuild()
end

function Nav:replace(screen)
  self.stack[math.max(1, #self.stack)] = screen
  self:rebuild()
end

function Nav:run(interval)
  self.done = false
  while not self.done and #self.stack > 0 do
    local screen = self.stack[#self.stack]
    if screen.tick then screen:tick(self) end
    local kind, a, b = self.ui:pump(interval or 0.25)
    if kind == "quit" then
      self.done = true
    elseif kind == "key" and screen.onKey then
      screen:onKey(self, a, b)
    end
  end
end

--------------------------------------------------------------- helpers ---

-- Greedy word-wrap into lines of at most `width` characters.
function ocui.wrap(text, width)
  local lines = {}
  for paragraph in tostring(text):gmatch("[^\n]+") do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      if unicode.len(word) > width then
        word = unicode.sub(word, 1, width)
      end
      if line == "" then
        line = word
      elseif unicode.len(line) + 1 + unicode.len(word) <= width then
        line = line .. " " .. word
      else
        lines[#lines + 1] = line
        line = word
      end
    end
    if line ~= "" then lines[#lines + 1] = line end
  end
  return lines
end

-- Bottom-line text input (needs a keyboard). Returns the trimmed string
-- or nil when aborted/empty/no keyboard.
function ocui.prompt(screen, label)
  local ok, term = pcall(require, "term")
  if not ok or not term.isAvailable() then return nil end
  screen:box(1, screen.h, screen.w, 1, ocui.theme.accent)
  screen:blit(1, screen.h, " " .. label .. ": ",
    ocui.theme.accentText, ocui.theme.accent)
  local rfg, rbg = screen:colors(ocui.theme.accentText, ocui.theme.accent)
  screen.gpu.setForeground(rfg)
  screen.gpu.setBackground(rbg)
  term.setCursor(unicode.len(label) + 4, screen.h)
  local input = term.read({ dobreak = false })
  if type(input) ~= "string" then return nil end
  input = input:gsub("[\r\n]+$", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if input == "" then return nil end
  return input
end

return ocui
