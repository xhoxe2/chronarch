"""Tests for tools/gpssetup.lua: one command turns a computer into a GPS host.

Run from the project root:
    .venv/bin/python tests/test_gpssetup.py
"""
import sys
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
SRC = (ROOT / "tools" / "gpssetup.lua").read_text()

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


def run(args, modem=True):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("FILES = {}; LABEL = nil; REBOOTED = false; OUT = {}")
    lua.execute("print = function(s) OUT[#OUT + 1] = s end; sleep = function() end")
    lua.execute("os.setComputerLabel = function(l) LABEL = l end; os.reboot = function() REBOOTED = true end")
    lua.execute("""fs = { open = function(p) return {
        write = function(s) FILES[p] = (FILES[p] or '') .. s end, close = function() end } end }""")
    lua.execute("peripheral = { find = function(t, f) if %s then return { isWireless = function() return true end } end end }"
                % ("true" if modem else "false"))
    lua.eval("function(src, ...) return load(src, 'gpssetup.lua')(...) end")(SRC, *args)
    return lua


lua = run(["645", "67", "-107", "gps4"])
check("writes startup with gps host + coords", lua.eval("FILES['startup.lua']") == 'shell.run("gps", "host", 645, 67, -107)\n',
      lua.eval("FILES['startup.lua']"))
check("sets the label", lua.eval("LABEL") == "gps4")
check("reboots", lua.eval("REBOOTED") is True)

lua = run(["645", "67"])
check("missing coords: usage, writes nothing", lua.eval("next(FILES)") is None and "Usage" in lua.eval("OUT[1]"))

lua = run(["1", "2", "3"], modem=False)
check("no modem: says so, writes nothing", lua.eval("next(FILES)") is None and "modem" in lua.eval("OUT[1]"))

for n, good, d in results:
    print(("PASS " if good else "FAIL ") + n + ("" if good else f"  -> {d}"))
print(f"\n{sum(g for _, g, _ in results)}/{len(results)} passed")
sys.exit(0 if all(g for _, g, _ in results) else 1)
