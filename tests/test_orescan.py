"""Tests for common/orescan.lua: the Geo Scanner ore summary.

Pure logic. Run from the project root:
    .venv/bin/python tests/test_orescan.py
"""
import sys
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
SRC = (ROOT / "common" / "orescan.lua").read_text()

lua = LuaRuntime(unpack_returned_tuples=True)
M = lua.eval("function(s) return load(s, 'orescan.lua')() end")(SRC)
mk = lua.eval("function(src) return load('return ' .. src)() end")

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


# A field: iron at d1, coal at d3, diamond at d4, a tag-only ore (no "_ore" in
# the name) at d2, and a non-ore stone that must be ignored.
blocks = mk("""{
  { x=1, y=0, z=0, name='minecraft:iron_ore', tags={ ['c:ores']=true } },
  { x=0, y=-2, z=1, name='minecraft:coal_ore', tags={ ['c:ores']=true } },
  { x=-3, y=1, z=0, name='minecraft:diamond_ore', tags={ ['c:ores']=true } },
  { x=2, y=0, z=0, name='minecraft:stone', tags={} },
  { x=1, y=0, z=1, name='allthemodium:ancient_debris', tags={ ['c:ores']=true } },
  { x=0, y=1, z=0, name='minecraft:iron_ore', tags={ ['c:ores']=true } },
}""")
s = M.summarize(blocks)

check("counts only ores, not stone", s.total == 5, s.total)


def counts_map(summary):
    out = {}
    n = len(summary.counts)
    for i in range(1, n + 1):
        row = summary.counts[i]
        out[row.name] = row.count
    return out


cm = counts_map(s)
check("iron counted twice", cm.get("minecraft:iron_ore") == 2, cm)
check("tag-only ore (ancient_debris) counted", cm.get("allthemodium:ancient_debris") == 1, cm)
check("stone ignored", "minecraft:stone" not in cm, cm)
check("counts sorted: iron (2) first", s.counts[1].name == "minecraft:iron_ore" and s.counts[1].count == 2,
      (s.counts[1].name, s.counts[1].count))
check("nearest is a d1 ore", s.nearest.dist == 1, s.nearest.dist if s.nearest else None)
check("nearest name is iron_ore", s.nearest.name == "minecraft:iron_ore", s.nearest.name if s.nearest else None)
check("ores list has every ore with coords", len(s.ores) == 5
      and all(s.ores[i].name and s.ores[i].x is not None for i in range(1, 6)), len(s.ores))

# empty scan
e = M.summarize(mk("{}"))
check("empty: total 0", e.total == 0, e.total)
check("empty: no nearest", e.nearest is None, e.nearest)
check("empty: no counts", len(e.counts) == 0, len(e.counts))

# short()
check("short strips modid", M.short("minecraft:iron_ore") == "iron_ore", M.short("minecraft:iron_ore"))

width = max(len(n) for n, _, _ in results)
for n, good, d in results:
    print(("PASS " if good else "FAIL ") + n.ljust(width) + ("" if good else f"  -> {d}"))
print(f"\n{sum(g for _, g, _ in results)}/{len(results)} passed")
sys.exit(0 if all(g for _, g, _ in results) else 1)
