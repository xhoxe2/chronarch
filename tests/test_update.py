"""Tests for update.lua: the in-game self-updater.

Runs the real program with http/fs/turtle stubbed, then checks it fetched the
right files from the right repo paths for each role (turtle vs base).

Run from the project root:
    .venv/bin/python tests/test_update.py
"""
import sys
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parent.parent
SRC = (ROOT / "update.lua").read_text()

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


def run(is_turtle, sha=None):
    """Run update.lua as a turtle or a base; return (written {path: url}, all urls)."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("WRITES = {}; URLS = {}")
    # turtle global decides the role; a plain table is enough
    lua.execute("turtle = %s" % ("{}" if is_turtle else "nil"))
    lua.execute("print = function() end")
    # http.get records the URL and hands back a fake body keyed to it
    lua.execute("""
      http = { get = function(url)
        URLS[#URLS + 1] = url
        if url:find("api.github.com", 1, true) then
          if not SHA then return nil end
          return { readAll = function() return SHA end, close = function() end }
        end
        return { readAll = function() return "-- body " .. url end, close = function() end }
      end }
    """)
    lua.globals().SHA = sha
    # fs.open records what path got written and with which URL's body
    lua.execute("""
      fs = { open = function(path, mode)
        return {
          write = function(d) WRITES[path] = d end,
          close = function() end,
        }
      end }
    """)
    lua.execute(SRC)
    writes = dict(lua.eval("WRITES"))
    urls = [u for u in (lua.eval("URLS")[i] for i in range(1, lua.eval("#URLS") + 1)) if "api.github.com" not in u]
    return writes, urls


RAW = "https://raw.githubusercontent.com/xhoxe2/chronarch/main/"

# --- base role ---
writes, urls = run(is_turtle=False)
got = set(writes.keys())
check("base writes exactly its file set",
      got == {"startup.lua", "statusview.lua", "oremap.lua", "chronarch.lua", "update.lua"}, got)
check("base startup.lua comes from base/base.lua",
      "-- body " + RAW + "base/base.lua" == writes.get("startup.lua"), writes.get("startup.lua"))
check("base pulls oremap from common/oremap.lua",
      writes.get("oremap.lua") == "-- body " + RAW + "common/oremap.lua", writes.get("oremap.lua"))
check("base never fetches the turtle-only files",
      not any("agent.lua" in u or "navigate.lua" in u or "mine.lua" in u for u in urls), urls)
check("base never touches the secret key",
      not any("chronarch.key" in p for p in writes), list(writes))

# --- turtle role ---
writes, urls = run(is_turtle=True)
got = set(writes.keys())
check("turtle writes exactly its file set",
      got == {"startup.lua", "mine.lua", "orescan.lua", "navigate.lua", "chronarch.lua", "update.lua"}, got)
check("turtle startup.lua comes from turtle/agent.lua",
      writes.get("startup.lua") == "-- body " + RAW + "turtle/agent.lua", writes.get("startup.lua"))
check("turtle pulls navigate from common/navigate.lua",
      writes.get("navigate.lua") == "-- body " + RAW + "common/navigate.lua", writes.get("navigate.lua"))
check("turtle never fetches the base-only files",
      not any("base.lua" in u or "statusview.lua" in u or "oremap.lua" in u for u in urls), urls)

# --- shared: both roles self-update and refresh the shared library ---
check("every URL points at the right public repo", all(u.startswith(RAW) for u in urls), urls)
check("update.lua refreshes itself",
      writes.get("update.lua") == "-- body " + RAW + "update.lua", writes.get("update.lua"))

# --- pinned to the latest commit (dodges the raw CDN cache) ---
SHA = "04809c82e023cd07b41385c09432b85df70f7aa8"
writes, urls = run(is_turtle=True, sha=SHA)
PINNED = "https://raw.githubusercontent.com/xhoxe2/chronarch/" + SHA + "/"
check("with the API: every file comes from the latest commit", urls and all(u.startswith(PINNED) for u in urls), urls[:2])
writes, urls = run(is_turtle=True, sha="not a sha")
check("garbage from the API: falls back to the branch", all(u.startswith(RAW) for u in urls), urls[:2])

width = max(len(n) for n, _, _ in results)
for n, good, d in results:
    print(("PASS " if good else "FAIL ") + n.ljust(width) + ("" if good else f"  -> {d}"))
print(f"\n{sum(g for _, g, _ in results)}/{len(results)} passed")
sys.exit(0 if all(g for _, g, _ in results) else 1)
