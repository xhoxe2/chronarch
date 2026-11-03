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

-- World memory from the scans: "x,y,z" -> block name, false = air, "!" = a
-- cell we failed to get through. Missing = never seen (planned as stone).
local world = {}
local function wkey(x, y, z) return x .. "," .. y .. "," .. z end

function M.reset(x, y, z, h)
  state = { x = x or 0, y = y or 0, z = z or 0, h = h or 0 }
  M.chestH = nil
  world = {}
end

-- Remember a scan made at (ox,oy,oz) with radius r: every cell in its cube is
-- air unless the scan listed a block there.
function M.remember(blocks, ox, oy, oz, r)
  if type(blocks) ~= "table" then return end
  for x = ox - r, ox + r do
    for y = oy - r, oy + r do
      for z = oz - r, oz + r do world[wkey(x, y, z)] = false end
    end
  end
  for _, b in ipairs(blocks) do
    if b.name then world[wkey(ox + b.x, oy + b.y, oz + b.z)] = b.name end
  end
end

function M.pos() return state.x, state.y, state.z, state.h end

local function isContainer(name)
  return type(name) == "string" and (name:find("chest") or name:find("barrel") or name:find("shulker")) ~= nil
end

local function isProtected(name)
  if not name then return false end
  if name == "minecraft:bedrock" then return true end
  if name:find("^computercraft:") then return true end
  return isContainer(name)
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
local stepHook = nil   -- mineArea's per-step work: scan on the go, drop junk
local function moved()
  world[wkey(state.x, state.y, state.z)] = false -- we stand here: it is open now
  if stepReport then stepReport() end
  if stepHook and not homing then stepHook() end
end

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

-- Fallback move to (tx,ty,tz) without a map: any path along the axes is as
-- short as the Manhattan distance, and digging makes every cell passable. Height
-- first (needs no turning), then the axis we already face, so it turns at most
-- once. A protected block in the way (chest, computer) is walked around: the
-- other axis order first, then over the top. stopWhen() is checked before
-- every step: return true to end early (e.g. the target was dug from next door).
local function axisTravel(tx, ty, tz, stopWhen)
  local function enough() return stopWhen ~= nil and stopWhen() end
  local function vertical(target)
    while state.y ~= target do
      if enough() then return true end
      local ok, e
      if state.y < target then ok, e = stepUp() else ok, e = stepDown() end
      if not ok then return false, e end
    end
    return true
  end
  local function leg(ax)
    local t = (ax == "x") and tx or tz
    if state[ax] == t then return true end
    if ax == "x" then turnTo(t > state.x and 0 or 2) else turnTo(t > state.z and 1 or 3) end
    while state[ax] ~= t do
      if enough() then return true end
      local ok, e = stepForward()
      if not ok then return false, e end
    end
    return true
  end
  local function flat()
    local a = (state.h % 2 == 1) and "z" or "x"
    local b = (a == "x") and "z" or "x"
    local ok, e = leg(a)
    if ok then ok, e = leg(b) end
    if ok or e == "stopped" then return ok, e end
    ok, e = leg(b) -- blocked: try round the other way
    if ok then ok, e = leg(a) end
    return ok, e
  end

  local ok, e = vertical(ty)
  if not ok then return false, e end
  ok, e = flat()
  if ok or e == "stopped" then return ok, e end
  if vertical(ty + 1) then -- still blocked: go over the top, then back down
    local ok2 = flat()
    if ok2 then return vertical(ty) end
  end
  return false, e
end

-- Path planning --------------------------------------------------------------
-- Cost is time, in turtle actions: a step = 1, digging the cell first = +1, a
-- quarter turn = 1. So walking round through air beats digging only when it is
-- really quicker, and the trip home runs back through our own tunnels.
local function extra(x, y, z)
  local b = world[wkey(x, y, z)]
  if b == false then return 0 end
  if b == nil then return 1 end -- never seen: plan as stone
  if b == "!" or isProtected(b) then return nil end -- impassable
  if b:find("water") or b:find("lava") then return 0 end -- a turtle swims
  return 1
end

-- Binary min-heap keyed on f.
local function push(heap, node)
  heap[#heap + 1] = node
  local i = #heap
  while i > 1 do
    local p = math.floor(i / 2)
    if heap[p].f <= heap[i].f then break end
    heap[p], heap[i] = heap[i], heap[p]; i = p
  end
end
local function pop(heap)
  local top, last = heap[1], heap[#heap]
  heap[#heap] = nil
  if #heap > 0 then
    heap[1] = last
    local i = 1
    while true do
      local l, r, m = 2 * i, 2 * i + 1, i
      if heap[l] and heap[l].f < heap[m].f then m = l end
      if heap[r] and heap[r].f < heap[m].f then m = r end
      if m == i then break end
      heap[m], heap[i] = heap[i], heap[m]; i = m
    end
  end
  return top
end

-- A* from where we are to (tx,ty,tz), inside the box around both ends plus a
-- margin. Returns a list of moves ("u", "d" or a heading 0-3), or nil if no
-- path within maxNodes (then the caller digs straight, as before).
-- ponytail: weighted heuristic (x1.5) trades a few % of optimality for speed;
-- past maxNodes (long trips through solid rock) it digs straight instead.
function M.plan(tx, ty, tz, maxNodes)
  maxNodes = maxNodes or 6000
  local PAD = 4
  local lox, hix = math.min(state.x, tx) - PAD, math.max(state.x, tx) + PAD
  local loy, hiy = math.min(state.y, ty) - PAD, math.max(state.y, ty) + PAD
  local loz, hiz = math.min(state.z, tz) - PAD, math.max(state.z, tz) + PAD
  local function h(x, y, z) return 1.5 * (math.abs(tx - x) + math.abs(ty - y) + math.abs(tz - z)) end

  local heap, best, came = {}, {}, {}
  local startKey = wkey(state.x, state.y, state.z) .. "," .. state.h
  best[startKey] = 0
  push(heap, { f = h(state.x, state.y, state.z), g = 0, x = state.x, y = state.y, z = state.z, h = state.h, k = startKey })
  local n = 0
  while #heap > 0 do
    local cur = pop(heap)
    if cur.x == tx and cur.y == ty and cur.z == tz then
      local moves, k = {}, cur.k
      while came[k] do table.insert(moves, 1, came[k].move); k = came[k].from end
      return moves
    end
    if cur.g <= best[cur.k] then
      n = n + 1
      if n > maxNodes then return nil end
      if n % 2000 == 0 and os.queueEvent then -- CC kills code that never yields
        os.queueEvent("nav_yield"); os.pullEvent("nav_yield")
      end
      local function try(nx, ny, nz, nh, move, turns)
        if nx < lox or nx > hix or ny < loy or ny > hiy or nz < loz or nz > hiz then return end
        local e = extra(nx, ny, nz)
        if not e then return end
        local g = cur.g + turns + 1 + e
        local k = wkey(nx, ny, nz) .. "," .. nh
        if best[k] == nil or g < best[k] then
          best[k] = g
          came[k] = { from = cur.k, move = move }
          push(heap, { f = g + h(nx, ny, nz), g = g, x = nx, y = ny, z = nz, h = nh, k = k })
        end
      end
      try(cur.x, cur.y + 1, cur.z, cur.h, "u", 0)
      try(cur.x, cur.y - 1, cur.z, cur.h, "d", 0)
      for d = 0, 3 do
        local t = (d - cur.h) % 4
        try(cur.x + DX[d], cur.y, cur.z + DZ[d], d, d, t == 3 and 1 or t)
      end
    end
  end
  return nil
end

-- Move to (tx,ty,tz) the quickest way the map knows: through air, our own
-- tunnels and caves when that beats digging, digging when it does not. If
-- something the map did not know blocks a step, mark it and plan again; with
-- no map or no plan, dig straight along the axes. stopWhen() is checked before
-- every step: return true to end early (e.g. the target was dug from next door).
function M.travel(tx, ty, tz, stopWhen)
  if next(world) ~= nil then
    for _ = 1, 3 do
      local moves = M.plan(tx, ty, tz)
      if not moves then break end
      local ok, e, bx, by, bz = true, nil, nil, nil, nil
      for _, m in ipairs(moves) do
        if stopWhen and stopWhen() then return true end
        if m == "u" then
          bx, by, bz = state.x, state.y + 1, state.z; ok, e = stepUp()
        elseif m == "d" then
          bx, by, bz = state.x, state.y - 1, state.z; ok, e = stepDown()
        else
          turnTo(m)
          bx, by, bz = state.x + DX[m], state.y, state.z + DZ[m]; ok, e = stepForward()
        end
        if not ok then break end
      end
      if ok then return true end
      if e == "stopped" then return false, e end
      world[wkey(bx, by, bz)] = "!" -- the map was wrong here; route round it
    end
  end
  return axisTravel(tx, ty, tz, stopWhen)
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

local AREA_SCAN_R = 8 -- the Geo Scanner's free radius; bigger costs fuel/is capped

local function oreData(o, only)
  if type(o) ~= "table" or not o.name then return false end
  if only and not o.name:find(only, 1, true) then return false end
  if o.tags and o.tags["c:ores"] then return true end
  return o.name:find("_ore") ~= nil
end

-- Junk the turtle throws away on the go (same list as mine.lua), so it only
-- drives home with real loot.
local JUNK = {
  ["minecraft:cobblestone"] = true, ["minecraft:cobbled_deepslate"] = true,
  ["minecraft:stone"] = true, ["minecraft:deepslate"] = true,
  ["minecraft:dirt"] = true, ["minecraft:gravel"] = true,
  ["minecraft:sand"] = true, ["minecraft:netherrack"] = true,
  ["minecraft:andesite"] = true, ["minecraft:diorite"] = true,
  ["minecraft:granite"] = true, ["minecraft:tuff"] = true,
  ["minecraft:calcite"] = true, ["minecraft:flint"] = true,
}

local function freeSlots()
  local n = 0
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
  return n
end

-- Drop junk into the hole below (or wherever it falls). Facing is unchanged.
function M.dropJunk()
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and JUNK[d.name] then turtle.select(s); turtle.dropDown() end
  end
  turtle.select(1)
end

-- Harvest every ore within areaRadius of the start (or of opts.center):
--   * go straight to the NEAREST known ore, one block at a time, so a vein is
--     eaten cell by cell with no spinning to look around;
--   * scan on the go every few steps (no waiting on the scanner's cooldown), so
--     new ore shows up while it walks;
--   * when no known ore is left: stop and go home, unless opts.explore is set;
--     then walk to the nearest part of the area no scan has covered yet and
--     scan there (that walk can go deep and far, so only on request);
--   * throw junk away on the go, drive home only to unload real loot.
-- Needs the heading already calibrated. scanFn(r, quick) returns the raw scan
-- (quick = one try, no cooldown wait). Ends back at the start.
-- Returns (ores mined, reason string).
function M.mineArea(scanFn, areaRadius, opts)
  opts = opts or {}
  local step = opts.step or 14         -- spacing of exploration points (<= 2 * scan radius)
  local scanEvery = opts.scanEvery or 6 -- steps between scans on the go
  local cover = opts.cover or 4        -- a point counts as explored if scanned within this
  local fuelBuffer = opts.fuelBuffer or 40
  local only = opts.only               -- e.g. "diamond": mine only ore with this in its name
  local onProgress = opts.onProgress   -- function(remainingOres, {x,y,z}) for the live map
  local cx0, cy0, cz0 = 0, 0, 0
  if opts.center then cx0, cy0, cz0 = opts.center.x or 0, opts.center.y or 0, opts.center.z or 0 end

  stopFn = opts.shouldStop -- let movement abort the moment a stop lands
  stepReport = opts.onMove and function() opts.onMove({ x = state.x, y = state.y, z = state.z }) end or nil
  local mined, reason = 0, "area clear"
  local done, found = {}, {} -- tried keys; every ore seen (home frame)
  local scans = {}           -- where we have scanned

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
  local points = {}
  for _, yy in ipairs(ys) do
    for _, zz in ipairs(zs) do
      for _, xx in ipairs(xs) do points[#points + 1] = { x = xx, y = yy, z = zz } end
    end
  end

  local function dist(o) return math.abs(o.x - state.x) + math.abs(o.y - state.y) + math.abs(o.z - state.z) end
  local function homeDist(o) return math.abs(o.x) + math.abs(o.y) + math.abs(o.z) end
  local function inArea(ox, oy, oz)
    return math.max(math.abs(ox - cx0), math.abs(oy - cy0), math.abs(oz - cz0)) <= areaRadius
  end
  local function afford(d)
    M.ensureFuel(d)
    local fl = turtle.getFuelLevel()
    return type(fl) ~= "number" or fl >= d
  end
  local function report()
    if not onProgress then return end
    local rem = {}
    for k, o in pairs(found) do if not done[k] then rem[#rem + 1] = o end end
    onProgress(rem, { x = state.x, y = state.y, z = state.z })
  end

  -- Dig known ore straight above, below or in front without moving or turning:
  -- a vein gets eaten from the inside, and ore passed on the way is taken too.
  local function grab()
    if freeSlots() < 2 then M.dropJunk() end
    if freeSlots() == 0 then return end -- a full inventory would lose the ore
    local function try(dx, dy, dz, dig)
      local k = (state.x + dx) .. "," .. (state.y + dy) .. "," .. (state.z + dz)
      if found[k] and not done[k] then
        done[k], found[k] = true, nil
        if dig() then mined = mined + 1; world[k] = false end
      end
    end
    try(0, 1, 0, turtle.digUp)
    try(0, -1, 0, turtle.digDown)
    try(DX[state.h], 0, DZ[state.h], turtle.dig)
  end

  -- Self-check by the scan: ore we already know should show up exactly where
  -- we expect it. If most of it shows up shifted by the same small amount, our
  -- position is off by that much (pushed by a piston, a lost step...): fix it.
  local function correct(blocks)
    local votes, zero, best, bestN = {}, 0, nil, 0
    for _, o in ipairs(blocks) do
      if oreData(o, only) then
        local gx, gy, gz = state.x + o.x, state.y + o.y, state.z + o.z
        for dx = -2, 2 do for dy = -2, 2 do for dz = -2, 2 do
          local kn = found[(gx + dx) .. "," .. (gy + dy) .. "," .. (gz + dz)]
          if kn and kn.name == o.name then
            if dx == 0 and dy == 0 and dz == 0 then
              zero = zero + 1
            else
              local k = dx .. "," .. dy .. "," .. dz
              votes[k] = (votes[k] or 0) + 1
              if votes[k] > bestN then best, bestN = { dx, dy, dz }, votes[k] end
            end
          end
        end end end
      end
    end
    -- the true shift explains every known ore in range; demand a clear win
    if best and bestN >= 3 and bestN >= zero + 2 then
      state.x, state.y, state.z = state.x + best[1], state.y + best[2], state.z + best[3]
      if opts.onFix then opts.onFix(best[1], best[2], best[3]) end
    end
  end

  local sinceScan = 0
  local function scanHere(quick)
    local blocks = scanFn(AREA_SCAN_R, quick)
    if type(blocks) ~= "table" then return false end
    correct(blocks)
    M.remember(blocks, state.x, state.y, state.z, AREA_SCAN_R)
    sinceScan = 0
    scans[#scans + 1] = { x = state.x, y = state.y, z = state.z }
    local seen = {}
    for _, o in ipairs(blocks) do
      if oreData(o, only) then
        local ox, oy, oz = state.x + o.x, state.y + o.y, state.z + o.z
        local k = ox .. "," .. oy .. "," .. oz
        seen[k] = true
        if inArea(ox, oy, oz) and not done[k] then found[k] = { x = ox, y = oy, z = oz, name = o.name } end
      end
    end
    -- Ghosts: ore in this scan's range that it no longer returns was dug out.
    for k, o in pairs(found) do
      if not seen[k] and math.abs(o.x - state.x) <= AREA_SCAN_R
        and math.abs(o.y - state.y) <= AREA_SCAN_R and math.abs(o.z - state.z) <= AREA_SCAN_R then
        found[k] = nil
      end
    end
    report()
    return true
  end

  stepHook = function()
    if freeSlots() < 3 then M.dropJunk() end
    grab()
    sinceScan = sinceScan + 1
    if sinceScan >= scanEvery then
      if not scanHere(true) then sinceScan = scanEvery - 2 end -- on cooldown: retry soon
    end
  end

  local function explored(p)
    for _, sc in ipairs(scans) do
      if math.max(math.abs(sc.x - p.x), math.abs(sc.y - p.y), math.abs(sc.z - p.z)) <= cover then return true end
    end
    return false
  end

  scanHere(false)
  if opts.center then -- a tapped cluster may be out of sight from home: go and look
    M.travel(cx0, cy0, cz0)
    scanHere(false)
  end
  while true do
    if opts.shouldStop and opts.shouldStop() then reason = "stopped"; break end

    -- Nearest ore first; on a tie, the one we can reach without turning.
    local best, bestD, bestKey
    for k, o in pairs(found) do
      if not done[k] then
        local dx, dz = o.x - state.x, o.z - state.z
        local straight = (dx == 0 and dz == 0)
          or (dz == 0 and dx * DX[state.h] > 0) or (dx == 0 and dz * DZ[state.h] > 0)
        local d = dist(o) + (straight and 0 or 0.5)
        if not bestD or d < bestD then best, bestD, bestKey = o, d, k end
      end
    end

    if best then
      if freeSlots() < 2 then M.dropJunk() end
      if freeSlots() == 0 then -- real loot only now: unload, then carry on from here
        local rx, ry, rz = state.x, state.y, state.z
        homing = true; M.travel(0, 0, 0); homing = false
        local ok, why = M.deposit()
        if not ok then reason = why or "inventory full, no chest"; break end
        M.travel(rx, ry, rz)
      end
      if not afford(math.ceil(bestD) + homeDist(best) + fuelBuffer) then reason = "low fuel"; break end
      local reached = M.travel(best.x, best.y, best.z, function() return done[bestKey] end)
      if not done[bestKey] then -- not grabbed from next door on the way
        done[bestKey] = true
        if reached and state.x == best.x and state.y == best.y and state.z == best.z then mined = mined + 1 end
      end
      found[bestKey] = nil
      grab()
      report()
    else
      local next, nd
      for _, p in ipairs(points) do
        if not p.done and not explored(p) then
          local d = dist(p)
          if not nd or d < nd then next, nd = p, d end
        end
      end
      if not next or not opts.explore then break end -- done: all known ore mined
      if not afford(nd + homeDist(next) + fuelBuffer) then reason = "low fuel"; break end
      next.done = true -- even if the way is blocked, don't try forever
      M.travel(next.x, next.y, next.z)
      scanHere(false)
    end
  end

  stepHook = nil
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

local function unload()
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and not keepItem(d.name) then turtle.select(s); turtle.drop() end
  end
  turtle.select(1)
end

-- Face the chest at home and drop the loot into it. If calibration saw where
-- the chest is, turn straight to it; finding no chest there means our position
-- is off, so report "lost" instead of driving on with a wrong map. Every turn
-- is tracked, so the heading stays right after unloading.
function M.deposit()
  if M.chestH then
    turnTo(M.chestH)
    local ok, data = turtle.inspect()
    if ok and isContainer(data.name) then unload(); return true end
    return false, "lost: no chest where home should be"
  end
  for _ = 1, 4 do
    local ok, data = turtle.inspect()
    if ok and isContainer(data.name) then unload(); return true end
    turnTo((state.h + 1) % 4)
  end
  return false, "no chest next to me"
end

-- Heading without moving: the scan shows on which world side the chest is,
-- turning until the chest is in front tells which way we face. Needs exactly
-- one chest/barrel beside the turtle, level with it. Sets home = here.
function M.calibrateByChest(blocks)
  if type(blocks) ~= "table" then return false, "scan failed" end
  local side
  for _, b in ipairs(blocks) do
    if b.y == 0 and isContainer(b.name) then
      local h = unit(b.x, b.z)
      if h then
        if side then return false, "more than one chest beside me" end
        side = h
      end
    end
  end
  if not side then return false, "no chest beside me" end
  for _ = 1, 4 do
    local ok, data = turtle.inspect()
    if ok and isContainer(data.name) then
      state = { x = 0, y = 0, z = 0, h = side }
      M.chestH = side
      return true, side
    end
    turtle.turnRight()
  end
  return false, "chest not found by turning"
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
