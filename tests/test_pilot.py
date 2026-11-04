"""Tests for lib/pilot.lua: the autopilot that learns the craft it sits on.

A physics model of a craft: lifting thrusters in any layout (+, x), side
thrusters, thrusters pointing down, legs on the ground with friction,
Gimbal Sensor + Altitude Sensor + Velocity Sensors in any orientation.
Facts from the game: getAngles X > 0 = south edge lower, Z > 0 = east edge
lower; a peripheral read costs a tick and is a tick old; the platform's
first flight log: hover 1.37% per thruster, turn rate K ~100..150, one
control step ~0.09 s; an edge lifts at 2.5x its hover share. Unknown, so
tried over a range: inertia, gravity, thrust lag, a player off-centre.

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
EDGE = (-0.15, 0.06)  # a player off-centre: torque in hover units
REAL = {"hov": 0.0137, "K": 120.0}  # the platform, from its first flight log

# torque of each lifter on (gimbal X, gimbal Z) per hover share: N raises the
# north edge -> south lower -> X grows; E raises east -> Z falls.
LAYOUTS = {
    "plus": [(1, 0), (0, -1), (-1, 0), (0, 1)],  # N, E, S, W
    "x": [(0.7, -0.7), (-0.7, -0.7), (-0.7, 0.7), (0.7, 0.7)],  # NE, SE, SW, NW
}


class Sim:
    """Lifters from `layout`, then `side` thrusters (push direction (south, east),
    (0, 0) = points down). perm[i] = physical actuator of hw index i."""

    def __init__(self, K=100.0, grav=9.8, hov=0.05, tau=0.0, dist=(0.0, 0.0), layout="plus", side=(),
                 perm=None, swap=False, flip=(1, 1), dead=None, sensors=((-1, 0), (0, 1)), ground=66.5,
                 events=(), held=(), limit=150.0, mu=0.6, alt=(0.0, 1.0), rest=(0.0, 0.0), edge=3.0):
        self.K, self.grav, self.hov, self.tau, self.dist = K, grav, hov, tau, dist
        self.lifters = LAYOUTS[layout]
        self.side = list(side)
        self.n = len(self.lifters) + len(self.side)
        self.perm = list(perm) if perm else list(range(self.n))
        self.swap, self.flip, self.dead, self.sensors = swap, flip, dead, list(sensors)
        self.ground, self.mu = ground, mu
        # Altitude Sensor (south, east of the middle); the lean it stands with on
        # uneven ground; how far the legs are from the middle
        self.alt, self.rest, self.edge = alt, list(rest), edge
        self.t, self.y, self.vy = 0.0, ground, 0.0
        self.th, self.w = list(rest), [0.0, 0.0]
        self.v, self.p = [0.0, 0.0], [0.0, 0.0]  # horizontal (south, east)
        self.cmd, self.eff = [0.0] * self.n, [0.0] * self.n
        self.spin, self.fade = [0.0] * self.n, [0.0] * self.n
        self.hist = [(0.0, rest[0], rest[1], ground, 0.0, 0.0, True)]
        self.events = sorted(events)
        self.held_plan = list(held)  # (t0, t1, {f, r, u})
        self.limit = limit
        self.trace = []  # (t, height, X, Z, airborne, pS, pE)
        self.impact = 0.0
        self.writes = []

    def on_ground(self):
        return self.y <= self.ground + 1e-9

    def tip_ground(self, k, torque):
        """One axis on the legs: an edge lifts past 2.5x its hover share (measured in game)."""
        lift = 0.0
        if torque > 2.5:
            lift = torque - 2.5
        elif torque < -2.5:
            lift = torque + 2.5
        if lift:
            self.w[k] += self.K * lift * SUB
        elif self.th[k] != self.rest[k]:
            self.w[k] += -math.copysign(self.K * 0.5, self.th[k] - self.rest[k]) * SUB  # falls back on the legs
        self.th[k] += self.w[k] * SUB
        d = self.th[k] - self.rest[k]
        if not lift and (d * (d - self.w[k] * SUB) < 0 or abs(d) < 1e-6):
            self.th[k], self.w[k] = self.rest[k], 0.0

    def step(self):
        for k in range(self.n):
            target = 0.0 if self.dead == k else self.cmd[k]
            # Create Propulsion: from zero a thruster spins up over 10 ticks, fades over 10
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
        nl = len(self.lifters)
        W = nl * self.hov  # weight, in thrust fractions
        lift = sum(self.eff[:nl]) / W
        torque = [sum(c[k] * e / self.hov for c, e in zip(self.lifters, self.eff[:nl])) for k in range(2)]
        push = [sum(d[k] * e / W * self.grav for d, e in zip(self.side, self.eff[nl:])) for k in range(2)]
        cos = math.cos(math.radians(self.th[0])) * math.cos(math.radians(self.th[1]))
        ay = self.grav * (lift * cos - 1) - 0.2 * self.vy
        if self.on_ground() and ay <= 0:
            self.y, self.vy = self.ground, 0.0
            for k in range(2):
                self.tip_ground(k, torque[k])
            mag = math.hypot(*push)  # legs hold it until the push beats friction
            if mag > self.mu * self.grav:
                for k in range(2):
                    self.v[k] += (push[k] - push[k] / mag * self.mu * self.grav) * SUB
            else:
                self.v = [0.0, 0.0]
        else:
            self.vy += ay * SUB
            self.y += self.vy * SUB
            for k in range(2):
                alpha = self.K * (torque[k] + self.dist[k]) - 0.5 * self.w[k]
                self.w[k] += alpha * SUB
                self.th[k] += self.w[k] * SUB
                acc = self.grav * lift * math.sin(math.radians(self.th[k])) + push[k] - 0.1 * self.v[k]
                self.v[k] += acc * SUB
            if self.y < self.ground:
                self.impact = max(self.impact, -self.vy)
                self.y, self.vy = self.ground, 0.0
                for k in range(2):
                    self.w[k] = 0.0
                    if abs(self.th[k] - self.rest[k]) < 8:
                        self.th[k] = self.rest[k]
        for k in range(2):
            self.p[k] += self.v[k] * SUB
        self.t += SUB
        self.hist.append((self.t, self.th[0], self.th[1], self.y, self.v[0], self.v[1], self.on_ground()))
        if len(self.hist) > 200:
            del self.hist[:100]
        self.trace.append((self.t, self.y - self.ground, self.th[0], self.th[1], not self.on_ground(),
                           self.p[0], self.p[1]))

    def advance(self, s):
        for _ in range(max(1, int(round(s / SUB)))):
            self.step()

    # hw for pilot.lua ----------------------------------------------------
    def read(self):
        self.advance(TICK)  # a tick for the call, and the value is a tick old
        old = self.hist[0]
        for h in self.hist:
            if h[0] <= self.t - TICK:
                old = h
        a, b = old[1], old[2]
        if self.swap:
            a, b = b, a
        v = [cs * old[4] + ce * old[5] for cs, ce in self.sensors]
        # the Altitude Sensor is off the middle: it rises and sinks with the lean;
        # tipped on the legs, the middle itself rises (the pivot is an edge)
        s0, s1 = (math.sin(math.radians(x)) for x in (old[1], old[2]))
        y = old[3] - s0 * self.alt[0] - s1 * self.alt[1]
        if old[6]:
            r0, r1 = (math.sin(math.radians(self.rest[k])) for k in range(2))
            y += self.edge * (abs(s0 - r0) + abs(s1 - r1)) + r0 * self.alt[0] + r1 * self.alt[1]
        return lua.table_from({"a": a * self.flip[0], "b": b * self.flip[1], "y": y, "v": lua.table_from(v)})

    def write(self, fs):
        vals = [float(fs[i + 1] or 0) for i in range(self.n)]
        self.writes.append(vals)
        for i, f in enumerate(vals):
            p, c = P.knobs(f)
            self.cmd[self.perm[i]] = (c + 1) / 100 * p / 15 if p > 0 else 0.0
        # the writes go out in parallel with the next read's tick: one step ~0.1 s

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

    def held(self):
        out = {"f": 0, "r": 0, "u": 0}
        for t0, t1, keys in self.held_plan:
            if t0 <= self.t < t1:
                out.update(keys)
        return lua.table_from(out)

    def hw(self):
        return lua.table_from({"n": self.n, "read": self.read, "write": self.write, "wait": self.wait,
                               "clock": self.clock, "poll": self.poll, "held": self.held})

    def after(self, t0, dt):
        """state at time t0 + dt from the trace"""
        best = self.trace[0]
        for x in self.trace:
            if x[0] <= t0 + dt:
                best = x
            else:
                break
        return best


def calibrate(sim):
    r = P.calibrate(sim.hw())
    return r if isinstance(r, tuple) else (r, None)


def fly(sim, cal, height=4, forward="north", learn=None, alt_side="left"):
    if learn is not None:
        cal.learn = lua.table_from(learn) if isinstance(learn, dict) else learn
    r = P.fly(sim.hw(), cal, lua.table_from({"height": height, "forward": forward, "altSide": alt_side}))
    return r if isinstance(r, tuple) else (r, None)


def window(sim, t0, t1):
    return [x for x in sim.trace if t0 <= x[0] <= t1]


def tilt_max(rows):
    return max((max(abs(x[2]), abs(x[3])) for x in rows), default=99)


def kinds(cal):
    return [cal.t[i + 1].kind for i in range(len(cal.t))]


def ltable(t):
    return {k: t[k] for k in t} if t is not None else {}


# --- knobs & maths ------------------------------------------------------------
check("knobs: zero is off", tuple(P.knobs(0)) == (0, 0))
worst, ok_range = 0, True
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
x = P.solve(lua.eval("{{2,1},{1,3}}"), lua.eval("{3,5}"))
check("solve: 2x2", abs(x[1] - 0.8) < 1e-9 and abs(x[2] - 1.4) < 1e-9, (x[1], x[2]))
mix_cal = lua.eval("""{ t = { {kind='lift',c1=1,c2=0}, {kind='lift',c1=0,c2=-1}, {kind='lift',c1=-1,c2=0},
                             {kind='lift',c1=0,c2=1}, {kind='side'} } }""")
D1, D2 = P.mixer(mix_cal)
check("mixer: + layout, torque on X from N/S only, side thruster untouched",
      [round(D1[i], 3) for i in range(1, 6)] == [0.5, 0, -0.5, 0, 0], [D1[i] for i in range(1, 6)])
check("mixer: no change of total lift", abs(sum(D2[i] for i in range(1, 6))) < 1e-6)

# --- ground scan --------------------------------------------------------------
sim = Sim(**REAL)
cal, why = calibrate(sim)
check("calibrate (+ layout): works", cal is not None, why)
if cal:
    t = [(round(cal.t[i].c1), round(cal.t[i].c2)) for i in range(1, 5)]
    check("calibrate: finds which edge each thruster lifts (N, E, S, W)", t == [(1, 0), (0, -1), (-1, 0), (0, 1)], t)
    check("calibrate: hover guessed within 25%", abs(cal.hover - 0.0137) / 0.0137 < 0.25, cal.hover)
    check("calibrate: all thrusters off, craft flat on its legs", sim.writes[-1] == [0] * 4 and sim.on_ground()
          and abs(sim.th[0]) < 0.5 and abs(sim.th[1]) < 0.5, (sim.writes[-1], sim.th))
    check("calibrate: under 2 minutes", sim.t < 120, sim.t)

cal_x, why = calibrate(Sim(layout="x", **REAL))
check("calibrate (x layout, corners): works", cal_x is not None, why)
if cal_x:
    t = [(round(cal_x.t[i].c1), round(cal_x.t[i].c2)) for i in range(1, 5)]
    check("calibrate: corner thrusters lift two edges at once", t == [(1, -1), (-1, -1), (-1, 1), (1, 1)], t)

cal_s, why = calibrate(Sim(side=[(1, 0), (-1, 0), (0, 0)], **REAL))
check("calibrate: side thrusters found as 'side', one pointing down as 'none'",
      cal_s is not None and kinds(cal_s) == ["lift"] * 4 + ["side", "side", "none"], kinds(cal_s) if cal_s else why)

dead_cal, dead_why = calibrate(Sim(dead=2, **REAL))
check("calibrate: a dead thruster -> cannot level, said why", dead_cal is None and "axis 1" in (dead_why or ""),
      dead_why)
kill_cal, kill_why = calibrate(Sim(events=[(3.0, "kill")], **REAL))
check("calibrate: kill key stops it", kill_cal is None and kill_why == "stopped", kill_why)


# --- first flight: takes off, learns the craft, holds still, lands ------------
def first_flight(name, sim, height=4, land_after=65.0, tilt_ok=8.0, calm_ok=2.0, hold_ok=1.0):
    cal, why = calibrate(sim)
    if not cal:
        check(name + ": calibrated", False, why)
        return None, None, None
    t0 = sim.t
    sim.events = [(t0 + land_after, "land")]
    sim.limit = t0 + land_after + 60
    res, learn = fly(sim, cal, height)
    learn = ltable(learn)
    hold = window(sim, t0 + land_after - 12, t0 + land_after)
    check(name + ": scan finished", learn.get("done"), learn)
    ys = [x[1] for x in hold]
    check(name + ": holds height", ys and max(abs(v - height) for v in ys) < 0.5, (min(ys), max(ys)) if ys else None)
    check(name + ": level while holding (< %g deg)" % calm_ok, tilt_max(hold) < calm_ok, tilt_max(hold))
    check(name + ": never past %g deg" % tilt_ok, tilt_max(window(sim, t0, t0 + land_after)) < tilt_ok,
          tilt_max(window(sim, t0, t0 + land_after)))
    if hold:
        drift = math.hypot(hold[-1][5] - hold[0][5], hold[-1][6] - hold[0][6])
        check(name + ": stays in place (< %g block in 12 s)" % hold_ok, drift < hold_ok, drift)
    check(name + ": lands softly and switches off", res == "landed" and sim.on_ground() and sim.impact < 1.5
          and all(v == 0 for v in sim.writes[-1]), (res, sim.impact, sim.writes[-1]))
    return cal, learn, t0


sim = Sim(dist=EDGE, **REAL)
cal, learn, t0 = first_flight("real platform, player at the edge", sim)
if learn:
    check("learns the turn rate (lever of a thruster) within 35%", abs(learn.get("kref", 0) - 120) / 120 < 0.35,
          learn.get("kref"))
    c = learn.get("c")
    got = [(round(c[i][1]), round(c[i][2])) for i in range(1, 5)] if c else None
    check("learns which way each thruster turns the craft, in the air", got == [(1, 0), (0, -1), (-1, 0), (0, 1)], got)
    check("learns gravity within 25%", abs(learn.get("G", 0) - 9.8) / 9.8 < 0.25, learn.get("G"))
    check("learns the real hover thrust within 10%", abs(learn.get("hover", 0) - 0.0137) / 0.0137 < 0.10,
          learn.get("hover"))
    M = learn.get("Mrows")
    if M and M[1] and M[2]:
        # back sensor measures north (-south), right sensor east: rows ~ [[-gk, 0], [0, gk]]
        gk = 9.8 * math.pi / 180
        check("learns what each speed sensor measures", M[1][1] < -0.7 * gk and M[2][2] > 0.7 * gk
              and abs(M[1][2]) < 0.3 * gk and abs(M[2][1]) < 0.3 * gk, [[M[1][1], M[1][2]], [M[2][1], M[2][2]]])
        check("both directions of speed sensed", learn.get("speedSeen") == 2, learn.get("speedSeen"))
    else:
        check("learns what each speed sensor measures", False, "no rows")


# --- second flight: knows the craft, W/A/S/D --------------------------------
def keys_flight(name, sim, cal, learn, forward="north", side_level=None, hold_ok=1.0, stop_ok=7.5):
    t0 = sim.t
    # W for 6 s, let go, D for 4 s, let go, land
    sim.held_plan = [(t0 + 15, t0 + 21, {"f": 1}), (t0 + 33, t0 + 37, {"r": 1})]
    sim.events = [(t0 + 50, "land")]
    sim.limit = t0 + 110
    res, learned = fly(sim, cal, 4, forward, learn)
    p15, p21, p31 = sim.after(t0, 15), sim.after(t0, 21), sim.after(t0, 31)
    p33, p37, p48 = sim.after(t0, 33), sim.after(t0, 37), sim.after(t0, 48)
    north = -(p21[5] - p15[5])
    check(name + ": W flies forward (north) > 10 blocks", north > 10, north)
    check(name + ": ... and not sideways (< 2 blocks)", abs(p21[6] - p15[6]) < 2, p21[6] - p15[6])
    stop = math.hypot(p31[5] - p21[5], p31[6] - p21[6])
    check(name + ": let go: stops smoothly within %g blocks" % stop_ok, stop < stop_ok, stop)
    east = p37[6] - p33[6]
    check(name + ": D flies right (east) > 5.5 blocks", east > 5.5, east)
    rest = math.hypot(p48[5] - sim.after(t0, 42)[5], p48[6] - sim.after(t0, 42)[6])
    check(name + ": then hangs still (< %g block in 6 s)" % hold_ok, rest < hold_ok, rest)
    if side_level is not None:
        lean = tilt_max(window(sim, t0 + 15, t0 + 21))
        check(name + ": moves on side thrusters, almost level (< %g deg)" % side_level, lean < side_level, lean)
    check(name + ": no new scan, lands", res == "landed", res)


if learn:
    keys_flight("real platform", sim, cal, learn)

# speed sensors put the other way round: the scan sorts it out
sim = Sim(sensors=((0, -1), (1, 0)), **REAL)
cal2, learn2, _ = first_flight("speed sensors swapped and reversed", sim)
if learn2:
    keys_flight("speed sensors swapped and reversed", sim, cal2, learn2)

# other forward: facing east, W goes east
sim = Sim(**REAL)
cal3, learn3, _ = first_flight("plain", sim)
if learn3:
    t0 = sim.t
    sim.held_plan = [(t0 + 15, t0 + 20, {"f": 1})]
    sim.events = [(t0 + 30, "land")]
    sim.limit = t0 + 90
    res, _ = fly(sim, cal3, 4, "east", learn3)
    check("forward = east: W goes east", sim.after(t0, 20)[6] - sim.after(t0, 15)[6] > 8,
          sim.after(t0, 20)[6] - sim.after(t0, 15)[6])

# where is the screen? The first flight finds the Altitude Sensor (it hangs on a
# known side of the computer) from how it rises and sinks as the craft leans
for alt, side, kw, want in [((0.0, 1.0), "left", {}, "north"), ((0.0, 1.0), "right", {}, "south"),
                            ((1.0, 0.0), "left", {}, "east"), ((-1.0, 0.0), "back", {}, "north"),
                            ((1.0, 0.0), "left", {"rest": (9.6, 0.0), "dist": EDGE}, "east")]:
    sim = Sim(alt=alt, **kw, **REAL)
    c, _ = calibrate(sim)
    t0 = sim.t
    sim.events = [(t0 + 60, "land")]
    sim.limit = t0 + 120
    res, lr = fly(sim, c, 4, None, None, side)
    lr = ltable(lr)
    loc = lr.get("alt")
    where = "%s%s" % (alt, " on uneven ground + player at the edge" if kw else "")
    check("first flight finds the Altitude Sensor at %s (within 0.3 block)" % where,
          loc and abs(loc[1] - alt[0]) < 0.3 and abs(loc[2] - alt[1]) < 0.3, (loc[1], loc[2]) if loc else None)
    check("... on the computer's %s side: W flies %s" % (side, want), lr.get("forward") == want, lr.get("forward"))
check("forward: sensor in the middle or on top -> cannot tell",
      P.forwardFrom(lua.eval("{0.1, -0.2}"), "left") is None and P.forwardFrom(lua.eval("{0, 1}"), "top") is None)

# both speed sensors along one direction (as on the real craft): one direction
# sensed, the other from physics; it still flies, stops and holds
sim = Sim(sensors=((-1, 0), (-1, 0)), **REAL)
cal_same, learn_same, _ = first_flight("both speed sensors along one direction", sim, tilt_ok=8.0)
if learn_same:
    check("same-direction speed sensors: knows it sees one direction", learn_same.get("speedSeen") == 1,
          learn_same.get("speedSeen"))
    # one direction is worked out, not measured: it holds, less exactly
    keys_flight("both speed sensors along one direction", sim, cal_same, learn_same, hold_ok=3.0)

# no speed sensors at all: speed from physics alone
sim = Sim(sensors=(), dist=EDGE, **REAL)
cal_none, learn_none, _ = first_flight("no speed sensors at all", sim, tilt_ok=8.0, hold_ok=2.5)
if learn_none:
    keys_flight("no speed sensors at all", sim, cal_none, learn_none, hold_ok=3.0)

# calibrated on uneven ground (the real log): N and W tipped the craft over a
# diagonal at half the thrust. The in-air scan has to measure the truth.
sim = Sim(dist=EDGE, **REAL)
cal_r, _ = calibrate(sim)
cal_r.t[1].c1, cal_r.t[1].c2, cal_r.t[1].tip = 1.0, 0.98, cal_r.t[1].tip / 2
cal_r.t[4].c1, cal_r.t[4].c2, cal_r.t[4].tip = 0.98, 1.0, cal_r.t[4].tip / 2
cal_r.hover = cal_r.hover * 0.75
t0 = sim.t
sim.events = [(t0 + 65, "land")]
sim.limit = t0 + 130
res, learn_r = fly(sim, cal_r)
learn_r = ltable(learn_r)
c = learn_r.get("c")
got = [(round(c[i][1]), round(c[i][2])) for i in range(1, 5)] if c else None
check("uneven-ground calibration: the air scan finds the true levers", got == [(1, 0), (0, -1), (-1, 0), (0, 1)], got)
check("uneven-ground calibration: level while holding (< 2 deg)", tilt_max(window(sim, t0 + 53, t0 + 65)) < 2,
      tilt_max(window(sim, t0 + 53, t0 + 65)))
check("uneven-ground calibration: lands", res == "landed", res)

# stands 9.6 deg leaned on uneven ground (the third real flight): no jolt at liftoff
sim = Sim(rest=(9.6, 0.0), **REAL)
cal_u, _ = calibrate(sim)
t0 = sim.t
sim.events = [(t0 + 20, "land")]
sim.limit = t0 + 80
res, _ = fly(sim, cal_u, 4, "north", {"done": True, "kref": 120, "hover": 0.0137, "G": 9.8, "v": 3})
air = [x for x in window(sim, t0, t0 + 20) if x[4]]
swing = min((x[2] for x in air), default=0)
rates = [abs(b[2] - a[2]) / (b[0] - a[0]) for a, b in zip(air[::20], air[20::20])]
check("takeoff from a 9.6 deg lean: levels gently (< 8 deg/s, then brakes softly: no swing past -7)",
      air and max(rates) < 8 and swing > -7, (max(rates) if rates else None, swing))

# corners
sim = Sim(layout="x", dist=EDGE, **REAL)
# hover is guessed for edge thrusters (2.5x), corners tip later: a harder takeoff
first_flight("x layout (corner thrusters) + edge", sim, tilt_ok=10.0)

# side thrusters: the craft moves without leaning
sim = Sim(side=[(-1, 0), (0, 1), (1, 0), (0, -1)], **REAL)
cal4, learn4, _ = first_flight("with 4 side thrusters", sim, land_after=75.0)  # 4 more tests
if learn4:
    sides = learn4.get("side") or {}
    check("scan finds all 4 side thrusters", len(list(sides.keys())) == 4, ltable(sides))
    keys_flight("with 4 side thrusters", sim, cal4, learn4, side_level=3.0, stop_ok=8.0)

# robustness: crafts the guesses do not fit; the scan has to fix it
for name, kw in [("heavy to turn (K 40)", {"K": 40.0, "hov": 0.0137, "dist": EDGE}),
                 ("light to turn (K 250)", {"K": 250.0, "hov": 0.0137, "dist": EDGE}),
                 ("thrust lags 0.1 s", {"tau": 0.1, "dist": EDGE, **REAL}),
                 # gravity: the scan measured 9.97 in the game, so 9.8 +- a little is enough
                 ("gravity 12", {"grav": 12.0, "K": 150.0, "hov": 0.0137, "dist": EDGE}),
                 ("strong thrusters (hover 1%)", {"hov": 0.01, "K": 120.0, "dist": EDGE}),
                 ("weak thrusters (hover 20%)", {"hov": 0.2, "K": 120.0, "dist": EDGE}),
                 ("names shuffled, gimbal axes swapped and flipped",
                  {"perm": (2, 0, 3, 1), "swap": True, "flip": (-1, 1), "dist": EDGE, **REAL})]:
    first_flight(name, Sim(**kw), tilt_ok=16.0, calm_ok=3.0)

# heavier than calibrated: the hover it learns in the air wins
sim = Sim(**REAL)
cal6, _ = calibrate(sim)
sim.hov = 0.0137 * 1.4
t0 = sim.t
sim.events = [(t0 + 65, "land")]
sim.limit = t0 + 120
res, learn6 = fly(sim, cal6)
learn6 = ltable(learn6)
check("40% heavier than calibrated: learns the new hover (within 10%)",
      abs(learn6.get("hover", 0) - 0.0137 * 1.4) / (0.0137 * 1.4) < 0.1, learn6.get("hover"))
check("40% heavier: lands", res == "landed", res)

# an old saved scan with a broken speed-sensor map must not steer the takeoff
sim = Sim(**REAL)
cal_old, _ = calibrate(sim)
t0 = sim.t
sim.events = [(t0 + 65, "land")]
sim.limit = t0 + 130
res, learn_old = fly(sim, cal_old, 4, "north", {"done": True, "k1": 60, "k2": 103, "M": lua.eval("{{0.157,0.002},{0.157,0.0021}}")})
drift = math.hypot(sim.after(t0, 15)[5], sim.after(t0, 15)[6])
check("old saved scan is ignored: rescans, no runaway on takeoff", ltable(learn_old).get("kref") and drift < 6
      and res == "landed", (drift, res))

# a held Up key: the goal stops at +30
sim = Sim(**REAL)
cal7, _ = calibrate(sim)
t0 = sim.t
sim.events = [(t0 + 5 + i * 0.05, "up") for i in range(200)] + [(t0 + 20, "land")]
sim.limit = t0 + 200
res, _ = fly(sim, cal7, 4, "north", {"done": True, "kref": 120, "v": 3})
check("goal never above +30 blocks", max(x[1] for x in window(sim, t0, sim.t)) < 31,
      max(x[1] for x in window(sim, t0, sim.t)))

# kill in flight
sim = Sim(**REAL)
cal8, _ = calibrate(sim)
t0 = sim.t
sim.events = [(t0 + 12, "kill")]
res, _ = fly(sim, cal8)
check("kill in flight: stopped, all off at once", res == "stopped" and sim.writes[-1] == [0] * 4
      and sim.t - (t0 + 12) < 0.4, (res, sim.writes[-1], sim.t - t0 - 12))

# wrong calibration (gimbal flipped after it): the safety cut fires before a flip
sim = Sim(**REAL)
cal9, _ = calibrate(sim)
sim.flip, sim.dist = (-1, 1), EDGE
t0 = sim.t
sim.limit = t0 + 60
res, _ = fly(sim, cal9)
peak = tilt_max(window(sim, t0, sim.t))
check("bad calibration: tilt cut, all off, before 45 deg", res == "tilt" and sim.writes[-1] == [0] * 4 and peak < 45,
      (res, peak))

# --- the game program itself (programs/pilot/pilot.lua) with fake CC APIs ----
PROG = (ROOT / "programs" / "pilot" / "pilot.lua").read_text()
LIB = (ROOT / "lib" / "pilot.lua").read_text()
KEYS = {"w": 17, "s": 31, "a": 30, "d": 32, "space": 57, "leftShift": 42, "up": 200, "down": 208, "l": 38, "q": 16}
FAKE = lua.eval(r"""function(prog, lib, thr, speeds, call, angles, height, speed, wait, clock, files, out, events, keys, arg, arg2)
  local fsys = {
    exists = function(p) return files[p] ~= nil end,
    open = function(p, mode)
      if mode == "r" then return { readAll = function() return files[p] end, close = function() end } end
      local buf = {}
      return { write = function(s) buf[#buf+1] = s end, writeLine = function(s) buf[#buf+1] = s .. "\n" end,
               flush = function() files[p] = table.concat(buf) end, close = function() files[p] = table.concat(buf) end }
    end }
  local types = { top = "gimbal_sensor", left = "altitude_sensor", bottom = "modem" }
  for _, n in ipairs(speeds) do types[n] = "velocity_sensor" end
  local per = {
    getNames = function()
      local t = { "top", "left", "bottom" }
      for _, n in ipairs(speeds) do t[#t+1] = n end
      for _, n in ipairs(thr) do t[#t+1] = n end
      return t
    end,
    getType = function(n) return types[n] or "creative_thruster" end,
    getMethods = function(n) return { "setPower", "setThrustConfig", "getPower" } end,
    find = function(t)
      if t == "gimbal_sensor" then return { getAngles = angles, side = "top" } end
      if t == "altitude_sensor" then return { getHeight = height, side = "left" } end
    end,
    getName = function(obj) return obj.side end,
    call = function(n, m, ...) if m == "getVelocity" then return speed(n) end return call(n, m, ...) end }
  -- The key listener runs as a coroutine resumed after each sleep; it must not
  -- call Python itself (lupa), so the time comes in through NOW.
  local NOW, keyco = 0, nil
  local function pullEvent()
    while true do
      local e = events[1]
      if e and NOW >= e[1] then
        table.remove(events, 1)
        if e[2] == "terminate" then error("Terminated", 0) end
        return e[2], keys[e[3]], e[4]
      end
      coroutine.yield()
    end
  end
  local function pump()
    if keyco and coroutine.status(keyco) ~= "dead" then
      NOW = clock()
      local ok, err = coroutine.resume(keyco)
      if not ok then error(err, 0) end
    end
  end
  local env = setmetatable({
    peripheral = per, fs = fsys, keys = keys,
    sleep = function(s) wait(s); pump() end,
    os = { clock = clock, pullEvent = pullEvent },
    parallel = {
      waitForAll = function(...) for _, f in ipairs({...}) do f() end end,
      waitForAny = function(job, listener)
        keyco = coroutine.create(listener)
        pump()
        job()
        keyco = nil
        return 1
      end },
    term = { clear = function() end, setCursorPos = function() end, clearLine = function() end,
             write = function() end, setTextColor = function() end },
    colors = { red = 1, white = 2, yellow = 4 },
    textutils = { serialize = function(t)
        local function ser(v)
          if type(v) == "table" then
            local o = {}
            for k, x in pairs(v) do
              o[#o+1] = "[" .. (type(k) == "string" and ("%q"):format(k) or tostring(k)) .. "]=" .. ser(x)
            end
            return "{" .. table.concat(o, ",") .. "}"
          elseif type(v) == "string" then return ("%q"):format(v)
          elseif type(v) == "boolean" then return tostring(v) end
          return ("%.17g"):format(v)
        end
        return ser(t) end,
      unserialize = function(s) return load("return " .. s)() end },
    print = function(s) out[#out+1] = tostring(s) end,
    require = function() return load(lib, "pilot.lua")() end,
  }, { __index = _G })
  return load(prog, "pilot", "t", env)(arg, arg2)
end""")


def run_program(sim, files, events=(), arg=None, arg2=None):
    thr = ["creative_thruster_%d" % i for i in range(4, 4 + sim.n)]
    speeds = ["back", "right"][:len(sim.sensors)]
    st = {"p": [0] * sim.n, "c": [0] * sim.n}
    snap = {}

    def call(name, method, *a):
        i = thr.index(name)
        if method == "setPower":
            st["p"][i] = int(a[0])
        elif method == "setThrustConfig":
            st["c"][i] = int(a[0])
        f = (st["c"][i] + 1) / 100 * st["p"][i] / 15 if st["p"][i] > 0 else 0.0
        sim.cmd[sim.perm[i]] = f

    def angles():
        r = sim.read()
        snap["r"] = r
        return lua.table_from([r.a, r.b])

    def height():
        return snap["r"].y if "r" in snap else sim.ground

    def speed(n):
        return snap["r"].v[speeds.index(n) + 1] if "r" in snap else 0.0

    ev = lua.table_from([lua.table_from(list(e)) for e in sorted(events)])
    out = lua.table_from([])
    FAKE(PROG, LIB, lua.table_from(thr), lua.table_from(speeds), call, angles, height, speed, sim.wait, sim.clock,
         files, out, ev, lua.table_from(KEYS), arg, arg2)
    return [out[i] for i in range(1, len(out) + 1)]


files = lua.table_from({})
sim = Sim(dist=EDGE, **REAL)
out = run_program(sim, files, arg="calibrate")
check("program: calibrate saves /.pilot with the thruster names",
      files["/.pilot"] is not None and "creative_thruster_4" in (files["/.pilot"] or ""), out)
check("program: calibrate says which side each thruster lifts",
      any("creative_thruster_4" in l and "lifts N side" in l for l in out)
      and any("creative_thruster_5" in l and "lifts E side" in l for l in out), out)
# first flight: takeoff, scan, W held 5 s (the key repeats), L lands
t0 = sim.t
w = [(t0 + 50, "key", "w", False)] + [(t0 + 50.3 + 0.3 * i, "key", "w", True) for i in range(16)] + \
    [(t0 + 55, "key_up", "w", False), (t0 + 70, "key", "l", False)]
out = run_program(sim, files, events=w)
north = -(sim.after(t0, 55)[5] - sim.after(t0, 50)[5])
check("program: W flies north (keys through real events)", north > 5, (north, out))
check("program: L lands, thrusters off", any("landed" in l for l in out) and all(c == 0 for c in sim.cmd), out)
check("program: saves what it learned", "learn" in (files["/.pilot"] or "") and any("Learned" in l for l in out), out)
log = (files["/pilot.log"] or "").splitlines()
check("program: /pilot.log has thrusts and speeds", len(log) > 100 and "|" in log[1], log[:2])
# a key held while the screen closes: no key_up, the repeats stop -> it lets go
t0 = sim.t
w = [(t0 + 15, "key", "w", False), (t0 + 30, "key", "l", False)]
out = run_program(sim, files, events=w)
moved = math.hypot(sim.after(t0, 29)[5] - sim.after(t0, 15)[5], sim.after(t0, 29)[6] - sim.after(t0, 15)[6])
check("program: second flight needs no scan, a stuck W lets go by itself", moved < 6 and
      any("landed" in l for l in out), (moved, out))
# Ctrl+T in the air: all off
t0 = sim.t
out = run_program(sim, files, events=[(t0 + 15, "terminate", None, False)])
check("program: Ctrl+T -> all thrusters off", any("Terminated" in l for l in out) and all(c == 0 for c in sim.cmd),
      (out, sim.cmd))
# any other key = all off
t0 = sim.t
out = run_program(sim, files, events=[(t0 + 15, "key", "q", False)])
check("program: any other key -> all off", any("stopped" in l for l in out) and all(c == 0 for c in sim.cmd), out)
# the computer turned the other way (screen west): calibrate finds it, W flies east
sim3 = Sim(alt=(1.0, 0.0), **REAL)  # Altitude Sensor on the computer's left = south of the middle
files3 = lua.table_from({})
run_program(sim3, files3, arg="calibrate")
t0 = sim3.t
out3 = run_program(sim3, files3, events=[(t0 + 60, "key", "l", False)])
check("program: first flight finds the screen side by itself", any("W flies east" in l for l in out3), out3)
t0 = sim3.t
w = [(t0 + 15, "key", "w", False)] + [(t0 + 15.3 + 0.3 * i, "key", "w", True) for i in range(16)] + \
    [(t0 + 20, "key_up", "w", False), (t0 + 35, "key", "l", False)]
out3 = run_program(sim3, files3, events=w)
east = sim3.after(t0, 21)[6] - sim3.after(t0, 15)[6]
check("program: ... and on the next flight W flies east", east > 4, (east, out3))

# re-assembled: thruster names changed
sim2 = Sim(**REAL)
sim2_files = lua.table_from({"/.pilot": (files["/.pilot"] or "").replace("creative_thruster_4", "creative_thruster_9")})
out = run_program(sim2, sim2_files)
check("program: renamed thrusters -> asks to calibrate, does not fly", any("calibrate" in l for l in out)
      and all(c == 0 for c in sim2.cmd), out)

# =============================================================================
failed = [x for x in results if not x[1]]
for name, good, d in results:
    print(("PASS " if good else "FAIL ") + name + ("" if good else f"   -> {d}"))
print(f"\n{len(results) - len(failed)}/{len(results)} passed")
sys.exit(1 if failed else 0)
