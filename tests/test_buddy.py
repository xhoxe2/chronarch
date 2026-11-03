"""Tests for lib/buddycmd.lua: pocket-computer orders for the buddy turtle.

Run from the project root:
    .venv/bin/python tests/test_buddy.py
"""
import sys
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
lua = LuaRuntime(unpack_returned_tuples=True)
M = lua.eval("function(s) return load(s, 'buddycmd.lua')() end")((ROOT / "lib" / "buddycmd.lua").read_text())
mk = lua.eval("function(src) return load('return ' .. src)() end")

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


def parse(line, known="{xhoxi=true}", default=None):
    r = M.parse(line, mk(known), default)
    act, err = r if isinstance(r, tuple) else (r, None)
    return (dict(act.items()) if act else None), err


check("name + come here", parse("xhoxi come here")[0] == {"to": "xhoxi", "cmd": "come"})
check("capitals, commas, extra words", parse("Xhoxi, please COME here!")[0] == {"to": "xhoxi", "cmd": "come"})
check("name can be left out with one turtle", parse("come here")[0] == {"to": "xhoxi", "cmd": "come"})
check("two turtles, no name: asks which", parse("come", "{xhoxi=true, miner2=true}")[0] is None)
check("two turtles, last used is the default", parse("follow", "{xhoxi=true, miner2=true}", "miner2")[0]
      == {"to": "miner2", "cmd": "follow"})
check("stash / unload", parse("xhoxi unload")[0]["cmd"] == "stash")
check("dig here with radius", parse("xhoxi dig here 12")[0] == {"to": "xhoxi", "cmd": "dig", "radius": 12})
check("dig radius default and clamp", parse("dig")[0]["radius"] == 8 and parse("dig 500")[0]["radius"] == 24)
check("stay = stop", parse("xhoxi stay")[0]["cmd"] == "stop")
check("unknown order explained", "unknown" in (parse("xhoxi dance")[1] or ""))
check("empty line explained", parse("")[0] is None and parse("")[1])

for n, good, d in results:
    print(("PASS " if good else "FAIL ") + n + ("" if good else f"  -> {d}"))
print(f"\n{sum(g for _, g, _ in results)}/{len(results)} passed")
sys.exit(0 if all(g for _, g, _ in results) else 1)
