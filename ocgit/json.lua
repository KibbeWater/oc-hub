-- json.lua: minimal JSON decoder for OpenOS (decode only).
-- Install to /usr/lib/json.lua so programs can require("json").

local json = {}

local decodeValue

local ESCAPES = {
  ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
  b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

local function jsonError(s, i, msg)
  local line = 1
  for _ in s:sub(1, i):gmatch("\n") do line = line + 1 end
  error(string.format("json: %s at position %d (line %d)", msg, i, line), 0)
end

local function skipSpace(s, i)
  local _, j = s:find("^[ \t\r\n]*", i)
  return j + 1
end

local function utf8Char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  else
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40)
  end
end

local function decodeString(s, i)
  local buf = {}
  i = i + 1 -- skip opening quote
  while true do
    local c = s:sub(i, i)
    if c == "" then
      jsonError(s, i, "unterminated string")
    elseif c == '"' then
      return table.concat(buf), i + 1
    elseif c == "\\" then
      local e = s:sub(i + 1, i + 1)
      if e == "u" then
        local cp = tonumber(s:sub(i + 2, i + 5), 16)
        if not cp then jsonError(s, i, "invalid unicode escape") end
        buf[#buf + 1] = utf8Char(cp)
        i = i + 6
      elseif ESCAPES[e] then
        buf[#buf + 1] = ESCAPES[e]
        i = i + 2
      else
        jsonError(s, i, "invalid escape '\\" .. e .. "'")
      end
    else
      local j = s:find('["\\]', i)
      if not j then jsonError(s, i, "unterminated string") end
      buf[#buf + 1] = s:sub(i, j - 1)
      i = j
    end
  end
end

local function decodeNumber(s, i)
  local j = i
  while j <= #s and s:sub(j, j):match("[%deE%.%+%-]") do j = j + 1 end
  local n = tonumber(s:sub(i, j - 1))
  if not n then jsonError(s, i, "invalid number") end
  return n, j
end

local function decodeArray(s, i)
  local arr = {}
  i = skipSpace(s, i + 1)
  if s:sub(i, i) == "]" then return arr, i + 1 end
  while true do
    local value
    value, i = decodeValue(s, i)
    arr[#arr + 1] = value
    i = skipSpace(s, i)
    local c = s:sub(i, i)
    if c == "]" then return arr, i + 1 end
    if c ~= "," then jsonError(s, i, "expected ',' or ']'") end
    i = skipSpace(s, i + 1)
  end
end

local function decodeObject(s, i)
  local obj = {}
  i = skipSpace(s, i + 1)
  if s:sub(i, i) == "}" then return obj, i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then jsonError(s, i, "expected object key") end
    local key, value
    key, i = decodeString(s, i)
    i = skipSpace(s, i)
    if s:sub(i, i) ~= ":" then jsonError(s, i, "expected ':'") end
    value, i = decodeValue(s, skipSpace(s, i + 1))
    obj[key] = value
    i = skipSpace(s, i)
    local c = s:sub(i, i)
    if c == "}" then return obj, i + 1 end
    if c ~= "," then jsonError(s, i, "expected ',' or '}'") end
    i = skipSpace(s, i + 1)
  end
end

decodeValue = function(s, i)
  local c = s:sub(i, i)
  if c == '"' then
    return decodeString(s, i)
  elseif c == "{" then
    return decodeObject(s, i)
  elseif c == "[" then
    return decodeArray(s, i)
  elseif c == "t" and s:sub(i, i + 3) == "true" then
    return true, i + 4
  elseif c == "f" and s:sub(i, i + 4) == "false" then
    return false, i + 5
  elseif c == "n" and s:sub(i, i + 3) == "null" then
    return nil, i + 4
  elseif c:match("[%d%-]") then
    return decodeNumber(s, i)
  else
    jsonError(s, i, "unexpected character '" .. c .. "'")
  end
end

function json.decode(s)
  if type(s) ~= "string" then
    error("json.decode expects a string", 2)
  end
  local value, i = decodeValue(s, skipSpace(s, 1))
  i = skipSpace(s, i)
  if i <= #s then jsonError(s, i, "trailing garbage") end
  return value
end

return json
