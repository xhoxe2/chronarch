-- CHRONARCH :: update.lua  - same as `cx update` (kept for old habits).
--   update            download the latest code of this machine's program
--   update <program>  same as cx install <program>
local name = ...
if name then shell.run("cx", "install", ...) else shell.run("cx", "update") end
