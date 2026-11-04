-- CHRONARCH :: pilot  (computer on any Create Aeronautics craft)
--   pilot calibrate        on its legs: fires each thruster, learns what it does
--   pilot                  take off to +4 blocks; the first flight scans the
--                          craft in the air (~25 s of small pushes) and saves it
--   pilot 8                hover at +8
--   pilot forward north    which way W flies (calibrate finds it by itself:
--                          from the screen side; this overrides it)
--   pilot forward auto     back to finding it by itself
--   pilot relearn          scan the craft again on the next flight
-- In flight:  W/S forward/back, A/D left/right, Space/Shift up/down,
--             Up/Down arrows 1 block, L land,
--             ANY OTHER KEY = all thrusters off at once.
-- Needs: Gimbal Sensor + Altitude Sensor touching the computer, thrusters on a
-- wired network; Velocity Sensors (2, on different sides) to stop and hold
-- still. Writes the flight to /pilot.log.

if package then package.path = "/lib/?.lua;" .. package.path end
local P = require("pilot")

local CAL_FILE, LOG_FILE = "/.pilot", "/pilot.log"

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
if not gimbal then print("No gimbal_sensor next to the computer."); return end
if not alt then print("No altitude_sensor next to the computer."); return end
if #names < 3 then print(("Need thrusters on the network, see %d."):format(#names)); return end

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
    term.write("learned - WASD Space/Shift to fly")
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

term.clear()
term.setCursorPos(1, 1)
local arg, arg2 = ...
local cal = loadCal()

if arg == "forward" then
  cal = cal or {}
  if arg2 == "auto" then
    cal.forwardManual = nil
    cal.forward = cal.forwardAuto
    saveCal(cal)
    print("W flies away from the screen: " .. tostring(cal.forward) .. ".")
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
elseif arg == "calibrate" then
  print("CALIBRATE: craft on its legs. Any key = stop.")
  local new, why = guarded(function() return P.calibrate(hw) end)
  if not new then print("Failed: " .. tostring(why)); return end
  new.names = names
  -- which way the screen looks, from where the Altitude Sensor sits
  new.forwardAuto = P.forwardFrom(new.alt, peripheral.getName(alt))
  if cal and cal.forwardManual then
    new.forward, new.forwardManual = cal.forward, true
  else
    new.forward = new.forwardAuto or (cal and cal.forward) or "north"
  end
  saveCal(new)
  local what = { side = "pushes sideways", none = "does nothing (down?)" }
  for i, t in ipairs(new.t) do
    local d = what[t.kind]
    if not d then
      d = ""
      if t.c1 > 0.4 then d = d .. "N" elseif t.c1 < -0.4 then d = d .. "S" end
      if t.c2 > 0.4 then d = d .. "W" elseif t.c2 < -0.4 then d = d .. "E" end
      d = d == "" and "lifts the middle" or ("lifts " .. d .. " side")
    end
    print(("%-22s %s"):format(names[i], d))
  end
  print(("Hover guess: %.1f%% each."):format(new.hover * 100))
  if new.forwardAuto then
    print(("Screen side found: W flies %s (away from the screen)."):format(new.forwardAuto))
  else
    print("Could not find the screen side (Altitude Sensor")
    print("too close to the middle): pilot forward <dir>")
  end
  if new.forwardManual then print("Your pilot forward " .. new.forward .. " is kept.") end
  print("Now: pilot")
  return
end

if not cal or not cal.t then print("First: pilot calibrate"); return end
local same = cal.names and #cal.names == #names
for i = 1, #names do same = same and cal.names[i] == names[i] end
if not same then
  print("Thrusters changed (new names after")
  print("re-assembly). Run: pilot calibrate")
  return
end
local height = math.max(1, math.min(30, tonumber(arg) or 4))
logf = fs.open(LOG_FILE, "w")
logUntil = os.clock() + 300 -- at most 5 minutes of log
logf.writeLine("# t y gimbalX gimbalZ thrust... | speeds | thrusters: " .. table.concat(names, " ")
  .. " | speed sensors: " .. table.concat(speeds, " "))
print(("PILOT +%d  W/S A/D move, Space/Shift up/down"):format(height))
print("arrows +-1 block, L land, other key = ALL OFF")
if #speeds < 2 then print("(no 2 speed sensors: cannot stop by itself)") end
local result, learn = guarded(function() return P.fly(hw, cal, { height = height, forward = cal.forward }) end)
term.setCursorPos(1, 8)
print("Result: " .. tostring(result) .. ". Thrusters off.")
if learn and learn.done and not (cal.learn and cal.learn.done) then
  cal.learn = learn
  saveCal(cal)
  print(("Learned: turn %d, g %.1f, hover %.2f%%"):format(math.floor(learn.kref or 0), learn.G or 0,
    (learn.hover or 0) * 100))
end
if learn and learn.sameAxis then
  print("Speed sensors measure the same direction:")
  print("re-place one (on the deck: no Shift = across")
  print("your view, Shift = along it), then calibrate.")
end
