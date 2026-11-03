"""Tests for common/navigate.lua in the simulated world.

Run from the project root:
    .venv/bin/python tests/test_navigate.py
"""
import sys
from pathlib import Path
from lupa import LuaRuntime

HERE = Path(__file__).resolve().parent
MOCK = (HERE / "mock.lua").read_text()
NAV = (HERE.parent / "common" / "navigate.lua").read_text()


def make():
    lua = LuaRuntime(unpack_returned_tuples=True)
    W = lua.execute(MOCK)
    W.fuel = 2000
    nav = lua.eval("function(s) return load(s, 'navigate.lua')() end")(NAV)
    scan = lua.eval("function(W) return function(r) return W.scanBlocks(r) end end")(W)
    return lua, W, nav, scan


def inv_has(W, name):
    return any(W.inv[i] and W.inv[i].name == name for i in range(1, 17))


results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


def first(x):
    # travel()/calibrate() return (false, err) on failure; lupa gives a tuple.
    return x[0] if isinstance(x, tuple) else x


# 1. Calibration: the turtle works out which way it faces.
lua, W, nav, scan = make()
W.h = 1  # really facing +z (south); the turtle does not know this yet
W.set(5, 0, 0, "minecraft:iron_ore")
W.set(0, 0, 6, "minecraft:iron_ore")
nav.reset()
ok, h = nav.calibrate(scan)
check("calibrate succeeds", ok, h)
check("calibrate finds the real heading", ok and h == 1, h)
x, y, z, hh = nav.pos()
check("calibrate tracks the step it took", (x, y, z, hh) == (0, 0, 1, 1), (x, y, z, hh))

# 1b. Many same-named ores: voting must still find the real heading.
# (face east, away from the chest the mock parks at -1,0,0)
lua, W, nav, scan = make()
W.h = 0  # facing +x (east)
for cx, cz in [(3, 0), (4, 1), (2, -2), (5, 0), (6, -1), (3, 3)]:
    W.set(cx, 0, cz, "minecraft:coal_ore")
nav.reset()
ok, h = nav.calibrate(scan)
check("calibrate robust with many identical ores", ok and h == 0, (ok, h))

# 2. Go to an ore: dig a straight path and mine it.
lua, W, nav, scan = make()
nav.reset(0, 0, 0, 0)  # facing +x (east), known
W.set(3, 0, 0, "minecraft:iron_ore")
ok = nav.travel(3, 0, 0)
check("goto reaches the ore", ok and (W.pos.x, W.pos.y, W.pos.z) == (3, 0, 0), (ok, W.pos.x, W.pos.z))
check("ore mined into inventory", W.get(3, 0, 0) is None and inv_has(W, "minecraft:raw_iron"),
      (W.get(3, 0, 0), inv_has(W, "minecraft:raw_iron")))

# 3. A protected block stops the path, unbroken.
lua, W, nav, scan = make()
nav.reset(0, 0, 0, 0)
W.set(2, 0, 0, "computercraft:computer_advanced")
W.set(3, 0, 0, "minecraft:iron_ore")
ok = first(nav.travel(3, 0, 0))
check("goto refuses to break a computer", (not ok) and W.get(2, 0, 0) == "computercraft:computer_advanced"
      and W.pos.x == 1, (ok, W.get(2, 0, 0), W.pos.x))

# 4. Round trip: go out, come back home.
lua, W, nav, scan = make()
nav.reset(0, 0, 0, 0)
W.set(3, -2, 1, "minecraft:iron_ore")
check("goto with a 3D target", nav.travel(3, -2, 1) and (W.pos.x, W.pos.y, W.pos.z) == (3, -2, 1),
      (W.pos.x, W.pos.y, W.pos.z))
check("goto back to start", nav.travel(0, 0, 0) and (W.pos.x, W.pos.y, W.pos.z) == (0, 0, 0),
      (W.pos.x, W.pos.y, W.pos.z))

# 5. Calibration step turns away from a blocked side (the mock's chest at -1,0,0).
lua, W, nav, scan = make()
W.h = 2  # facing the chest
moved = first(nav.probeAnyDir())
check("probeAnyDir turns past the chest and still moves",
      moved and (W.pos.x, W.pos.y, W.pos.z) != (0, 0, 0) and W.get(-1, 0, 0) == "minecraft:chest",
      (moved, W.pos.x, W.pos.z))

# 6. Deposit: drop non-fuel into the adjacent chest, keep fuel.
lua, W, nav, scan = make()
W.inv[1] = lua.table_from({"name": "minecraft:raw_iron", "count": 3})
W.inv[2] = lua.table_from({"name": "minecraft:coal", "count": 5})
dropped = nav.deposit()
check("deposit unloads ore into the chest", dropped and W.chest["minecraft:raw_iron"] == 3,
      (dropped, W.chest["minecraft:raw_iron"] if dropped else None))
check("deposit keeps the fuel", inv_has(W, "minecraft:coal"))

# 7. Vein mining: clear a whole connected clump and come back to the start.
lua, W, nav, scan = make()
nav.reset(0, 0, 0, 0)  # on the just-dug target cell (air), neighbours are ore
vein = [(1, 0, 0), (2, 0, 0), (1, -1, 0), (1, 0, 1)]
for c in vein:
    W.set(*c, "minecraft:iron_ore")
mined = nav.mineVein()
remaining = [c for c in vein if W.get(*c) == "minecraft:iron_ore"]
check("mineVein clears the whole vein", mined == 4 and not remaining, (mined, remaining))
check("mineVein returns to the start cell", (W.pos.x, W.pos.y, W.pos.z) == (0, 0, 0),
      (W.pos.x, W.pos.y, W.pos.z))

# 8. Deposit keeps the scanner and fuel, drops only the loot.
lua, W, nav, scan = make()
W.inv[1] = lua.table_from({"name": "advancedperipherals:geo_scanner", "count": 1})
W.inv[2] = lua.table_from({"name": "minecraft:raw_iron", "count": 4})
W.inv[3] = lua.table_from({"name": "minecraft:coal", "count": 5})
nav.deposit()
check("deposit keeps the geo scanner", inv_has(W, "advancedperipherals:geo_scanner"))
check("deposit unloads only the ore", W.chest["minecraft:raw_iron"] == 4,
      W.chest["minecraft:raw_iron"])
check("deposit keeps fuel too", inv_has(W, "minecraft:coal"))

# 9. Mine-area: the grid clears EVERY ore in the area, including isolated clumps
#    far from the rest that the old "hop to nearest" would never reach.
lua, W, nav, scan = make()
W.h = 1
W.fuel = 40000
area_ores = [(3, 0, 0), (3, 0, 1),  # near cluster
             (10, 0, 2),            # mid
             (0, 0, -11),           # isolated, far north
             (0, 0, 11),            # isolated, far south
             (8, 0, 9),             # corner
             (2, -4, 3)]            # a bit deep (above the mock's bedrock at y<=-5)
for c in area_ores:
    W.set(*c, "minecraft:iron_ore")
nav.reset()
nav.calibrate(scan)
mined, reason = nav.mineArea(scan, 12)
left = [c for c in area_ores if W.get(*c) == "minecraft:iron_ore"]
check("mineArea grid clears every ore, isolated clumps too", not left, (mined, reason, left))
check("mineArea ends back home", (W.pos.x, W.pos.y, W.pos.z) == (0, 0, 0),
      (W.pos.x, W.pos.y, W.pos.z))

# 9b. Centered harvest (what a map tap sends): clear the cluster at a far point,
#     leave ore outside that small radius alone, come home.
lua, W, nav, scan = make()
W.h = 1
W.fuel = 40000
cluster = [(10, 0, 0), (10, 0, 1), (11, 0, 0), (9, -1, 0)]
for c in cluster:
    W.set(*c, "minecraft:iron_ore")
W.set(3, 0, 0, "minecraft:iron_ore")   # near home, so calibration has something to see
W.set(0, 0, 11, "minecraft:iron_ore")  # far from the cluster -> must be left
nav.reset()
nav.calibrate(scan)
center_opts = lua.eval("function(x, y, z) return { center = { x = x, y = y, z = z } } end")(10, 0, 0)
nav.mineArea(scan, 4, center_opts)
check("centered harvest clears the tapped cluster",
      all(W.get(*c) != "minecraft:iron_ore" for c in cluster),
      [c for c in cluster if W.get(*c) == "minecraft:iron_ore"])
check("centered harvest leaves ore outside its radius", W.get(0, 0, 11) == "minecraft:iron_ore")
check("centered harvest ends home", (W.pos.x, W.pos.y, W.pos.z) == (0, 0, 0))

# 9c. onProgress feeds the live map: called with remaining ore + position.
lua, W, nav, scan = make()
W.h = 1
W.fuel = 20000
W.set(3, 0, 0, "minecraft:iron_ore")
W.set(5, 0, 2, "minecraft:iron_ore")
lua.execute("REPORTS = {}")
onprog = lua.eval("function(ores, pos) REPORTS[#REPORTS + 1] = #ores end")
nav.reset()
nav.calibrate(scan)
nav.mineArea(scan, 8, lua.table_from({"onProgress": onprog}))
check("onProgress fires during harvest", lua.eval("#REPORTS") > 0, lua.eval("#REPORTS"))
check("onProgress ends with nothing remaining", lua.eval("#REPORTS > 0 and REPORTS[#REPORTS] or -1") == 0,
      lua.eval("#REPORTS > 0 and REPORTS[#REPORTS] or -1"))

# 9d. shouldStop (what `stop` sends) aborts the harvest but the turtle still comes home.
lua, W, nav, scan = make()
W.h = 1
W.fuel = 20000
for c in [(3, 0, 0), (5, 0, 2), (7, 0, -2)]:
    W.set(*c, "minecraft:iron_ore")
lua.execute("STOPN = 0")
stopfn = lua.eval("function() STOPN = STOPN + 1; return STOPN > 2 end")
nav.reset()
nav.calibrate(scan)
mined, reason = nav.mineArea(scan, 10, lua.table_from({"shouldStop": stopfn}))
check("shouldStop aborts the harvest", reason == "stopped", reason)
check("stopped harvest still returns home", (W.pos.x, W.pos.y, W.pos.z) == (0, 0, 0))

# 9e. onMove streams position during movement (smooth live map); onHoming fires
#     once, right before the turtle heads home.
lua, W, nav, scan = make()
W.h = 1
W.fuel = 20000
W.set(5, 0, 0, "minecraft:iron_ore")
lua.execute("MOVES = 0; HOMING = 0")
onmove = lua.eval("function(pos) MOVES = MOVES + 1 end")
onhoming = lua.eval("function() HOMING = HOMING + 1 end")
nav.reset()
nav.calibrate(scan)
nav.mineArea(scan, 8, lua.table_from({"onMove": onmove, "onHoming": onhoming}))
check("onMove fires while moving", lua.eval("MOVES") > 0, lua.eval("MOVES"))
check("onHoming fires once before homeward", lua.eval("HOMING") == 1, lua.eval("HOMING"))

# 9f. A connected vein is cleared whole by one mineVein. The live map must not go
#     on showing the vein's other blocks as un-mined ghosts.
lua, W, nav, scan = make()
W.h = 1
W.fuel = 20000
vein = [(4, 0, 0), (5, 0, 0), (4, 0, 1), (4, -1, 0)]
for c in vein:
    W.set(*c, "minecraft:iron_ore")
W.set(2, 0, 0, "minecraft:iron_ore")  # calibration ore near home
lua.execute("LASTREM = -1")
onprog = lua.eval("function(ores, pos) LASTREM = #ores end")
nav.reset()
nav.calibrate(scan)
nav.mineArea(scan, 8, lua.table_from({"onProgress": onprog}))
check("vein leaves no ghost ores on the map", lua.eval("LASTREM") == 0, lua.eval("LASTREM"))
check("vein fully cleared in the world",
      all(W.get(*c) != "minecraft:iron_ore" for c in vein),
      [c for c in vein if W.get(*c) == "minecraft:iron_ore"])

# 11. Compass by the chest: no step, no ores needed, ends facing the chest.
lua, W, nav, scan = make()
W.scanAll = True
W.h = 3  # facing north; the mock's chest is west (-1,0,0)
nav.reset()
ok, h = nav.calibrateByChest(scan(8))
check("chest compass finds the heading", ok and h == 2 and W.h == 2, (ok, h, W.h))
check("chest compass does not move", W.moves == 0 and (W.pos.x, W.pos.y, W.pos.z) == (0, 0, 0))
lua, W, nav, scan = make()
W.scanAll = True
W.chestPos = "99,99,99"  # no chest
nav.reset()
check("chest compass reports a missing chest", first(nav.calibrateByChest(scan(8))) is False)

# 12. Regression: unloading at the chest must not scramble the heading.
lua, W, nav, scan = make()
W.h = 0
nav.reset(0, 0, 0, 0)  # facing east, chest west: deposit has to turn
W.inv[1] = lua.table_from({"name": "minecraft:raw_iron", "count": 2})
nav.deposit()
nav.travel(3, 0, 2)
check("heading survives a deposit", (W.pos.x, W.pos.y, W.pos.z) == (3, 0, 2), (W.pos.x, W.pos.z))

# 13. A full inventory mid-harvest: unload, go back, finish, end home.
lua, W, nav, scan = make()
W.scanAll = True
W.fuel = 40000
for i in range(1, 16):  # 15 slots of loot that is not junk
    W.inv[i] = lua.table_from({"name": f"minecraft:loot_{i}", "count": 1})
ores = [(4, 0, 2), (-3, 0, 5), (6, -2, -4)]
for c in ores:
    W.set(*c, "minecraft:iron_ore")
nav.reset()
nav.calibrateByChest(scan(8))
W.scanAll = False
mined, reason = nav.mineArea(scan, 8)
check("full inventory: unloads into the chest", W.chest["minecraft:loot_1"] == 1, reason)
check("full inventory: still clears every ore",
      all(W.get(*c) != "minecraft:iron_ore" for c in ores), (mined, reason))
check("full inventory: ends home", (W.pos.x, W.pos.y, W.pos.z) == (0, 0, 0), (W.pos.x, W.pos.y, W.pos.z))

# 14. Lost: the chest is not where calibration saw it -> deposit says so.
lua, W, nav, scan = make()
W.scanAll = True
nav.reset()
nav.calibrateByChest(scan(8))
W.chestPos = "99,99,99"
ok, why = nav.deposit()
check("deposit reports lost when the chest is gone", ok is False and "lost" in why, why)

# 15. Ore filter: harvest only diamonds, leave the iron.
lua, W, nav, scan = make()
W.h = 1
W.fuel = 20000
W.set(3, 0, 0, "minecraft:iron_ore")
W.set(4, 0, 3, "minecraft:diamond_ore")
nav.reset()
nav.calibrate(scan)
nav.mineArea(scan, 8, lua.table_from({"only": "diamond"}))
check("ore filter mines the diamond", W.get(4, 0, 3) != "minecraft:diamond_ore")
check("ore filter leaves the iron", W.get(3, 0, 0) == "minecraft:iron_ore")

# 16. Scans on the go: the turtle scans while walking, without waiting.
lua, W, nav, scan = make()
W.h = 1
W.fuel = 40000
W.set(3, 0, 0, "minecraft:iron_ore")
W.set(10, -6 + 2, 9, "minecraft:iron_ore")
lua.execute("QUICK = 0")
qscan = lua.eval("function(W) return function(r, quick) if quick then QUICK = QUICK + 1 end return W.scanBlocks(r) end end")(W)
nav.reset()
nav.calibrate(scan)
nav.mineArea(qscan, 12)
check("scans on the go while walking", lua.eval("QUICK") > 0, lua.eval("QUICK"))

# 17. dropJunk throws stone away and keeps loot.
lua, W, nav, scan = make()
W.inv[1] = lua.table_from({"name": "minecraft:cobblestone", "count": 64})
W.inv[2] = lua.table_from({"name": "minecraft:raw_iron", "count": 3})
nav.dropJunk()
check("dropJunk drops cobblestone", not W.inv[1] and W.dropped == 64)
check("dropJunk keeps the ore", inv_has(W, "minecraft:raw_iron"))

# 10. ensureFuel burns coal from the inventory when fuel runs low.
lua, W, nav, scan = make()
W.fuel = 5
W.inv[1] = lua.table_from({"name": "minecraft:coal", "count": 10})
nav.ensureFuel(400)
check("ensureFuel refuels from mined coal", W.fuel >= 400, W.fuel)

width = max(len(n) for n, _, _ in results)
for n, good, d in results:
    print(("PASS " if good else "FAIL ") + n.ljust(width) + ("" if good else f"  -> {d}"))
print(f"\n{sum(g for _, g, _ in results)}/{len(results)} passed")
sys.exit(0 if all(g for _, g, _ in results) else 1)
