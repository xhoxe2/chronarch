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
local abort = false -- set by a "stop" order; the harvest checks it and comes home

local function statusBody()
  return { type = "status", name = name, fuel = turtle.getFuelLevel(), state = state }
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

local CAL_RADIUS = 8

-- Equip the scanner, scan (retrying through its cooldown), put the pickaxe back.
-- quick = one try only (scans on the go must not stall the walk).
local function scanOnce(r, quick)
  local sc = equipScanner()
  if not sc then return nil end
  local blocks
  for _ = 1, quick and 1 or 6 do
    blocks = sc.scanBlocks(r or CAL_RADIUS)
    if type(blocks) == "table" then break end
    sleep(1.5) -- Geo Scanner cooldown
  end
  unequipScanner()
  return blocks
end

-- Work out the heading. Best: by the chest beside home (no step, no ores
-- needed). Fallback: scan, step some clear way, scan again, deduce.
local function calibrateHeading()
  nav.reset()
  local a = scanOnce()
  local okc, h = nav.calibrateByChest(a)
  if okc then return true, h end
  if type(a) ~= "table" or #a == 0 then return false, "no ores to calibrate heading" end
  local moved, me = nav.probeAnyDir()
  if not moved then return false, "cannot move to calibrate: " .. tostring(me) end
  local b = scanOnce()
  return nav.deduceHeading(a, b)
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
  local okc, h = calibrateHeading()
  if not okc then
    proto.send(secret, j.from, { type = "dig", name = name, ok = false, text = tostring(h) })
    return
  end
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
  local okc, h = calibrateHeading()
  if not okc then
    proto.send(secret, j.from, { type = "dig", name = name, ok = false, text = tostring(h) })
    return
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
  opts.explore = j.explore
  opts.onFix = function(dx, dy, dz) -- the scan showed we were off; tell the base
    proto.send(secret, j.from, { type = "log", name = name,
      text = ("position corrected by scan: %d,%d,%d"):format(dx, dy, dz) })
  end
  local mined, reason = nav.mineArea(scanOnce, radius, opts)
  local dropped = nav.deposit()
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

local function listener()
  while true do
    local from, msg = proto.receive(secret) -- only correctly signed messages return
    if msg.cmd == "ping" then
      proto.send(secret, from, statusBody())
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
    if j.scan then doScan(j) elseif j.dig then doDig(j) elseif j.area then doMineArea(j) else doMine(j) end
    state, job = "idle", nil
  end
end

print(("CHRONARCH agent '%s' (#%d) online"):format(name, os.getComputerID()))
proto.broadcast(secret, statusBody())
parallel.waitForAny(listener, worker)
