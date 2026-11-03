-- CHRONARCH :: swarm.lua  (on the base)
-- Splits a square of the world between several turtles so they never dig the
-- same ground: one stripe each along x, the westmost turtle gets the west
-- stripe (short trips). Pure: world coordinates in, stripes out.
--
--   local swarm = require("swarm")
--   local parts = swarm.split(cx, cz, r, { {name="xhoxi", x=638}, {name="b", x=700} })
--   -- parts = { xhoxi = { x1=, x2=, z1=, z2= }, b = {...} }

local M = {}

function M.split(cx, cz, r, turtles)
  local list = {}
  for _, t in ipairs(turtles) do list[#list + 1] = t end
  table.sort(list, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.name < b.name
  end)
  local n = #list
  if n == 0 then return {} end
  local x0, width = cx - r, 2 * r + 1
  local parts = {}
  for i, t in ipairs(list) do
    local a = x0 + math.floor((i - 1) * width / n)
    local b = x0 + math.floor(i * width / n) - 1
    parts[t.name] = { x1 = a, x2 = b, z1 = cz - r, z2 = cz + r }
  end
  return parts
end

return M
