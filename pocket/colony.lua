-- CHRONARCH :: colony.lua  (on a pocket computer with an ender modem)
-- The colony in your pocket: asks every turtle for its status every few
-- seconds and shows fuel, state (SOS in red) and position. Talks straight to
-- the turtles, so it works anywhere, even when the base is not loaded.
-- Needs chronarch.lua, statusview.lua and the same /chronarch.key.
--
--   colony        (Q to quit)

local proto = require("chronarch")
local view = require("statusview")

local secret = proto.loadSecret()
if not secret then print("No secret at " .. proto.SECRET_FILE); return end
local modem, err = proto.openModem()
if not modem then print(err); return end

local turtles = {}

local function draw()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()
  for i, r in ipairs(view.compact(turtles, os.clock(), 12)) do
    if i >= h then break end
    term.setCursorPos(1, i)
    if term.isColor() then term.setTextColor(colors[r.color] or colors.white) end
    term.write(r.text:sub(1, w))
  end
  term.setCursorPos(1, h)
  term.setTextColor(colors.gray)
  term.write("CHRONARCH  Q: quit")
end

local function listen()
  while true do
    local id, msg = proto.receive(secret) -- only correctly signed messages
    if msg.type == "status" and type(msg.name) == "string" then
      turtles[msg.name] = { id = id, fuel = msg.fuel, state = msg.state, seen = os.clock(), pos = msg.pos }
      draw()
    end
  end
end

local function poll()
  while true do
    proto.broadcast(secret, { cmd = "ping" })
    draw()
    sleep(3)
  end
end

local function quit()
  repeat local _, k = os.pullEvent("key") until k == keys.q
end

parallel.waitForAny(listen, poll, quit)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
