-- CHRONARCH :: buddy.lua  (on a pocket computer with an ender modem)
-- Your turtle on a leash: type an order, it goes where YOU are (the pocket
-- computer asks GPS for your position and sends it along, signed).
--   xhoxi come here     xhoxi follow     xhoxi stay     xhoxi home
--   xhoxi stash         xhoxi dig here 8                xhoxi light
-- The turtle's name can be left out when only one is around. Ctrl+T quits.
-- Needs chronarch.lua, statusview.lua, buddycmd.lua and /chronarch.key.

if package then package.path = "/lib/?.lua;" .. package.path end -- our libraries live in /lib
local proto = require("chronarch")
local view = require("statusview")
local buddy = require("buddycmd")

local secret = proto.loadSecret()
if not secret then print("No secret at " .. proto.SECRET_FILE); return end
local modem, err = proto.openModem()
if not modem then print(err); return end

local w, h = term.getSize()
local root = term.current()
local top = window.create(root, 1, 1, w, h - 2)
local msgLine = window.create(root, 1, h - 1, w, 1)
local input = window.create(root, 1, h, w, 1)
local turtles, last, following, followAt = {}, nil, nil, nil

local function say(text, color)
  msgLine.setBackgroundColor(colors.black)
  msgLine.clear()
  msgLine.setCursorPos(1, 1)
  msgLine.setTextColor(color or colors.white)
  msgLine.write(tostring(text):sub(1, w))
  input.restoreCursor()
end

local function draw()
  top.setBackgroundColor(colors.black)
  top.clear()
  local rows = view.compact(turtles, os.clock(), 12)
  for i, r in ipairs(rows) do
    if i > h - 2 then break end
    top.setCursorPos(1, i)
    top.setTextColor(colors[r.color] or colors.white)
    top.write(r.text:sub(1, w))
  end
  if following then
    top.setCursorPos(1, h - 2)
    top.setTextColor(colors.cyan)
    top.write(("following: %s"):format(following):sub(1, w))
  end
  input.restoreCursor()
end

-- Where you are. Above or below the plane of three GPS hosts the answer is
-- ambiguous until the fourth one replies, so give it time and one more try.
local function me()
  local x, y, z = gps.locate(2)
  if not x then x, y, z = gps.locate(3) end
  if not x then return nil end
  return { x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5) }
end

local function send(name, body)
  local t = turtles[name]
  if not t then say("no turtle " .. name, colors.red); return false end
  proto.send(secret, t.id, body)
  return true
end

local function comeTo(name, p)
  return send(name, { cmd = "goto", x = p.x, y = p.y, z = p.z, near = 2 })
end

local function act(a)
  last = a.to
  if a.cmd == "come" or a.cmd == "follow" or a.cmd == "dig" then
    local p = me()
    if not p then say("no GPS fix: try gps locate", colors.red); return end
    if a.cmd == "dig" then
      if send(a.to, { cmd = "mineArea", radius = a.radius, wx = p.x, wy = p.y, wz = p.z }) then
        say(("%s: digging round %d,%d,%d"):format(a.to, p.x, p.y, p.z), colors.cyan)
      end
      return
    end
    if comeTo(a.to, p) then
      if a.cmd == "follow" then following, followAt = a.to, p end
      say(("%s: coming to %d,%d,%d"):format(a.to, p.x, p.y, p.z), colors.cyan)
    end
  elseif a.cmd == "stop" then
    following = nil
    if send(a.to, { cmd = "stop" }) then say(a.to .. ": stop", colors.cyan) end
  else -- home, stash, light
    if a.cmd == "home" then following = nil end
    if send(a.to, { cmd = a.cmd }) then say(a.to .. ": " .. a.cmd, colors.cyan) end
  end
  draw()
end

local function listen()
  while true do
    local id, msg = proto.receive(secret) -- only correctly signed messages
    if type(msg.name) == "string" then
      if msg.type == "status" then
        turtles[msg.name] = { id = id, fuel = msg.fuel, state = msg.state, seen = os.clock(), pos = msg.pos }
        draw()
      elseif msg.type == "log" or msg.type == "dig" then
        say(msg.name .. ": " .. tostring(msg.text), msg.ok == false and colors.red or colors.lime)
      end
    end
  end
end

local function poll()
  while true do
    proto.broadcast(secret, { cmd = "ping" })
    sleep(3)
  end
end

-- Follow mode: every few seconds, if you moved 3+ blocks, send the new spot.
local function follow()
  while true do
    sleep(4)
    if following then
      local p = me()
      if p and (math.abs(p.x - followAt.x) + math.abs(p.y - followAt.y) + math.abs(p.z - followAt.z)) >= 3 then
        followAt = p
        comeTo(following, p)
      end
    end
  end
end

local function console()
  local history = {}
  while true do
    input.setBackgroundColor(colors.black)
    input.clear()
    input.setCursorPos(1, 1)
    input.setTextColor(colors.yellow)
    input.write("buddy> ")
    input.setTextColor(colors.white)
    local old = term.redirect(input)
    local line = read(nil, history)
    term.redirect(old)
    if line and line:find("%S") then
      history[#history + 1] = line
      local known = {}
      for n in pairs(turtles) do known[n] = true end
      local a, why = buddy.parse(line, known, last)
      if a then act(a) else say(why, colors.orange) end
    end
  end
end

root.clear()
say("CHRONARCH \183 buddy  e.g. come here", colors.lightGray)
draw()
proto.broadcast(secret, { cmd = "ping" })
parallel.waitForAny(listen, poll, follow, console)
term.redirect(root)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
