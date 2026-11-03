"""Tests for common/oremap.lua: the pixel ore map (rows ready for blit).

Pure logic. Run from the project root:
    .venv/bin/python tests/test_oremap.py
"""
import sys
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
SRC = (ROOT / "common" / "oremap.lua").read_text()

lua = LuaRuntime(unpack_returned_tuples=True)
M = lua.eval("function(s) return load(s, 'oremap.lua')() end")(SRC)
mk = lua.eval("function(src) return load('return ' .. src)() end")
rlen = lua.eval("function(t) return #t end")

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


W, H = 40, 14
ores = mk("""{
  { name='minecraft:iron_ore',    x=1,  y=0, z=0,  dist=1 },
  { name='minecraft:coal_ore',    x=0,  y=0, z=-2, dist=2 },
  { name='minecraft:diamond_ore', x=-1, y=0, z=1,  dist=2 },
}""")
rows = M.render(ores, W, H, mk("{ name='xhoxi', radius=8, total=3 }"))


def text(i):
    return rows[i].text


def fg(i):
    return rows[i].fg


def bg(i):
    return rows[i].bg


# cx = 21, cy = 7, bottom border row = 12
check("row count matches height", rlen(rows) == H, rlen(rows))
check("every row full width", all(len(rows[i].text) == W and len(rows[i].fg) == W
      and len(rows[i].bg) == W for i in range(1, H + 1)), None)
check("title bar names turtle on a cyan strip",
      "ORE MAP" in text(1) and "xhoxi" in text(1) and bg(1)[0] == "9", (text(1)[:20], bg(1)[0]))
check("turtle '+' at centre, yellow", text(7)[20] == "+" and fg(7)[20] == "4", (text(7)[20], fg(7)[20]))
check("iron = solid white cell east", text(7)[21] == " " and bg(7)[21] == "0", (text(7)[21], bg(7)[21]))
check("coal = solid gray cell north", text(5)[20] == " " and bg(5)[20] == "7", (text(5)[20], bg(5)[20]))
check("diamond = solid cyan cell SW", text(8)[19] == " " and bg(8)[19] == "9", (text(8)[19], bg(8)[19]))
check("compass N/S/W/E on the frame",
      text(2)[20] == "N" and text(12)[20] == "S" and text(7)[0] == "W" and text(7)[39] == "E",
      (text(2)[20], text(12)[20], text(7)[0], text(7)[39]))
# a live-harvest map: the turtle marker shows where it is
trows = M.render(ores, W, H, mk("{ name='xhoxi', total=3, turtle={ x=3, z=0 } }"))
check("turtle marker '@' placed where it stands",
      trows[7].text[23] == "@" and trows[7].fg[23] == "d", (trows[7].text[23], trows[7].fg[23]))

# a far-flung ore (x=30) would fall off a 1:1 map; auto-scaling brings it inside
big = M.render(mk("{ { name='minecraft:iron_ore', x=30, z=0 } }"), W, H, mk("{ name='x', total=1 }"))
check("big area auto-scales so far ore still fits",
      big[7].text[23] == " " and big[7].bg[23] == "0" and "1:" in big[1].text,
      (big[7].text[23], big[7].bg[23]))

legend = text(13) + text(14)
check("legend lists ore types with counts",
      "iron_ore" in legend and "coal_ore" in legend and "diamond_ore" in legend, legend)

small = M.render(ores, 10, 6)
check("small monitor: bare-dot fallback", rlen(small) == 6 and small[4].text[5] == "+",
      small[4].text if rlen(small) == 6 else None)

# hit-test: tapping a cell maps back to the ore drawn there (iron is at cell 22,7)
hit = M.hitTest(ores, W, H, 22, 7)
check("tap on the iron cell finds iron", hit is not None and hit.name == "minecraft:iron_ore",
      hit.name if hit else None)
check("tap on empty space finds nothing", M.hitTest(ores, W, H, 30, 7) is None)
check("tap outside the map finds nothing", M.hitTest(ores, W, H, 1, 1) is None)

width = max(len(n) for n, _, _ in results)
for n, good, d in results:
    print(("PASS " if good else "FAIL ") + n.ljust(width) + ("" if good else f"  -> {d}"))
print(f"\n{sum(g for _, g, _ in results)}/{len(results)} passed")
sys.exit(0 if all(g for _, g, _ in results) else 1)
