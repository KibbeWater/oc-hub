-- optimize.lua: safe Lua source optimizer for OpenOS.
-- Strips comments, indentation, blank lines and redundant whitespace WITHOUT
-- touching string literals, so program behavior is preserved exactly.
-- Useful for fitting code onto EEPROMs (4KB) and small OC drives.
-- Install to /usr/lib/optimize.lua.
--
--   local optimize = require("optimize")
--   local smaller, stats = optimize.safeStrip(source)
--   -- stats = { before = <bytes>, after = <bytes> }

local optimize = {}

-- Returns the end position of a long bracket ([[...]], [=[...]=], ...) that
-- starts at `i`, or nil if there is no long bracket at `i`.
local function longBracketEnd(source, i)
  local eq = source:match("^%[(=*)%[", i)
  if not eq then return nil end
  local _, e = source:find("]" .. eq .. "]", i + 2 + #eq, true)
  return e or #source
end

function optimize.strip(source)
  local out = {}

  local function last()
    return out[#out]
  end

  local function emitSpace()
    local prev = last()
    if prev ~= nil and prev ~= " " and prev ~= "\n" then
      out[#out + 1] = " "
    end
  end

  local function emitNewline()
    local prev = last()
    if prev == " " then
      out[#out] = "\n"
    elseif prev ~= nil and prev ~= "\n" then
      out[#out + 1] = "\n"
    end
  end

  local i = 1
  local n = #source
  while i <= n do
    local c = source:sub(i, i)
    if c == "-" and source:sub(i + 1, i + 1) == "-" then
      local e = longBracketEnd(source, i + 2)
      if e then
        i = e + 1 -- block comment: drop it entirely
      else
        i = source:find("\n", i, true) or (n + 1) -- line comment: keep the \n
      end
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = source:sub(j, j)
        if d == "\\" then
          j = j + 2
        elseif d == c then
          break
        else
          j = j + 1
        end
      end
      out[#out + 1] = source:sub(i, j)
      i = j + 1
    elseif c == "[" and longBracketEnd(source, i) then
      local e = longBracketEnd(source, i)
      out[#out + 1] = source:sub(i, e)
      i = e + 1
    elseif c == "\n" then
      emitNewline()
      i = i + 1
    elseif c == " " or c == "\t" or c == "\r" then
      emitSpace()
      i = i + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end

  while last() == " " or last() == "\n" do
    out[#out] = nil
  end
  local result = table.concat(out)
  if #result > 0 then result = result .. "\n" end
  return result, { before = #source, after = #result }
end

-- Verifies that source still compiles; returns true or nil, err.
function optimize.check(source)
  local fn, err = load(source, "=optimized")
  if not fn then return nil, err end
  return true
end

-- Strip, but fall back to the original source if the result no longer
-- compiles (while the original did). This is the recommended entry point.
function optimize.safeStrip(source)
  local ok, stripped, stats = pcall(optimize.strip, source)
  if not ok then
    return source, { before = #source, after = #source }
  end
  if not optimize.check(stripped) and optimize.check(source) then
    return source, { before = #source, after = #source }
  end
  return stripped, stats
end

return optimize
