-- EEPROM size gate + drone-image build check (Lua 5.3+):
--   lua tools/check_sizes.lua
-- Fails if boot0/relay0 exceed their stripped EEPROM budgets, and builds the
-- scout drone image from the real sources to catch bundling/compile regressions.

package.path = "hive/?.lua;hive/core/?.lua;hive/sdk/?.lua;ocgit/?.lua;tools/?.lua;" .. package.path
local optimize = require("optimize")
local firmware = require("firmware")

local failures = 0
local function check(name, ok, detail)
  if ok then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
end

local function readFile(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local d = f:read("*a"); f:close(); return d
end

-- EEPROM budgets (bytes, stripped). Headroom kept below the 4096 hard limit.
local BUDGETS = { ["hive/boot0.lua"] = 3600, ["hive/relay0.lua"] = 2500 }

for path, budget in pairs(BUDGETS) do
  local src = readFile(path)
  if not src then
    print("skip " .. path .. " (not present yet)")
  else
    local stripped, stats = optimize.safeStrip(src)
    local okCompile = optimize.check(stripped)
    check(path .. " compiles stripped", okCompile ~= nil)
    check(string.format("%s <= %d B (got %d, from %d)", path, budget, stats.after, stats.before),
      stats.after <= budget, stats.after)
  end
end

-- Build the scout drone image from the real sources through the bundle path.
do
  local fw = firmware.new{
    readFile = readFile,
    optimize = optimize.safeStrip,
    sha = function(s) return (s .. ("\0"):rep(32)):sub(1, 32) end, -- desktop stand-in
    common = {
      { name = "hxnet", path = "hive/hxnet.lua" },
      { name = "worldscan", path = "hive/sdk/worldscan.lua" },
      { name = "navcore", path = "hive/sdk/navcore.lua" },
      { name = "drone_sdk", path = "hive/sdk/drone_sdk.lua" },
    },
    roleDir = "hive/roles",
  }
  local img, ver, sha, stats = fw.build("scout")
  check("scout image builds", img ~= nil, ver)
  if img then
    check("scout image compiles", (load(img, "=scout")) ~= nil)
    print(string.format("     scout image: %d B stripped (from %d)", stats.after, stats.before))
    check("scout image fits a drone (512KB RAM)", #img < 200 * 1024, #img)
  end
end

print(string.rep("-", 40))
if failures == 0 then print("size gate passed"); os.exit(0)
else print(failures .. " check(s) failed"); os.exit(1) end
