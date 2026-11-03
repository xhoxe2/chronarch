-- CHRONARCH :: agent.lua  (on a turtle, save it as startup.lua)
-- Listens for signed orders from the base over an ender/wireless modem, runs
-- them and streams everything the job prints back to the base. Orders that are
-- not signed with the shared secret are dropped silently.
--
-- Orders: mine <length> [depth]   and   scan <radius>  (needs a Geo Scanner in
-- the turtle's inventory; the turtle swaps pickaxe <-> scanner and keeps the
-- modem in place, so radio is never lost).
--
-- Setup: turtle with a pickaxe AND an ender modem, mine.lua + orescan.lua on
-- the turtle, a name: label set Miner1. The same /chronarch.key must be on the
-- base and on every turtle.

if package then package.path = "/lib/?.lua;" .. package.path end -- our libraries live in /lib
local proto = require("chronarch")
local orescan = require("orescan")
local nav = require("navigate")
local PROTOCOL = proto.PROTOCOL
local name = os.getComputerLabel() or ("turtle" .. os.getComputerID())

local secret = proto.loadSecret()
if not secret then
  print("No secret found at " .. proto.SECRET_FILE)
  print("The base and every turtle need the same key. See the setup plan.")
  return
end

local modemSide, err = proto.openModem()
if not modemSide then print(err); return end

local ok, e = pcall(rednet.host, PROTOCOL, name)
if not ok then
  print("Name '" .. name .. "' is taken: " .. tostring(e))
  print("Give me another name:  label set <name>")
  return
end

-- The modem stays on its side forever. The pickaxe and the Geo Scanner share
-- the OTHER side, so swapping a tool can never knock the modem off.
local toolSide = (modemSide == "left") and "right" or "left"
local equipTool = (toolSide == "left") and turtle.equipLeft or turtle.equipRight
local SCANNER_ITEM = "advancedperipherals:geo_scanner"

local state, job = "idle", nil
local sos -- why the turtle needs help ("low fuel", "stuck away from home"...), or nil

-- Where home is in the world (the spot by the chest). With GPS the turtle
-- finds it by itself; without, the player tells it the height once with
-- `sety <name> <y>`. Kept in a file as "x y z" (or just "y").
local HOME_Y_FILE = "/home_y"
local homeX, homeY, homeZ
local function loadHome()
  if not fs.exists(HOME_Y_FILE) then return end
  local f = fs.open(HOME_Y_FILE, "r")
  local n = {}
  for v in f.readAll():gmatch("%-?%d+") do n[#n + 1] = tonumber(v) end
  f.close()
  if #n >= 3 then homeX, homeY, homeZ = n[1], n[2], n[3] elseif n[1] then homeY = n[1] end
end
local function saveHome()
  local f = fs.open(HOME_Y_FILE, "w")
  f.write(homeX and ("%d %d %d"):format(homeX, homeY, homeZ) or tostring(homeY))
  f.close()
end
loadHome()

-- What the turtle learned on earlier jobs (ore seen, tunnels, scanned spots).
local MEMORY_FILE = "/memory.txt"
local function readFile(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = f.readAll()
  f.close()
  return t
end
local abort = false -- set by a "stop" order; the harvest checks it and comes home

local function statusBody()
  local rx, ry, rz = nav.pos()
  local pos = { x = rx, y = ry, z = rz }
  if homeX then pos = { x = homeX + rx, y = homeY + ry, z = homeZ + rz, abs = true } end
  local fuel = turtle.getFuelLevel()
  local why = sos or (fuel == 0 and "no fuel") or nil
  return { type = "status", name = name, fuel = fuel, state = why and ("SOS " .. why) or state,
    homeY = homeY, pos = pos }
end

local function findItem(item)
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name == item then return s end
  end
end

-- Equip the Geo Scanner on the tool side and return it. The old tool ends up in
-- the selected slot; unequipScanner swaps it straight back.
local function equipScanner()
  local slot = findItem(SCANNER_ITEM)
  if not slot then return nil, "no geo_scanner in my inventory" end
  turtle.select(slot)
  equipTool()
  local sc = peripheral.wrap(toolSide)
  if not sc or not sc.scanBlocks then
    equipTool() -- put the tool back
    return nil, "scanner not responding"
  end
  return sc
end

local function unequipScanner()
  equipTool()
end

-- Chunk loading without giving up the radio. Advanced Peripherals' Chunk
-- Controller force-loads the turtle's chunk the moment it is equipped and
-- keeps it loaded ~10 minutes after it is taken off (chunkLoadValidTime);
-- the 8 chunks around a forced one keep ticking too. So the turtle carries
-- the controller in its inventory and:
--   * at home while idle wears it (the base and the GPS tower nearby stay
--     loaded when the player is far away),
--   * on the move swaps it on for a blink every 8 blocks / 4 minutes, so the
--     chunk it is in (or next to) is always loaded.
-- No controller in the inventory: all of this quietly does nothing.
local CONTROLLER_ITEM = "advancedperipherals:chunk_controller"

local function toolIs(ptype) return peripheral.getType(toolSide) == ptype end

local function findPickaxe()
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and d.name:find("pickaxe") then return s end
  end
end

-- Blink the controller on and back off (same slot, like the scanner swap).
local function anchorHere()
  local slot = findItem(CONTROLLER_ITEM)
  if not slot then return end
  turtle.select(slot)
  equipTool()
  for _ = 1, 5 do if toolIs("chunky") then break end; sleep(0.05) end
  equipTool()
  turtle.select(1)
end

local anchorX, anchorZ, anchorAt = 0, 0, -math.huge
local function anchorTick(pos)
  if math.abs(pos.x - anchorX) >= 8 or math.abs(pos.z - anchorZ) >= 8 or os.clock() - anchorAt > 240 then
    anchorHere()
    anchorX, anchorZ, anchorAt = pos.x, pos.z, os.clock()
  end
end

-- Idle at home: wear the controller. Working: wear the pickaxe.
local function wearAnchor()
  local slot = findItem(CONTROLLER_ITEM)
  if slot and not toolIs("chunky") then turtle.select(slot); equipTool(); turtle.select(1) end
end
local function wearPickaxe()
  if not toolIs("chunky") then return end
  local slot = findPickaxe()
  if slot then turtle.select(slot); equipTool(); turtle.select(1) end
end

local CAL_RADIUS = 8

-- Equip the scanner, scan (retrying through its cooldown), put the pickaxe back.
-- quick = one try only (scans on the go must not stall the walk). Returns the
-- blocks and the radius really used: a server that caps the scanner below the
-- asked radius gets the free radius 8 instead.
local function scanOnce(r, quick)
  r = r or CAL_RADIUS
  local sc = equipScanner()
  if not sc then return nil end
  local blocks, err
  for _ = 1, quick and 1 or 6 do
    blocks, err = sc.scanBlocks(r)
    if type(blocks) == "table" then break end
    if r > CAL_RADIUS and tostring(err):lower():find("radius") then
      r = CAL_RADIUS
    else
      sleep(1.5) -- Geo Scanner cooldown
    end
  end
  unequipScanner()
  return blocks, r
end

-- Work out the heading. Best: by the chest beside home (no step, no ores
-- needed). Fallback: scan, step some clear way, scan again, deduce.
-- Where we are by GPS (whole blocks), or nil without a GPS constellation.
local function gpsHere()
  if not (gps and gps.locate) then return nil end
  local x, y, z = gps.locate(1)
  if not x then return nil end
  return { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) }
end

-- Heading by GPS, anywhere (not only by the chest at home): ask, step one
-- block, ask again; the difference is the way we face.
local function gpsCalibrate(here)
  if not (here and homeX) then return false, "no GPS" end
  local moved, me = nav.probeAnyDir()
  if not moved then return false, "cannot move to calibrate: " .. tostring(me) end
  local there = gpsHere()
  if not there then return false, "GPS lost" end
  local dx, dz = there.x - here.x, there.z - here.z
  local h = (dx == 1 and 0) or (dz == 1 and 1) or (dx == -1 and 2) or (dz == -1 and 3)
  if not h then return false, "GPS step unclear" end
  nav.reset(there.x - homeX, there.y - homeY, there.z - homeZ, h)
  return true, h
end

-- Once per boot (navReady stays true after that: every turn and step is
-- tracked, scans correct drift). Away from home: by GPS. At home: by the
-- chest, which also tells home's GPS position. Last resort: ore voting.
local navReady, memoryLoaded = false, false
local function calibrateHeading()
  local here = gpsHere()
  local away = here and homeX and (here.x ~= homeX or here.y ~= homeY or here.z ~= homeZ)
  if away then
    local ok, e = gpsCalibrate(here)
    navReady = ok
    return ok, e
  end
  nav.reset()
  local a = scanOnce()
  local okc, h = nav.calibrateByChest(a)
  if okc then
    if here then
      homeX, homeY, homeZ = here.x, here.y, here.z
      saveHome()
    end
    if not memoryLoaded then nav.importMemory(readFile(MEMORY_FILE)); memoryLoaded = true end
    navReady = true
    return true, h
  end
  if here and homeX then
    local ok, e = gpsCalibrate(here)
    navReady = ok
    return ok, e
  end
  if type(a) ~= "table" or #a == 0 then return false, "no ores to calibrate heading" end
  local moved, me = nav.probeAnyDir()
  if not moved then return false, "cannot move to calibrate: " .. tostring(me) end
  local b = scanOnce()
  local ok, e = nav.deduceHeading(a, b)
  navReady = ok
  return ok, e
end

local function ensureNav(j)
  if navReady then return true end
  local ok, e = calibrateHeading()
  if not ok then proto.send(secret, j.from, { type = "dig", name = name, ok = false, text = tostring(e) }) end
  return ok
end

local function doScan(j)
  local sc, e2 = equipScanner()
  if not sc then
    proto.send(secret, j.from, { type = "scan", name = name, ok = false, text = e2 })
    return
  end
  local blocks = sc.scanBlocks(j.radius)
  unequipScanner()
  if type(blocks) ~= "table" then
    proto.send(secret, j.from, { type = "scan", name = name, ok = false,
      text = "scan on cooldown or out of range" })
    return
  end
  local sum = orescan.summarize(blocks)
  proto.send(secret, j.from, { type = "scan", name = name, ok = true, radius = j.radius,
    total = sum.total, counts = sum.counts, nearest = sum.nearest, ores = sum.ores })
end

-- Dig to an ore at (x,y,z) relative to the turtle's scan spot: calibrate, walk
-- there digging, take the whole connected vein, come back, unload.
local function doDig(j)
  if not ensureNav(j) then return end
  local h = select(4, nav.pos())
  local reached, re = nav.travel(j.x or 0, j.y or 0, j.z or 0)
  local mined = 0
  if reached then mined = nav.mineVein() end
  nav.travel(0, 0, 0)
  local dropped = nav.deposit()
  if reached then
    proto.send(secret, j.from, { type = "dig", name = name, ok = true,
      text = ("mined vein (%d blocks), home, %s (h=%s)"):format(mined + 1, dropped and "unloaded" or "no chest", tostring(h)),
      fuel = turtle.getFuelLevel() })
  else
    proto.send(secret, j.from, { type = "dig", name = name, ok = false,
      text = "path blocked: " .. tostring(re), fuel = turtle.getFuelLevel() })
  end
end

-- Harvest the whole area: calibrate, then scan + mine + re-scan around, clearing
-- every ore within radius, far past a single scan's reach. Comes home, unloads.
local function doMineArea(j)
  abort = false
  if not ensureNav(j) then return end
  -- "dig here" from the pocket computer: the player's world position
  if j.wx then
    if not homeX then
      proto.send(secret, j.from, { type = "dig", name = name, ok = false, text = "no GPS: cannot find you" })
      return
    end
    j.cx, j.cy, j.cz = j.wx - homeX, j.wy - homeY, j.wz - homeZ
  end
  local radius = j.radius or 12
  local last, lastMove = 0, 0
  local opts = {
    shouldStop = function() return abort end,
    onProgress = function(ores, pos) -- fresh ore list after each scan/vein, ~1/sec
      local now = os.clock()
      if now - last < 1 then return end
      last = now
      local list = ores
      if #ores > 120 then -- keep the radio message small: nearest ore only
        table.sort(ores, function(a, b)
          return (math.abs(a.x - pos.x) + math.abs(a.z - pos.z)) < (math.abs(b.x - pos.x) + math.abs(b.z - pos.z))
        end)
        list = {}
        for i = 1, 120 do list[i] = ores[i] end
      end
      proto.send(secret, j.from, { type = "harvest", name = name, pos = pos, ores = list })
    end,
    onMove = function(pos) -- just the '@' marker, every half-second, so the map keeps up
      anchorTick(pos)
      local now = os.clock()
      if now - lastMove < 0.5 then return end
      lastMove = now
      proto.send(secret, j.from, { type = "harvest", name = name, pos = pos })
    end,
    onHoming = function() -- tell the base it is on its way back, not digging
      state = "returning"
      proto.send(secret, j.from, statusBody())
    end,
  }
  if j.cx then opts.center = { x = j.cx, y = j.cy or 0, z = j.cz or 0 } end
  opts.only = j.ore
  -- Ore with a known best depth: go down there to search (home stays by the chest).
  if j.ore and not j.cx then
    local dy, y = orescan.depthFor(j.ore, homeY)
    if dy and dy < 0 then
      opts.center = { x = 0, y = dy, z = 0 }
      proto.send(secret, j.from, { type = "log", name = name,
        text = ("going down %d blocks to y=%d, best height for %s"):format(-dy, y, j.ore) })
    elseif not homeY then
      proto.send(secret, j.from, { type = "log", name = name,
        text = "tip: tell me my height (sety " .. name .. " <y>) and I dig down to the ore's best depth" })
    end
  end
  opts.explore = j.explore
  -- A swarm stripe comes in world coordinates: turn it into ours (needs GPS).
  if j.bounds then
    if not homeX then
      proto.send(secret, j.from, { type = "dig", name = name, ok = false,
        text = "no GPS here: cannot take a swarm stripe" })
      return
    end
    local b = j.bounds
    opts.bounds = { x1 = b.x1 - homeX, x2 = b.x2 - homeX, z1 = b.z1 - homeZ, z2 = b.z2 - homeZ }
  end
  opts.onFix = function(dx, dy, dz) -- the scan showed we were off; tell the base
    proto.send(secret, j.from, { type = "log", name = name,
      text = ("position corrected by scan: %d,%d,%d"):format(dx, dy, dz) })
  end
  opts.values = j.values
  local mined, reason = nav.mineArea(scanOnce, radius, opts)
  local mf = fs.open(MEMORY_FILE, "w")
  mf.write(nav.exportMemory())
  mf.close()
  local dropped = nav.deposit()
  local hx, hy, hz = nav.pos()
  if hx ~= 0 or hy ~= 0 or hz ~= 0 then
    sos = ("stuck at home+%d,%d,%d"):format(hx, hy, hz)
  elseif reason ~= "area clear" and reason ~= "stopped" then
    sos = tostring(reason)
  end
  if sos then proto.send(secret, j.from, statusBody()) end -- SOS goes out at once
  proto.send(secret, j.from, { type = "harvest", name = name, pos = { x = 0, y = 0, z = 0 }, ores = {}, done = true })
  proto.send(secret, j.from, { type = "dig", name = name, ok = reason == "area clear" or reason == "stopped",
    text = ("%s r%d%s: %d ores (%s), %s"):format(j.explore and "explore" or "harvest", radius, j.ore and (" " .. j.ore) or "", mined,
      tostring(reason), dropped and "unloaded" or "no chest"),
    fuel = turtle.getFuelLevel() })
end

local function doMine(j)
  -- Everything the mine program prints also goes to the base.
  local origPrint, origError = _G.print, _G.printError
  local function relay(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    proto.send(secret, j.from, { type = "log", name = name, text = table.concat(parts, " ") })
  end
  _G.print = function(...) relay(...); return origPrint(...) end
  _G.printError = function(...) relay(...); return origError(...) end

  local finished = shell.run("mine", table.unpack(j.args))

  _G.print, _G.printError = origPrint, origError
  proto.send(secret, j.from, { type = "done", name = name, ok = finished, fuel = turtle.getFuelLevel() })
end

-- Buddy (pocket computer) orders --------------------------------------------
local gotoTarget -- the latest "come here" spot (world coords); updated while walking

local function tripHooks()
  nav.setHooks(function() return abort end, function(pos) anchorTick(pos) end)
end

-- Walk to the player. While walking, a newer "come here" (follow mode) just
-- moves the target; a stop order halts the turtle where it is.
local function doGoto(j)
  abort = false
  if not homeX then
    proto.send(secret, j.from, { type = "log", name = name, text = "no GPS: I cannot find you" })
    return
  end
  if not ensureNav(j) then return end
  tripHooks()
  local tries, why = 0, nil
  while true do
    local t = gotoTarget
    local tx, ty, tz = t.x - homeX, t.y - homeY, t.z - homeZ
    local function near()
      local x, y, z = nav.pos()
      return math.abs(x - tx) + math.abs(y - ty) + math.abs(z - tz) <= (t.near or 2)
    end
    if near() then break end
    local x, y, z = nav.pos()
    local need = math.abs(x - tx) + math.abs(y - ty) + math.abs(z - tz) + math.abs(tx) + math.abs(ty) + math.abs(tz) + 40
    nav.ensureFuel(need)
    local fuel = turtle.getFuelLevel()
    if type(fuel) == "number" and fuel < need then sos = "low fuel"; why = "not enough fuel to come and go home"; break end
    nav.travel(tx, ty, tz, function() return near() or gotoTarget ~= t or abort end)
    if abort then why = "stopped"; break end
    if gotoTarget == t and not near() then
      tries = tries + 1
      if tries >= 3 then why = "cannot get to you"; break end
    end
  end
  nav.setHooks(nil, nil)
  proto.send(secret, j.from, { type = "log", name = name, text = why or "here!" })
end

local function doHome(j)
  abort = false
  if not ensureNav(j) then return end
  tripHooks()
  nav.travel(0, 0, 0)
  nav.setHooks(nil, nil)
  local x, y, z = nav.pos()
  local dropped = (x == 0 and y == 0 and z == 0) and nav.deposit()
  proto.send(secret, j.from, { type = "log", name = name,
    text = (x == 0 and y == 0 and z == 0) and ("home" .. (dropped and ", unloaded" or "")) or "could not get home" })
end

local function doStash(j)
  local ok = nav.unloadHere()
  proto.send(secret, j.from, { type = "log", name = name,
    text = ok and "loot is in the ender chest" or "no EnderStorage chest with me (or it is full)" })
end

-- Put a torch down next to us: on the first side with room for it.
local function doLight(j)
  local slot = findItem("minecraft:torch")
  if not slot then
    proto.send(secret, j.from, { type = "log", name = name, text = "give me torches" })
    return
  end
  local placed = false
  for _ = 1, 4 do
    turtle.select(slot)
    if turtle.place() then placed = true; break end
    local _, _, _, h = nav.pos()
    nav.turnTo(h + 1)
  end
  turtle.select(1)
  proto.send(secret, j.from, { type = "log", name = name, text = placed and "torch placed" or "no room for a torch here" })
end

local function listener()
  while true do
    local from, msg = proto.receive(secret) -- only correctly signed messages return
    if msg.cmd == "ping" then
      proto.send(secret, from, statusBody())
    elseif msg.cmd == "sety" and tonumber(msg.y) then
      homeY = math.floor(tonumber(msg.y))
      saveHome()
      proto.send(secret, from, { type = "log", name = name, text = "home height set to y=" .. homeY })
    elseif msg.cmd == "goto" and tonumber(msg.x) and tonumber(msg.y) and tonumber(msg.z) then
      gotoTarget = { x = tonumber(msg.x), y = tonumber(msg.y), z = tonumber(msg.z), near = tonumber(msg.near) or 2 }
      if state == "idle" then
        state = "coming"
        job = { from = from, kind = "goto" }
        os.queueEvent("chronarch_job")
      elseif state ~= "coming" then
        proto.send(secret, from, { type = "log", name = name, text = "Busy, come-here ignored" })
      end -- already coming: the new spot is picked up on the way
    elseif msg.cmd == "home" or msg.cmd == "stash" or msg.cmd == "light" then
      if state ~= "idle" then
        proto.send(secret, from, { type = "log", name = name, text = "Busy, " .. msg.cmd .. " ignored" })
      else
        state = msg.cmd == "home" and "returning" or msg.cmd
        job = { from = from, kind = msg.cmd }
        os.queueEvent("chronarch_job")
      end
    elseif msg.cmd == "forget" then
      if fs.exists(MEMORY_FILE) then fs.delete(MEMORY_FILE) end
      proto.send(secret, from, { type = "log", name = name, text = "memory cleared" })
    elseif msg.cmd == "stop" then
      abort = true -- handled even while busy, so a runaway harvest can be recalled
      proto.send(secret, from, { type = "log", name = name, text = "Stopping, heading home" })
    elseif msg.cmd == "mine" then
      if state ~= "idle" then
        proto.send(secret, from, { type = "log", name = name, text = "Busy, order ignored" })
      else
        state = "busy"
        job = { from = from, args = { tostring(msg.length or 16), tostring(msg.depth or 0) } }
        os.queueEvent("chronarch_job")
      end
    elseif msg.cmd == "scan" then
      if state ~= "idle" then
        proto.send(secret, from, { type = "log", name = name, text = "Busy, scan ignored" })
      else
        state = "scanning"
        job = { from = from, scan = true, radius = tonumber(msg.radius) or 8 }
        os.queueEvent("chronarch_job")
      end
    elseif msg.cmd == "dig" then
      if state ~= "idle" then
        proto.send(secret, from, { type = "log", name = name, text = "Busy, dig ignored" })
      else
        state = "digging"
        job = { from = from, dig = true, x = tonumber(msg.x) or 0, y = tonumber(msg.y) or 0, z = tonumber(msg.z) or 0 }
        os.queueEvent("chronarch_job")
      end
    elseif msg.cmd == "mineArea" then
      if state ~= "idle" then
        proto.send(secret, from, { type = "log", name = name, text = "Busy, harvest ignored" })
      else
        state = "digging"
        job = { from = from, area = true, radius = tonumber(msg.radius) or 12,
          ore = type(msg.ore) == "string" and msg.ore:match("^[%w_]+$") or nil,
          explore = msg.explore == true,
          wx = tonumber(msg.wx), wy = tonumber(msg.wy), wz = tonumber(msg.wz),
          bounds = (type(msg.bounds) == "table" and tonumber(msg.bounds.x1) and tonumber(msg.bounds.x2)
            and tonumber(msg.bounds.z1) and tonumber(msg.bounds.z2))
            and { x1 = tonumber(msg.bounds.x1), x2 = tonumber(msg.bounds.x2),
                  z1 = tonumber(msg.bounds.z1), z2 = tonumber(msg.bounds.z2) } or nil,
          values = (function() -- only "word" = number pairs
            local v = {}
            if type(msg.values) == "table" then
              for k, n in pairs(msg.values) do
                if type(k) == "string" and k:match("^[%w_]+$") and tonumber(n) then v[k] = tonumber(n) end
              end
            end
            return v
          end)(),
          cx = msg.cx and tonumber(msg.cx), cy = msg.cy and tonumber(msg.cy), cz = msg.cz and tonumber(msg.cz) }
        os.queueEvent("chronarch_job")
      end
    end
  end
end

local function worker()
  while true do
    os.pullEvent("chronarch_job")
    local j = job
    sos = nil -- a new order: start clean
    wearPickaxe()
    anchorX, anchorZ, anchorAt = 0, 0, -math.huge
    if j.kind == "goto" then doGoto(j)
    elseif j.kind == "home" then doHome(j)
    elseif j.kind == "stash" then doStash(j)
    elseif j.kind == "light" then doLight(j)
    elseif j.scan then doScan(j) elseif j.dig then doDig(j) elseif j.area then doMineArea(j) else doMine(j) end
    state, job = "idle", nil
    wearAnchor()
  end
end

print(("CHRONARCH agent '%s' (#%d) online"):format(name, os.getComputerID()))
wearAnchor()
do -- where are we? (the map shows world coordinates from the start, like `gps locate`)
  local here = gpsHere()
  if here then
    if not homeX then homeX, homeY, homeZ = here.x, here.y, here.z; saveHome() end
    nav.reset(here.x - homeX, here.y - homeY, here.z - homeZ, 0) -- heading unknown until a job
  end
end
proto.broadcast(secret, statusBody())
parallel.waitForAny(listener, worker)
