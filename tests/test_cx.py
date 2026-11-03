"""Tests for cx.lua: the one CHRONARCH command (where am I, list, help,
update, install) and its downloads by program.

Runs the real cx.lua with http/fs/os stubbed. Run from the project root:
    .venv/bin/python tests/test_cx.py
"""
import sys
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
SRC = (ROOT / "cx.lua").read_text()
RAW = "https://raw.githubusercontent.com/xhoxe2/chronarch/main/"
COMMON = {"cx.lua", "update.lua", "program.lua", "programs-custom.lua", "lib/chronarch.lua"}

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


class Run:
    def __init__(self, kind="computer", args=(), saved=None, sha=None, root_files=()):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute("WRITES = {}; URLS = {}; DELETED = {}; OUT = ''")
        lua.execute("turtle = %s" % ("{}" if kind == "turtle" else "nil"))
        lua.execute("pocket = %s" % ("{}" if kind == "pocket" else "nil"))
        lua.execute("print = function(s) OUT = OUT .. tostring(s) .. '\\n' end")
        lua.execute("os.getComputerID = function() return 7 end; os.getComputerLabel = function() return 'base' end")
        lua.globals().SAVED = saved
        lua.globals().SHA = sha
        lua.globals().ROOTFILES = lua.table_from(list(root_files))
        lua.execute("""
          http = { get = function(url)
            URLS[#URLS + 1] = url
            if url:find("api.github.com", 1, true) then
              if not SHA then return nil end
              return { readAll = function() return SHA end, close = function() end }
            end
            return { readAll = function() return "-- body " .. url end, close = function() end }
          end }
          fs = {
            exists = function(p)
              if p == "/.program" then return SAVED ~= nil end
              for _, f in ipairs(ROOTFILES) do if f == p then return true end end
              return false
            end,
            delete = function(p) DELETED[#DELETED + 1] = p end,
            getDir = function(p) return p:match("^(.*)/[^/]*$") or "" end,
            makeDir = function() end,
            open = function(path, mode)
              if mode == "r" then return { readAll = function() return SAVED end, close = function() end } end
              return { write = function(d) WRITES[path] = (WRITES[path] or "") .. d end, close = function() end }
            end,
          }
        """)
        lua.eval("function(src, ...) return load(src, 'cx.lua')(...) end")(SRC, *args)
        self.writes = dict(lua.eval("WRITES"))
        self.urls = [u for u in lua.eval("URLS").values() if "api.github.com" not in u]
        self.deleted = list(lua.eval("DELETED").values())
        self.out = lua.eval("OUT")


# --- cx update, by machine ----------------------------------------------------
r = Run("turtle", ("update",))
code = set(r.writes) - {"/.program"}
check("turtle -> mining files", code == COMMON | {"startup.lua", "mine.lua", "lib/navigate.lua", "lib/orescan.lua"}, code)
check("mining startup from programs/mining/", r.writes.get("startup.lua") == "-- body " + RAW + "programs/mining/startup.lua")
check("libraries from lib/", r.writes.get("lib/navigate.lua") == "-- body " + RAW + "lib/navigate.lua")
r = Run("computer", ("update",))
code = set(r.writes)
check("computer -> control files", code == COMMON | {"startup.lua", "lib/statusview.lua", "lib/oremap.lua", "lib/swarm.lua"}, code)
check("control startup from programs/control/", r.writes.get("startup.lua") == "-- body " + RAW + "programs/control/startup.lua")
r = Run("pocket", ("update",))
code = set(r.writes)
check("pocket -> buddy files, no startup", code == COMMON | {"buddy.lua", "colony.lua", "lib/statusview.lua", "lib/buddycmd.lua"}, code)
check("every URL is our public repo, never the key",
      all(u.startswith(RAW) for u in r.urls) and not any("chronarch.key" in u for u in r.urls), r.urls)

# --- cx install ---------------------------------------------------------------
r = Run("turtle", ("install", "mining"))
check("install saves the choice", r.writes.get("/.program") == "mining", r.writes.get("/.program"))
r = Run("computer", ("install", "mining"))
check("mining refused on a computer", not r.writes and "turtle" in r.out, r.out)
r = Run("turtle", ("install", "dancing"))
check("unknown program: short answer, nothing written", not r.writes and "No program" in r.out
      and len(r.out.strip().split("\n")) <= 3, r.out)
r = Run("turtle", ("install", "miner"))
check("'miner' means mining", r.writes.get("/.program") == "mining", r.writes.get("/.program"))
r = Run("pocket", ("install", "miner"))
check("mining on a pocket: says what this machine runs", not r.writes and "pocket" in r.out and "buddy" in r.out, r.out)
r = Run("computer", ("install", "base"))
check("old name base installs control", r.writes.get("/.program") == "control")
r = Run("pocket", ("update",), saved="colony")
check("saved old name colony means buddy", "buddy.lua" in r.writes, set(r.writes))
r = Run("computer", ("install", "gps", "645", "67", "-107"))
check("gps install stores the position", r.writes.get("/.gps.pos") == "645 67 -107"
      and r.writes.get("startup.lua") == "-- body " + RAW + "programs/gps/startup.lua", r.writes)
r = Run("computer", ("install", "gps"))
check("gps without coordinates: explains, writes nothing", not r.writes and "x" in r.out, r.out)

# --- tidy root ----------------------------------------------------------------
r = Run("turtle", ("update",), root_files=("navigate.lua", "chronarch.key"))
check("old root library copies deleted", "navigate.lua" in r.deleted, r.deleted)
check("the key is never deleted", "chronarch.key" not in r.deleted)

# --- where am I / list / help (no internet needed) ----------------------------
r = Run("computer", ())
check("cx: machine and program", "computer #7" in r.out and "program: control" in r.out, r.out)
check("cx needs no internet", not r.urls and not r.writes)
r = Run("computer", ("list",))
check("cx list: all programs + coming ones", all(n in r.out for n in ("mining", "control", "buddy", "gps", "scout", "carve")), r.out)
r = Run("turtle", ("help",))
check("cx help: this program's commands", "CHRONARCH mining" in r.out and "radio" in r.out, r.out)
r = Run("computer", ("help",))
check("cx help on the base lists base> commands", "harvest" in r.out and "base>" in r.out, r.out)

# --- pinned to the latest commit ----------------------------------------------
SHA = "04809c82e023cd07b41385c09432b85df70f7aa8"
r = Run("turtle", ("update",), sha=SHA)
check("files come from the latest commit",
      r.urls and all(u.startswith("https://raw.githubusercontent.com/xhoxe2/chronarch/" + SHA + "/") for u in r.urls))
r = Run("turtle", ("update",), sha="not a sha")
check("garbage from the API: falls back to the branch", all(u.startswith(RAW) for u in r.urls))

width = max(len(n) for n, _, _ in results)
for n, good, d in results:
    print(("PASS " if good else "FAIL ") + n.ljust(width) + ("" if good else f"  -> {d}"))
print(f"\n{sum(g for _, g, _ in results)}/{len(results)} passed")
sys.exit(0 if all(g for _, g, _ in results) else 1)
