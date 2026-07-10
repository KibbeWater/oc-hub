-- Aggregate desktop test runner for the hive (Lua 5.3+):
--   lua tools/test_hive.lua
-- Runs each suite in-process and reports a combined pass/fail. Individual suites
-- remain runnable on their own (they call os.exit); this runner intercepts that
-- so one failing suite doesn't stop the rest.

local suites = {
  "tools/test_hxnet.lua",
  "tools/test_worlddb.lua",
  "tools/test_tasker.lua",
  "tools/test_nav.lua",
  "tools/test_queen.lua",
  "tools/test_roles.lua",
  "tools/check_sizes.lua",
}

local realExit = os.exit
local failed = {}

for _, path in ipairs(suites) do
  print("\n=== " .. path .. " ===")
  local code = 0
  os.exit = function(c) code = (c == true and 0) or (c == false and 1) or (c or 0); error("__exit__") end
  local ok, err = pcall(dofile, path)
  os.exit = realExit
  if not ok and not tostring(err):match("__exit__") then
    print("ERROR: " .. tostring(err))
    failed[#failed + 1] = path .. " (error)"
  elseif code ~= 0 then
    failed[#failed + 1] = path
  end
end

print("\n" .. string.rep("=", 40))
if #failed == 0 then
  print("ALL SUITES PASSED")
  realExit(0)
else
  print("FAILED SUITES:")
  for _, f in ipairs(failed) do print("  - " .. f) end
  realExit(1)
end
