-- CHRONARCH :: mine.lua
-- Turtle-miner. Optionally digs a shaft down first, then a 1x2 tunnel
-- forward. Mines every ore vein it touches, throws away junk, unloads into
-- the chest next to its start point when full, and comes home when done.
--
-- Setup: a chest touching the turtle on any side, coal in the turtle.
-- Usage: mine <length> [depth]
--   mine 16       tunnel 16 blocks at the current level
--   mine 32 20    go 20 blocks down first, then tunnel 32 blocks

local args = { ... }
local LENGTH = tonumber(args[1]) or 32
local DEPTH = tonumber(args[2]) or 0
local VEIN_LIMIT = 48 -- max ore blocks per vein (protects fuel and time)

-- Junk the turtle throws away so it doesn't fill up with stone.
local JUNK = {
  ["minecraft:cobblestone"] = true, ["minecraft:cobbled_deepslate"] = true,
  ["minecraft:stone"] = true, ["minecraft:deepslate"] = true,
  ["minecraft:dirt"] = true, ["minecraft:gravel"] = true,
  ["minecraft:sand"] = true, ["minecraft:netherrack"] = true,
  ["minecraft:andesite"] = true, ["minecraft:diorite"] = true,
  ["minecraft:granite"] = true, ["minecraft:tuff"] = true,
  ["minecraft:calcite"] = true, ["minecraft:flint"] = true,
}

-- Blocks the turtle must never break: computers, turtles, storage.
local function isProtected(name)
  return name:find("^computercraft:") ~= nil
      or name:find("chest") ~= nil
      or name:find("barrel") ~= nil
      or name:find("shulker_box") ~= nil
end

-- Position relative to start. dir: 0 = forward, 1 = right, 2 = back, 3 = left
local x, y, z, dir = 0, 0, 0, 0
local TY = 0 -- tunnel level, set after the shaft
local DX = { [0] = 1, 0, -1, 0 }
local DZ = { [0] = 0, 1, 0, -1 }
local stats = { steps = 0, ores = 0, trips = 0 }

local function log(msg) print(msg) end

-- Fuel ---------------------------------------------------------------------
local function fuel()
  local f = turtle.getFuelLevel()
  if f == "unlimited" then return math.huge end
  return f
end

local function refuel(need)
  if fuel() >= need then return true end
  for s = 1, 16 do
    turtle.select(s)
    while fuel() < need and turtle.refuel(1) do end
    if fuel() >= need then break end
  end
  turtle.select(1)
  return fuel() >= need
end

local function distHome() return math.abs(x) + math.abs(y) + math.abs(z) end

-- Movement (digs through gravel, hits mobs, never breaks protected blocks) --
local function turnRight() turtle.turnRight(); dir = (dir + 1) % 4 end
local function turnLeft() turtle.turnLeft(); dir = (dir + 3) % 4 end

local function face(d)
  while dir ~= d do
    if (d - dir) % 4 == 3 then turnLeft() else turnRight() end
  end
end

local function tryMove(move, detect, dig, attack, inspect)
  for _ = 1, 50 do
    if move() then return true end
    if detect() then
      local ok, data = inspect()
      if ok and type(data) == "table" and isProtected(data.name) then return false end
      if not dig() then return false end -- bedrock / unbreakable
    else
      attack()
    end
  end
  return false
end

local function forward()
  if not tryMove(turtle.forward, turtle.detect, turtle.dig, turtle.attack, turtle.inspect) then return false end
  x, z = x + DX[dir], z + DZ[dir]
  return true
end

local function up()
  if not tryMove(turtle.up, turtle.detectUp, turtle.digUp, turtle.attackUp, turtle.inspectUp) then return false end
  y = y + 1
  return true
end

local function down()
  if not tryMove(turtle.down, turtle.detectDown, turtle.digDown, turtle.attackDown, turtle.inspectDown) then return false end
  y = y - 1
  return true
end

-- Navigation by coordinates. Going up: walk back along the tunnel first, then
-- climb the shaft. Going down: drop down the shaft first, then walk.
local function moveVertical(ty)
  while y < ty do if not up() then return false end end
  while y > ty do if not down() then return false end end
  return true
end

local function moveHorizontal(tx, tz)
  if z ~= tz then
    face(z < tz and 1 or 3)
    while z ~= tz do if not forward() then return false end end
  end
  if x ~= tx then
    face(x < tx and 0 or 2)
    while x ~= tx do if not forward() then return false end end
  end
  return true
end

local function goTo(tx, ty, tz)
  if ty > y then return moveHorizontal(tx, tz) and moveVertical(ty) end
  return moveVertical(ty) and moveHorizontal(tx, tz)
end

-- Inventory ----------------------------------------------------------------
local function freeSlots()
  local n = 0
  for s = 1, 16 do
    if turtle.getItemCount(s) == 0 then n = n + 1 end
  end
  return n
end

-- One step can dig the tunnel block, the block above it and ores, each of
-- them possibly a new item type, so keep a few slots in reserve.
local STEP_RESERVE = 3
local ORE_RESERVE = 2

local function dropJunk()
  local saved = dir
  face((dir + 2) % 4) -- drop into the tunnel behind us
  for s = 1, 16 do
    local item = turtle.getItemDetail(s)
    if item and JUNK[item.name] then
      turtle.select(s)
      turtle.drop()
    end
  end
  turtle.select(1)
  face(saved)
end

-- Ores ---------------------------------------------------------------------
local function isOre(ok, data)
  if not ok or type(data) ~= "table" then return false end
  if data.tags and (data.tags["c:ores"] or data.tags["forge:ores"]) then return true end
  return data.name:match("_ore$") ~= nil
end

local veinBudget = 0

local function canTakeOre()
  if veinBudget <= 0 then return false end
  if freeSlots() < ORE_RESERVE then dropJunk() end
  return freeSlots() >= ORE_RESERVE
end

-- Checks all 6 sides; follows ore into the vein and comes back.
local function mineVein()
  if isOre(turtle.inspectUp()) and canTakeOre() then
    veinBudget = veinBudget - 1
    stats.ores = stats.ores + 1
    if up() then mineVein(); down() end
  end
  if isOre(turtle.inspectDown()) and canTakeOre() then
    veinBudget = veinBudget - 1
    stats.ores = stats.ores + 1
    if down() then mineVein(); up() end
  end
  for _ = 1, 4 do
    if isOre(turtle.inspect()) and canTakeOre() then
      veinBudget = veinBudget - 1
      stats.ores = stats.ores + 1
      local saved = dir
      if forward() then
        mineVein()
        face((saved + 2) % 4)
        forward()
      end
      face(saved)
    end
    turnRight()
  end
end

-- Home and chest -----------------------------------------------------------
local function goHome()
  if not goTo(0, 0, 0) then
    error(("Stuck on the way home at %d %d %d"):format(x, y, z))
  end
end

-- Turns the turtle until the chest is behind it. That way decides "forward".
local function findChest()
  if not (peripheral and peripheral.hasType) then return true end
  for _ = 1, 4 do
    if peripheral.hasType("back", "inventory") then return true end
    turtle.turnRight()
  end
  return false
end

-- The turtle's own kit (the Geo Scanner it swaps in, a spare pickaxe) never
-- goes into the chest.
local function isKit(name)
  return name == "advancedperipherals:geo_scanner" or name:find("pickaxe") ~= nil
end

-- Empties everything into the chest except one stack of fuel and the kit.
local function unload()
  face(2)
  local keptFuel = false
  for s = 1, 16 do
    local item = turtle.getItemDetail(s)
    if item then
      turtle.select(s)
      if isKit(item.name) then
        -- keep it
      elseif not keptFuel and turtle.refuel(0) then
        keptFuel = true
      elseif not turtle.drop() then
        turtle.select(1)
        error("Chest is full")
      end
    end
  end
  turtle.select(1)
  face(0)
  stats.trips = stats.trips + 1
end

local function digShaft()
  for _ = 1, DEPTH do
    if not down() then break end -- bedrock: tunnel from here
    local level = y
    veinBudget = VEIN_LIMIT
    mineVein()
    if not goTo(0, level, 0) then return false end
  end
  TY = y
  return true
end

-- Main ---------------------------------------------------------------------
if not turtle then error("This program runs on a turtle") end
if not findChest() then
  log("No chest next to me. Place a chest touching me and run again.")
  return
end
if not refuel(LENGTH * 3 + DEPTH * 2 + 100) and fuel() < 50 then
  log("Not enough fuel. Put coal into my inventory.")
  return
end

log(("CHRONARCH miner: depth %d, tunnel %d"):format(DEPTH, LENGTH))
local reason = "done"

if DEPTH > 0 and not digShaft() then reason = "lost" end

for step = 1, LENGTH do
  if reason ~= "done" then break end
  if not refuel(distHome() + 2 * VEIN_LIMIT + 20) then
    reason = "low fuel"
    break
  end
  if freeSlots() < STEP_RESERVE then dropJunk() end
  if freeSlots() < STEP_RESERVE then
    local back = x
    goHome(); unload()
    if not goTo(back, TY, 0) then reason = "blocked"; break end
  end

  face(0)
  if not forward() then reason = "blocked"; break end
  stats.steps = step

  local here = x
  veinBudget = VEIN_LIMIT
  mineVein()
  if up() then
    mineVein()
    down()
  end
  if not goTo(here, TY, 0) then reason = "lost"; break end
  face(0)

  if step % 8 == 0 then
    log(("step %d/%d  ores %d  fuel %s"):format(step, LENGTH, stats.ores, tostring(turtle.getFuelLevel())))
  end
end

goHome()
unload()
log(("Finished (%s): %d blocks, %d ores, %d trips"):format(reason, stats.steps, stats.ores, stats.trips))
