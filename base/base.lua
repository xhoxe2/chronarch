-- CHRONARCH :: base.lua  (on the computer, save it as startup.lua)
-- Finds every turtle running the agent, shows who is online and sends signed
-- orders. Replies that are not signed with the shared secret are dropped, so a
-- stranger on the air cannot fake a turtle or its results.
--
-- Setup: an ender modem on any side of the computer, and /chronarch.key (the
-- same key as on the turtles).
-- Commands: help | list | mine <name> <length> [depth] | ask <question> | clear

local proto = require("chronarch")
local view = require("statusview")
local oremap = require("oremap")
local PROTOCOL = proto.PROTOCOL
-- The bridge (bridge/worker.js): holds the AI key, so this computer never does.
local BRIDGE_URL = "https://chronarch-bridge.chronarch.workers.dev/ask"

local secret = proto.loadSecret()
if not secret then
  print("No secret found at " .. proto.SECRET_FILE)
  print("The base and every turtle need the same key. See the setup plan.")
  return
end

local modem, err = proto.openModem()
if not modem then print(err); return end

local w, h = term.getSize()
local root = term.current()
local logWin = window.create(root, 1, 1, w, h - 1)
local inputWin = window.create(root, 1, h, w, 1)
local turtles = {} -- name -> { id, fuel, state }

local function out(text, color)
  local old = term.redirect(logWin)
  if color and term.isColor() then term.setTextColor(color) end
  print(text)
  term.setTextColor(colors.white)
  term.redirect(old)
  inputWin.restoreCursor()
end

-- Status monitor (optional: the advanced monitor above the computer) ---------
local monitor = peripheral.find("monitor")
if monitor then pcall(monitor.setTextScale, 0.5) end
local STALE = 12 -- seconds without an answer => turtle shown offline
local MON_COLORS = { white = colors.white, orange = colors.orange, magenta = colors.magenta,
  lightBlue = colors.lightBlue, yellow = colors.yellow, lime = colors.lime, pink = colors.pink,
  gray = colors.gray, lightGray = colors.lightGray, cyan = colors.cyan, purple = colors.purple,
  blue = colors.blue, brown = colors.brown, green = colors.green, red = colors.red, black = colors.black }
-- The monitor shows the turtle list by default; a map only when you ask for one
-- with `map <name>`. Each turtle's ore data accumulates in the background.
local viewMode, mapTarget = "status", nil
local maps = {} -- name -> { name=, ores=, total=, turtle= }
local plan = {}   -- the AI's suggested actions, run in order only after `yes`
local running    -- the plan step in progress; the next starts when it reports back
local lastAuto = {} -- name -> os.clock() of the last automatic problem report to the AI
local commands = {}
local runNext, autoAsk -- defined below, used by receiver()

-- Ore worth set by the player or the AI (`value <ore> <n>`), sent with every
-- harvest so the turtle mines the most valuable ore first. Kept in a file.
local VALUES_FILE = "/values"
local values = {}
if fs.exists(VALUES_FILE) then
  local f = fs.open(VALUES_FILE, "r")
  values = textutils.unserialize(f.readAll()) or {}
  f.close()
end

local function renderStatus()
  local rows = view.format(turtles, os.clock(), STALE)
  for i, row in ipairs(rows) do
    monitor.setCursorPos(1, i)
    monitor.setTextColor(MON_COLORS[row.color] or colors.white)
    monitor.write(row.text)
  end
end

local function renderMap()
  local m = maps[mapTarget] or { name = mapTarget, ores = {} }
  local w, h = monitor.getSize()
  local rows = oremap.render(m.ores or {}, w, h, m)
  for r = 1, #rows do
    monitor.setCursorPos(1, r)
    monitor.blit(rows[r].text, rows[r].fg, rows[r].bg)
  end
end

local function render()
  if not monitor then return end
  monitor.setBackgroundColor(colors.black)
  monitor.setTextColor(colors.white)
  monitor.clear()
  if viewMode == "map" then renderMap() else renderStatus() end
end

local function shortName(n) return (tostring(n):match("[^:]+$")) or tostring(n) end

local function receiver()
  while true do
    local id, msg = proto.receive(secret) -- only correctly signed messages return
    if type(msg.name) == "string" then
      local t = turtles[msg.name]
      if msg.type == "status" then
        if not t then
          out(("+ %s online, fuel %s"):format(msg.name, tostring(msg.fuel)), colors.lime)
        end
        turtles[msg.name] = { id = id, fuel = msg.fuel, state = msg.state, seen = os.clock(), homeY = msg.homeY }
      elseif msg.type == "log" then
        if t then t.seen = os.clock() end
        out("[" .. msg.name .. "] " .. tostring(msg.text), colors.lightGray)
      elseif msg.type == "done" then
        if t then t.state, t.fuel, t.seen = "idle", msg.fuel, os.clock() end
        out(("[%s] job %s, fuel %s"):format(msg.name, msg.ok and "finished" or "FAILED", tostring(msg.fuel)),
          msg.ok and colors.lime or colors.red)
      elseif msg.type == "scan" then
        if t then t.seen = os.clock() end
        if msg.ok then
          maps[msg.name] = { name = msg.name, ores = msg.ores or {}, total = msg.total }
          out(("[%s] scan: %d ores (r=%s)  -> map %s"):format(msg.name, tonumber(msg.total) or 0, tostring(msg.radius), msg.name), colors.lime)
          for _, c in ipairs(msg.counts or {}) do
            out(("    %2d  %s"):format(c.count, shortName(c.name)), colors.lightGray)
          end
          if msg.nearest then
            local nn = msg.nearest
            out(("    nearest %s  d=%s  (x%s y%s z%s)"):format(shortName(nn.name),
              tostring(nn.dist), tostring(nn.x), tostring(nn.y), tostring(nn.z)), colors.cyan)
          end
        else
          out(("[%s] scan failed: %s"):format(msg.name, tostring(msg.text)), colors.orange)
        end
      elseif msg.type == "dig" then
        if t then t.state, t.seen = "idle", os.clock() end
        out(("[%s] dig %s: %s"):format(msg.name, msg.ok and "done" or "FAILED", tostring(msg.text)),
          msg.ok and colors.lime or colors.orange)
        if not msg.ok then autoAsk(msg.name, tostring(msg.text)) end
      elseif msg.type == "harvest" then
        -- accumulate the live map in the background; only redraw if it's on screen.
        -- two kinds of update: with an ore list (after a scan/vein) and
        -- position-only (just the '@' marker, sent every half-second).
        if t then t.seen = os.clock() end
        local m = maps[msg.name] or { name = msg.name, ores = {} }
        if msg.ores then m.ores, m.total = msg.ores, #msg.ores end
        m.name = msg.name
        m.turtle = (not msg.done) and msg.pos or nil
        maps[msg.name] = m
      end
      render()
      -- the running plan step finished -> start the next one (a failure ends the plan)
      local finished = msg.type == "dig" or msg.type == "done" or msg.type == "scan"
      if running and running.name == msg.name and finished then
        if msg.ok then
          runNext()
        else
          plan, running = {}, nil
        end
      end
    end
  end
end

function commands.help()
  out("list                       who is online", colors.yellow)
  out("mine <name> <len> [depth]  send a turtle mining", colors.yellow)
  out("scan <name> [radius]       find ores around a turtle", colors.yellow)
  out("harvest <name> [r] [ore]   find ore within r, mine it, come home", colors.yellow)
  out("explore <name> [r] [ore]   sweep the WHOLE area, mine everything", colors.yellow)
  out("sety <name> <y>            turtle's home height (F3) -> digs to ore depth", colors.yellow)
  out("value <ore> <n>            how much an ore is worth (most valuable first)", colors.yellow)
  out("forget <name>              clear a turtle's map memory", colors.yellow)
  out("stop <name>                recall a turtle (stop, come home)", colors.yellow)
  out("map <name> | status        show a turtle's ore map / the list", colors.yellow)
  out("(tap an ore on the map -> harvest that cluster)", colors.lightGray)
  out("ask <question>             ask the AI (English)", colors.yellow)
  out("yes                        run what the AI suggested", colors.yellow)
  out("clear                      clear the screen", colors.yellow)
end

function commands.list()
  proto.broadcast(secret, { cmd = "ping" })
  sleep(1) -- answers arrive in receiver()
  local names = {}
  for n in pairs(turtles) do names[#names + 1] = n end
  table.sort(names)
  if #names == 0 then
    out("No turtles found. Is agent running on them?", colors.orange)
  end
  for _, n in ipairs(names) do
    local t = turtles[n]
    out(("%-10s #%-3d fuel %-7s %s"):format(n, t.id, tostring(t.fuel), t.state))
  end
end

function commands.mine(name, length, depth)
  if not name then
    out("Usage: mine <name> <length> [depth]", colors.orange)
    return
  end
  local id = turtles[name] and turtles[name].id or rednet.lookup(PROTOCOL, name)
  if not id then
    out("Unknown turtle: " .. name .. "  (try: list)", colors.red)
    return
  end
  length, depth = tonumber(length) or 16, tonumber(depth) or 0
  proto.send(secret, id, { cmd = "mine", length = length, depth = depth })
  if turtles[name] then turtles[name].state = "busy" end
  out(("-> %s: mine %d, depth %d"):format(name, length, depth), colors.cyan)
  render()
end

function commands.scan(name, radius)
  if not name then
    out("Usage: scan <name> [radius]", colors.orange)
    return
  end
  local id = turtles[name] and turtles[name].id or rednet.lookup(PROTOCOL, name)
  if not id then
    out("Unknown turtle: " .. name .. "  (try: list)", colors.red)
    return
  end
  radius = tonumber(radius) or 8
  proto.send(secret, id, { cmd = "scan", radius = radius })
  if turtles[name] then turtles[name].state = "scanning" end
  out(("-> %s: scan radius %d"):format(name, radius), colors.cyan)
  render()
end

local function areaJob(cmd, name, radius, ore)
  if not name then
    out(("Usage: %s <name> [radius] [ore]"):format(cmd), colors.orange)
    return
  end
  local id = turtles[name] and turtles[name].id or rednet.lookup(PROTOCOL, name)
  if not id then
    out("Unknown turtle: " .. name .. "  (try: list)", colors.red)
    return
  end
  radius = tonumber(radius) or 12
  proto.send(secret, id, { cmd = "mineArea", radius = radius, ore = ore, explore = cmd == "explore", values = values })
  if turtles[name] then turtles[name].state = "digging" end
  out(("-> %s: %s r%d%s   (watch live: map %s)"):format(name, cmd, radius,
    ore and (" only " .. ore) or "", name), colors.cyan)
end

-- sety: tell a turtle the height of its home (y on the F3 screen / minimap), so
-- harvest of a vanilla ore digs down to that ore's best depth by itself.
function commands.sety(name, y)
  local id = name and (turtles[name] and turtles[name].id or rednet.lookup(PROTOCOL, name))
  if not id or not tonumber(y) then
    out("Usage: sety <name> <y>   (y of the turtle's spot, from F3)", colors.orange)
    return
  end
  proto.send(secret, id, { cmd = "sety", y = tonumber(y) })
  out(("-> %s: home height y=%d"):format(name, tonumber(y)), colors.cyan)
end

function commands.value(ore, n)
  if not ore then
    for k, v in pairs(values) do out(("%-16s %d"):format(k, v)) end
    out("Usage: value <ore> <n>  (n=0 removes; defaults: coal 1 ... diamond 10)", colors.orange)
    return
  end
  values[ore] = (tonumber(n) and tonumber(n) > 0) and tonumber(n) or nil
  local f = fs.open(VALUES_FILE, "w")
  f.write(textutils.serialize(values))
  f.close()
  out(("Ore value: %s = %s"):format(ore, tostring(values[ore] or "default")), colors.cyan)
end

function commands.forget(name)
  local id = name and (turtles[name] and turtles[name].id or rednet.lookup(PROTOCOL, name))
  if not id then
    out("Usage: forget <name>   (clear what it remembers, e.g. after moving its home)", colors.orange)
    return
  end
  proto.send(secret, id, { cmd = "forget" })
end

-- harvest: search within the radius until it finds ore, mine it, come home.
-- explore: sweep the whole area, deep and far, and mine everything.
function commands.harvest(...) areaJob("harvest", ...) end
function commands.explore(...) areaJob("explore", ...) end

function commands.stop(name)
  if not name then
    out("Usage: stop <name>", colors.orange)
    return
  end
  local id = turtles[name] and turtles[name].id or rednet.lookup(PROTOCOL, name)
  if not id then
    out("Unknown turtle: " .. name .. "  (try: list)", colors.red)
    return
  end
  proto.send(secret, id, { cmd = "stop" })
  out(("-> %s: stop and come home"):format(name), colors.cyan)
end

function commands.map(name)
  if name then mapTarget = name end
  if not mapTarget then
    out("Usage: map <name>", colors.orange)
    return
  end
  viewMode = "map"
  render()
  out(("Monitor: %s ore map"):format(mapTarget), colors.lightGray)
end

function commands.status()
  viewMode = "status"
  render()
  out("Monitor: turtle list", colors.lightGray)
end

-- The answer comes back later as an http_success/http_failure event (asker).
-- The AI also gets the live colony status, so it answers about this colony.
local function askAI(q)
  q = (q:gsub("[\128-\255]", "?"))
  local body = q .. "\n\n" .. view.summary(turtles, maps, os.clock(), STALE)
  local vs = {}
  for k, v in pairs(values) do vs[#vs + 1] = k .. "=" .. v end
  if #vs > 0 then body = body .. "\nCustom ore values: " .. table.concat(vs, ", ") end
  http.request({ url = BRIDGE_URL, method = "POST", body = body,
    headers = proto.signRequest(secret, body, os.epoch("utc")) })
end

function commands.ask(...)
  local q = table.concat({ ... }, " ")
  if q == "" then
    out("Usage: ask <question>", colors.orange)
    return
  end
  askAI(q)
  out("-> AI: " .. q, colors.cyan)
end

-- Run the next step of the AI's plan. A step counts as done when its turtle
-- reports back (see receiver); `stop` to an idle turtle is done at once.
function runNext()
  running = table.remove(plan, 1)
  if not running then return end
  local a = running
  commands[a.cmd](a.name, a.n, a.ore)
  if a.cmd == "value" or (a.cmd == "stop" and (not turtles[a.name] or turtles[a.name].state == "idle")) then
    runNext()
  end
end

function commands.yes()
  if #plan == 0 then
    out("The AI has not suggested anything.", colors.orange)
    return
  end
  runNext()
end

-- A turtle reported a problem: ask the AI what to do, at most once a minute
-- per turtle, so a repeating failure cannot burn the free quota.
function autoAsk(name, text)
  local now = os.clock()
  if lastAuto[name] and now - lastAuto[name] < 60 then return end
  lastAuto[name] = now
  askAI(("Turtle %s reported a problem: %s. What should I do?"):format(name, text))
  out("-> AI (auto): what to do about " .. name .. "?", colors.lightGray)
end

function commands.clear()
  logWin.clear()
  logWin.setCursorPos(1, 1)
end

local function console()
  local history = {}
  term.redirect(inputWin)
  while true do
    inputWin.clear()
    inputWin.setCursorPos(1, 1)
    if term.isColor() then term.setTextColor(colors.yellow) end
    write("> ")
    term.setTextColor(colors.white)
    local line = read(nil, history)
    if line and line:find("%S") then
      history[#history + 1] = line
      local words = {}
      for word in line:gmatch("%S+") do words[#words + 1] = word end
      local fn = commands[words[1]]
      if fn then
        fn(table.unpack(words, 2))
      else
        out("Unknown command. Type: help", colors.orange)
      end
    end
  end
end

-- Tap an ore on the map (monitor touch) -> send that turtle to dig it.
local function toucher()
  while true do
    local _, _, tx, ty = os.pullEvent("monitor_touch")
    local m = maps[mapTarget]
    if monitor and viewMode == "map" and m and m.name then
      local w, h = monitor.getSize()
      local ore = oremap.hitTest(m.ores or {}, w, h, tx, ty, m)
      if ore then
        local tname = m.name
        local id = turtles[tname] and turtles[tname].id or rednet.lookup(PROTOCOL, tname)
        if id then
          proto.send(secret, id, { cmd = "mineArea", radius = 6, cx = ore.x, cy = ore.y, cz = ore.z })
          if turtles[tname] then turtles[tname].state = "digging" end
          out(("-> %s: harvest cluster %s (x%d y%d z%d)"):format(tname, oremap.short(ore.name), ore.x, ore.y, ore.z), colors.cyan)
        else
          out("Unknown turtle: " .. tostring(tname), colors.red)
        end
      end
    end
  end
end

local function asker()
  while true do
    local ev, url, a, b = os.pullEvent()
    if (ev == "http_success" or ev == "http_failure") and url == BRIDGE_URL then
      local res = ev == "http_success" and a or b -- failure carries a handle on 4xx/5xx
      local text = res and res.readAll() or tostring(a)
      if res then res.close() end
      if ev == "http_success" then
        local answer, acts = view.parseActions(text, turtles)
        out("AI: " .. answer, colors.lime)
        if #acts > 0 then
          plan, running = acts, nil
          for i, a in ipairs(acts) do out(("AI plan %d: %s"):format(i, a.line), colors.yellow) end
          out("(type yes to run)", colors.yellow)
        end
      else
        out("AI: " .. text, colors.red)
      end
    end
  end
end

-- Pings everyone every few seconds so the monitor stays fresh and offline
-- turtles get noticed. Calm rhythm: one broadcast per cycle.
local function ticker()
  while true do
    proto.broadcast(secret, { cmd = "ping" })
    render()
    sleep(5)
  end
end

root.clear()
out("CHRONARCH base #" .. os.getComputerID() .. " online. Type: help", colors.yellow)
if monitor then out("Status monitor attached.", colors.lightGray) end
proto.broadcast(secret, { cmd = "ping" })
render()
-- On exit (Ctrl+T) put the terminal back, so the shell is visible again.
local okRun, runErr = pcall(parallel.waitForAny, receiver, console, ticker, toucher, asker)
term.redirect(root)
term.setTextColor(colors.white)
term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
if not okRun and tostring(runErr) ~= "Terminated" then printError(runErr) end
