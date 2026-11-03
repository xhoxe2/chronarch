"""Tests for turtle/mine.lua in a simulated CC:Tweaked world.

Run from the project root:   python3 tests/run_tests.py
Needs:                       pip install lupa
"""
import sys
from pathlib import Path
from lupa import LuaRuntime

HERE = Path(__file__).resolve().parent
MINE_PATH = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / "turtle" / "mine.lua"
MINE = MINE_PATH.read_text()
MOCK = (HERE / "mock.lua").read_text()


def make():
    lua = LuaRuntime(unpack_returned_tuples=True)
    W = lua.execute(MOCK)
    return lua, W


def run(lua, W, *args):
    runner = lua.eval("""function(src, ...)
        local fn, err = load(src, "mine.lua")
        if not fn then return false, err end
        local ok, e = pcall(fn, ...)
        return ok, tostring(e)
    end""")
    ok, err = runner(MINE, *[str(a) for a in args])
    out = [W.out[i] for i in range(1, len(W.out) + 1)]
    return ok, err, out


def setup_inv(lua, W, items):
    for slot, (name, n) in items.items():
        W.inv[slot] = lua.table_from({"name": name, "count": n})


def chest(W):
    return {k: v for k, v in W.chest.items()}


def pos(W):
    return (W.pos.x, W.pos.y, W.pos.z, W.h)


def remaining_ores(lua, W, coords):
    return [c for c in coords if W.get(*c) and W.ORE[W.get(*c)]]


results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


# 1. Basic run: veins in every direction, falling gravel, unreachable ore
lua, W = make()
setup_inv(lua, W, {1: ("minecraft:coal", 10)})
ores = [(5, 1, 1), (5, 2, 1), (6, 2, 1), (6, 3, 1),        # iron vein off the upper wall
        (10, -1, 0), (10, -2, 0), (10, -3, 0), (10, -4, 0),  # coal going down to bedrock
        (12, 0, -1),                                         # diamond, left wall
        (15, 2, 0)]                                          # above the upper block
names = ["minecraft:iron_ore"] * 4 + ["minecraft:coal_ore"] * 4 + ["minecraft:diamond_ore", "allthemodium:allthemodium_ore"]
for c, n in zip(ores, names):
    W.set(*c, n)
W.set(3, 0, 3, "minecraft:diamond_ore")  # not touching the tunnel
W.set(8, 1, 0, "minecraft:gravel"); W.regen["8,1,0"] = 2
ok, err, out = run(lua, W, 20)
check("basic: no error", ok, err)
check("basic: home and facing forward", pos(W) == (0, 0, 0, 0), pos(W))
check("basic: all touching ores mined", not remaining_ores(lua, W, ores), remaining_ores(lua, W, ores))
check("basic: far ore left alone", W.get(3, 0, 3) == "minecraft:diamond_ore")
c = chest(W)
check("basic: loot in chest", c.get("minecraft:raw_iron") == 4 and c.get("minecraft:diamond") == 1
      and c.get("allthemodium:raw_allthemodium") == 1, c)
check("basic: chest never dug, nothing lost", not W.dugChest and W.lost == 0, (W.dugChest, W.lost))
check("basic: summary printed", any("Finished (done): 20 blocks, 10 ores" in l for l in out), out[-1:])

# 2. Inventory fills up: every column is a different rock, forces trips home
lua, W = make()
setup_inv(lua, W, {1: ("minecraft:coal", 30)})
W.default = lua.eval('function(x,y,z) if y <= -5 then return "minecraft:bedrock" end return "mod:rock_" .. x end')
W.set(9, 0, 1, "minecraft:iron_ore")
ok, err, out = run(lua, W, 40)
check("full: no error", ok, err)
check("full: made trips home", "trips" and any("trips" in l for l in out) and not any(" 0 trips" in l for l in out), out[-1:])
check("full: back home", pos(W) == (0, 0, 0, 0), pos(W))
check("full: nothing lost", W.lost == 0, W.lost)
check("full: chest got rock types", len(chest(W)) >= 30, len(chest(W)))

# 3. Low fuel: must stop early and still make it home
lua, W = make()
setup_inv(lua, W, {1: ("minecraft:coal", 2)})
ok, err, out = run(lua, W, 200)
check("fuel: no error", ok, err)
check("fuel: stopped for low fuel", any("low fuel" in l for l in out), out[-1:])
check("fuel: home", pos(W) == (0, 0, 0, 0), (pos(W), W.fuel))

# 4. No chest behind
lua, W = make()
setup_inv(lua, W, {1: ("minecraft:coal", 5)})
W.chestPos = "99,99,99"
ok, err, out = run(lua, W, 10)
check("nochest: refuses to start", ok and W.moves == 0 and any("No chest" in l for l in out), out)

# 5. Bedrock wall in the tunnel
lua, W = make()
setup_inv(lua, W, {1: ("minecraft:coal", 5)})
W.set(7, 0, 0, "minecraft:bedrock")
ok, err, out = run(lua, W, 20)
check("bedrock: stops as blocked and returns", ok and any("blocked" in l for l in out) and pos(W) == (0, 0, 0, 0), (out[-1:], pos(W)))

DEEP = 'function(x,y,z) if y <= -40 then return "minecraft:bedrock" end return "minecraft:stone" end'
DEEP_COLS = 'function(x,y,z) if y <= -40 then return "minecraft:bedrock" end return "mod:rock_" .. x .. "_" .. y end'

# 6-7. Chest in front / on the side: turtle turns itself, tunnel goes away from chest
for label, h in (("front", 2), ("side", 1)):
    lua, W = make()
    setup_inv(lua, W, {1: ("minecraft:coal", 5)})
    W.h = h
    W.set(6, 0, 1, "minecraft:iron_ore")
    ok, err, out = run(lua, W, 10)
    check(f"chest {label}: turns, mines, comes home", ok and pos(W) == (0, 0, 0, 0)
          and chest(W).get("minecraft:raw_iron") == 1, (err, pos(W), chest(W), out[-1:]))

# 8. Shaft down first, ores in the shaft wall and along the deep tunnel
lua, W = make()
setup_inv(lua, W, {1: ("minecraft:coal", 10)})
W.default = lua.eval(DEEP)
deep_ores = [(0, -4, 1), (5, -10, 1), (6, -8, 0), (9, -11, 0)]
for c in deep_ores:
    W.set(*c, "minecraft:iron_ore")
ok, err, out = run(lua, W, 12, 10)
check("depth: no error, home", ok and pos(W) == (0, 0, 0, 0), (err, pos(W)))
check("depth: all ores mined", not remaining_ores(lua, W, deep_ores) and chest(W).get("minecraft:raw_iron") == 4,
      (remaining_ores(lua, W, deep_ores), chest(W)))

# 9. Deep tunnel with full inventory: trips must reuse the one shaft
lua, W = make()
setup_inv(lua, W, {1: ("minecraft:coal", 40)})
W.default = lua.eval(DEEP_COLS)
ok, err, out = run(lua, W, 40, 10)
extra = [(xx, yy) for xx in range(1, 45) for yy in range(-8, 0) if W.get(xx, yy, 0) is None]
check("depth+full: trips, home, nothing lost", ok and pos(W) == (0, 0, 0, 0) and W.lost == 0
      and not any(" 0 trips" in l for l in out), (err, pos(W), W.lost, out[-1:]))
check("depth+full: no extra shafts dug", not extra, extra[:5])

# 10. Asked to go deeper than bedrock: tunnels just above it
lua, W = make()
setup_inv(lua, W, {1: ("minecraft:coal", 20)})
W.default = lua.eval(DEEP)
ok, err, out = run(lua, W, 8, 100)
check("depth bedrock: tunnels above bedrock, home", ok and pos(W) == (0, 0, 0, 0)
      and W.get(3, -39, 0) is None and any("(done)" in l for l in out), (err, pos(W), out[-1:]))

# 11. Your computer in the way is never dug
lua, W = make()
setup_inv(lua, W, {1: ("minecraft:coal", 5)})
W.set(5, 0, 0, "computercraft:computer_advanced")
ok, err, out = run(lua, W, 10)
check("protect: computer untouched", ok and W.get(5, 0, 0) == "computercraft:computer_advanced"
      and any("blocked" in l for l in out) and pos(W) == (0, 0, 0, 0), (out[-1:], pos(W)))

# 12. Coal in a random slot; one fuel stack stays in the turtle
lua, W = make()
setup_inv(lua, W, {7: ("minecraft:coal", 5)})
ok, err, out = run(lua, W, 10)
inv = [W.inv[i] for i in range(1, 17)]
check("fuel slot: works from any slot, keeps fuel", ok and "minecraft:coal" not in chest(W)
      and any(s and s.name == "minecraft:coal" for s in inv), (err, chest(W)))

width = max(len(n) for n, _, _ in results)
for n, good, d in results:
    print(("PASS " if good else "FAIL ") + n.ljust(width) + ("" if good else f"  -> {d}"))
print(f"\n{sum(g for _, g, _ in results)}/{len(results)} passed")
sys.exit(0 if all(g for _, g, _ in results) else 1)
