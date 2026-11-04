-- CHRONARCH :: lib/pilot.lua  - autopilot that learns the craft it sits on
--
-- Nothing is assumed about the craft. On the ground `calibrate` fires each
-- thruster alone and watches what it does (tips which edge, lifts, pushes
-- sideways). In the air `fly` runs a short scan - small test pushes - and
-- measures how hard each control actually turns, lifts and moves the craft;
-- the gains come from those measurements, so a heavy barge and a light
-- drone both fly. The scan results are returned to be saved and reused.
--
-- Hardware comes in as `hw`, so the same code runs in the game and in the
-- physics model of the tests:
--   hw.n                   number of thrusters
--   hw.read() -> { a, b, y, v = {...} }  Gimbal Sensor X/Z (degrees),
--                          Altitude Sensor y, Velocity Sensor readings
--   hw.write(fs)           thrust per thruster, fraction 0..0.99 of maximum
--   hw.wait(s), hw.clock() sleep / seconds
--   hw.poll() -> nil | "up" | "down" | "land" | "kill"
--   hw.held() -> { f = -1|0|1, r = -1|0|1, u = -1|0|1 }  keys held now:
--                          forward/back, right/left, rise/sink (optional)
--   hw.show(state)         optional: draw the status
--
-- Directions: Gimbal X > 0 = south edge lower, Z > 0 = east edge lower (in
-- the craft's frame as it was assembled). A craft tilted toward a side is
-- pushed to that side, which is how the scan finds what each Velocity
-- Sensor measures.

local P = {}

P.TILT_CUT = 30   -- degrees: past this every thruster goes off
P.SCAN_VERSION = 3 -- saved scans of other versions are scanned again
P.DT = 0.05       -- extra sleep per control step (reading/writing takes ticks too)
P.MAX_HEIGHT = 30
P.CLIMB = 0.6     -- blocks/s, target height speed (and Space/Shift)
P.DESCEND = 0.35
P.SPEED = 4       -- blocks/s with W/A/S/D
P.MAX_TILT = 10   -- degrees the craft may lean to move (and brake)
P.TILT_RATE = 15  -- degrees/s: the wanted lean changes no faster (no jolts)
P.TIP_PER_HOVER = 2.5 -- first flight: an edge lifted at 3.5%, hover was 1.37% each
-- Tilt loop: bandwidth (rad/s) and damping. Before the scan the craft's turn
-- rate K (deg/s^2 per unit of torque, in hover units) is guessed; this guess
-- flew in the model for K 40..250. After the scan K is measured and the
-- bandwidth follows the real control step: faster loop, stiffer control.
P.K_GUESS, P.W_PRIOR, P.ZETA, P.TI = 120, 1.55, 0.77, 4.0
P.TI_PRIOR = 1.7  -- before the scan: level out a player's weight faster
P.W_FACTOR = 0.35 -- after the scan: bandwidth = this / (control step + sensor lag)
P.RATE_F = 0.8    -- weight of the newest sample in the turn-rate estimate
-- Height loop (hover units per block, per block/s, per block*s), for g = 9.8;
-- scaled by the gravity the scan measures.
P.HP, P.HD, P.HI = 0.07, 0.05, 0.02
P.VEL_K = 0.8     -- 1/s: how fast speed follows the wanted speed
P.ACCEL = 1.5     -- blocks/s^2: the wanted speed grows and falls no faster (smooth keys)
P.LEAK = 0.05     -- 1/s: speed no sensor sees fades (air drag, and drift of the sum)
P.SENSOR_K = 20   -- 1/s: how hard a speed sensor pulls the worked-out speed (20: takes it as is)
P.LEVEL_RATE = 4  -- degrees/s: from its lean on uneven ground to level after liftoff
P.POS_K = 0.15    -- 1/s: pulls back to where you stopped
P.LAG = 0.05      -- sensor values are about a tick old

P.COMPASS = { -- forward and right as (south, east)
  north = { f = { -1, 0 }, r = { 0, 1 } }, east = { f = { 0, 1 }, r = { 1, 0 } },
  south = { f = { 1, 0 }, r = { 0, -1 } }, west = { f = { 0, -1 }, r = { -1, 0 } },
}

-- Thrust fraction -> setPower (1..15) and setThrustConfig (0..99).
-- From the Create Propulsion code: thrust = (config+1)/100 * maximum *
-- min(power/15, free blocks behind the nozzle/10). The lowest power that
-- reaches f keeps fine steps and stays under that obstruction cap.
P.MIN = 1 / 1500 -- power 1, config 0: the least thrust that is still "on"
function P.knobs(f)
  if not f or f <= 0 then return 0, 0 end
  local p = math.min(15, math.max(1, math.ceil(f * 15 - 1e-9)))
  local c = math.min(99, math.max(0, math.floor(f * 1500 / p + 0.5) - 1))
  return p, c
end

-- the thrust a fraction really gives after the knobs' steps
function P.real(f)
  local p, c = P.knobs(f)
  return p > 0 and (c + 1) / 100 * p / 15 or 0
end

local function zeros(n) local z = {} for i = 1, n do z[i] = 0 end return z end
function P.cut(hw) hw.write(zeros(hw.n)) end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

-- Small linear algebra ------------------------------------------------------

-- Solve A x = b (n x n), Gaussian elimination with pivoting; nil if singular.
function P.solve(A, b)
  local n, M = #b, {}
  for i = 1, n do
    M[i] = {}
    for j = 1, n do M[i][j] = A[i][j] end
    M[i][n + 1] = b[i]
  end
  for c = 1, n do
    local p = c
    for r = c + 1, n do if math.abs(M[r][c]) > math.abs(M[p][c]) then p = r end end
    if math.abs(M[p][c]) < 1e-12 then return nil end
    M[c], M[p] = M[p], M[c]
    for r = 1, n do
      if r ~= c then
        local k = M[r][c] / M[c][c]
        for j = c, n + 1 do M[r][j] = M[r][j] - k * M[c][j] end
      end
    end
  end
  local x = {}
  for i = 1, n do x[i] = M[i][n + 1] / M[i][i] end
  return x
end

-- Least squares: rows X[r] (features), values y[r] -> coefficients or nil.
function P.lsq(X, y)
  if #X == 0 then return nil end
  local k, A, b = #X[1], {}, {}
  for i = 1, k do A[i] = {} for j = 1, k do A[i][j] = 0 end b[i] = 0 end
  for r = 1, #X do
    for i = 1, k do
      b[i] = b[i] + X[r][i] * y[r]
      for j = 1, k do A[i][j] = A[i][j] + X[r][i] * X[r][j] end
    end
  end
  return P.solve(A, b)
end

local function inv2(M)
  local d = M[1][1] * M[2][2] - M[1][2] * M[2][1]
  if math.abs(d) < 1e-9 then return nil end
  return { { M[2][2] / d, -M[1][2] / d }, { -M[2][1] / d, M[1][1] / d } }
end

-- How to share a torque among the lifting thrusters: the least change of
-- thrust that gives torque (1, 0) or (0, 1) without changing the total lift.
-- c1/c2 of each lifter = which way it tips the craft (from `calibrate`).
-- Returns D1, D2: per-thruster change for a unit torque on each axis.
function P.mixer(cal)
  local L = {}
  for i, x in ipairs(cal.t) do if x.kind == "lift" then L[#L + 1] = i end end
  local C = { {}, {}, {} }
  for k, i in ipairs(L) do C[1][k] = 1; C[2][k] = cal.t[i].c1; C[3][k] = cal.t[i].c2 end
  local G = {}
  for r = 1, 3 do
    G[r] = {}
    for s = 1, 3 do
      local v = 0
      for k = 1, #L do v = v + C[r][k] * C[s][k] end
      G[r][s] = v + (r == s and 1e-6 or 0)
    end
  end
  local D1, D2 = zeros(#cal.t), zeros(#cal.t)
  for axis, D in ipairs({ D1, D2 }) do
    local d = { 0, 0, 0 }
    d[axis + 1] = 1
    local y = P.solve(G, d) or { 0, 0, 0 }
    for k, i in ipairs(L) do D[i] = C[1][k] * y[1] + C[2][k] * y[2] + C[3][k] * y[3] end
  end
  return D1, D2
end

-- Ground scan ------------------------------------------------------------------

-- Fire each thruster alone, growing slowly, until something happens:
--   the craft tips 1 degree   -> "lift", c1/c2 = which way it tips
--   the craft rises            -> "lift" through the middle (c1 = c2 = 0)
--   a Velocity Sensor moves    -> "side": it pushes sideways
--   nothing up to full power   -> "none" (points down, or is dead)
-- Returns { hover, t = { {kind, c1, c2, tip}, ... } } or nil, why.
-- wait until the craft stops moving on its legs (a slow one takes a while)
local function settle(hw)
  P.cut(hw)
  hw.wait(1)
  local last, calm = hw.read(), 0
  for _ = 1, 40 do
    hw.wait(0.5)
    local s = hw.read()
    if math.abs(s.a - last.a) < 0.05 and math.abs(s.b - last.b) < 0.05 and math.abs(s.y - last.y) < 0.02 then
      calm = calm + 1
      if calm >= 2 then return s end
    else
      calm = 0
    end
    last = s
  end
  return last
end

function P.calibrate(hw)
  local t, tips, n = {}, 0, 0
  for i = 1, hw.n do
    local s0 = settle(hw)
    local f, got = 0.0007, nil
    while f < 0.99 and not got do
      if hw.poll() == "kill" then P.cut(hw); return nil, "stopped" end
      local fs = zeros(hw.n)
      fs[i] = f
      hw.write(fs)
      hw.wait(0.25)
      local s = hw.read()
      local d1, d2 = s.a - s0.a, s.b - s0.b
      local m = math.max(math.abs(d1), math.abs(d2))
      local moved = 0
      for k = 1, #s.v do moved = math.max(moved, math.abs(s.v[k] - (s0.v[k] or 0))) end
      if m > 1 then
        got = { kind = "lift", c1 = d1 / m, c2 = d2 / m, tip = f }
        tips, n = tips + f, n + 1
      elseif s.y - s0.y > 0.3 then -- rose whole; a slow craft may still lean a little
        if m > 0.2 then got = { kind = "lift", c1 = d1 / m, c2 = d2 / m, tip = f / 1.6 }
        else got = { kind = "lift", c1 = 0, c2 = 0, tip = f } end
        if m > 0.2 then tips, n = tips + got.tip, n + 1 end
      elseif moved > 0.3 then
        got = { kind = "side", tip = f }
      end
      f = f * 1.15
    end
    P.cut(hw)
    t[i] = got or { kind = "none" }
  end
  for axis = 1, 2 do
    local plus, minus = false, false
    for _, x in ipairs(t) do
      local c = x.kind == "lift" and (axis == 1 and x.c1 or x.c2) or 0
      plus = plus or c > 0.4
      minus = minus or c < -0.4
    end
    if not (plus and minus) then
      local side = axis == 1 and (plus and "south" or "north") or (plus and "east" or "west")
      return nil, ("cannot level axis %d: nothing lifts the %s side"):format(axis, side), t
    end
  end
  settle(hw)
  return { hover = tips / math.max(n, 1) / P.TIP_PER_HOVER, t = t }
end

-- The way W flies, from where the Altitude Sensor sits and on which side of
-- the computer (its peripheral side). The pilot faces the screen, so forward
-- is opposite to where the screen looks. nil when it cannot tell (the sensor
-- is near the middle, or above/below the computer).
local ORDER = { "north", "east", "south", "west" }
function P.forwardFrom(alt, side)
  local turn = ({ front = 2, right = 1, back = 0, left = 3 })[side or ""]
  if not (alt and turn) then return nil end
  local south, east = alt[1], alt[2]
  if math.sqrt(south * south + east * east) < 0.5 then return nil end
  local i
  if math.abs(south) > math.abs(east) then i = south > 0 and 3 or 1 else i = east > 0 and 2 or 4 end
  return ORDER[(i - 1 + turn) % 4 + 1]
end

-- Craft report ----------------------------------------------------------------

-- A compass direction (of the craft as assembled) said the pilot's way, when
-- it is known where the screen is: "front", "back", "left", "right".
local SIDES = { [0] = "front", "right", "back", "left" }
local function pilotSide(dir, forward)
  local idx = { north = 0, east = 1, south = 2, west = 3 }
  if not (forward and idx[forward] and idx[dir]) then return dir end
  return SIDES[(idx[dir] - idx[forward]) % 4]
end
-- which side a lifter raises, from its (c1, c2): c1 > 0 raises north, c2 > 0 west
local function liftSide(c1, c2)
  local d = ""
  if c1 > 0.4 then d = "north" elseif c1 < -0.4 then d = "south" end
  if c2 > 0.4 then d = d .. (d ~= "" and "-" or "") .. "west" elseif c2 < -0.4 then d = d .. (d ~= "" and "-" or "") .. "east" end
  return d
end
local function sayDir(d, forward)
  local out = {}
  for part in d:gmatch("[^-]+") do out[#out + 1] = pilotSide(part, forward) end
  return table.concat(out, "-")
end

-- What is on board and what it gives the pilot. devices = { {name, type,
-- side}, ... } (every peripheral the computer sees), cal = the ground check
-- (nil before it), learn = the air scan (nil before it). Returns lines (each
-- fits a 51-wide screen) and caps = { height, level, move, hold, turn }, each
-- { ok = true/false, why = text }.
function P.report(devices, cal, learn)
  learn = learn or {}
  local fwd = cal and cal.forward
  local lines, caps = {}, {}
  local idx, count = {}, { thr = 0, gimbal = 0, alt = 0, speed = 0 }
  for i, n in ipairs(cal and cal.names or {}) do idx[n] = i end
  local altSide
  local speedK = 0
  lines[#lines + 1] = ("ON BOARD (%d devices):"):format(#devices)
  for _, d in ipairs(devices) do
    local what
    local t = d.type or "?"
    if t:find("thruster") then
      count.thr = count.thr + 1
      local x = cal and idx[d.name] and cal.t[idx[d.name]]
      local c = x and learn.c and learn.c[idx[d.name]]
      if not x then what = "thruster: not checked yet"
      elseif x.kind == "lift" then
        local side = c and liftSide(c[1], c[2]) or liftSide(x.c1, x.c2)
        what = side == "" and "thruster: lifts the middle" or ("thruster: lifts " .. sayDir(side, fwd) .. " side")
      elseif x.kind == "side" then
        local v = learn.side and learn.side[idx[d.name]]
        if v then
          local dir = math.abs(v[1]) > math.abs(v[2]) and (v[1] > 0 and "south" or "north") or (v[2] > 0 and "east" or "west")
          what = "thruster: pushes to the " .. pilotSide(dir, fwd)
        else
          what = "thruster: pushes sideways"
        end
      else
        what = "thruster: NO EFFECT (down? blocked?)"
      end
    elseif t == "gimbal_sensor" then
      count.gimbal = count.gimbal + 1
      what = "gimbal: tilt, for levelling"
    elseif t == "altitude_sensor" then
      count.alt = count.alt + 1
      altSide = d.side
      what = "altitude: height" .. ((d.side == "top" or d.side == "bottom") and "" or ", finds the front")
    elseif t == "velocity_sensor" then
      count.speed = count.speed + 1
      speedK = speedK + 1
      local m = learn.Mrows and learn.Mrows[speedK]
      if not learn.done then what = "speed: checked in the first flight"
      elseif not m then what = "speed: does not answer (vertical?)"
      else
        local dir = math.abs(m[1]) > math.abs(m[2]) and "north" or "east"
        local a = pilotSide(dir, fwd)
        what = "speed: sees " .. ((a == "front" or a == "back") and "front-back" or (a == "left" or a == "right")
          and "left-right" or (dir == "north" and "north-south" or "east-west"))
      end
    elseif t == "modem" then
      what = "network"
    else
      what = t .. ": not used yet"
    end
    local label = (d.side or d.name):gsub("^creative_", "")
    lines[#lines + 1] = (" %-12s %s"):format(label:sub(1, 12), what):sub(1, 51)
  end

  -- what the pilot gets
  local function cap(key, ok, why) caps[key] = { ok = ok, why = why } end
  local lift = false
  for _, x in ipairs(cal and cal.t or {}) do lift = lift or x.kind == "lift" end
  if count.alt == 0 then cap("height", false, "no Altitude Sensor by the computer")
  elseif count.thr == 0 then cap("height", false, "no thrusters on the network")
  elseif not cal then cap("height", false, "craft not checked yet")
  elseif not lift then cap("height", false, "no thruster lifts the craft")
  else cap("height", true, "Space/Shift, arrows 1 block") end
  if count.gimbal == 0 then cap("level", false, "no Gimbal Sensor by the computer")
  elseif not cal then cap("level", false, "craft not checked yet")
  elseif cal.why then cap("level", false, cal.why)
  else cap("level", true, "levels itself") end
  local sides = learn.side and next(learn.side) ~= nil
  if not caps.level.ok then cap("move", false, "needs levelling first")
  elseif sides then cap("move", true, "WASD: side thrusters + lean")
  else cap("move", true, "WASD by leaning (side thrusters would not lean)") end
  if not caps.level.ok then cap("hold", false, "needs levelling first")
  elseif not learn.done then cap("hold", true, "after the first flight learns it")
  elseif (learn.speedSeen or 0) >= 2 then cap("hold", true, "exact: speed sensed both ways")
  elseif learn.speedSeen == 1 then cap("hold", true, "1 way sensed, 1 worked out")
  else cap("hold", true, "worked out (2 Velocity Sensors: exact)") end
  cap("turn", false, "needs thrusters that twist it and a heading sensor")
  if not fwd and caps.move.ok then caps.move.why = "WASD after the 1st flight finds the front" end

  lines[#lines + 1] = "CONTROLS:"
  for _, k in ipairs({ { "height", "Up/down" }, { "level", "Level" }, { "move", "Move" }, { "hold", "Hold still" },
    { "turn", "Turn" } }) do
    local c = caps[k[1]]
    -- long reasons wrap under themselves
    local head, rest = (" %-10s %-3s "):format(k[2], c.ok and "YES" or "NO"), c.why
    while #head + #rest > 51 do
      local cut = rest:sub(1, 51 - #head):match("^.*() ") or (51 - #head)
      lines[#lines + 1] = head .. rest:sub(1, cut - 1)
      head, rest = (" "):rep(16), rest:sub(cut + 1)
    end
    lines[#lines + 1] = head .. rest
  end
  return lines, caps
end

-- How many directions of the speed the sensors cover: 0, 1 or 2.
function P.seen(rows, gk)
  local a, b, c = 0, 0, 0
  for _, m in pairs(rows or {}) do
    local R1, R2 = m[1] / gk, m[2] / gk
    a, b, c = a + R1 * R1, b + R1 * R2, c + R2 * R2
  end
  if a + c < 0.1 then return 0 end
  return (a * c - b * b) > 0.1 * ((a + c) / 2) ^ 2 and 2 or 1
end

-- Flight ---------------------------------------------------------------------

-- double integral of a +1 / -1 doublet (each half T long), from 0
local function doublet(t, T)
  if t <= 0 then return 0 elseif t < T then return t * t / 2 end
  local s = t - T
  if s < T then return T * T / 2 + T * s - s * s / 2 end
  return T * T
end
local function square(t, T) if t < 0 then return 0 elseif t < T then return 1 elseif t < 2 * T then return -1 end return 0 end

-- slope of v over samples with t in [t0, t1); also the mean of `a`
local function slope(data, key, i, t0, t1)
  local X, Y, am, n = {}, {}, 0, 0
  for _, d in ipairs(data) do
    if d.t >= t0 and d.t < t1 then
      X[#X + 1] = { 1, d.t }
      Y[#Y + 1] = i and d[key][i] or d[key]
      am, n = am + (d.ang or 0), n + 1
    end
  end
  local c = #X >= 3 and P.lsq(X, Y)
  return c and c[2], n > 0 and am / n or 0
end

-- Take off to `opts.height` blocks above the start, learn the craft (once),
-- then hold height, level and position; W/A/S/D move, Space/Shift climb/sink.
-- Returns result ("landed" | "stopped" | "tilt"), learn (what the scan found).
function P.fly(hw, cal, opts)
  opts = opts or {}
  local learn = {}
  -- a scan from an older version is not trusted at all: scan again
  if cal.learn and cal.learn.v == P.SCAN_VERSION then
    for k, v in pairs(cal.learn) do learn[k] = v end
  end
  local h = learn.hover or cal.hover
  local G = learn.G or 9.8
  -- how each lifter turns the craft: from the ground scan at first (rough:
  -- uneven ground rocks it on a diagonal), measured in the air once scanned
  local mixCal = cal
  if learn.c then
    mixCal = { t = {} }
    for i, x in ipairs(cal.t) do
      mixCal.t[i] = learn.c[i] and { kind = "lift", c1 = learn.c[i][1], c2 = learn.c[i][2] } or x
    end
  end
  local K = learn.kref and { learn.kref, learn.kref } or { P.K_GUESS, P.K_GUESS }
  local w = P.W_PRIOR
  local gk = G * math.pi / 180 -- blocks/s^2 per degree of lean
  -- The craft's speed (south, east): worked out from physics - a lean of X
  -- degrees pushes it by G*sin(X) - and corrected by every speed sensor along
  -- the direction that sensor happens to see (learn.Mrows, from the lean
  -- tests; any number of sensors, set any way). What no sensor sees runs on
  -- physics alone and fades slowly.
  local vS, vE, lastF = 0, 0, {}
  local side = learn.side or {} -- [i] = { s, e }: push per unit thrust (blocks/s^2)
  local dirs = P.COMPASS[opts.forward or "north"] or P.COMPASS.north
  local D1, D2 = P.mixer(mixCal)
  local isLift, lifters = {}, {}
  for i, x in ipairs(cal.t) do
    isLift[i] = x.kind == "lift"
    if isLift[i] then lifters[#lifters + 1] = i end
  end
  local Bm = {} -- measured: lifter i -> { turn X, turn Z } per unit of its thrust
  local warn = nil

  local s = hw.read()
  local ground = s.y
  local goal = ground + math.min(P.MAX_HEIGHT, opts.height or 4)
  local target = ground
  local I = -0.3 -- start under the guessed hover: lift off gently
  local Ia, Ib = 0, 0
  local vy, wa, wb = 0, 0, 0
  local a, b, y = s.a, s.b, s.y
  local landing, still = false, 0
  local t = hw.clock()
  local nextShow, dtAvg = 0, 0.1
  local pS, pE, tS, tE = 0, 0, 0, 0 -- position (from the speed sensors) and where to hold
  local spPrev = { s.a, s.b }
  local rest = { s.a, s.b } -- the lean it stands with on uneven ground
  local wS, wE, holding = 0, 0, false -- wanted speed (slews smoothly), holding still
  local wasActive, recovering = false, false
  local settled, baseSum, baseN = 0, 0, 0
  local queue, T = nil, nil -- scan tests still to run, the running one
  local scanned = learn.kref ~= nil or opts.noscan

  local function hp() return P.HP * 9.8 / G end
  local function hd() return P.HD * 9.8 / G end
  local function hi() return P.HI * 9.8 / G end

  -- what each test does and how long; analyse() fills `learn`
  local tests = {}
  local function startTest(name, amp)
    T = { name = name, t0 = nil, amp = amp, data = {}, tries = (T and T.name == name) and T.tries + 1 or 0,
          u = 0, vI = 0, qI = 0 }
  end
  local function nextTest()
    T = nil
    local name = table.remove(queue, 1)
    if name then startTest(name, tests[name].amp) end
  end

  -- Tests that push and watch: value = c0 + c1 t + c2 t^2 + coef * Q, where Q
  -- is the double integral of the push really applied (after the thrust
  -- steps), and t^2 soaks up any steady push that is not the test's (a
  -- player at the edge). Returns coef and how much the push moved things.
  local function fitPush(d, key)
    local X, Y, qmax = {}, {}, 0
    for _, p in ipairs(d) do
      X[#X + 1] = { 1, p.t, p.t * p.t, p.Q }
      Y[#Y + 1] = p[key]
      qmax = math.max(qmax, math.abs(p.Q))
    end
    local c = #X >= 6 and P.lsq(X, Y)
    if not c then return nil, 0 end
    return c[4], math.abs(c[4] * qmax)
  end
  tests.lift = { half = 0.5, dur = 1.4, analyse = function(d)
    local g, seen = fitPush(d, "y")
    if not g then return true end
    if seen < 0.05 then return false end -- too small to see: push harder
    if g > 2 and g < 60 then learn.G = g; G = g; gk = g * math.pi / 180 end
    learn.speedSeen = P.seen(learn.Mrows, gk)
    return true
  end }
  -- One lifter at a time gets a little more, then less thrust, the craft
  -- free to turn: how fast it turns on X and on Z is that thruster's lever
  -- (deg/s^2 per hover share). Physics, not the ground's guess.
  local function thrTest(i)
    return { half = 0.3, dur = 0.8, lifter = i, analyse = function(d)
      local b1, s1 = fitPush(d, "a")
      local b2, s2 = fitPush(d, "b")
      if not (b1 and b2) then return true end
      if math.max(s1, s2) < 0.25 then return false end -- too small to see: harder
      Bm[i] = { b1, b2 }
      return true
    end }
  end
  -- level out with the levelling on; over as soon as the craft is calm
  tests.rest = { dur = 5, calm = true, analyse = function() return true end }
  -- all levers measured: share torque by them from now on
  tests.mix = { dur = 0, analyse = function()
    local kref = 0
    for _, i in ipairs(lifters) do
      if not Bm[i] then return true end
      kref = math.max(kref, math.abs(Bm[i][1]), math.abs(Bm[i][2]))
    end
    if kref < 5 or kref > 5000 then return true end
    local c, cover = {}, { 0, 0, 0, 0 }
    for _, i in ipairs(lifters) do
      c[i] = { Bm[i][1] / kref, Bm[i][2] / kref }
      for k = 1, 2 do
        if c[i][k] > 0.2 then cover[2 * k - 1] = 1 elseif c[i][k] < -0.2 then cover[2 * k] = 1 end
      end
    end
    if cover[1] + cover[2] + cover[3] + cover[4] < 4 then return true end -- cannot level: keep the old
    learn.c, learn.kref = c, kref
    local mc = { t = {} }
    for i, x in ipairs(cal.t) do mc.t[i] = c[i] and { kind = "lift", c1 = c[i][1], c2 = c[i][2] } or x end
    D1, D2 = P.mixer(mc)
    K = { kref, kref }
    return true
  end }
  -- Lean one way, then the other, on each axis; meanwhile record both lean
  -- angles and every speed sensor. Each sensor's speed changes by
  -- M[i][1] * lean X + M[i][2] * lean Z per second: fitted over both tests at
  -- once, so a lean the test did not ask for (a player at the edge) does not
  -- fool it.
  local moveData = {}
  local function fitM()
    local M = {}
    for i = 1, #moveData[1][1].v do
      M[i] = {}
      local X, Y = {}, {}
      for k = 1, 2 do
        local d, i1, i2 = moveData[k], 0, 0
        for j, p in ipairs(d) do
          if j > 1 then
            local dt2 = p.t - d[j - 1].t
            i1 = i1 + 0.5 * (p.a + d[j - 1].a) * dt2
            i2 = i2 + 0.5 * (p.b + d[j - 1].b) * dt2
          end
          X[#X + 1] = { k == 1 and 1 or 0, k == 2 and 1 or 0, k == 1 and p.t or 0, k == 2 and p.t or 0, i1, i2 }
          Y[#Y + 1] = p.v[i]
        end
      end
      local c = P.lsq(X, Y)
      if not c then return nil end
      M[i][1], M[i][2] = c[5], c[6]
    end
    return M
  end
  -- Where the Altitude Sensor sits (blocks south, east of the middle): in
  -- the air the craft turns about its middle, so leaning by X, Z the sensor
  -- goes down by sin(X) * south + sin(Z) * east. Height thrust is frozen during
  -- the lean tests; drift up or down is soaked up by 1, t, t^2 per test.
  local function locate()
    local X, Y, r = {}, {}, math.pi / 180
    for k = 1, 2 do
      for _, p in ipairs(moveData[k]) do
        local row = { 0, 0, 0, 0, 0, 0, -math.sin(p.a * r), -math.sin(p.b * r) }
        row[k], row[k + 2], row[k + 4] = 1, p.t, p.t * p.t
        X[#X + 1] = row
        Y[#Y + 1] = p.y
      end
    end
    local c = P.lsq(X, Y)
    return c and { c[7], c[8] }
  end
  local function moveTest(axis)
    return { amp = 1.2, dur = 3.4, analyse = function(d)
      moveData[axis] = d
      if axis == 2 and moveData[1] then
        learn.alt = locate()
        local f = not opts.forwardManual and P.forwardFrom(learn.alt, opts.altSide)
        if f then learn.forward, dirs = f, P.COMPASS[f] end
      end
      if axis == 2 and moveData[1] and #s.v >= 1 then
        -- each sensor: how fast its reading changes per degree of lean X, Z.
        -- One that does not answer a lean (vertical, broken) is left out.
        local rows = {}
        for i, m in ipairs(fitM() or {}) do
          if math.sqrt(m[1] ^ 2 + m[2] ^ 2) > 0.3 * gk then rows[i] = m end
        end
        learn.Mrows = rows
        learn.speedSeen = P.seen(rows, gk)
      end
      return true
    end }
  end
  tests.m1, tests.m2 = moveTest(1), moveTest(2)
  -- Fire one side thruster (it needs 0.5 s to spin up, so the push is held
  -- long) and compare how the speed changes before and during it. Whatever
  -- the craft's own lean does to the speed (M) is taken out first.
  local function sideTest(i) -- first push: half of one lifter's hover thrust
    return { amp = 0.5 * h, dur = 2.2, thruster = i, analyse = function(d)
      local rows = learn.Mrows or {}
      if not next(rows) then return true end
      local i1, i2, prev = 0, 0, nil
      for _, p in ipairs(d) do
        if prev then
          i1 = i1 + 0.5 * (p.a + prev.a) * (p.t - prev.t)
          i2 = i2 + 0.5 * (p.b + prev.b) * (p.t - prev.t)
        end
        p.r = {}
        for k, m in pairs(rows) do p.r[k] = p.v[k] - m[1] * i1 - m[2] * i2 end
        prev = p
      end
      -- the push in (south, east) that best explains what the sensors saw
      local A, bb = { { 1e-3, 0 }, { 0, 1e-3 } }, { 0, 0 }
      for k, m in pairs(rows) do
        local s1 = slope(d, "r", k, 0.2, 0.8)
        local s2 = slope(d, "r", k, 1.5, 2.2)
        if not (s1 and s2) then return true end
        local R1, R2, da = m[1] / gk, m[2] / gk, s2 - s1
        A[1][1], A[1][2], A[2][2] = A[1][1] + R1 * R1, A[1][2] + R1 * R2, A[2][2] + R2 * R2
        bb[1], bb[2] = bb[1] + R1 * da, bb[2] + R2 * da
      end
      A[2][1] = A[1][2]
      local Ai = inv2(A)
      if not Ai then return true end
      local aS = Ai[1][1] * bb[1] + Ai[1][2] * bb[2]
      local aE = Ai[2][1] * bb[1] + Ai[2][2] * bb[2]
      if math.sqrt(aS * aS + aE * aE) < 0.15 then return false end -- too weak to see: harder
      side[i] = { aS / T.amp, aE / T.amp }
      learn.side = side
      return true
    end }
  end

  local function buildScan()
    -- pushes of at least 2 thrust steps, or the steps would hide them
    local step = 2 / 1500 / h
    tests.lift.amp = math.max(0.15, step)
    -- lean tests first: they find the screen side and the speed sensors
    queue = { "m1", "m2", "lift" }
    queue[#queue + 1] = "rest"
    for _, i in ipairs(lifters) do
      tests["t" .. i] = thrTest(i)
      tests["t" .. i].amp = math.max(0.12, step)
      queue[#queue + 1] = "t" .. i
      queue[#queue + 1] = "rest" -- level out again before the next one
    end
    queue[#queue + 1] = "mix"
    if #s.v >= 1 then
      for i, x in ipairs(cal.t) do
        if x.kind ~= "lift" then
          tests["side" .. i] = sideTest(i)
          queue[#queue + 1] = "side" .. i
        end
      end
    end
    nextTest()
  end

  local function retune()
    local D = dtAvg + P.LAG
    w = clamp(P.W_FACTOR / D, 0.8, 2.2)
  end

  -- share a horizontal push (south, east; blocks/s^2) among side thrusters,
  -- return their thrusts and what is left for leaning
  local function sideShare(aS, aE)
    local u, L = {}, 0
    for _, v in pairs(side) do L = L + v[1] * v[1] + v[2] * v[2] end
    if L == 0 then return u, aS, aE end
    for i in pairs(side) do u[i] = 0 end
    for _ = 1, 30 do
      local rS, rE = aS, aE
      for i, v in pairs(side) do rS = rS - v[1] * u[i]; rE = rE - v[2] * u[i] end
      for i, v in pairs(side) do u[i] = clamp(u[i] + (v[1] * rS + v[2] * rE) / L, 0, 0.99) end
    end
    for i, v in pairs(side) do aS = aS - v[1] * u[i]; aE = aE - v[2] * u[i] end
    return u, aS, aE
  end

  while true do
    local cmd = hw.poll()
    if cmd == "kill" then P.cut(hw); return "stopped", learn end
    if cmd == "up" then goal = math.min(ground + P.MAX_HEIGHT, goal + 1)
    elseif cmd == "down" then goal = math.max(ground + 1, goal - 1)
    elseif cmd == "land" then landing = true; T = nil; queue = {} end
    local held = hw.held and hw.held() or {}
    if not (learn.done or opts.noscan) then held = {} end -- hands off until it knows the craft

    s = hw.read()
    local now = hw.clock()
    local dt = math.max(now - t, 0.01)
    t = now
    dtAvg = 0.95 * dtAvg + 0.05 * dt
    if learn.kref then retune() end
    if math.abs(s.a) > P.TILT_CUT or math.abs(s.b) > P.TILT_CUT then P.cut(hw); return "tilt", learn end
    vy = 0.5 * vy + 0.5 * (s.y - y) / dt
    wa = (1 - P.RATE_F) * wa + P.RATE_F * (s.a - a) / dt
    wb = (1 - P.RATE_F) * wb + P.RATE_F * (s.b - b) / dt
    a, b, y = s.a, s.b, s.y
    local airborne = y > ground + 0.2

    -- height: the target moves to the goal at a calm speed (Space/Shift move the goal)
    if (held.u or 0) ~= 0 and not landing and not T then
      goal = clamp(goal + held.u * P.CLIMB * dt, ground + 1, ground + P.MAX_HEIGHT)
      target = clamp(target + held.u * P.CLIMB * dt, ground, ground + P.MAX_HEIGHT)
    end
    local vt = 0
    if landing then
      vt = -P.DESCEND
      target = math.max(target - P.DESCEND * dt, y - 1)
    elseif target < goal - 1e-6 then
      vt = math.min(P.CLIMB, (goal - target) / dt)
      target = math.min(goal, target + P.CLIMB * dt)
    elseif target > goal + 1e-6 then
      vt = -math.min(P.DESCEND, (target - goal) / dt)
      target = math.max(goal, target - P.DESCEND * dt)
    end
    if landing then
      if target < y - 0.3 and math.abs(vy) < 0.08 then still = still + dt else still = 0 end
      if still > 1 then P.cut(hw); return "landed", learn end
    end

    -- the scan starts once the craft hangs steady at its first goal
    if not scanned and not landing and math.abs(y - goal) < 0.3 and math.abs(vy) < 0.2 then
      settled = settled + dt
    else
      settled = 0
    end
    if not scanned and settled > 1 then
      local base = h * (1 + I) -- what it takes to hang here: the real hover thrust
      baseSum, baseN = baseSum + base, baseN + 1
    end
    if not scanned and not T and settled > 3 then
      learn.v = P.SCAN_VERSION
      if baseN > 0 then -- same thrust, now counted from the real hover
        learn.hover = baseSum / baseN
        I = h * (1 + I) / learn.hover - 1
        h = learn.hover
      end
      buildScan()
      scanned = true
    end

    -- the running test: its time, what it changes, what it records
    local inj = { base = 0, tau = { 0, 0 }, open = {}, sp = { 0, 0 }, f = {}, df = {} }
    if T then
      T.t0 = T.t0 or now
      local el = now - T.t0
      local test = tests[T.name]
      if el > 0 then -- integrate the push applied since the last step
        T.qI = T.qI + T.vI * dt + 0.5 * T.u * dt * dt
        T.vI = T.vI + T.u * dt
      end
      local rec = { t = el - P.LAG, y = y, v = s.v, a = a, b = b, Q = T.qI - T.vI * P.LAG }
      if T.name == "lift" then
        inj.base = h * T.amp * square(el, test.half)
      elseif test.lifter then
        inj.open[1], inj.open[2] = true, true
        inj.df[test.lifter] = T.amp * square(el, test.half)
      elseif T.name == "m1" or T.name == "m2" then
        local axis = T.name == "m1" and 1 or 2
        inj.sp[axis] = el < 1.5 and T.amp or el < 3.0 and -T.amp or 0
        rec.a, rec.b = a, b
      elseif test.thruster and el >= 0.8 then
        inj.f[test.thruster] = T.amp
      end
      T.data[#T.data + 1] = rec
      if test.calm and el > 0.6 and math.abs(a) < 1 and math.abs(b) < 1 and math.abs(wa) < 1.5 and math.abs(wb) < 1.5 then
        el = test.dur + 1
      end
      if test.lifter and (math.abs(a) > 8 or math.abs(b) > 8) then
        -- leaning too far with the levelling off: give up on this one
        T.tries = 99
        T.data = {}
        el = test.dur + 1
      end
      if el > test.dur then
        local done = test.analyse(T.data)
        if T.name == "mix" then retune() end
        if done or T.tries >= 3 then nextTest() else startTest(T.name, T.amp * 2.5) end
        if not T and #queue == 0 then learn.done = true end
      end
    end

    -- height
    local e = target - y
    local frozen = T and (T.name == "lift" or T.name == "m1" or T.name == "m2")
    if not frozen then I = clamp(I + hi() * e * dt, -0.7, 1.5) end
    local base
    if frozen then base = h * (1 + I) + inj.base
    else base = h * (1 + hp() * e - hd() * (vy - vt) + I) end
    base = clamp(base, 0, 3 * h)

    -- horizontal: speed from the sensors, keys -> wanted speed -> lean
    local sp = { inj.sp[1], inj.sp[2] }
    local sideF = {}
    local fwd, right = held.f or 0, held.r or 0
    -- the keys' speed, reached smoothly (P.ACCEL), back to zero when let go
    local kS, kE = 0, 0
    if not landing then
      kS = P.SPEED * (dirs.f[1] * fwd + dirs.r[1] * right)
      kE = P.SPEED * (dirs.f[2] * fwd + dirs.r[2] * right)
    end
    local dv = P.ACCEL * dt * (recovering and 0.5 or 1)
    wS = wS + clamp(kS - wS, -dv, dv)
    wE = wE + clamp(kE - wE, -dv, dv)
    if recovering and math.abs(wS) + math.abs(wE) < 0.05 then recovering = false end
    if airborne then
      local r = math.pi / 180
      vS = vS + (G * math.sin(a * r) - P.LEAK * vS) * dt
      vE = vE + (G * math.sin(b * r) - P.LEAK * vE) * dt
      for i, v in pairs(side) do
        vS, vE = vS + v[1] * (lastF[i] or 0) * dt, vE + v[2] * (lastF[i] or 0) * dt
      end
      for i, m in pairs(learn.Mrows or {}) do
        local R1, R2 = m[1] / gk, m[2] / gk
        local innov = (s.v[i] or 0) - (R1 * vS + R2 * vE)
        local k = math.min(1, P.SENSOR_K * dt) / (R1 * R1 + R2 * R2)
        vS, vE = vS + k * R1 * innov, vE + k * R2 * innov
      end
      if math.sqrt(vS * vS + vE * vE) > 2 * P.SPEED + 2 then
        -- far faster than ever asked: the speed picture is wrong. Stop trusting
        -- the sensors for this flight, keep the physics only.
        learn.Mrows, vS, vE, warn = nil, 0, 0, "SPEED SENSORS IGNORED (runaway)"
      end
      pS, pE = pS + vS * dt, pE + vE * dt
    else
      vS, vE = 0, 0
    end
    -- only once it knows the craft, and has come out of its starting lean
    local levelled = math.abs(rest[1]) < 0.5 and math.abs(rest[2]) < 0.5
    local active = not T and airborne and levelled and (learn.done or opts.noscan)
    if active and not wasActive then
      -- taking over a craft that is already moving: slow it down gently
      wS, wE, holding, recovering = vS, vE, false, true
    end
    wasActive = active
    if active then
      do
        -- moving: follow the wanted speed; stopped: stay where it came to rest
        local still = kS == 0 and kE == 0 and math.abs(wS) + math.abs(wE) < 0.05
        if still and not holding then tS, tE, holding = pS, pE, true end
        if not still then holding = false end
        local uS, uE = wS, wE
        if holding then
          uS = clamp(P.POS_K * (tS - pS), -P.SPEED, P.SPEED)
          uE = clamp(P.POS_K * (tE - pE), -P.SPEED, P.SPEED)
        end
        local lim = gk * P.MAX_TILT
        local aS = clamp(P.VEL_K * (uS - vS), -lim, lim)
        local aE = clamp(P.VEL_K * (uE - vE), -lim, lim)
        sideF, aS, aE = sideShare(aS, aE)
        sp[1], sp[2] = aS / gk, aE / gk
      end
    end
    for k = 1, 2 do
      if airborne then rest[k] = rest[k] - clamp(rest[k], -P.LEVEL_RATE * dt, P.LEVEL_RATE * dt) end
      sp[k] = sp[k] + rest[k]
    end

    for k = 1, 2 do
      sp[k] = spPrev[k] + clamp(sp[k] - spPrev[k], -P.TILT_RATE * dt, P.TILT_RATE * dt)
      spPrev[k] = sp[k]
    end

    -- tilt: wanted turn rate per axis -> torque in hover units
    local tau = {}
    local ang, rate, Iax = { a, b }, { wa, wb }, { Ia, Ib }
    for k = 1, 2 do
      local err = ang[k] - sp[k]
      if airborne and not inj.open[k] then
        Iax[k] = clamp(Iax[k] + (w * w / (learn.kref and P.TI or P.TI_PRIOR)) * err * dt, -0.6 * K[k], 0.6 * K[k])
      end
      if inj.open[k] then
        tau[k] = -Iax[k] / K[k] + inj.tau[k]
      else
        local alpha = -w * w * err - 2 * P.ZETA * w * rate[k] - Iax[k]
        tau[k] = clamp(alpha / K[k], -1, 1)
      end
    end
    Ia, Ib = Iax[1], Iax[2]

    local function makeFs(bs, t1, t2, plain)
      local fs = {}
      for i = 1, hw.n do
        if isLift[i] then
          -- never fully off in the air: from zero a thruster needs 0.5 s to spin up
          fs[i] = clamp(bs + h * (D1[i] * t1 + D2[i] * t2 + (plain and 0 or inj.df[i] or 0)), P.MIN, 0.99)
        elseif inj.f[i] then
          fs[i] = clamp(inj.f[i], 0, 0.99)
        elseif side[i] and airborne then
          -- known side thrusters idle at the least thrust (opposite ones cancel):
          -- from zero they need 0.5 s to spin up
          fs[i] = clamp(sideF[i] or 0, P.MIN, 0.99)
        else
          fs[i] = 0
        end
      end
      return fs
    end
    local fs = makeFs(base, tau[1], tau[2])
    if T and (T.name == "lift" or tests[T.name].lifter) then
      -- the push really applied: thrust after the steps, with minus without the test
      local j = tests[T.name].lifter
      if j then
        T.u = (P.real(fs[j]) - P.real(makeFs(base, tau[1], tau[2], true)[j])) / h
      else
        local fs0, v = makeFs(base - inj.base, tau[1], tau[2]), 0
        for _, i in ipairs(lifters) do v = v + (P.real(fs[i]) - P.real(fs0[i])) / h end
        T.u = v / #lifters
      end
    end
    hw.write(fs)
    lastF = fs

    if hw.show and now >= nextShow then
      nextShow = now + 0.5
      hw.show({ y = y - ground, goal = goal - ground, a = a, b = b, base = base / h, landing = landing,
        scan = T and T.name, learned = learn.done, warn = warn, seen = learn.speedSeen })
    end
    hw.wait(P.DT)
  end
end

return P
