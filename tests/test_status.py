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

width = max(len(n) for n, _, _ in results)
for n, good, d in results:
    print(("PASS " if good else "FAIL ") + n.ljust(width) + ("" if good else f"  -> {d}"))
print(f"\n{sum(g for _, g, _ in results)}/{len(results)} passed")
sys.exit(0 if all(g for _, g, _ in results) else 1)
