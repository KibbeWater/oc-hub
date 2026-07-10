-- store.lua: persistence helpers for the hive queen.
-- Filesystem access goes through an injected `fs` backend so the same code runs
-- on OpenOS (filesystem-backed) and on the desktop test harness (io/os-backed).
-- Serialization is injected too: OpenOS passes `serialization`; desktop uses the
-- built-in Lua serializer below. Install to /usr/lib/hive/core/store.lua.

local store = {}

-- Minimal Lua-value serializer (nil/boolean/number/string/table, no cycles).
-- Produces a loadable expression; mirrors OpenOS serialization for desktop use.
function store.luaSerialize(v)
  local t = type(v)
  if t == "nil" then
    return "nil"
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "number" then
    if math.type(v) == "integer" then return tostring(v) end
    return string.format("%.17g", v)
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "table" then
    local parts, n = {}, 0
    for i, item in ipairs(v) do
      parts[#parts + 1] = store.luaSerialize(item)
      n = i
    end
    for k, item in pairs(v) do
      local skip = type(k) == "number" and math.type(k) == "integer" and k >= 1 and k <= n
      if not skip then
        local ks
        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
          ks = k .. "="
        else
          ks = "[" .. store.luaSerialize(k) .. "]="
        end
        parts[#parts + 1] = ks .. store.luaSerialize(item)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("cannot serialize " .. t)
end

function store.luaUnserialize(s)
  local fn = load("return " .. s, "=unser", "t", {})
  if not fn then return nil end
  local ok, v = pcall(fn)
  if not ok then return nil end
  return v
end

-- Default filesystem backend over standard io/os. Works on desktop; hived may
-- inject an OpenOS filesystem-backed variant if os.rename is unavailable there.
function store.iofs()
  return {
    read = function(path)
      local f = io.open(path, "rb")
      if not f then return nil end
      local d = f:read("*a")
      f:close()
      return d
    end,
    write = function(path, data)
      local f = assert(io.open(path, "wb"))
      f:write(data)
      f:close()
    end,
    append = function(path, data)
      local f = assert(io.open(path, "ab"))
      f:write(data)
      f:close()
    end,
    remove = function(path) os.remove(path) end,
    rename = function(from, to)
      os.remove(to)
      return os.rename(from, to)
    end,
    exists = function(path)
      local f = io.open(path, "rb")
      if f then f:close() return true end
      return false
    end,
  }
end

-- opts: fs (backend), serialize, unserialize.
function store.new(opts)
  opts = opts or {}
  local fs = opts.fs or store.iofs()
  local ser = opts.serialize or store.luaSerialize
  local unser = opts.unserialize or store.luaUnserialize
  local self = { fs = fs }

  -- Crash-safe write: stage to a sibling ".new" file then rename over the target.
  function self.saveRaw(path, data)
    fs.write(path .. ".new", data)
    fs.rename(path .. ".new", path)
  end

  function self.loadRaw(path) return fs.read(path) end

  function self.saveAtomic(path, tbl) self.saveRaw(path, ser(tbl)) end

  function self.load(path, default)
    local d = fs.read(path)
    if not d then return default end
    local ok, v = pcall(unser, d)
    if not ok or v == nil then return default end
    return v
  end

  function self.exists(path) return fs.exists(path) end
  function self.remove(path) fs.remove(path) end

  -- Append-only journal. Records are length-prefixed so a torn final write (a
  -- crash mid-append) leaves at most one unreadable tail record, which replay skips.
  function self.journal(path)
    local j = {}
    function j.append(rec)
      local s = ser(rec)
      fs.append(path, string.pack("<I4", #s) .. s)
    end
    function j.replay(fn)
      local data = fs.read(path)
      if not data then return 0 end
      local pos, n = 1, 0
      while pos + 4 <= #data + 1 do
        local len = string.unpack("<I4", data, pos)
        pos = pos + 4
        if pos + len - 1 > #data then break end -- truncated tail
        local ok, rec = pcall(unser, data:sub(pos, pos + len - 1))
        pos = pos + len
        if ok and rec ~= nil then
          fn(rec)
          n = n + 1
        end
      end
      return n
    end
    function j.truncate() fs.write(path, "") end
    function j.size()
      local d = fs.read(path)
      return d and #d or 0
    end
    return j
  end

  return self
end

return store
