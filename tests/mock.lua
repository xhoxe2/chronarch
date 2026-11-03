-- Minimal CC:Tweaked turtle world for testing mine.lua
local W = {}
W.blocks = {}          -- "x,y,z" -> name (nil = default rock, "air" = empty)
W.default = function(x, y, z) if y <= -5 then return "minecraft:bedrock" end return "minecraft:stone" end
W.pos = { x = 0, y = 0, z = 0 }; W.h = 0
W.fuel = 0
W.inv = {}; for i = 1, 16 do W.inv[i] = false end
W.sel = 1
W.chest = {}; W.chestPos = "-1,0,0"; W.chestCap = 27 * 64
W.dropped = 0; W.lost = 0; W.dugChest = false; W.moves = 0
W.regen = {}           -- key -> times the block reappears (falling gravel)
W.out = {}

local HX = { [0] = 1, 0, -1, 0 }
local HZ = { [0] = 0, 1, 0, -1 }
local function key(x, y, z) return x .. "," .. y .. "," .. z end
function W.get(x, y, z)
  local k = key(x, y, z)
  if k == W.chestPos then return "minecraft:chest" end
  local b = W.blocks[k]
  if b == nil then return W.default(x, y, z) end
  if b == "air" then return nil end
  return b
end
function W.set(x, y, z, n) W.blocks[key(x, y, z)] = n end

local FUEL = { ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80 }
local DROPS = {
  ["minecraft:stone"] = "minecraft:cobblestone",
  ["minecraft:iron_ore"] = "minecraft:raw_iron",
  ["minecraft:deepslate_iron_ore"] = "minecraft:raw_iron",
  ["minecraft:coal_ore"] = "minecraft:coal",
  ["minecraft:diamond_ore"] = "minecraft:diamond",
  ["allthemodium:allthemodium_ore"] = "allthemodium:raw_allthemodium",
}
local ORE = {}
for k in pairs(DROPS) do if k:match("_ore$") then ORE[k] = true end end
W.ORE = ORE

local function addItem(name, n)
  for i = 1, 16 do
    local s = W.inv[i]
    if s and s.name == name and s.count < 64 then
      local add = math.min(n, 64 - s.count); s.count = s.count + add; n = n - add
      if n == 0 then return end
    end
  end
  for i = 1, 16 do
    if not W.inv[i] then W.inv[i] = { name = name, count = n }; return end
  end
  W.lost = W.lost + n
end
W.addItem = addItem

local function target(dir)
  local p = W.pos
  if dir == "f" then return p.x + HX[W.h], p.y, p.z + HZ[W.h] end
  if dir == "u" then return p.x, p.y + 1, p.z end
  return p.x, p.y - 1, p.z
end

local function move(dir)
  local x, y, z = target(dir)
  if W.get(x, y, z) then return false, "Movement obstructed" end
  if W.fuel <= 0 then return false, "Out of fuel" end
  W.fuel = W.fuel - 1; W.moves = W.moves + 1
  W.pos.x, W.pos.y, W.pos.z = x, y, z
  return true
end

local function dig(dir)
  local x, y, z = target(dir)
  local b = W.get(x, y, z)
  if not b then return false, "Nothing to dig here" end
  if b == "minecraft:bedrock" then return false, "Cannot break unbreakable block" end
  if b == "minecraft:chest" then W.dugChest = true; return false, "chest" end
  local k = key(x, y, z)
  if W.regen[k] and W.regen[k] > 0 then
    W.regen[k] = W.regen[k] - 1
  else
    W.set(x, y, z, "air")
  end
  addItem(DROPS[b] or b, 1)
  return true
end

local function inspect(dir)
  local x, y, z = target(dir)
  local b = W.get(x, y, z)
  if not b then return false, "No block to inspect" end
  local tags = {}
  if ORE[b] then tags["c:ores"] = true end
  return true, { name = b, state = {}, tags = tags }
end

turtle = {
  forward = function() return move("f") end,
  up = function() return move("u") end,
  down = function() return move("d") end,
  back = function() return false end,
  turnRight = function() W.h = (W.h + 1) % 4; return true end,
  turnLeft = function() W.h = (W.h + 3) % 4; return true end,
  detect = function() return W.get(target("f")) ~= nil end,
  detectUp = function() return W.get(target("u")) ~= nil end,
  detectDown = function() return W.get(target("d")) ~= nil end,
  dig = function() return dig("f") end,
  digUp = function() return dig("u") end,
  digDown = function() return dig("d") end,
  attack = function() return false end,
  attackUp = function() return false end,
  attackDown = function() return false end,
  inspect = function() return inspect("f") end,
  inspectUp = function() return inspect("u") end,
  inspectDown = function() return inspect("d") end,
  getFuelLevel = function() return W.fuel end,
  select = function(s) assert(s >= 1 and s <= 16); W.sel = s; return true end,
  getItemCount = function(s) local it = W.inv[s or W.sel]; return it and it.count or 0 end,
  getItemDetail = function(s)
    local it = W.inv[s or W.sel]; if not it then return nil end
    return { name = it.name, count = it.count }
  end,
  refuel = function(n)
    local it = W.inv[W.sel]
    if not it or not FUEL[it.name] then return false, "Items not combustible" end
    n = math.min(n or it.count, it.count)
    W.fuel = W.fuel + FUEL[it.name] * n
    it.count = it.count - n
    if it.count == 0 then W.inv[W.sel] = false end
    return true
  end,
  drop = function()
    local it = W.inv[W.sel]
    if not it then return false, "No items to drop" end
    local x, y, z = target("f")
    if key(x, y, z) == W.chestPos then
      local used = 0
      for _, n in pairs(W.chest) do used = used + n end
      if used + it.count > W.chestCap then return false, "No space for items" end
      W.chest[it.name] = (W.chest[it.name] or 0) + it.count
    else
      W.dropped = W.dropped + it.count
    end
    W.inv[W.sel] = false
    return true
  end,
}

peripheral = {
  hasType = function(side, t)
    if side ~= "back" then return false end
    local h = (W.h + 2) % 4
    local k = key(W.pos.x + HX[h], W.pos.y, W.pos.z + HZ[h])
    return k == W.chestPos and t == "inventory"
  end,
}

-- Geo Scanner: ores within radius of the turtle, in world coords relative to it.
function W.scanBlocks(radius)
  local out = {}
  for dx = -radius, radius do
    for dy = -radius, radius do
      for dz = -radius, radius do
        local b = W.get(W.pos.x + dx, W.pos.y + dy, W.pos.z + dz)
        if b and ORE[b] then
          out[#out + 1] = { x = dx, y = dy, z = dz, name = b, tags = { ["c:ores"] = true } }
        end
      end
    end
  end
  return out
end

print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  W.out[#W.out + 1] = table.concat(parts, " ")
end

return W
