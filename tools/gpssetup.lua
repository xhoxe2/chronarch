-- CHRONARCH :: gpssetup.lua
-- Turns this computer into a GPS host in one command: writes a startup that
-- runs `gps host x y z`, names the computer (so its files survive being
-- broken) and reboots. x y z are this computer's own block coordinates
-- (F3 -> Targeted Block, looking at the computer).
--
--   wget run https://raw.githubusercontent.com/xhoxe2/chronarch/main/tools/gpssetup.lua <x> <y> <z> [label]

local x, y, z, label = ...
x, y, z = tonumber(x), tonumber(y), tonumber(z)
if not (x and y and z) then
  print("Usage: gpssetup <x> <y> <z> [label]")
  return
end
if not peripheral.find("modem", function(_, m) return m.isWireless() end) then
  print("No ender modem on this computer. Attach one, then run this again.")
  return
end
-- A computer copied in creative (middle-click on a labelled one) keeps the
-- SAME id, and two machines with one id share one set of files. If this one
-- already holds another CHRONARCH program, writing a GPS startup here would
-- break that machine too, so stop and say why.
if fs.exists("/chronarch.key") or fs.exists("/.program") then
  print(("Computer #%d already runs CHRONARCH."):format(os.getComputerID()))
  print("Two computers share this id (a creative")
  print("copy). Break this one, place a NEW computer")
  print("from the creative tab, run this again.")
  return
end
if label then os.setComputerLabel(label) end
local f = fs.open("startup.lua", "w")
f.write(('shell.run("gps", "host", %d, %d, %d)\n'):format(x, y, z))
f.close()
print(("GPS host at %d %d %d. Rebooting..."):format(x, y, z))
sleep(1)
os.reboot()
