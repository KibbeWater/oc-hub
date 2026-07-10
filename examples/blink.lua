-- Example ocnet worker script: beeps (and toggles redstone output, if a
-- redstone card is present) every few seconds. Push it to your listener
-- nodes from the master computer with:
--
--   ocpush examples/blink.lua --watch
--
-- ocnet scripts run in a bare environment: use component/computer directly
-- (no require/OpenOS), and sleep via computer.pullSignal so the node can
-- deliver hot updates.

local rs
for address in component.list("redstone") do
  rs = component.proxy(address)
end

local on = false
while true do
  on = not on
  if rs then
    for side = 0, 5 do
      rs.setOutput(side, on and 15 or 0)
    end
  end
  computer.beep(on and 880 or 440, 0.1)
  computer.pullSignal(3)
end
