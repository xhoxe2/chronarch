"""Tests for tools/probe.lua.

Uses the turtle world from mock.lua plus the real textutils/expect modules
from CC: Tweaked, so the JSON is written exactly as the game would write it.

Run from the project root:   sh tests/fetch_ccrom.sh   (once)
                             python3 tests/test_probe.py
"""
import json
import sys
from pathlib import Path
from lupa import LuaRuntime

HERE = Path(__file__).resolve().parent
PROBE = (HERE.parent / "tools" / "probe.lua").read_text()
MOCK = (HERE / "mock.lua").read_text()
ROM = HERE / "ccrom"
if not (ROM / "textutils.lua").exists():
    sys.exit("Run tests/fetch_ccrom.sh first")

SETUP = r"""
local W, EXPECT_SRC, TEXTUTILS_SRC, MODE = ...

-- Real CC modules -------------------------------------------------------
local expect = load(EXPECT_SRC, "expect.lua")()
local function req(name)
  if name == "cc.expect" then return expect end
  if name == "cc.strings" then return { wrap = function(s) return { s } end } end
  error("no module " .. name)
end
local src = TEXTUTILS_SRC:gsub('local require = dofile%b()', 'local require = ...', 1)
local env = setmetatable({}, { __index = _G })
assert(load(src, "textutils.lua", "t", env))(req)
textutils = {}
for k, v in pairs(env) do textutils[k] = v end

-- Computer basics ---------------------------------------------------------
FILES = {}
fs = { open = function(path, mode)
  local buf = {}
  return {
    write = function(s) buf[#buf + 1] = s end,
    close = function() FILES[path] = table.concat(buf) end,
  }
end }
_HOST = "ComputerCraft 1.116.1 (Minecraft 1.21.1)"
os.getComputerID = function() return 0 end
os.getComputerLabel = function() return "xhoxi" end
os.version = function() return "CraftOS 1.9" end
os.day = function() return 12 end
os.epoch = function() return 1793628000000 end
term = { isColor = function() return true end }
http = { checkURL = function() return true end }
settings = {
  getNames = function() return { "shell.allow_disk_startup", "motd.enable" } end,
  get = function(n) if n == "motd.enable" then return true end return false end,
}

-- Devices around: chest behind, ender modem on the right ----------------
CALLS = {}
local devices = {
  back = {
    types = { "minecraft:chest", "inventory" },
    methods = { "list", "size", "getItemDetail", "pushItems", "pullItems", "getItemLimit" },
    impl = {
      list = function() return { [1] = { name = "minecraft:coal", count = 5 },
                                 [3] = { name = "minecraft:raw_iron", count = 12 } } end,
      size = function() return 27 end,
      getItemDetail = function(slot)
        if slot == 1 then
          return { name = "minecraft:coal", count = 5, maxCount = 64,
                   displayName = "\208\163\208\179\208\190\208\187\209\140", -- "Уголь" in UTF-8
                   tags = { ["minecraft:coals"] = true } }
        end
        return { name = "minecraft:raw_iron", count = 12, maxCount = 64,
                 tags = { ["c:raw_materials/iron"] = true } }
      end,
    },
  },
  right = {
    types = { "modem" },
    methods = { "isWireless", "open", "close", "transmit", "isOpen", "closeAll" },
    impl = { isWireless = function() return true end },
  },
}
peripheral = {
  getNames = function() return { "back", "right" } end,
  getType = function(n) return table.unpack(devices[n].types) end,
  getMethods = function(n) return devices[n].methods end,
  call = function(n, m, ...)
    CALLS[#CALLS + 1] = n .. "." .. m
    local f = devices[n].impl[m]
    if not f then error("unexpected call " .. m) end
    return f(...)
  end,
}

-- Turtle extras -----------------------------------------------------------
TURNS = 0
if MODE == "computer" then
  turtle = nil
else
  local right = turtle.turnRight
  turtle.turnRight = function() TURNS = TURNS + 1; return right() end
  turtle.getFuelLimit = function() return 100000 end
  turtle.getSelectedSlot = function() return 1 end
  turtle.getEquippedLeft = function() return { name = "minecraft:diamond_pickaxe", count = 1 } end
  turtle.getEquippedRight = function() return { name = "computercraft:wireless_modem_advanced", count = 1 } end
end
"""


def run(mode="turtle", args=()):
    lua = LuaRuntime(unpack_returned_tuples=True)
    W = lua.execute(MOCK)
    W.fuel = 160
    W.inv[2] = lua.table_from({"name": "minecraft:coal_block", "count": 63})
    W.set(0, 0, 1, "minecraft:iron_ore")   # right of the turtle
    W.set(0, 0, -1, "minecraft:dirt")      # left
    W.set(0, 1, 0, "air")                  # nothing above
    lua.execute(SETUP, W, (ROM / "expect.lua").read_text(), (ROM / "textutils.lua").read_text(), mode)
    runner = lua.eval("""function(src, ...)
        local fn, err = load(src, "probe.lua")
        if not fn then return false, err end
        local ok, e = pcall(fn, ...)
        return ok, tostring(e)
    end""")
    ok, err = runner(PROBE, *args)
    g = lua.globals()
    files = {k: v for k, v in g.FILES.items()}
    calls = [g.CALLS[i] for i in range(1, len(g.CALLS) + 1)]
    out = [W.out[i] for i in range(1, len(W.out) + 1)]
    return ok, err, files, calls, out, W, g.TURNS


results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


SAFE = {"back.list", "back.size", "back.getItemDetail", "right.isWireless"}

# 1. Turtle, full scan
ok, err, files, calls, out, W, turns = run()
check("turtle: runs without error", ok, err)
data = None
try:
    data = json.loads(files["probe-0.json"])
except Exception as e:  # noqa: BLE001
    check("turtle: JSON is valid", False, e)
if data:
    check("turtle: JSON is valid", True)
    check("turtle: identity", data["kind"] == "turtle" and data["label"] == "xhoxi"
          and data["host"].startswith("ComputerCraft") and data["craftos"] == "CraftOS 1.9", data.get("host"))
    b = data["turtle"]["blocks"]
    check("turtle: sees blocks on all sides", b["front"]["name"] == "minecraft:stone"
          and b["right"]["name"] == "minecraft:iron_ore" and b["back"]["name"] == "minecraft:chest"
          and b["left"]["name"] == "minecraft:dirt" and b["up"] == {"empty": True}
          and b["down"]["name"] == "minecraft:stone", b)
    check("turtle: ore tags captured", b["right"]["tags"].get("c:ores") is True, b["right"])
    t = data["turtle"]
    check("turtle: fuel, upgrades, inventory", t["fuel"] == 160 and t["fuel_limit"] == 100000
          and t["equipped_left"]["name"] == "minecraft:diamond_pickaxe"
          and t["inventory"][0]["name"] == "minecraft:coal_block" and t["inventory"][0]["slot"] == 2, t)
    p = data["peripherals"]
    check("devices: chest types, size, methods", "inventory" in p["back"]["types"]
          and p["back"]["values"]["size"] == [27] and "pushItems" in p["back"]["methods"], p["back"])
    items = p["back"].get("items", [])
    check("devices: chest items with exact names and tags", len(items) == 2
          and items[0]["tags"] == {"minecraft:coals": True} and items[1]["name"] == "minecraft:raw_iron"
          and items[1]["slot"] == 3, items)
    check("devices: modem is wireless", p["right"]["values"]["isWireless"] == [True], p["right"])
    check("apis: lists real functions", "forward" in data["apis"]["turtle"]
          and "serializeJSON" in data["apis"]["textutils"] and "print" in data["globals"], list(data["apis"])[:10])
    check("settings captured", data["settings"].get("motd.enable") is True, data["settings"])
check("safety: only read-only device calls", set(calls) <= SAFE, sorted(set(calls) - SAFE))
check("safety: turtle did not move or dig", W.moves == 0 and W.pos.x == 0 and W.pos.y == 0 and W.pos.z == 0
      and W.get(1, 0, 0) == "minecraft:stone" and W.get(0, 0, 1) == "minecraft:iron_ore", (W.moves,))
check("safety: faces the same way after 4 turns", turns == 4 and W.h == 0, (turns, W.h))
check("screen: tells how to upload", any("pastebin put probe-0.json" in l for l in out), out)

# 2. Turtle with "noturn"
ok, err, files, calls, out, W, turns = run(args=("noturn",))
d = json.loads(files.get("probe-0.json", "{}")) if ok else {}
check("noturn: no turning, front only", ok and turns == 0 and "front" in d.get("turtle", {}).get("blocks", {})
      and "left" not in d["turtle"]["blocks"], (err, turns))

# 3. Plain computer
ok, err, files, calls, out, W, turns = run(mode="computer")
d = json.loads(files.get("probe-0.json", "{}")) if ok else {}
check("computer: works, no turtle section", ok and d.get("kind") == "computer" and "turtle" not in d, err)

width = max(len(n) for n, _, _ in results)
for n, good, d in results:
    print(("PASS " if good else "FAIL ") + n.ljust(width) + ("" if good else f"  -> {d}"))
print(f"\n{sum(g for _, g, _ in results)}/{len(results)} passed")
sys.exit(0 if all(g for _, g, _ in results) else 1)
