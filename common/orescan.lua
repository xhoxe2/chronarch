-- CHRONARCH :: orescan.lua  (shared helper, put it in the turtle root)
-- Turns a raw Geo Scanner result into an ore summary. Pure: no peripherals,
-- so it is fully testable. The turtle calls scanBlocks(radius) and hands the
-- block list here; the base shows the summary.
--
--   local orescan = require("orescan")
--   local sum = orescan.summarize(blocks)
--   -- sum = { total = <n>, counts = { {name=, count=}, ... }, nearest = {name,x,y,z,dist} or nil }
--
-- A block is { x=, y=, z=, name="mod:thing", tags={ ["c:ores"]=true, ... } },
-- with x/y/z relative to the scanner (the turtle).

local M = {}

local function isOre(b)
  if type(b) ~= "table" or type(b.name) ~= "string" then return false end
  if type(b.tags) == "table" and (b.tags["c:ores"] or b.tags["forge:ores"]) then return true end
  return b.name:find("_ore") ~= nil
end

function M.summarize(blocks)
  local counts, total, nearest, ores = {}, 0, nil, {}
  for _, b in ipairs(blocks) do
    if isOre(b) then
      total = total + 1
      counts[b.name] = (counts[b.name] or 0) + 1
      local x, y, z = b.x or 0, b.y or 0, b.z or 0
      local dist = math.abs(x) + math.abs(y) + math.abs(z) -- Manhattan: whole blocks
      ores[#ores + 1] = { name = b.name, x = x, y = y, z = z, dist = dist }
      if not nearest or dist < nearest.dist then
        nearest = { name = b.name, x = x, y = y, z = z, dist = dist }
      end
    end
  end

  local arr = {}
  for name, n in pairs(counts) do arr[#arr + 1] = { name = name, count = n } end
  table.sort(arr, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)

  -- counts/nearest for the log, ores (with coords) for the map
  return { total = total, counts = arr, nearest = nearest, ores = ores }
end

-- Height where each vanilla ore is most common (Minecraft 1.21 world gen).
-- Modded ores are not listed: for them the turtle searches from home level.
local BEST_Y = { diamond = -59, redstone = -59, gold = -16, lapis = 0,
  iron = 16, copper = 48, coal = 96, emerald = 232 }

-- How far down (negative) to go from a home at homeY to find `ore` best, plus
-- the target height. Never up (ore up a mountain is not worth the climb), never
-- into the bedrock floor. nil if the ore or the home height is unknown.
function M.depthFor(ore, homeY)
  if type(ore) ~= "string" or type(homeY) ~= "number" then return nil end
  for key, y in pairs(BEST_Y) do
    if ore:find(key, 1, true) then
      y = math.max(y, -58)
      return math.min(0, y - homeY), y
    end
  end
  return nil
end

-- "minecraft:iron_ore" -> "iron_ore"
function M.short(name)
  return (tostring(name):match("[^:]+$")) or tostring(name)
end

return M
