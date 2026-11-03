"""Tests for common/statusview.lua: the base status-monitor table.

Pure logic. Run from the project root:
    .venv/bin/python tests/test_status.py
"""
import sys
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
SRC = (ROOT / "common" / "statusview.lua").read_text()

lua = LuaRuntime(unpack_returned_tuples=True)
view = lua.eval("function(s) return load(s, 'statusview.lua')() end")(SRC)
mk = lua.eval("function(src) return load('return ' .. src)() end")
# rows -> list of "color|text"
dump = lua.eval(r"""function(rows)
  local out = {}
  for i = 1, #rows do out[i] = rows[i].color .. "|" .. rows[i].text end
  return table.concat(out, "\n")
end""")


def lines(turtles, now, stale=12):
    return dump(view.format(turtles, now, stale)).split("\n")


results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


# empty
rows = lines(mk("{}"), 100)
check("empty: header shows 0", rows[0].startswith("cyan|CHRONARCH  0 turtle"), rows)
check("empty: hint row", any("No turtles" in r for r in rows), rows)

# two turtles: xhoxi busy & fresh, miner2 idle but stale (not heard in 100s)
turtles = mk("{xhoxi = {id=0, fuel=800, state='busy', seen=99}, "
             "miner2 = {id=2, fuel=120, state='idle', seen=0}}")
rows = lines(turtles, 100, 12)
check("header counts 2", rows[0] == "cyan|CHRONARCH  2 turtle(s)", rows[0])
check("sorted: miner2 before xhoxi", rows[2].split("|")[1].startswith("miner2")
      and rows[3].split("|")[1].startswith("xhoxi"), rows)
check("fresh busy turtle is yellow", rows[3].startswith("yellow|") and "busy" in rows[3], rows[3])
check("stale turtle shown offline in red", rows[2].startswith("red|") and "offline" in rows[2], rows[2])
check("fuel is shown", "800" in rows[3] and "120" in rows[2], (rows[2], rows[3]))

# a fresh idle turtle is green
rows = lines(mk("{a = {id=1, fuel=64, state='idle', seen=100}}"), 100, 12)
check("fresh idle turtle is lime", rows[2].startswith("lime|") and "idle" in rows[2], rows[2])

# summary for the AI
summary = lambda t, m, now=100: view.summary(t, m, now, 12)
check("summary: no turtles", "no turtles online" in summary(mk("{}"), mk("{}")))
t = mk("{xhoxi = {id=0, fuel=800, state='digging', seen=99}, old = {id=2, fuel=5, state='idle', seen=0}}")
m = mk("{xhoxi = {ores = {{name='minecraft:iron_ore', x=3, y=0, z=0}, {name='minecraft:diamond_ore', x=-5, y=-2, z=1}, "
       "{name='minecraft:iron_ore', x=1, y=-1, z=0}, {name='create:zinc_ore', x=0, y=0, z=9}}}}")
s_ = summary(t, m).split("\n")
check("summary: header + one line per turtle, sorted", len(s_) == 3 and s_[1].startswith("old:")
      and s_[2].startswith("xhoxi:"), s_)
check("summary: online turtle with state and fuel", "xhoxi: online, digging, fuel 800." in s_[2], s_[2])
check("summary: stale turtle is offline", "old: offline, unknown, fuel 5." == s_[1], s_[1])
check("summary: ore counts, most first, mod prefix dropped",
      s_[2].endswith("Ore it knows from home: 2 iron_ore (nearest 2 blocks), 1 diamond_ore (nearest 8 blocks), "
                     "1 zinc_ore (nearest 9 blocks)."), s_[2])

# AI action line
known = mk("{xhoxi = {id=0}}")
def act(text):
    ans, a = view.parseAction(text, known)
    return ans, (a.line if a else None)
check("action: harvest parsed, line removed",
      act("Diamonds nearby.\nDO: harvest xhoxi 12") == ("Diamonds nearby.", "harvest xhoxi 12"))
check("action: radius clamped", act("Go.\nDO: scan xhoxi 99")[1] == "scan xhoxi 16")
check("action: default number", act("Go.\nDO: mine xhoxi")[1] == "mine xhoxi 16")
check("action: stop has no number", act("Halt.\nDO: stop xhoxi")[1] == "stop xhoxi")
check("action: unknown command ignored", act("x\nDO: dig xhoxi 5")[1] is None)
check("action: unknown turtle ignored", act("x\nDO: harvest ghost 5")[1] is None)
check("action: no DO line", act("Just advice.") == ("Just advice.", None))
check("action: harvest with an ore filter", act("Go.\nDO: harvest xhoxi 12 diamond")[1] == "harvest xhoxi 12 diamond")
check("action: ore word only for harvest", act("Go.\nDO: scan xhoxi 8 diamond")[1] == "scan xhoxi 8")

width = max(len(n) for n, _, _ in results)
for n, good, d in results:
    print(("PASS " if good else "FAIL ") + n.ljust(width) + ("" if good else f"  -> {d}"))
print(f"\n{sum(g for _, g, _ in results)}/{len(results)} passed")
sys.exit(0 if all(g for _, g, _ in results) else 1)
