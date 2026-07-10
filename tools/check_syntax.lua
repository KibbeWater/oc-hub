-- Compile-check Lua files without executing them (loadfile compiles only).
--   lua tools/check_syntax.lua <file> [file ...]
-- Used to validate OpenOS programs on the desktop, where their require()d
-- runtime modules (component, event, ...) are absent but the syntax must be sound.
local bad = 0
for _, f in ipairs(arg) do
  local fn, err = loadfile(f)
  if fn then
    print("OK   " .. f)
  else
    bad = bad + 1
    print("FAIL " .. f)
    print("     " .. tostring(err))
  end
end
os.exit(bad == 0 and 0 or 1)
