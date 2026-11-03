"""Tests for lib/swarm.lua: splitting an area between turtles.

Run from the project root:
    .venv/bin/python tests/test_swarm.py
"""
import sys
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
lua = LuaRuntime(unpack_returned_tuples=True)
M = lua.eval("function(s) return load(s, 'swarm.lua')() end")((ROOT / "lib" / "swarm.lua").read_text())
mk = lua.eval("function(src) return load('return ' .. src)() end")

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


def stripes(parts):
    return {k: (v.x1, v.x2, v.z1, v.z2) for k, v in parts.items()}


p = stripes(M.split(100, 50, 10, mk("{ {name='east', x=200}, {name='west', x=0}, {name='mid', x=90} }")))
check("one stripe per turtle", set(p) == {"east", "west", "mid"}, p)
check("west turtle gets the west stripe", p["west"][0] == 90 and p["east"][1] == 110, p)
cells = sorted(x for a, b, _, _ in p.values() for x in range(a, b + 1))
check("stripes cover the square exactly once", cells == list(range(90, 111)), cells)
check("every stripe spans the full z range", all(v[2] == 40 and v[3] == 60 for v in p.values()), p)
check("one turtle gets it all", stripes(M.split(0, 0, 5, mk("{ {name='a', x=3} }")))["a"] == (-5, 5, -5, 5))
check("no turtles: nothing", len(stripes(M.split(0, 0, 5, mk("{}")))) == 0)

for n, good, d in results:
    print(("PASS " if good else "FAIL ") + n + ("" if good else f"  -> {d}"))
print(f"\n{sum(g for _, g, _ in results)}/{len(results)} passed")
sys.exit(0 if all(g for _, g, _ in results) else 1)
