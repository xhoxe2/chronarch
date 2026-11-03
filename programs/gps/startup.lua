-- CHRONARCH :: gps (startup.lua on a GPS host computer)
-- Answers `gps locate` for every turtle and pocket computer: one of the four
-- computers of the GPS tower. Its own position is in /.gps.pos ("x y z"),
-- written by `cx install gps <x> <y> <z>`.
local f = fs.exists("/.gps.pos") and fs.open("/.gps.pos", "r")
local pos = f and f.readAll() or ""
if f then f.close() end
local x, y, z = pos:match("(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)")
if not x then
  print("CHRONARCH gps: no position. Run: cx install gps <x> <y> <z>")
  return
end
print(("CHRONARCH \183 gps \183 %s %s %s"):format(x, y, z))
shell.run("gps", "host", x, y, z)
