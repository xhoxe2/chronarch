-- CHRONARCH :: lib/pilot.lua  - autopilot for a Create Aeronautics platform
--
-- Hardware comes in as `hw`, so the same code runs in the game and in the
-- physics model of the tests:
--   hw.n                 number of thrusters (all pointing up)
--   hw.read()  -> ax, az, y   Gimbal Sensor angles (degrees) + Altitude Sensor
--   hw.write(fs)         thrust per thruster, fraction 0..0.99 of maximum
--   hw.wait(s)           sleep
--   hw.clock()           seconds
--   hw.poll()  -> nil | "up" | "down" | "land" | "kill"
--   hw.show(state)       optional: draw the status
--
-- Nothing assumes where each thruster stands: `calibrate` fires them one at a
-- time with the platform on its legs and watches which way it tips.

local P = {}

P.TILT_CUT = 30 -- degrees: past this every thruster goes off
P.DT = 0.05     -- extra sleep per control step (reading/writing takes ticks too)
-- Gains, in "hover thrust" units: tilt per degree (tp), per degree/s (td),
-- per degree*s (ti); height per block (hp), per block/s (hd), per block*s (hi).
-- Tuned in tests/test_pilot.py: tilt for the inertia measured in the first
-- flight log (K ~100..150, survives 40..250), height over gravity 9.8..32,
-- hover guessed -30..+30%, a player at the edge.
P.GAINS = { tp = 0.01, td = 0.01, ti = 0.006, hp = 0.07, hd = 0.05, hi = 0.02 }
P.TIP_PER_HOVER = 2.5 -- first flight: an edge lifted at 3.5%, hover was 1.37% each
P.MAX_HEIGHT = 30
P.CLIMB = 0.6   -- blocks/s, how fast the target height moves
P.DESCEND = 0.35

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

local function zeros(n) local z = {} for i = 1, n do z[i] = 0 end return z end
function P.cut(hw) hw.write(zeros(hw.n)) end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

-- Fire each thruster alone, growing slowly, until the platform tips 1 degree.
-- Returns { hover = f, t = { {axis=1|2, sign=+1|-1, tip=f}, ... } } or nil, why.
-- sign: firing it makes that angle grow. Hover is guessed from the tipping
-- point: an edge thruster lifts its edge at P.TIP_PER_HOVER times its share
-- of the hover thrust (2 on paper, 2.5 measured: the legs stand at the corners).
function P.calibrate(hw)
  local t, tips = {}, 0
  for i = 1, hw.n do
    P.cut(hw)
    hw.wait(2) -- settle on the legs
    local a0, b0, y0 = hw.read()
    local f, got = 0.0007, nil
    while f < 0.99 and not got do
      if hw.poll() == "kill" then P.cut(hw); return nil, "stopped" end
      local fs = zeros(hw.n)
      fs[i] = f
      hw.write(fs)
      hw.wait(0.25)
      local a, b, y = hw.read()
      local d1, d2 = a - a0, b - b0
      if math.max(math.abs(d1), math.abs(d2)) > 1 then
        local axis = math.abs(d1) >= math.abs(d2) and 1 or 2
        local d = axis == 1 and d1 or d2
        got = { axis = axis, sign = d > 0 and 1 or -1, tip = f }
      elseif y - y0 > 0.5 then
        break -- the whole platform rose: this thruster says nothing about tilt
      end
      f = f * 1.15
    end
    P.cut(hw)
    if not got then return nil, ("thruster %d did not tip the platform"):format(i) end
    t[i] = got
    tips = tips + got.tip
  end
  for axis = 1, 2 do
    local plus, minus = false, false
    for _, x in ipairs(t) do
      if x.axis == axis then plus = plus or x.sign > 0; minus = minus or x.sign < 0 end
    end
    if not (plus and minus) then
      return nil, ("axis %d has no thruster on one side"):format(axis)
    end
  end
  hw.wait(2)
  return { hover = tips / hw.n / P.TIP_PER_HOVER, t = t }
end

-- Take off to `opts.height` blocks above the start, hold level and height,
-- land on "land". Returns "landed", "stopped" (kill key) or "tilt" (safety cut).
function P.fly(hw, cal, opts)
  opts = opts or {}
  local g = opts.gains or P.GAINS
  local h = cal.hover
  local a, b, y = hw.read()
  local ground = y
  local goal = ground + math.min(P.MAX_HEIGHT, opts.height or 4)
  local target = ground
  local I, Ia, Ib = -0.3, 0, 0 -- start under the guessed hover: lift off gently
  local vy, wa, wb = 0, 0, 0
  local landing, still = false, 0
  local t = hw.clock()
  local nextShow = 0
  while true do
    local cmd = hw.poll()
    if cmd == "kill" then P.cut(hw); return "stopped" end
    if cmd == "up" then goal = math.min(ground + P.MAX_HEIGHT, goal + 1)
    elseif cmd == "down" then goal = math.max(ground + 1, goal - 1)
    elseif cmd == "land" then landing = true end

    local na, nb, ny = hw.read()
    local now = hw.clock()
    local dt = math.max(now - t, 0.01)
    t = now
    if math.abs(na) > P.TILT_CUT or math.abs(nb) > P.TILT_CUT then P.cut(hw); return "tilt" end
    vy = 0.5 * vy + 0.5 * (ny - y) / dt
    wa = 0.5 * wa + 0.5 * (na - a) / dt
    wb = 0.5 * wb + 0.5 * (nb - b) / dt
    a, b, y = na, nb, ny

    -- where we want to be: the target moves to the goal at a calm speed
    local vt = 0
    if landing then
      vt = -P.DESCEND
      target = math.max(target - P.DESCEND * dt, y - 1)
    elseif target < goal then
      vt = P.CLIMB
      target = math.min(goal, target + P.CLIMB * dt)
    elseif target > goal then
      vt = -P.DESCEND
      target = math.max(goal, target - P.DESCEND * dt)
    end
    if landing then
      -- on the ground the target stays below us and we stop sinking
      if target < y - 0.3 and math.abs(vy) < 0.08 then still = still + dt else still = 0 end
      if still > 1 then P.cut(hw); return "landed" end
    end

    local e = target - y
    I = clamp(I + g.hi * e * dt, -0.7, 1.0)
    local base = clamp(h * (1 + g.hp * e - g.hd * (vy - vt) + I), 0, 3 * h)
    local airborne = y > ground + 0.2
    if airborne then
      Ia = clamp(Ia + g.ti * a * dt, -0.3, 0.3)
      Ib = clamp(Ib + g.ti * b * dt, -0.3, 0.3)
    end
    local u = { g.tp * a + g.td * wa + Ia, g.tp * b + g.td * wb + Ib }
    local fs = {}
    for i, x in ipairs(cal.t) do
      -- never fully off in the air: from zero a thruster needs 0.5 s to spin up
      fs[i] = clamp(base - x.sign * h * u[x.axis], P.MIN, 0.99)
    end
    hw.write(fs)

    if hw.show and now >= nextShow then
      nextShow = now + 0.5
      hw.show({ y = y - ground, goal = goal - ground, a = a, b = b, base = base / h, landing = landing })
    end
    hw.wait(P.DT)
  end
end

return P
