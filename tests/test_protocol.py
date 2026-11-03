"""Tests for common/chronarch.lua: SHA-256, HMAC and message signing.

Pure logic, no network. Run from the project root:
    .venv/bin/python tests/test_protocol.py
"""
import sys
from pathlib import Path
from lupa import LuaRuntime

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cchelpers import load_chronarch  # noqa: E402

lua = LuaRuntime(unpack_returned_tuples=True)
M = load_chronarch(lua)
# Build a Lua table from a constructor string, e.g. mk("{a=1, b='x'}").
mk = lua.eval("function(src) return load('return ' .. src)() end")

results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))


# --- SHA-256 / HMAC against published vectors -----------------------------
check("sha256 empty", M.sha256("") ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
check("sha256 abc", M.sha256("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
check("sha256 56 bytes", M.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
check("hmac rfc4231 case2", M.hmac("Jefe", "what do ya want for nothing?") ==
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")

# --- sign / verify ---------------------------------------------------------
SECRET = "correct horse battery staple"

msg = mk("{type='status', name='xhoxi', fuel=800, state='idle'}")
M.sign(SECRET, msg)
check("sign adds a 64-hex signature", isinstance(msg.sig, str) and len(msg.sig) == 64, msg.sig)
check("verify accepts a genuine message", M.verify(SECRET, msg) is True)
check("verify rejects the wrong secret", M.verify("guessed", msg) is False)

msg.fuel = 1  # tamper after signing
check("verify rejects a tampered field", M.verify(SECRET, msg) is False)

unsigned = mk("{cmd='mine', length=9999, depth=64}")
check("verify rejects an unsigned message", M.verify(SECRET, unsigned) is False)
check("verify rejects a non-table", M.verify(SECRET, "open") is False)

# A forged signature of the right length must still fail (constant-time eq).
ping = mk("{cmd='ping'}")
M.sign(SECRET, ping)
flipped = ("0" if ping.sig[0] != "0" else "1") + ping.sig[1:]
ping.sig = flipped
check("verify rejects a bogus same-length signature", M.verify(SECRET, ping) is False)

# --- canonical form: order of keys must not matter -------------------------
a = mk("{type='mine', cmd='mine', length=16, depth=0}")
b = mk("{depth=0, length=16, cmd='mine', type='mine'}")
check("canon ignores key order", M.canon(a) == M.canon(b), (M.canon(a), M.canon(b)))
check("canon separates different values",
      M.canon(mk("{length=16}")) != M.canon(mk("{length=17}")))

# So a message rebuilt in a different key order (as rednet does on the wire)
# still verifies with the same signature.
M.sign(SECRET, a)
sig_a = a.sig
M.sign(SECRET, b)
check("same content signs the same regardless of key order", b.sig == sig_a, (sig_a, b.sig))

width = max(len(n) for n, _, _ in results)
for n, good, d in results:
    print(("PASS " if good else "FAIL ") + n.ljust(width) + ("" if good else f"  -> {d}"))
print(f"\n{sum(g for _, g, _ in results)}/{len(results)} passed")
sys.exit(0 if all(g for _, g, _ in results) else 1)
