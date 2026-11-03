-- CHRONARCH :: getscanner.lua  (one-off helper on a turtle)
-- Picks up a Geo Scanner that was dropped on the ground right in front of the
-- turtle, into its inventory, so agent.lua can equip it for scanning.
-- Run it, then reboot (Ctrl+R) to bring the agent back.
local ok, err = turtle.suck()
if ok then
  print("Got it. Now hold Ctrl+R to restart the agent.")
else
  print("Nothing to pick up: " .. tostring(err))
  print("Drop a Geo Scanner right in front of me (aim at me, press Q), then run getscanner again.")
end
