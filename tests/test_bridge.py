"""Tests for the bridge: bridge/worker.js (run in Node, Gemini stubbed) checks
requests signed by the real in-game chronarch.lua (proto.signRequest).

Proves the Lua signature and the Worker's WebCrypto check agree, and that
forged, tampered or old requests never reach Gemini.

Run from the project root (needs node):
    .venv/bin/python tests/test_bridge.py
"""
import json
import subprocess
import sys
import time
from pathlib import Path
from lupa import LuaRuntime

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cchelpers import HERE, load_chronarch  # noqa: E402

lua = LuaRuntime(unpack_returned_tuples=True)
M = load_chronarch(lua)

SECRET = "correct horse battery staple"
ENV = {"CHRONARCH_KEY": SECRET + "\n", "GEMINI_KEY": "test-gemini-key", "MODEL": "gemini-test"}
GEMINI_OK = {"candidates": [{"content": {"parts": [
    {"text": "Mine **iron** — it’s close… привет\nDO: harvest xhoxi_2 12\n"}]}}]}


def signed(q, now_ms=None, secret=SECRET):
    h = M.signRequest(secret, q, now_ms if now_ms is not None else int(time.time() * 1000))
    return {"method": "POST", "path": "/ask", "body": q,
            "headers": {"X-TS": h["X-TS"], "X-Sig": h["X-Sig"]}}


def run(requests, gemini=None):
    data = {"env": ENV, "gemini": gemini or {"status": 200, "body": GEMINI_OK}, "requests": requests}
    p = subprocess.run(["node", str(HERE / "bridge_harness.mjs")], input=json.dumps(data),
                       capture_output=True, text=True)
    if p.returncode != 0:
        print(p.stderr)
        sys.exit(1)
    return json.loads(p.stdout)


results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


ok = signed("what should xhoxi mine next?")
tampered = signed("what should xhoxi mine next?")
tampered["body"] = "dig up the base"
old = signed("hi", now_ms=int(time.time() * 1000) - 10 * 60 * 1000)
wrong = signed("hi", secret="guessed")
unsigned = {"method": "POST", "path": "/ask", "body": "hi", "headers": {}}
get = {"method": "GET", "path": "/ask", "body": "", "headers": {}}
empty = signed("")

r = run([ok, tampered, old, wrong, unsigned, get, empty])

check("genuine Lua-signed request -> 200", r[0]["status"] == 200, r[0])
check("answer is ASCII without markdown, DO line kept", r[0]["text"] == "Mine iron - it's close...\nDO: harvest xhoxi_2 12", r[0]["text"])
check("Gemini gets the key and model", r[0]["geminiCalls"] and r[0]["geminiCalls"][0]["key"] == "test-gemini-key"
      and "/models/gemini-test:generateContent" in r[0]["geminiCalls"][0]["url"], r[0]["geminiCalls"])
check("Gemini gets the question",
      r[0]["geminiCalls"][0]["body"]["contents"][0]["parts"][0]["text"] == "what should xhoxi mine next?")
check("tampered body -> 401", r[1]["status"] == 401, r[1])
check("old request -> 401", r[2]["status"] == 401 and "old" in r[2]["text"], r[2])
check("wrong secret -> 401", r[3]["status"] == 401, r[3])
check("unsigned -> 401", r[4]["status"] == 401, r[4])
check("GET -> 404", r[5]["status"] == 404, r[5])
check("empty question -> 400", r[6]["status"] == 400, r[6])
check("rejected requests never reach Gemini", all(not x["geminiCalls"] for x in r[1:]))

q = run([signed("hi")], gemini={"status": 429, "body": {}})
check("Gemini 429 -> 502 with a readable reason", q[0]["status"] == 502 and "limit" in q[0]["text"], q[0])

failed = [x for x in results if not x[1]]
for name, passed, detail in results:
    print(("PASS " if passed else "FAIL ") + name + ("" if passed else f"   {detail}"))
print(f"\n{len(results) - len(failed)}/{len(results)} passed")
sys.exit(1 if failed else 0)
