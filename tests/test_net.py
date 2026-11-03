"""Integration test: base <-> real agent.lua over the real rednet, plus an
attacker with no secret, inside tests/net.lua.

Proves two things end to end:
  * a signed order from the base makes the turtle work and report back;
  * an unsigned/forged order (and a fake status) are ignored by both sides.

Run from the project root (after tests/fetch_ccrom.sh):
    .venv/bin/python tests/test_net.py
"""
import sys
from pathlib import Path
from lupa import LuaRuntime

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cchelpers import BIT32, ROM, ROOT  # noqa: E402

HERE = Path(__file__).resolve().parent
NET = (HERE / "net.lua").read_text()
AGENT = (ROOT / "turtle" / "agent.lua").read_text()
CHRONARCH = (ROOT / "common" / "chronarch.lua").read_text()
ORESCAN = (ROOT / "common" / "orescan.lua").read_text()
NAVIGATE = (ROOT / "common" / "navigate.lua").read_text()
SECRET = "correct horse battery staple"

BASE_DRIVER = r"""
local proto = require("chronarch")
local S = SECRET
assert(proto.openModem())
local from, st = proto.receive(S, 30)         -- wait for the agent to announce
if st and st.type == "status" then record("status", st.name .. "/" .. st.state) end
if from then
  proto.send(S, from, { cmd = "mine", length = 8, depth = 0 })
  while true do
    local f, m = proto.receive(S, 30)
    if not m then break end
    local info = m.type .. "/" .. tostring(m.name)
    if m.type == "done" then info = info .. "/ok=" .. tostring(m.ok) end
    if m.type == "log" then info = info .. "/" .. tostring(m.text) end
    record("recv", info)
    if m.type == "done" then break end
  end
  proto.send(S, from, { cmd = "scan", radius = 8 })
  while true do
    local f, m = proto.receive(S, 30)
    if not m then break end
    if m.type == "scan" then
      record("scan", "ok=" .. tostring(m.ok) .. "/total=" .. tostring(m.total)
        .. "/nearest=" .. (m.nearest and m.nearest.name or "nil"))
      break
    end
  end
end
stop()
"""

ATTACKER_DRIVER = r"""
local m = peripheral.find("modem", function(_, md) return md.isWireless() end)
rednet.open(peripheral.getName(m))
rednet.broadcast({ cmd = "mine", length = 9999, depth = 64 }, "chronarch")    -- forged order
rednet.broadcast({ type = "status", name = "ghost", fuel = 1, state = "idle" }, "chronarch") -- fake turtle
-- If the agent obeyed the forged order it would reply to us; tattle on it.
while true do
  local f, msg = rednet.receive("chronarch", 30)
  if not f then break end
  if type(msg) == "table" and (msg.type == "done" or msg.type == "log") then
    record("attacker_got", tostring(msg.type)); break
  end
end
"""

lua = LuaRuntime(unpack_returned_tuples=True)
sim = lua.execute(NET)()
sim.setSources(lua.table_from({
    "bit32": BIT32,
    "parallel": (ROM / "parallel.lua").read_text(),
    "rednet": (ROM / "rednet.lua").read_text(),
    "expect": (ROM / "expect.lua").read_text(),
    "chronarch": CHRONARCH,
    "orescan": ORESCAN,
    "navigate": NAVIGATE,
}))
sim.addComputer(lua.table_from({"id": 0, "label": "base", "secret": SECRET, "src": BASE_DRIVER}))
sim.addComputer(lua.table_from({"id": 5, "label": "xhoxi", "secret": SECRET, "src": AGENT,
                                "withTurtle": True, "withShell": True, "scanner": True}))
sim.addComputer(lua.table_from({"id": 9, "label": "evil", "src": ATTACKER_DRIVER}))
sim.run(100000)

dump = lua.eval(r"""function(res)
  local out = {}
  for k, list in pairs(res) do for i = 1, #list do out[#out + 1] = k .. "::" .. tostring(list[i]) end end
  table.sort(out)
  return table.concat(out, "\n")
end""")
rows = [r for r in dump(sim.results()).split("\n") if r]
errs = [sim.errors[i] for i in range(1, lua.eval("function(e) return #e end")(sim.errors) + 1)]

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


check("no lua errors", not errs, errs)
check("base saw the real turtle", any(r == "status::xhoxi/idle" for r in rows), rows)
check("turtle ran the signed job", any(r.startswith("recv::done/xhoxi/ok=true") for r in rows), rows)
check("base got streamed log output", any(r.startswith("recv::log/xhoxi") for r in rows), rows)
check("fake turtle 'ghost' never trusted", not any("ghost" in r for r in rows), rows)
check("forged order ignored by the turtle", not any(r.startswith("attacker_got") for r in rows), rows)
check("turtle scanned ores and reported", any(
    r == "scan::ok=true/total=3/nearest=minecraft:iron_ore" for r in rows), rows)

width = max(len(n) for n, _, _ in results)
for n, good, d in results:
    print(("PASS " if good else "FAIL ") + n.ljust(width) + ("" if good else f"  -> {d}"))
print(f"\n{sum(g for _, g, _ in results)}/{len(results)} passed")
sys.exit(0 if all(g for _, g, _ in results) else 1)
