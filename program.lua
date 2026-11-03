-- CHRONARCH :: program.lua
-- Choose what this machine does, then it downloads that program:
--   program            show the current program and the list
--   program mining     become a mining turtle (then hold Ctrl+R)
local name = ...
if name then
  shell.run("update", name)
  return
end
if fs.exists("/program") then
  local f = fs.open("/program", "r")
  print("Program: " .. f.readAll())
  f.close()
else
  print("Program: (auto)")
end
print("Change: program <name>   (mining, base, colony)")
