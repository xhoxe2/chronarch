-- CHRONARCH :: pilot  (computer on any Create Aeronautics craft)
--   pilot calibrate        analyse the craft (on its legs): finds every device,
--                          fires each thruster alone, then a learning hop to
--                          +4 (hands off ~40 s, it lands by itself) and a
--                          report: what is on board, what you can steer, why not
--   pilot                  fly: take off to +4, keys work at once
--   pilot 8                fly to +8
--   pilot info             the report again (also saved to /pilot.txt)
--   pilot forward north    which way W flies (the first flight finds it by
--                          itself: away from the screen; this overrides it)
--   pilot forward auto     back to finding it by itself
--   pilot relearn          scan the craft again on the next flight
-- In flight:  W/S forward/back, A/D left/right, Space/Shift up/down,
--             Up/Down arrows 1 block, L land,
--             ANY OTHER KEY = all thrusters off at once.
-- Needs at least: Gimbal Sensor + Altitude Sensor touching the computer,
-- thrusters on a wired network. Anything else is found and used if it can
-- be; the report says what is missing for what. Flight log: /pilot.log.

if package then package.path = "/lib/?.lua;" .. package.path end
local P = require("pilot")

local CAL_FILE, LOG_FILE, REPORT_FILE = "/.pilot", "/pilot.log", "/pilot.txt"

local gimbal = peripheral.find("gimbal_sensor")
local alt = peripheral.find("altitude_sensor")
local names, speeds = {}, {}
for _, n in ipairs(peripheral.getNames()) do
  local t = peripheral.getType(n) or ""
  if t:find("thruster") then names[#names + 1] = n
  elseif t == "velocity_sensor" then speeds[#speeds + 1] = n end
end
table.sort(names)
table.sort(speeds)
-- every device the computer sees, for the report
local SIDE = { top = true, bottom = true, left = true, right = true, front = true, back = true }
local devices = {}
for _, n in ipairs(peripheral.getNames()) do
  devices[#devices + 1] = { name = n, type = peripheral.getType(n), side = SIDE[n] and n or nil }
end
local canFly = gimbal ~= nil and alt ~= nil and #names > 0

-- How each thruster takes a thrust fraction: creative ones have fine steps.
local fine = {}
for i, n in ipairs(names) do
  for _, m in ipairs(peripheral.getMethods(n) or {}) do
    if m == "setThrustConfig" then fine[i] = true end
  end
end

local queue, last, logf, logUntil = {}, {}, nil, 0
local seen = { a = 0, b = 0, y = 0, v = {} }
local hw = { n = #names }

function hw.read()
  local a, y, v = nil, nil, {}
  local jobs = { function() a = gimbal.getAngles() end, function() y = alt.getHeight() end }
  for k, n in ipairs(speeds) do jobs[#jobs + 1] = function() v[k] = peripheral.call(n, "getVelocity") or 0 end end
  parallel.waitForAll(table.unpack(jobs))
  seen = { a = a[1] or a.x or a.X or 0, b = a[2] or a.z or a.Z or 0, y = y, v = v }
  return seen
end

function hw.write(fs)
  local jobs = {}
  for i, n in ipairs(names) do
    local f = fs[i] or 0
    local p, c
    if fine[i] then p, c = P.knobs(f)
    else p, c = (f > 0 and math.max(1, math.floor(f * 15 + 0.5)) or 0), 0 end
    if last[i] ~= p * 100 + c then
      last[i] = p * 100 + c
      jobs[#jobs + 1] = function()
        if p > 0 and fine[i] then peripheral.call(n, "setThrustConfig", c) end
        peripheral.call(n, "setPower", p)
      end
    end
  end
  if #jobs > 0 then parallel.waitForAll(table.unpack(jobs)) end
  if logf and os.clock() < logUntil then
    local f = {}
    for i = 1, #names do f[i] = ("%.5f"):format(fs[i] or 0) end
    local v = {}
    for k = 1, #speeds do v[k] = ("%.3f"):format(seen.v[k] or 0) end
    logf.writeLine(("%.2f %.3f %.3f %.3f %s | %s"):format(os.clock(), seen.y, seen.a, seen.b,
      table.concat(f, " "), table.concat(v, " ")))
  end
end

function hw.wait(s) sleep(s) end
hw.clock = os.clock
function hw.poll() return table.remove(queue, 1) end

-- Keys held down. A key counts as let go when its key_up comes, or when it
-- stops repeating (the screen was closed with the key still down).
local down = {}
local MOVE = { [keys.w] = { "f", 1 }, [keys.s] = { "f", -1 }, [keys.d] = { "r", 1 }, [keys.a] = { "r", -1 },
  [keys.space] = { "u", 1 }, [keys.leftShift] = { "u", -1 } }
function hw.held()
  local out, now = { f = 0, r = 0, u = 0 }, os.clock()
  for k, t in pairs(down) do
    if now - t > 1.0 then down[k] = nil
    else out[MOVE[k][1]] = out[MOVE[k][1]] + MOVE[k][2] end
  end
  return out
end

function hw.show(s)
  term.setCursorPos(1, 4)
  term.clearLine()
  term.write(("height %5.1f  goal %d%s"):format(s.y, s.goal, s.landing and "  LANDING" or ""))
  term.setCursorPos(1, 5)
  term.clearLine()
  local tilt = math.max(math.abs(s.a), math.abs(s.b))
  term.setTextColor(tilt > 15 and colors.red or colors.white)
  term.write(("tilt %4.1f  thrust x%.2f"):format(tilt, s.base))
  term.setTextColor(colors.white)
  term.setCursorPos(1, 6)
  term.clearLine()
  if s.warn then
    term.setTextColor(colors.red)
    term.write(s.warn)
    term.setTextColor(colors.white)
  elseif s.scan then
    term.setTextColor(colors.yellow)
    term.write("LEARNING THE CRAFT: " .. s.scan .. " (hands off)")
    term.setTextColor(colors.white)
  elseif s.learned then
    local seen = ({ [0] = "speed by physics only", [1] = "speed: 1 way sensed + physics",
      [2] = "speed: sensed both ways" })[s.seen or 0]
    term.write("WASD Space/Shift to fly | " .. seen)
  end
  if logf then logf.flush() end
end

local function keysToOrders()
  while true do
    local ev, k, held = os.pullEvent()
    if ev == "key" and MOVE[k] then
      down[k] = os.clock()
    elseif ev == "key_up" and MOVE[k] then
      down[k] = nil
    elseif ev == "key" and not held then
      if k == keys.up then queue[#queue + 1] = "up"
      elseif k == keys.down then queue[#queue + 1] = "down"
      elseif k == keys.l then queue[#queue + 1] = "land"
      else table.insert(queue, 1, "kill") end
    end
  end
end

-- Run `job` while listening to keys; whatever happens (error, Ctrl+T), the
-- thrusters end up off.
local function guarded(job)
  local result = {}
  local ok, err = pcall(parallel.waitForAny, function() result = table.pack(job()) end, keysToOrders)
  last = {}
  pcall(P.cut, hw)
  if logf then logf.close(); logf = nil end
  if not ok then print("Stopped: " .. tostring(err)) end
  return table.unpack(result, 1, result.n or 0)
end

local function loadCal()
  if not fs.exists(CAL_FILE) then return nil end
  local f = fs.open(CAL_FILE, "r")
  local cal = textutils.unserialize(f.readAll())
  f.close()
  return cal
end
local function saveCal(cal)
  local f = fs.open(CAL_FILE, "w")
  f.write(textutils.serialize(cal))
  f.close()
end

local _, H = term.getSize()
-- show lines a screen at a time; also keep them in /pilot.txt
local function page(lines)
  local f = fs.open(REPORT_FILE, "w")
  for _, l in ipairs(lines) do f.writeLine(l) end
  f.close()
  local y = 0
  for _, l in ipairs(lines) do
    if y >= H - 1 then -- the last row stays for the question
      write("-- more: any key --")
      os.pullEvent("key")
      term.clear()
      term.setCursorPos(1, 1)
      y = 0
    end
    print(l)
    y = y + 1
  end
end
local function sameThrusters(c)
  local same = c and c.t and c.names and #c.names == #names
  for i = 1, #names do same = same and c.names[i] == names[i] end
  return same
end
local function learned(c) return c and c.learn and c.learn.v == P.SCAN_VERSION and c.learn or nil end

-- the ground check: every thruster fires alone; returns the new calibration
local function check(old)
  print("1/2 CHECKING EVERY THRUSTER (on its legs):")
  print("each fires alone for a moment. Any key = stop.")
  local new, why, partial = guarded(function() return P.calibrate(hw) end)
  if not new then
    page((P.report(devices, partial and { t = partial, names = names, why = why } or nil, nil)))
    print("Cannot fly: " .. tostring(why))
    return nil
  end
  new.names = names
  if old and old.forwardManual then new.forward, new.forwardManual = old.forward, true end
  saveCal(new)
  return new
end

-- a flight; returns its result and what it learned (saved here)
local function flight(cal, height, learnOnly)
  logf = fs.open(LOG_FILE, "w")
  logUntil = os.clock() + 300 -- at most 5 minutes of log
  logf.writeLine("# t y gimbalX gimbalZ thrust... | speeds | thrusters: " .. table.concat(names, " ")
    .. " | speed sensors: " .. table.concat(speeds, " "))
  local opts = { height = height, forward = cal.forward, forwardManual = cal.forwardManual,
    altSide = peripheral.getName(alt), learnOnly = learnOnly }
  local result, learn = guarded(function() return P.fly(hw, cal, opts) end)
  if learn and learn.done and not learned(cal) then
    cal.learn = learn
    if learn.forward and not cal.forwardManual then cal.forward = learn.forward end
    saveCal(cal)
  end
  return result, learn
end

term.clear()
term.setCursorPos(1, 1)
local arg, arg2 = ...
local cal = loadCal()

if arg == "forward" then
  cal = cal or {}
  if arg2 == "auto" then
    cal.forwardManual = nil
    cal.forward = cal.learn and cal.learn.forward
    saveCal(cal)
    print(cal.forward and ("W flies away from the screen: " .. cal.forward .. ".")
      or "The next flight finds the screen side.")
    return
  end
  if not P.COMPASS[arg2 or ""] then print("pilot forward north|east|south|west|auto"); return end
  cal.forward, cal.forwardManual = arg2, true
  saveCal(cal)
  print("W now flies " .. arg2 .. ". (pilot forward auto: undo)")
  return
elseif arg == "relearn" then
  if cal then cal.learn = nil; saveCal(cal) end
  print("The next flight scans the craft again.")
  return
elseif arg == "info" then
  local ok = sameThrusters(cal)
  page((P.report(devices, ok and cal or nil, ok and learned(cal) or nil)))
  return
elseif arg == "calibrate" or arg == "check" then
  if not canFly then page((P.report(devices, nil, nil))); print("Cannot fly: see NO above."); return end
  cal = check(cal)
  if not cal then return end
  term.clear()
  term.setCursorPos(1, 1)
  print("2/2 LEARNING HOP: lifts +4, learns the craft")
  print("(~40 s, it rocks a little on purpose), then")
  print("lands by itself. HANDS OFF. Any key = all off.")
  local result = flight(cal, 4, true)
  term.clear()
  term.setCursorPos(1, 1)
  page((P.report(devices, cal, learned(cal))))
  if result == "landed" and learned(cal) then
    print(cal.forward and ("Analysis done. W flies " .. cal.forward .. ". Fly: pilot")
      or "Analysis done; front not found: pilot forward <dir>")
  else
    print("Hop stopped (" .. tostring(result) .. "): the first flight learns the rest.")
  end
  return
end

if not canFly then page((P.report(devices, nil, nil))); print("Cannot fly: see NO above."); return end
if not sameThrusters(cal) then
  print("This craft is not analysed yet (new or rebuilt).")
  print("First: pilot calibrate")
  return
end
local height = math.max(1, math.min(30, tonumber(arg == "go" and arg2 or arg) or 4))
print(("PILOT +%d  W/S A/D move, Space/Shift up/down"):format(height))
print("arrows +-1 block, L land, other key = ALL OFF")
if not learned(cal) then print("(not learned yet: hands off while it learns)") end
local result, learn = flight(cal, height, false)
term.setCursorPos(1, 8)
print("Result: " .. tostring(result) .. ". Thrusters off.")
if learn and learn.forward and not cal.forwardManual and learned(cal) == learn then
  print("Front found: W flies " .. learn.forward .. " (away from the screen).")
end
