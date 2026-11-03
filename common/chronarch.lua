-- CHRONARCH :: chronarch.lua  (shared library, put it in the computer root)
-- Message signing for the "chronarch" rednet protocol, so a turtle obeys only
-- orders from someone who knows the shared secret, and the base trusts only
-- real turtles. Everything else off the air is dropped.
--
-- Load it:  local proto = require("chronarch")
--
-- ponytail: HMAC-SHA256 stops FORGED messages, not REPLAYED ones. Someone who
-- records a valid signed order can resend it. Add a nonce + seen-set in sign()/
-- verify() if replay ever matters; for stopping stray/forged commands this is
-- enough.

local M = { PROTOCOL = "chronarch" }

-- SHA-256 ------------------------------------------------------------------
-- Pure Lua over bit32 (present in CC: Tweaked). Tests feed a bit32 shim.
local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local rshift, lshift, rrotate = bit32.rshift, bit32.lshift, bit32.rrotate
local MOD = 0x100000000

local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function u32be(n)
  return string.char(band(rshift(n, 24), 0xff), band(rshift(n, 16), 0xff),
    band(rshift(n, 8), 0xff), band(n, 0xff))
end

local function sha256_raw(msg)
  local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
              0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
  local bitlen = #msg * 8
  msg = msg .. "\128"
  while (#msg % 64) ~= 56 do msg = msg .. "\0" end
  msg = msg .. u32be(math.floor(bitlen / MOD)) .. u32be(bitlen % MOD)

  for i = 1, #msg, 64 do
    local w = {}
    for j = 0, 15 do
      local a, b, c, d = msg:byte(i + j * 4, i + j * 4 + 3)
      w[j] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
    end
    for j = 16, 63 do
      local x, y = w[j - 15], w[j - 2]
      local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
      local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
      w[j] = (w[j - 16] + s0 + w[j - 7] + s1) % MOD
    end
    local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    for j = 0, 63 do
      local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = (h + S1 + ch + K[j + 1] + w[j]) % MOD
      local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local t2 = (S0 + maj) % MOD
      h = g; g = f; f = e; e = (d + t1) % MOD; d = c; c = b; b = a; a = (t1 + t2) % MOD
    end
    H[1] = (H[1] + a) % MOD; H[2] = (H[2] + b) % MOD; H[3] = (H[3] + c) % MOD; H[4] = (H[4] + d) % MOD
    H[5] = (H[5] + e) % MOD; H[6] = (H[6] + f) % MOD; H[7] = (H[7] + g) % MOD; H[8] = (H[8] + h) % MOD
  end

  local out = {}
  for i = 1, 8 do out[i] = u32be(H[i]) end
  return table.concat(out)
end

local function hmac_raw(key, msg)
  if #key > 64 then key = sha256_raw(key) end
  key = key .. string.rep("\0", 64 - #key)
  local ipad, opad = {}, {}
  for i = 1, 64 do
    local b = key:byte(i)
    ipad[i] = string.char(bxor(b, 0x36))
    opad[i] = string.char(bxor(b, 0x5c))
  end
  return sha256_raw(table.concat(opad) .. sha256_raw(table.concat(ipad) .. msg))
end

local function tohex(s)
  return (s:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

M.sha256 = function(s) return tohex(sha256_raw(s)) end
M.hmac = function(key, s) return tohex(hmac_raw(key, s)) end

-- Canonical serialization --------------------------------------------------
-- textutils.serialize does NOT sort keys, so sender and receiver could build
-- different strings for the same table. This one sorts keys, so the signed
-- bytes are the same on both ends.
local function canon(v)
  local t = type(v)
  if t == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = tostring(k) .. "=" .. canon(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "number" then
    if v % 1 == 0 then return "n:" .. ("%d"):format(v) end
    return "n:" .. tostring(v)
  elseif t == "boolean" then
    return "b:" .. tostring(v)
  else
    return "s:" .. tostring(v)
  end
end
M.canon = canon

-- Constant-time string compare: don't leak where the signature first differs.
local function eq(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do diff = bor(diff, bxor(a:byte(i), b:byte(i))) end
  return diff == 0
end

-- Sign / verify ------------------------------------------------------------
-- sign adds msg.sig in place and returns the table. verify leaves msg as it
-- found it and returns true only if the signature matches the secret.
function M.sign(secret, msg)
  msg.sig = nil
  msg.sig = M.hmac(secret, canon(msg))
  return msg
end

function M.verify(secret, msg)
  if type(msg) ~= "table" or type(msg.sig) ~= "string" then return false end
  local sig = msg.sig
  msg.sig = nil
  local good = M.hmac(secret, canon(msg))
  msg.sig = sig
  return eq(good, sig)
end

-- Headers for a signed HTTP request to the bridge (bridge/worker.js).
-- now = os.epoch("utc") in ms; the bridge refuses requests older than 2 min.
function M.signRequest(secret, body, now)
  local ts = ("%d"):format(now)
  -- A plain User-Agent: Cloudflare rejects some generic client ones (error 1010).
  return { ["X-TS"] = ts, ["X-Sig"] = M.hmac(secret, ts .. "\n" .. body),
    ["User-Agent"] = "chronarch-base" }
end

-- Signed rednet wrappers ---------------------------------------------------
-- All traffic goes through these, so a script can never forget to sign on the
-- way out or to check on the way in.
function M.send(secret, id, body, protocol)
  M.sign(secret, body)
  rednet.send(id, body, protocol or M.PROTOCOL)
end

function M.broadcast(secret, body, protocol)
  M.sign(secret, body)
  rednet.broadcast(body, protocol or M.PROTOCOL)
end

-- Receive, dropping anything that is not correctly signed. timeout is shared
-- across dropped junk, so a flood of garbage cannot keep us waiting forever.
function M.receive(secret, timeout, protocol)
  protocol = protocol or M.PROTOCOL
  local deadline = timeout and (os.clock() + timeout) or nil
  while true do
    local t = deadline and math.max(0, deadline - os.clock()) or nil
    local from, msg = rednet.receive(protocol, t)
    if from == nil then return nil end
    if M.verify(secret, msg) then return from, msg end
  end
end

-- Game-side helpers (not reached by tests) ---------------------------------
M.SECRET_FILE = "/chronarch.key"

function M.loadSecret(path)
  path = path or M.SECRET_FILE
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local s = f.readAll()
  f.close()
  return (s:gsub("%s+$", ""))
end

function M.openModem()
  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then return nil, "No ender/wireless modem attached." end
  rednet.open(peripheral.getName(modem))
  return peripheral.getName(modem)
end

return M
