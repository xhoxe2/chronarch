"""Shared bits for the CHRONARCH Lua tests.

CC: Tweaked ships a `bit32` API; lupa's Lua 5.5 does not. This provides a
bit32 shim built on native 5.3+ operators, so the exact in-game chronarch.lua
runs unchanged under the tests.
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
ROM = HERE / "ccrom"

# A bit32 shim, as Lua source that sets the global `bit32`.
BIT32 = r"""
local MASK = 0xFFFFFFFF
bit32 = {
  band = function(a, ...) local r=a&MASK for _,v in ipairs({...}) do r=r&v end return r&MASK end,
  bor  = function(a, ...) local r=a&MASK for _,v in ipairs({...}) do r=r|v end return r&MASK end,
  bxor = function(a, ...) local r=a&MASK for _,v in ipairs({...}) do r=r~v end return r&MASK end,
  bnot = function(a) return (~a)&MASK end,
  lshift = function(a,n) return (a<<n)&MASK end,
  rshift = function(a,n) return (a&MASK)>>n end,
  rrotate = function(a,n) a=a&MASK n=n%32 return ((a>>n)|(a<<(32-n)))&MASK end,
}
"""

CHRONARCH = (ROOT / "lib" / "chronarch.lua").read_text()


def load_chronarch(lua):
    """Install bit32 + a minimal textutils, then return the chronarch module."""
    loader = lua.eval(r"""function(bit32src, libsrc)
        load(bit32src)()
        return load(libsrc, "chronarch.lua")()
    end""")
    return loader(BIT32, CHRONARCH)
