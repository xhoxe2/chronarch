-- CHRONARCH :: navigate.lua  (on the turtle)
-- Dead-reckoning navigation. Turtles have no compass or GPS, so this:
--   * tracks position + heading from a start point as it moves/turns,
--   * works out which way it faces using the Geo Scanner (calibrate), by
--     scanning, stepping one block and scanning again,
--   * digs a straight path to a target, never breaking protected blocks.
--
-- Heading matches a turtle that turns right 0->1->2->3:
--   0 = +x (east), 1 = +z (south), 2 = -x (west), 3 = -z (north).
--
--   local nav = require("navigate")
--   nav.reset()                         -- at the scan spot, heading unknown
--   nav.calibrate(function(r) return scanner.scanBlocks(r) end)
--   nav.travel(tx, ty, tz)              -- dig a path to the ore
--   nav.travel(0, 0, 0)                 -- come back

local M = {}

local DX = { [0] = 1, [1] = 0, [2] = -1, [3] = 0 }
local DZ = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }

local state = { x = 0, y = 0, z = 0, h = 0 }

function M.reset(x, y, z, h)
  state = { x = x or 0, y = y or 0, z = z or 0, h = h or 0 }
end

function M.pos() return state.x, state.y, state.z, state.h end

local function isProtected(name)
  if not name then return false end
  if name == "minecraft:bedrock" then return true end
  if name:find("^computercraft:") then return true end
  if name:find("chest") or name:find("barrel") or name:find("shulker") then return true end
  return false
end

-- Dig in a direction only if what's there is safe to break.
local function clear(detect, inspect, dig)
  if not detect() then return true end
  local ok, data = inspect()
  if ok and isProtected(data.name) then return false, "blocked by " .. data.name end
  dig()
  return true
end

-- A "stop" order aborts movement at once (so a harvest can be recalled), except
-- while homing, when we still want to drive back to base.
local stopFn, homing = nil, false
local function shouldAbort() return (not homing) and stopFn ~= nil and stopFn() end
local stepReport = nil -- called after every block moved, for a smooth live map
local function moved() if stepReport then stepReport() end end

local function stepForward()
  if shouldAbort() then return false, "stopped" end
  for _ = 1, 10 do -- retry: falling gravel/sand can refill the space
    local ok, err = clear(turtle.detect, turtle.inspect, turtle.dig)
    if not ok then return false, err end
    if turtle.forward() then
      state.x = state.x + DX[state.h]
      state.z = state.z + DZ[state.h]
      moved(); return true
    end
  end
  return false, "stuck moving forward"
end

local function stepUp()
  if shouldAbort() then return false, "stopped" end
  for _ = 1, 10 do
    local ok, err = clear(turtle.detectUp, turtle.inspectUp, turtle.digUp)
    if not ok then return false, err end
    if turtle.up() then state.y = state.y + 1; moved(); return true end
  end
  return false, "stuck moving up"
end

local function stepDown()
  if shouldAbort() then return false, "stopped" end
  for _ = 1, 10 do
    local ok, err = clear(turtle.detectDown, turtle.inspectDown, turtle.digDown)
    if not ok then return false, err end
    if turtle.down() then state.y = state.y - 1; moved(); return true end
  end
  return false, "stuck moving down"
end

local function turnTo(h)
  while state.h ~= h do
    if (state.h + 1) % 4 == h then
      turtle.turnRight(); state.h = (state.h + 1) % 4
    else
      turtle.turnLeft(); state.h = (state.h + 3) % 4
    end
  end
end

-- Move to (tx,ty,tz): height first, then the x axis, then the z axis.
function M.travel(tx, ty, tz)
  while state.y < ty do local ok, e = stepUp(); if not ok then return false, e end end
  while state.y > ty do local ok, e = stepDown(); if not ok then return false, e end end
  if state.x ~= tx then turnTo(tx > state.x and 0 or 2) end
  while state.x ~= tx do local ok, e = stepForward(); if not ok then return false, e end end
  if state.z ~= tz then turnTo(tz > state.z and 1 or 3) end
  while state.z ~= tz do local ok, e = stepForward(); if not ok then return false, e end end
  return true
end

-- Vein mining: from the ore cell the turtle just dug into, flood-fill every
-- connected ore block and come back to where it started. Each branch is undone
-- so the turtle ends on the starting cell, facing the way it began.
local function neighborOre(detect, inspect)
  if not detect() then return false end
  local ok, data = inspect()
  if not ok or type(data) ~= "table" or not data.name then return false end
  if data.tags and data.tags["c:ores"] then return true end
  return data.name:find("_ore") ~= nil
end

local veinMined
local function veinDFS(depth)
  if depth > 128 then return end -- safety cap on vein size
  for _ = 1, 4 do
    if neighborOre(turtle.detect, turtle.inspect) and stepForward() then
      veinMined = veinMined + 1
      veinDFS(depth + 1)
      -- step back to the cell we came from, keeping our facing
      turtle.turnRight(); turtle.turnRight(); state.h = (state.h + 2) % 4
      stepForward()
      turtle.turnRight(); turtle.turnRight(); state.h = (state.h + 2) % 4
    end
    turtle.turnRight(); state.h = (state.h + 1) % 4
  end
  if neighborOre(turtle.detectUp, turtle.inspectUp) and stepUp() then
    veinMined = veinMined + 1; veinDFS(depth + 1); stepDown()
  end
  if neighborOre(turtle.detectDown, turtle.inspectDown) and stepDown() then
    veinMined = veinMined + 1; veinDFS(depth + 1); stepUp()
  end
end

function M.mineVein()
  veinMined = 0
  veinDFS(0)
  return veinMined
end

local AREA_SCAN_R = 8

local function oreData(o)
  if type(o) ~= "table" or not o.name then return false end
  if o.tags and o.tags["c:ores"] then return true end
  return o.name:find("_ore") ~= nil
end

-- Harvest every ore within areaRadius of the start: scan the ~8-block vicinity,
-- walk to the nearest ore and take its whole vein, re-scan, repeat until the
-- area is clear (or fuel/inventory/limit runs out). Ends back at the start.
-- Needs the heading already calibrated. scanFn(r) returns the raw scan; the
-- caller handles equipping the scanner. Returns (mined blocks, reason string).
function M.mineArea(scanFn, areaRadius, opts)
  opts = opts or {}
  local step = opts.step or 14 -- waypoint spacing, <= 2 * scan radius so scans overlap
  local fuelBuffer = opts.fuelBuffer or 40
  local onProgress = opts.onProgress -- function(remainingOres, {x,y,z}) for the live map
  local cx0, cy0, cz0 = 0, 0, 0
  if opts.center then cx0, cy0, cz0 = opts.center.x or 0, opts.center.y or 0, opts.center.z or 0 end

  stopFn = opts.shouldStop -- let movement abort the moment a stop lands
  stepReport = opts.onMove and function() opts.onMove({ x = state.x, y = state.y, z = state.z }) end or nil
  local mined, reason = 0, "area clear"
  local done, found = {}, {} -- mined keys; every ore seen (home frame)

  local function axis(lo, hi)
    local t, v = {}, lo
    while v <= hi do t[#t + 1] = v; v = v + step end
    if t[#t] ~= hi then t[#t + 1] = hi end
    return t
  end
  local xs = axis(cx0 - areaRadius, cx0 + areaRadius)
  local zs = axis(cz0 - areaRadius, cz0 + areaRadius)
  local ys
  if opts.center then
    ys = (areaRadius <= AREA_SCAN_R) and { cy0 } or axis(cy0 - areaRadius, cy0 + areaRadius)
  else
    ys = (areaRadius <= AREA_SCAN_R) and { 0 } or axis(-areaRadius, 0) -- ore is below home
  end

  local waypoints = {}
  for yi, yy in ipairs(ys) do
    for zi, zz in ipairs(zs) do
      local row = {}
      for i = 1, #xs do row[i] = xs[i] end
      if (yi + zi) % 2 == 0 then -- snake, to keep travel short
        local r = {}; for i = #row, 1, -1 do r[#r + 1] = row[i] end; row = r
      end
      for _, xx in ipairs(row) do waypoints[#waypoints + 1] = { x = xx, y = yy, z = zz } end
    end
  end

  local function inArea(ox, oy, oz)
    return math.max(math.abs(ox - cx0), math.abs(oy - cy0), math.abs(oz - cz0)) <= areaRadius
  end
  local function invFull()
    for s = 1, 16 do if turtle.getItemCount(s) == 0 then return false end end
    return true
  end
  local function afford(d)
    local fl = turtle.getFuelLevel()
    return type(fl) ~= "number" or fl >= d
  end
  local function report()
    if not onProgress then return end
    local rem = {}
    for k, o in pairs(found) do if not done[k] then rem[#rem + 1] = o end end
    onProgress(rem, { x = state.x, y = state.y, z = state.z })
  end

  local reach = step -- one waypoint sees and can reach every ore up to `step` away
  for _, wp in ipairs(waypoints) do
    if opts.shouldStop and opts.shouldStop() then reason = "stopped"; break end
    local dWp = math.abs(wp.x - state.x) + math.abs(wp.y - state.y) + math.abs(wp.z - state.z)
    local dHome = math.abs(wp.x) + math.abs(wp.y) + math.abs(wp.z)
    M.ensureFuel(dWp + dHome + fuelBuffer)
    if not afford(dWp + dHome + fuelBuffer) then reason = "low fuel"; break end
    M.travel(wp.x, wp.y, wp.z) -- a blocked waypoint just leaves us nearby; fine

    -- ONE scan per waypoint. The Geo Scanner has a cooldown, so re-scanning after
    -- every vein (the old way) left the turtle standing still for seconds at a
    -- time and froze the live map. Mine everything this single scan reveals.
    local blocks = scanFn(AREA_SCAN_R)
    if type(blocks) == "table" then
      local seen = {}
      for _, o in ipairs(blocks) do
        if oreData(o) then
          local ox, oy, oz = state.x + o.x, state.y + o.y, state.z + o.z
          local k = ox .. "," .. oy .. "," .. oz
          seen[k] = true
          if inArea(ox, oy, oz) then found[k] = { x = ox, y = oy, z = oz, name = o.name } end
        end
      end
      -- Drop ghosts: an ore near enough to be in this scan's range but no longer
      -- returned has been dug out (a whole vein vanishes at once), so forget it.
      for k, o in pairs(found) do
        if not seen[k] and math.abs(o.x - state.x) <= AREA_SCAN_R
          and math.abs(o.y - state.y) <= AREA_SCAN_R
          and math.abs(o.z - state.z) <= AREA_SCAN_R then
          found[k], done[k] = nil, nil
        end
      end
      report()

      while true do -- take every ore in reach, nearest first, no re-scan
        if opts.shouldStop and opts.shouldStop() then reason = "stopped"; break end
        local best, bestD, bestKey
        for k, o in pairs(found) do
          if not done[k] then
            local d = math.abs(o.x - state.x) + math.abs(o.y - state.y) + math.abs(o.z - state.z)
            if d <= reach and (not bestD or d < bestD) then bestD, best, bestKey = d, o, k end
          end
        end
        if not best then break end -- the rest waits for a nearer waypoint

        local toHome = math.abs(best.x) + math.abs(best.y) + math.abs(best.z)
        M.ensureFuel(bestD + toHome + fuelBuffer)
        if not afford(bestD + toHome + fuelBuffer) then reason = "low fuel"; break end

        done[bestKey] = true
        if M.travel(best.x, best.y, best.z) then mined = mined + 1 + M.mineVein() end
        report()

        if invFull() then -- unload and come back to the same spot
          local rx, ry, rz = state.x, state.y, state.z
          M.travel(0, 0, 0)
          if not M.deposit() then reason = "inventory full, no chest"; break end
          M.travel(rx, ry, rz)
        end
      end
    end
    if reason == "stopped" or reason == "low fuel" or reason == "inventory full, no chest" then break end
  end

  if opts.onHoming then opts.onHoming() end
  homing = true
  M.travel(0, 0, 0) -- always come home, even on stop
  homing, stopFn, stepReport = false, nil, nil
  report()
  return mined, reason
end

local function unit(dx, dz)
  if dx == 1 and dz == 0 then return 0 end
  if dx == 0 and dz == 1 then return 1 end
  if dx == -1 and dz == 0 then return 2 end
  if dx == 0 and dz == -1 then return 3 end
  return nil
end

-- Move forward one block (dig safely) WITHOUT updating the tracked position,
-- used for calibration while the heading is still unknown. Needs the pickaxe.
function M.probeStep()
  for _ = 1, 10 do
    local ok, err = clear(turtle.detect, turtle.inspect, turtle.dig)
    if not ok then return false, err end
    if turtle.forward() then return true end
  end
  return false, "stuck moving forward"
end

-- Step one block to calibrate; if blocked (chest/computer/bedrock in front),
-- turn and try another side. Returns true once it moved, false if boxed in.
function M.probeAnyDir()
  for _ = 1, 4 do
    if M.probeStep() then return true end
    turtle.turnRight()
  end
  return false, "boxed in on all four sides"
end

-- Given scans before and after one forward step, work out the heading. Every
-- stable ore shifts by exactly -forward, so the real forward is the candidate
-- direction that makes the MOST ores in `a` reappear at (a - F) in `b`. Voting
-- over all ores beats a single match, which with many same-named ores is often
-- a coincidence. Sets the tracked position to that one-block step.
function M.deduceHeading(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false, "bad scans" end
  local set = {}
  for _, o in ipairs(b) do
    set[(o.name or "?") .. "|" .. o.x .. "," .. o.y .. "," .. o.z] = true
  end
  local cands = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }
  local best, bestF = 0, nil
  for _, F in ipairs(cands) do
    local n = 0
    for _, o in ipairs(a) do
      if set[(o.name or "?") .. "|" .. (o.x - F[1]) .. "," .. o.y .. "," .. (o.z - F[2])] then
        n = n + 1
      end
    end
    if n > best then best, bestF = n, F end
  end
  if best < 1 or not bestF then return false, "could not match ores between the two scans" end
  local h = unit(bestF[1], bestF[2])
  state.h = h; state.x = DX[h]; state.z = DZ[h]; state.y = 0
  return true, h
end

local FUEL_ITEMS = {
  ["minecraft:coal"] = true, ["minecraft:charcoal"] = true, ["minecraft:coal_block"] = true,
}

-- Keep fuel and the turtle's own kit (the Geo Scanner it swaps in, a pickaxe);
-- everything else is loot to drop.
local function keepItem(name)
  if not name then return false end
  if FUEL_ITEMS[name] then return true end
  if name == "advancedperipherals:geo_scanner" then return true end
  if name:find("pickaxe") then return true end
  return false
end

-- Top up fuel from coal in the inventory when it drops below `reserve`.
function M.ensureFuel(reserve)
  local fl = turtle.getFuelLevel()
  if type(fl) ~= "number" or fl >= reserve then return end
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and FUEL_ITEMS[d.name] then
      turtle.select(s); turtle.refuel()
      if turtle.getFuelLevel() >= reserve then break end
    end
  end
  turtle.select(1)
end

-- Face an adjacent chest/barrel/shulker and drop the loot into it.
function M.deposit()
  for _ = 1, 4 do
    local ok, data = turtle.inspect()
    if ok and data.name and (data.name:find("chest") or data.name:find("barrel") or data.name:find("shulker")) then
      for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d and not keepItem(d.name) then
          turtle.select(s)
          turtle.drop()
        end
      end
      turtle.select(1)
      return true
    end
    turtle.turnRight()
  end
  return false
end

-- All-in-one (used by the tests): scan, step, scan, deduce.
function M.calibrate(scan)
  local a = scan(8)
  if type(a) ~= "table" or #a == 0 then return false, "no ores to calibrate against" end
  local ok, err = M.probeStep()
  if not ok then return false, "calibration move failed: " .. tostring(err) end
  local b = scan(8)
  return M.deduceHeading(a, b)
end

return M
