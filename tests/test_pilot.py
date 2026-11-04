"""Tests for lib/pilot.lua: autopilot of a Create Aeronautics platform.

A small physics model of the 7x7 platform: 4 thrusters at the edge centres
(N, E, S, W), legs at the corners, Gimbal Sensor + Altitude Sensor. Facts from
the game: getAngles X > 0 = south edge lower, Z > 0 = east edge lower; reading
and writing a peripheral costs a tick. Unknown in the game, so tried over a
range: inertia, thrust lag, hover thrust, a player standing off-centre.

Run from the project root:
    .venv/bin/python tests/test_pilot.py
"""
import math
import sys
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
lua = LuaRuntime(unpack_returned_tuples=True)
P = lua.eval("function(s) return load(s, 'pilot.lua')() end")((ROOT / "lib" / "pilot.lua").read_text())

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


TICK = 0.05
SUB = 0.005


class Sim:
    """N, E, S, W thrusters (physical order). perm[i] = physical thruster of hw index i."""

    def __init__(self, K=100.0, grav=9.8, hov=0.05, tau=0.0, dist=(0.0, 0.0), perm=(0, 1, 2, 3),
                 swap=False, flip=(1, 1), dead=None, ground=66.5, events=(), limit=120.0):
        self.K, self.hov, self.tau, self.dist = K, hov, tau, dist
        self.perm, self.swap, self.flip, self.dead = perm, swap, flip, dead
        self.ground, self.grav = ground, grav
        self.t, self.y, self.vy = 0.0, ground, 0.0
        self.th, self.w = [0.0, 0.0], [0.0, 0.0]
        self.cmd, self.eff = [0.0] * 4, [0.0] * 4
        self.spin, self.fade = [0.0] * 4, [0.0] * 4  # start-up envelope 0..1, last power while fading
        self.hist = [(0.0, 0.0, 0.0, ground)]
        self.events = sorted(events)
        self.limit = limit
        self.trace = []  # (t, y, th0, th1, airborne)
        self.impact = 0.0
        self.writes = []

    # physics -------------------------------------------------------------
    def on_ground(self):
        return self.y <= self.ground + 1e-9

    def tip_ground(self, k, up, down):
        """One axis on the legs: an edge lifts only past twice its hover share."""
        lift = 0.0
        if up > 2:
            lift = up - 2
        elif down > 2:
            lift = -(down - 2)
        if lift:
            self.w[k] += self.K * lift * SUB
        elif self.th[k]:
            # falls back on the legs
            back = -math.copysign(self.K * 0.5, self.th[k])
            self.w[k] += back * SUB
        self.th[k] += self.w[k] * SUB
        if not lift and self.th[k] * (self.th[k] - self.w[k] * SUB) < 0:
            self.th[k], self.w[k] = 0.0, 0.0
        if not lift and abs(self.th[k]) < 1e-6:
            self.th[k], self.w[k] = 0.0, 0.0

    def step(self):
        for k in range(4):
            target = 0.0 if self.dead == k else self.cmd[k]
            # Create Propulsion: from zero a thruster spins up over 10 ticks, and fades out
            # over 10 ticks at its last power when switched off
            if target > 0:
                self.spin[k] = min(1.0, self.spin[k] + SUB / 0.5)
                self.fade[k] = target
            else:
                self.spin[k] = max(0.0, self.spin[k] - SUB / 0.5)
            target = (target if target > 0 else self.fade[k]) * self.spin[k]
            if self.tau > 0:
                self.eff[k] += (target - self.eff[k]) * min(1.0, SUB / self.tau)
            else:
                self.eff[k] = target
        N, E, S, W = (e / self.hov for e in self.eff)
        tot = N + E + S + W
        cos = math.cos(math.radians(self.th[0])) * math.cos(math.radians(self.th[1]))
        ay = self.grav * (tot * cos / 4 - 1) - 0.2 * self.vy
        if self.on_ground() and ay <= 0:
            self.y, self.vy = self.ground, 0.0
            # firing N raises the north edge: south lower: X grows. W raises west: Z grows.
            self.tip_ground(0, N, S)
            self.tip_ground(1, W, E)
        else:
            self.vy += ay * SUB
            self.y += self.vy * SUB
            for k, (up, down) in enumerate(((N, S), (W, E))):
                alpha = self.K * (up - down + self.dist[k]) - 0.5 * self.w[k]
                self.w[k] += alpha * SUB
                self.th[k] += self.w[k] * SUB
            if self.y < self.ground:
                self.impact = max(self.impact, -self.vy)
                self.y, self.vy = self.ground, 0.0
                for k in range(2):
                    self.w[k] = 0.0
                    if abs(self.th[k]) < 8:
                        self.th[k] = 0.0
        self.t += SUB
        self.hist.append((self.t, self.th[0], self.th[1], self.y))
        if len(self.hist) > 200:
            del self.hist[:100]
        self.trace.append((self.t, self.y - self.ground, self.th[0], self.th[1], not self.on_ground()))

    def advance(self, s):
        n = max(1, int(round(s / SUB)))
        for _ in range(n):
            self.step()

    # hw for pilot.lua ----------------------------------------------------
    def read(self):
        self.advance(TICK)  # one tick for the call
        # the value is a tick old
        old = self.hist[0]
        for h in self.hist:
            if h[0] <= self.t - TICK:
                old = h
        a, b = old[1], old[2]
        if self.swap:
            a, b = b, a
        return a * self.flip[0], b * self.flip[1], old[3]

    def write(self, fs):
        vals = [float(fs[i + 1] or 0) for i in range(4)]
        self.writes.append(vals)
        for i, f in enumerate(vals):
            p, c = P.knobs(f)
            self.cmd[self.perm[i]] = (c + 1) / 100 * p / 15 if p > 0 else 0.0
        self.advance(TICK)

    def wait(self, s):
        self.advance(s)

    def clock(self):
        return self.t

    def poll(self):
        if self.t > self.limit:
            return "kill"
        if self.events and self.events[0][0] <= self.t:
            return self.events.pop(0)[1]
        return None

    def hw(self):
        return lua.table_from({"n": 4, "read": self.read, "write": self.write, "wait": self.wait,
                               "clock": self.clock, "poll": self.poll})


def tolist(t):
    return {k: (dict(v.items()) if lua.lua_type(v) == "table" else v) for k, v in t.items()}


def calibrate(sim):
    r = P.calibrate(sim.hw())
    cal, why = r if isinstance(r, tuple) else (r, None)
    return cal, why


def fly(sim, cal, height=4):
    return P.fly(sim.hw(), cal, lua.table_from({"height": height}))


def window(sim, t0, t1):
    return [x for x in sim.trace if t0 <= x[0] <= t1]


# --- knobs ------------------------------------------------------------------
check("knobs: zero is off", tuple(P.knobs(0)) == (0, 0))
worst = 0
ok_range = True
for i in range(1, 100):
    f = i / 100
    p, c = P.knobs(f)
    ok_range = ok_range and 1 <= p <= 15 and 0 <= c <= 99
    worst = max(worst, abs((c + 1) / 100 * p / 15 - f) / f)
check("knobs: power 1..15, config 0..99", ok_range)
check("knobs: within 2% of the asked thrust", worst < 0.02, worst)
p, c = P.knobs(0.003)
check("knobs: small thrust keeps fine steps (low power)", p == 1 and abs((c + 1) / 1500 - 0.003) < 0.0004, (p, c))
check("knobs: the least 'on' thrust is power 1, config 0", tuple(P.knobs(P.MIN)) == (1, 0) and tuple(P.knobs(1e-6)) == (1, 0))
check("knobs: lowest power that reaches it (obstruction cap)",
      all(P.knobs(f / 100)[0] == math.ceil(f / 100 * 15 - 1e-9) for f in range(1, 100)))

# --- calibration ------------------------------------------------------------
sim = Sim()
cal, why = calibrate(sim)
check("calibrate: works on the real layout", cal is not None, why)
if cal:
    t = [dict(cal.t[i].items()) for i in range(1, 5)]
    want = [(1, 1), (2, -1), (1, -1), (2, 1)]  # N: X up, E: Z down, S: X down, W: Z up
    check("calibrate: finds axis and sign of N, E, S, W", [(x["axis"], x["sign"]) for x in t] == want, t)
    check("calibrate: hover guessed within 25%", abs(cal.hover - 0.05) / 0.05 < 0.25, cal.hover)
    check("calibrate: all thrusters off at the end", sim.writes[-1] == [0, 0, 0, 0], sim.writes[-1])
    check("calibrate: platform back flat on its legs", sim.on_ground() and abs(sim.th[0]) < 0.5 and abs(sim.th[1]) < 0.5,
          (sim.y, sim.th))
    check("calibrate: under 2 minutes", sim.t < 120, sim.t)

dead_cal, dead_why = calibrate(Sim(dead=2))
check("calibrate: a dead thruster is reported, not flown", dead_cal is None and "thruster 3" in (dead_why or ""),
      dead_why)
kill_cal, kill_why = calibrate(Sim(events=[(3.0, "kill")]))
check("calibrate: kill key stops it", kill_cal is None and kill_why == "stopped", kill_why)


# --- flight -----------------------------------------------------------------
def flight(name, height=4, land_at=40.0, **kw):
    sim = Sim(**kw)
    cal, why = calibrate(sim)
    if not cal:
        check(name + ": calibrated", False, why)
        return None, None
    t0 = sim.t
    sim.events = [(t0 + land_at, "land")]
    sim.limit = t0 + land_at + 60
    res = fly(sim, cal, height)
    return sim, (res, t0)


def judge(name, sim, res, height=4, land_at=40.0, settle=15.0, tilt_ok=4.0, calm_ok=2.0):
    res, t0 = res
    hold = window(sim, t0 + settle, t0 + land_at)
    ys = [x[1] for x in hold]
    tilt = max((max(abs(x[2]), abs(x[3])) for x in window(sim, t0, t0 + land_at)), default=99)
    calm = max((max(abs(x[2]), abs(x[3])) for x in hold), default=99)
    check(name + ": holds height", ys and max(abs(v - height) for v in ys) < 0.5,
          (min(ys), max(ys)) if ys else "no data")
    check(name + ": never tilts past %g deg" % tilt_ok, tilt < tilt_ok, tilt)
    check(name + ": level once settled (< %g deg)" % calm_ok, calm < calm_ok, calm)
    check(name + ": lands and switches off", res == "landed" and sim.writes[-1] == [0, 0, 0, 0] and sim.on_ground(),
          (res, sim.writes[-1], sim.y - sim.ground))
    check(name + ": soft touchdown (< 1.5 b/s)", sim.impact < 1.5, sim.impact)


# A player off-centre (torque in hover units: 0.15 = a fair share of the
# weight at the edge) is what actually tilts it; a symmetric model never would.
EDGE = (-0.15, 0.06)
cases = [
    ("hover, player in the middle", {}, 4.0),
    ("player at the south-west edge", {"dist": EDGE}, 16.0),
    # ponytail: fixed gains; a body 2.5x harder to turn only settles slowly (period ~10 s).
    # Gains get tuned from the first real flight log (/pilot.log).
    ("heavy body (K x0.4) + edge", {"K": 40.0, "dist": EDGE}, 16.0, 10.0),
    ("light body (K x2.5) + edge", {"K": 250.0, "dist": EDGE}, 16.0),
    ("thrust lags 0.1 s + edge", {"tau": 0.1, "dist": EDGE}, 16.0),
    ("gravity 32 (Minecraft-like) + edge", {"grav": 32.0, "K": 330.0, "dist": EDGE}, 16.0),
    # one thrust step (power 1, config +1) is 7% of hover here: a small wobble stays
    ("strong thrusters (hover 1%) + edge", {"hov": 0.01, "dist": EDGE}, 16.0, 4.0),
    ("weak thrusters (hover 20%) + edge", {"hov": 0.2, "dist": EDGE}, 16.0),
    ("names shuffled, axes swapped, sign flipped + edge",
     {"perm": (2, 0, 3, 1), "swap": True, "flip": (-1, 1), "dist": EDGE}, 16.0),
]
for name, kw, tilt_ok, *calm in cases:
    sim, res = flight(name, **kw)
    if sim:
        judge(name, sim, res, tilt_ok=tilt_ok, calm_ok=calm[0] if calm else 2.0)

# player gets on after calibration: hover thrust 40% higher than calibrated
sim = Sim()
cal, _ = calibrate(sim)
sim.hov = 0.07
t0 = sim.t
sim.events = [(t0 + 40, "land")]
sim.limit = t0 + 100
judge("heavier than calibrated (+40%)", sim, (fly(sim, cal), t0), settle=25.0)

# up / down keys move the goal by a block
sim = Sim()
cal, _ = calibrate(sim)
t0 = sim.t
sim.events = [(t0 + 20, "up"), (t0 + 20.5, "up"), (t0 + 45, "land")]
sim.limit = t0 + 110
res = fly(sim, cal, 3)
ys = [x[1] for x in window(sim, t0 + 35, t0 + 45)]
check("up twice: 3 -> 5 blocks", ys and max(abs(v - 5) for v in ys) < 0.5, (min(ys), max(ys)) if ys else None)
check("then lands", res == "landed", res)

# kill key in the air: everything off at once
sim = Sim()
cal, _ = calibrate(sim)
t0 = sim.t
sim.events = [(t0 + 12, "kill")]
res = fly(sim, cal)
check("kill in flight: stopped, all thrusters off", res == "stopped" and sim.writes[-1] == [0, 0, 0, 0],
      (res, sim.writes[-1]))
check("kill acts within a tick or two", sim.t - (t0 + 12) < 0.4, sim.t - t0 - 12)

# wrong calibration (gimbal flipped after it): the safety cut fires
sim = Sim()
cal, _ = calibrate(sim)
sim.flip = (-1, 1)
sim.dist = EDGE
t0 = sim.t
sim.limit = t0 + 60
res = fly(sim, cal)
peak = max(max(abs(x[2]), abs(x[3])) for x in window(sim, t0, sim.t))
check("unstable (bad calibration): tilt cut, all off", res == "tilt" and sim.writes[-1] == [0, 0, 0, 0],
      (res, sim.writes[-1]))
check("tilt cut long before it flips (< 45 deg)", peak < 45, peak)

# --- the game program itself (programs/pilot/pilot.lua) with fake CC APIs --
PROG = (ROOT / "programs" / "pilot" / "pilot.lua").read_text()
LIB = (ROOT / "lib" / "pilot.lua").read_text()


def run_program(sim, arg, files):
    names = ["creative_thruster_%d" % i for i in range(4)]
    state = {"f": [0.0] * 4, "p": [0] * 4, "c": [0] * 4, "printed": []}

    def call(name, method, *a):
        i = names.index(name)
        if method == "setPower":
            state["p"][i] = int(a[0])
        elif method == "setThrustConfig":
            state["c"][i] = int(a[0])
        fs = [((state["c"][k] + 1) / 100 * state["p"][k] / 15) if state["p"][k] > 0 else 0 for k in range(4)]
        for k in range(4):
            sim.cmd[sim.perm[k]] = fs[k]

    snap = {}

    def angles():
        a, b, y = sim.read()
        snap["y"] = y
        return lua.table_from([a, b])

    env = lua.eval("""function(prog, lib, names, call, angles, height, wait, clock, files, out, arg)
      local fsys = {
        exists = function(p) return files[p] ~= nil end,
        open = function(p, mode)
          if mode == "r" then return { readAll = function() return files[p] end, close = function() end } end
          local buf = {}
          return { write = function(s) buf[#buf+1] = s end, writeLine = function(s) buf[#buf+1] = s .. "\\n" end,
                   flush = function() end, close = function() files[p] = table.concat(buf) end }
        end }
      local per = {
        getNames = function() local t = { "top", "left", "bottom" } for i = 1, #names do t[#t+1] = names[i] end return t end,
        getType = function(n) if n == "top" then return "gimbal_sensor" elseif n == "left" then return "altitude_sensor"
          elseif n == "bottom" then return "modem" else return "creative_thruster" end end,
        find = function(t)
          if t == "gimbal_sensor" then return { getAngles = angles } end
          if t == "altitude_sensor" then return { getHeight = function() return height() end } end
        end,
        call = call }
      local env = setmetatable({
        peripheral = per, fs = fsys, sleep = wait,
        os = { clock = clock, pullEvent = function() error("no keys in the test") end },
        parallel = { waitForAll = function(...) for _, f in ipairs({...}) do f() end end,
                     waitForAny = function(f) f() end },
        term = { clear = function() end, setCursorPos = function() end, clearLine = function() end,
                 write = function() end, setTextColor = function() end },
        colors = { red = 1, white = 2 }, keys = {},
        textutils = { serialize = function(t)
            local function ser(v) if type(v) == "table" then local o = {} for k, x in pairs(v) do
              o[#o+1] = "[" .. (type(k) == "string" and ("%q"):format(k) or tostring(k)) .. "]=" .. ser(x) end
              return "{" .. table.concat(o, ",") .. "}" end return ("%.17g"):format(v) end
            return ser(t) end,
          unserialize = function(s) return load("return " .. s)() end },
        print = function(s) out[#out+1] = tostring(s) end,
        require = function() return load(lib, "pilot.lua")() end,
      }, { __index = _G })
      env.table = { pack = table.pack, unpack = table.unpack, remove = table.remove, insert = table.insert,
                    concat = table.concat, sort = table.sort }
      return load(prog, "pilot", "t", env)(arg)
    end""")
    out = lua.table_from([])
    env(PROG, LIB, lua.table_from(names), call, angles, lambda: snap.get("y", sim.ground),
        sim.wait, sim.clock, files, out, arg)
    return [out[i] for i in range(1, len(out) + 1)]


files = lua.table_from({})
sim = Sim(dist=EDGE)
out = run_program(sim, "calibrate", files)
check("program: calibrate saves /.pilot", files["/.pilot"] is not None, out)
check("program: calibrate prints each thruster's side",
      any("creative_thruster_0" in l and "S lower" in l for l in out)
      and any("creative_thruster_1" in l and "W lower" in l for l in out), out)  # E fires: east rises
# Flight; after 30 s the user holds Ctrl+T: sleep throws "Terminated" like in CC.
t0 = sim.t
real_wait = sim.wait


def wait_then_terminate(s):
    if sim.t > t0 + 30:
        raise RuntimeError("Terminated")
    real_wait(s)


sim.wait = wait_then_terminate
out = run_program(sim, "4", files)
ys = [x[1] for x in window(sim, t0 + 20, t0 + 30)]
check("program: flies to +4", ys and max(abs(v - 4) for v in ys) < 0.5, (min(ys), max(ys)) if ys else out)
check("program: Ctrl+T -> all thrusters off", any("Terminated" in l for l in out) and sim.cmd == [0.0] * 4,
      (out, sim.cmd))
log = (files["/pilot.log"] or "").splitlines()
check("program: writes /pilot.log (t y X Z + 4 thrusts)", len(log) > 100 and len(log[1].split()) == 8,
      log[:2])

failed = [x for x in results if not x[1]]
for name, good, d in results:
    print(("PASS " if good else "FAIL ") + name + ("" if good else f"   -> {d}"))
print(f"\n{len(results) - len(failed)}/{len(results)} passed")
sys.exit(1 if failed else 0)
