-- CHRONARCH :: pilot  (computer on a Create Aeronautics platform)
--   pilot calibrate   once, platform standing on its legs: learns the thrusters
--   pilot             take off to 4 blocks above the start and hover
--   pilot 8           hover at 8 blocks
-- In flight:  Up/Down = 1 block higher/lower,  L = land,
--             ANY OTHER KEY = all thrusters off at once.
-- Needs: Gimbal Sensor + Altitude Sensor touching the computer, 4 thrusters
-- pointing up on a wired network. Writes the flight to /pilot.log.

if package then package.path = "/lib/?.lua;" .. package.path end
local P = require("pilot")

local CAL_FILE, LOG_FILE = "/.pilot", "/pilot.log"

local gimbal = peripheral.find("gimbal_sensor")
local alt = peripheral.find("altitude_sensor")
local names = {}
for _, n in ipairs(peripheral.getNames()) do
  local t = peripheral.getType(n)
  if t and t:find("thruster") then names[#names + 1] = n end
end
table.sort(names)
if not gimbal then print("No gimbal_sensor next to the computer."); return end
if not alt then print("No altitude_sensor next to the computer."); return end
if #names < 4 then print(("Need 4 thrusters on the network, see %d."):format(#names)); return end

local queue, last, logf, logUntil = {}, {}, nil, 0
local seen = { 0, 0, 0 }
local hw = { n = #names }

function hw.read()
  local a, y
  parallel.waitForAll(function() a = gimbal.getAngles() end, function() y = alt.getHeight() end)
  seen = { a[1] or a.x or a.X or 0, a[2] or a.z or a.Z or 0, y }
  return seen[1], seen[2], seen[3]
end

function hw.write(fs)
  local jobs = {}
  for i, n in ipairs(names) do
    local p, c = P.knobs(fs[i] or 0)
    if last[i] ~= p * 100 + c then
      last[i] = p * 100 + c
      jobs[#jobs + 1] = function()
        if p > 0 then peripheral.call(n, "setThrustConfig", c) end
        peripheral.call(n, "setPower", p)
      end
    end
  end
  if #jobs > 0 then parallel.waitForAll(table.unpack(jobs)) end
  if logf and os.clock() < logUntil then
    local f = {}
    for i = 1, #names do f[i] = ("%.5f"):format(fs[i] or 0) end
    logf.writeLine(("%.2f %.3f %.3f %.3f %s"):format(os.clock(), seen[3], seen[1], seen[2], table.concat(f, " ")))
  end
end

function hw.wait(s) sleep(s) end
hw.clock = os.clock
function hw.poll() return table.remove(queue, 1) end

function hw.show(s)
  term.setCursorPos(1, 3)
  term.clearLine()
  term.write(("height %5.1f  goal %d%s"):format(s.y, s.goal, s.landing and "  LANDING" or ""))
  term.setCursorPos(1, 4)
  term.clearLine()
  local tilt = math.max(math.abs(s.a), math.abs(s.b))
  term.setTextColor(tilt > 15 and colors.red or colors.white)
  term.write(("tilt %4.1f  thrust x%.2f"):format(tilt, s.base))
  term.setTextColor(colors.white)
  if logf then logf.flush() end
end

local function keysToOrders()
  while true do
    local _, k, held = os.pullEvent("key")
    if held then -- a key kept down repeats: count it once
    elseif k == keys.up then queue[#queue + 1] = "up"
    elseif k == keys.down then queue[#queue + 1] = "down"
    elseif k == keys.l then queue[#queue + 1] = "land"
    else table.insert(queue, 1, "kill") end
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

term.clear()
term.setCursorPos(1, 1)
local arg = ...
if arg == "calibrate" then
  print("CALIBRATE: platform on its legs. Any key = stop.")
  local cal, why = guarded(function() return P.calibrate(hw) end)
  if not cal then print("Failed: " .. tostring(why)); return end
  local f = fs.open(CAL_FILE, "w")
  f.write(textutils.serialize(cal))
  f.close()
  local side = { [1] = { "S lower", "N lower" }, [2] = { "E lower", "W lower" } }
  for i, t in ipairs(cal.t) do
    print(("%-22s fire -> %s"):format(names[i], side[t.axis][t.sign > 0 and 1 or 2]))
  end
  print(("Hover guess: %.1f%% each. Now: pilot"):format(cal.hover * 100))
  return
end

local cal = loadCal()
if not cal then print("First: pilot calibrate"); return end
local height = math.max(1, math.min(30, tonumber(arg) or 4))
logf = fs.open(LOG_FILE, "w")
logUntil = os.clock() + 300 -- at most 5 minutes of log
logf.writeLine("# t y gimbalX gimbalZ thrust... | thrusters: " .. table.concat(names, " "))
print(("PILOT: up to +%d. Up/Down height, L land,"):format(height))
print("any other key = ALL OFF")
local result = guarded(function() return P.fly(hw, cal, { height = height }) end)
term.setCursorPos(1, 6)
print("Result: " .. tostring(result) .. ". Thrusters off.")
