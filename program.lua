-- CHRONARCH :: program.lua
-- Choose what this machine does, then it downloads that program:
--   program            the list of our programs and what runs here
--   program mining     become a mining turtle (then hold Ctrl+R)
local name = ...
shell.run("update", name or "--list")
