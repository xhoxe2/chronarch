-- CHRONARCH :: cx.lua  - the one command on every CHRONARCH machine
--
--   cx                where am I: this machine, its program, what to type
--   cx list           all CHRONARCH programs
--   cx help           the commands of this machine's program
--   cx update         download the latest code of this machine's program
--   cx install <p>    put another program on this machine (gps: cx install gps x y z)
--   cx <command>      run one of this program's commands, e.g. cx buddy
--
-- Every machine runs ONE program (kept in /.program). Its files come from the
-- public GitHub repo: programs/<program>/<file> and lib/<library>.lua, the
-- same layout as on the machine. The secret /chronarch.key is never fetched
-- or touched. First time on a fresh machine: copy cx.lua in (single-player
-- world) or `pastebin get <code> cx` (server), then `cx install <program>`.

local USER, REPO, BRANCH = "xhoxe2", "chronarch", "main"
local API = ("https://api.github.com/repos/%s/%s/commits/%s"):format(USER, REPO, BRANCH)
-- Data files start with a dot: hidden from `ls`/`programs`, never mistaken
-- for a command. Older versions used names without the dot.
local PROGRAM_FILE = "/.program"
local function migrate(old, new)
  if fs.exists and fs.move and not fs.exists(new) and fs.exists(old) then fs.move(old, new) end
end

-- The CHRONARCH programs. files: programs/<name>/<file> -> /<file>.
-- libs: lib/<lib>.lua -> /lib/<lib>.lua. help: what to type, for `cx help`.
local PROGRAMS = {
  mining = {
    needs = "turtle", files = { "startup.lua", "mine.lua" }, libs = { "navigate", "orescan" },
    about = "miner: harvest, scan, swarm, buddy orders",
    run = "starts by itself",
    help = {
      "Runs by itself; orders come by radio",
      "from the base (base>) and the pocket (buddy>).",
      "Ctrl+T stops it, hold Ctrl+R to restart.",
      "Keep in it: Geo Scanner, bucket, coal,",
      "Chunk Controller, EnderStorage chest.",
    },
  },
  control = {
    needs = "computer/pocket", files = { "startup.lua" }, libs = { "statusview", "oremap", "swarm" },
    about = "base + monitor: commands, map, AI, swarm",
    run = "starts by itself, type at base>",
    help = {
      "Type at base>   (help shows them all)",
      " list                 who is online",
      " harvest xhoxi 16 diamond   find+dig",
      " explore xhoxi 24     sweep an area",
      " swarm 32 diamond     all turtles",
      " map xhoxi | status   monitor view",
      " stop xhoxi           come home",
      " ask <question>       ask the AI, yes",
    },
  },
  buddy = {
    needs = "pocket", files = { "buddy.lua", "colony.lua" }, libs = { "statusview", "buddycmd" },
    about = "pocket: come here, follow, home + colony",
    run = "cx buddy  (or cx colony)",
    help = {
      "cx buddy, then at buddy>:",
      " come here | follow | stay",
      " home | stash | light",
      " dig here 8",
      "cx colony: only watch turtles",
    },
  },
  pilot = {
    needs = "computer", files = { "pilot.lua" }, libs = { "pilot" },
    about = "autopilot: learns any craft, WASD flight",
    run = "pilot calibrate, then pilot",
    help = {
      "On the craft's computer:",
      " pilot calibrate   once, on its legs",
      " pilot [height]    take off (1st: scan)",
      " pilot forward north   W direction",
      "Fly: WASD, Space/Shift, L land,",
      " any other key = all thrusters off",
    },
  },
  gps = {
    needs = "computer", files = { "startup.lua" }, libs = {},
    about = "GPS host: gives everyone coordinates",
    run = "starts by itself",
    help = {
      "Runs by itself: answers gps locate.",
      "Its position is in /.gps.pos;",
      "set it: cx install gps <x> <y> <z>",
    },
  },
}
local ORDER = { "mining", "control", "buddy", "pilot", "gps" }
local SOON = { { "scout", "explorer: spawners, dungeons, cities" },
               { "carve", "digs rooms and halls underground" } }
-- Other names people type (and older names) for the same programs.
local ALIASES = { base = "control", colony = "buddy", miner = "mining", mine = "mining",
  helper = "buddy", pocket = "buddy", turtle = "mining" }
-- Libraries that older versions kept in the root; removed after an update.
local LEGACY = { "chronarch.lua", "statusview.lua", "navigate.lua", "orescan.lua",
  "oremap.lua", "swarm.lua", "buddycmd.lua" }

local function kindHere() return turtle and "turtle" or pocket and "pocket" or "computer" end
local function guess() return turtle and "mining" or pocket and "buddy" or "control" end

local function savedProgram()
  migrate("/program", PROGRAM_FILE)
  if not fs.exists(PROGRAM_FILE) then return nil end
  local f = fs.open(PROGRAM_FILE, "r")
  local p = (f.readAll() or ""):gsub("%s+", "")
  f.close()
  p = ALIASES[p] or p
  return PROGRAMS[p] and p or nil
end
local function current() return savedProgram() or guess() end

-- raw.githubusercontent.com caches a branch for ~5 minutes, so an update right
-- after a push could pull the old code. A commit's files never change: ask
-- GitHub for the latest commit and download from it. Without the API (60
-- calls/hour), fall back to the branch.
local function latestRaw()
  local base = "https://raw.githubusercontent.com/%s/%s/%s/"
  local res = http.get(API, { Accept = "application/vnd.github.sha" })
  if res then
    local sha = res.readAll()
    res.close()
    if sha and sha:match("^%x+$") and #sha == 40 then return base:format(USER, REPO, sha), sha end
  end
  return base:format(USER, REPO, BRANCH), BRANCH
end

-- local path -> repo path, for one program
local function plan(name)
  local p = PROGRAMS[name]
  local files = {
    ["cx.lua"] = "cx.lua", ["update.lua"] = "update.lua", ["program.lua"] = "program.lua",
    ["programs-custom.lua"] = "programs-custom.lua", ["lib/chronarch.lua"] = "lib/chronarch.lua",
  }
  for _, f in ipairs(p.files) do files[f] = "programs/" .. name .. "/" .. f end
  for _, l in ipairs(p.libs) do files["lib/" .. l .. ".lua"] = "lib/" .. l .. ".lua" end
  return files
end

-- Download one file and write it. An empty body (a 404 page) is a failure,
-- so good code is never overwritten with junk.
local function fetch(raw, localPath, repoPath)
  local res, err = http.get(raw .. repoPath)
  if not res then return false, err or "no response" end
  local data = res.readAll()
  res.close()
  if not data or #data == 0 then return false, "empty body" end
  local dir = fs.getDir and fs.getDir(localPath) or ""
  if dir ~= "" and fs.makeDir then fs.makeDir(dir) end
  local f, ferr = fs.open(localPath, "w")
  if not f then return false, ferr or "cannot write" end
  f.write(data)
  f.close()
  return true
end

local function download(name)
  if not http then print("HTTP is off in the CC config; cannot download."); return false end
  local raw, ref = latestRaw()
  print(("CHRONARCH %s <- %s/%s @ %s"):format(name, USER, REPO, ref:sub(1, 7)))
  local files, names = plan(name), {}
  for k in pairs(files) do names[#names + 1] = k end
  table.sort(names)
  local fail = 0
  for _, path in ipairs(names) do
    local good, why = fetch(raw, path, files[path])
    if not good then fail = fail + 1 end
    print((good and "  ok   " or "  FAIL ") .. path .. (good and "" or (" (" .. tostring(why) .. ")")))
  end
  if fail > 0 then print(("%d failed. Check HTTP, then cx update again."):format(fail)); return false end
  for _, old in ipairs(LEGACY) do if fs.exists(old) then fs.delete(old) end end
  print("Done. Hold Ctrl+R to restart with it.")
  return true
end

-- Commands -----------------------------------------------------------------

local function where()
  local name = current()
  local p = PROGRAMS[name]
  local label = os.getComputerLabel and os.getComputerLabel()
  print("CHRONARCH")
  print((" machine: %s #%s%s"):format(kindHere(), tostring(os.getComputerID and os.getComputerID()),
    label and (' "' .. label .. '"') or ""))
  print((" program: %s - %s"):format(name, p.about))
  print(" start:   " .. p.run)
  print("cx help | cx list | cx update")
end

-- One line per program; the descriptions only where there is room for them
-- (a pocket computer is 26 wide).
local function list()
  local wide = not (term and term.getSize) or term.getSize() >= 40
  print("CHRONARCH programs:")
  for _, name in ipairs(ORDER) do
    local p = PROGRAMS[name]
    print((" %-8s %-15s %s"):format(name, p.needs, wide and p.about or ""))
  end
  for _, s in ipairs(SOON) do print((" %-8s %-15s %s"):format(s[1], "soon", wide and s[2] or "")) end
  print(("This %s runs: %s"):format(kindHere(), current()))
  print("Change: cx install <name>")
end

local function help()
  local name = current()
  print(("CHRONARCH %s:"):format(name))
  for _, line in ipairs(PROGRAMS[name].help) do print(line) end
  print("Anywhere: cx | cx list | cx update")
end

local function install(name, ...)
  name = name and (ALIASES[name] or name)
  local p = PROGRAMS[name or ""]
  if not p then
    -- short, so it stays on screen: no list dump
    print(("No program '%s'."):format(tostring(name)))
    print("Programs: mining, control, buddy, pilot, gps")
    print("This " .. kindHere() .. " can run: " .. (turtle and "mining" or pocket and "buddy" or "control, pilot, gps"))
    return
  end
  if not p.needs:find(kindHere(), 1, true) then
    print(("'%s' is for a %s,"):format(name, p.needs))
    print(("this is a %s: it runs %s."):format(kindHere(), current()))
    return
  end
  if name == "gps" then -- a GPS host has to know where it stands
    local x, y, z = ...
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x and y and z) then
      print("cx install gps <x> <y> <z>   (F3, Targeted Block, looking at this computer)")
      return
    end
    local f = fs.open("/.gps.pos", "w")
    f.write(("%d %d %d"):format(x, y, z))
    f.close()
  end
  local prev = current()
  local f = fs.open(PROGRAM_FILE, "w")
  f.write(name)
  f.close()
  if download(name) and prev ~= name then
    -- the old program's own files (e.g. its startup.lua) must not linger
    local keep = plan(name)
    for path in pairs(plan(prev)) do
      if not keep[path] and fs.exists(path) then fs.delete(path) end
    end
  end
end

local args = { ... }
local cmd = table.remove(args, 1)
if cmd == nil then where()
elseif cmd == "list" then list()
elseif cmd == "help" then help()
elseif cmd == "update" then download(current())
elseif cmd == "install" then install(table.unpack(args))
elseif cmd == "--list" then list() -- older aliases
elseif shell and shell.resolveProgram and shell.resolveProgram(cmd) then shell.run(cmd, table.unpack(args))
else
  print("Unknown: cx " .. cmd)
  where()
end
