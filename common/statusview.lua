-- CHRONARCH :: statusview.lua  (shared helper, put it in the computer root)
-- Turns the base's turtle table into lines for the status monitor. Pure: no
-- peripherals, no globals beyond stdlib, so it is fully testable. base.lua maps
-- the colour names to colors.* and draws each line.
--
--   local view = require("statusview")
--   local rows = view.format(turtles, os.clock(), 12)
--   -- rows = { { text = "...", color = "cyan" }, ... }
--
-- turtles: name -> { id = <n>, fuel = <n>, state = <string>, seen = <os.clock>,
--                   pos = { x, y, z, abs = true if world coords (GPS) } }
-- A turtle in trouble reports state "SOS <reason>"; it is shown in red.

local M = {}

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- A turtle counts as offline if we have not heard from it for staleAfter secs.
function M.format(turtles, now, staleAfter)
  local rows = {}
  rows[#rows + 1] = { text = ("CHRONARCH  %d turtle(s)"):format(count(turtles)), color = "cyan" }
  rows[#rows + 1] = { text = ("%-8s %-6s %-16s %s"):format("NAME", "FUEL", "STATE", "POS"), color = "lightGray" }

  local names = {}
  for name in pairs(turtles) do names[#names + 1] = name end
  table.sort(names)

  if #names == 0 then
    rows[#rows + 1] = { text = "No turtles yet. Run agent on them.", color = "orange" }
    return rows
  end

  for _, name in ipairs(names) do
    local t = turtles[name]
    local state, color
    if not t.seen or (now - t.seen) > staleAfter then
      state, color = "offline", "red"
    elseif tostring(t.state):find("^SOS") then
      state, color = tostring(t.state), "red"
    elseif t.state == "busy" then
      state, color = "busy", "yellow"
    else
      state, color = t.state or "idle", "lime"
    end
    rows[#rows + 1] = {
      text = ("%-8s %-6s %-16s %s"):format(name:sub(1, 8), tostring(t.fuel), state:sub(1, 16), M.posText(t.pos)),
      color = color,
    }
  end
  return rows
end

-- "638,63,-90" for world coords (GPS), "home+3,-2,5" for coords from home.
function M.posText(p)
  if type(p) ~= "table" or not p.x then return "?" end
  local xyz = ("%d,%d,%d"):format(p.x, p.y, p.z)
  return p.abs and xyz or ("home+" .. xyz)
end

-- Plain-text colony status for the AI, appended to `ask` questions so the
-- answer is about this colony. maps: name -> { ores = { {name=...}, ... } }.
function M.summary(turtles, maps, now, staleAfter)
  local names = {}
  for name in pairs(turtles) do names[#names + 1] = name end
  table.sort(names)
  local lines = { "Colony status (live):" }
  if #names == 0 then lines[2] = "no turtles online" end
  for _, name in ipairs(names) do
    local t = turtles[name]
    local online = t.seen and (now - t.seen) <= staleAfter
    local line = ("%s: %s, %s, fuel %s."):format(name, online and "online" or "offline",
      online and (t.state or "idle") or "unknown", tostring(t.fuel))
    if t.homeY then line = line .. (" Home at y=%d."):format(t.homeY) end
    if online and type(t.pos) == "table" and t.pos.x then line = line .. " At " .. M.posText(t.pos) .. "." end
    local ores = maps[name] and maps[name].ores or {}
    if #ores > 0 then
      local counts, kinds, near = {}, {}, {}
      for _, o in ipairs(ores) do
        local k = (tostring(o.name):match("[^:]+$"))
        if not counts[k] then kinds[#kinds + 1] = k end
        counts[k] = (counts[k] or 0) + 1
        local d = math.abs(o.x or 0) + math.abs(o.y or 0) + math.abs(o.z or 0)
        near[k] = math.min(near[k] or d, d)
      end
      table.sort(kinds, function(a, b)
        if counts[a] ~= counts[b] then return counts[a] > counts[b] end
        return a < b
      end)
      local parts = {}
      for i = 1, math.min(6, #kinds) do
        local k = kinds[i]
        parts[i] = ("%d %s (nearest %d blocks)"):format(counts[k], k, near[k])
      end
      line = line .. " Ore it knows from home: " .. table.concat(parts, ", ") .. "."
    end
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n")
end

-- The AI may end its answer with up to 3 lines "DO: <command>" (see SYSTEM in
-- bridge/worker.js), a plan run in order. Returns the answer without those
-- lines, plus the actions we allow: for a turtle we know, with numbers clamped
-- to safe limits. The base still asks the player to confirm with `yes`.
local ALLOWED = { scan = { 1, 16, 8 }, harvest = { 1, 24, 12 }, explore = { 1, 24, 12 },
  mine = { 1, 64, 16 }, stop = false }

local function parseOne(line, turtles)
  local vore, vn = line:match("DO:%s*value%s+([%w_]+)%s+(%d+)")
  if vore then -- how much an ore is worth (no turtle involved)
    vn = math.max(1, math.min(100, tonumber(vn)))
    return { cmd = "value", name = vore, n = vn, line = "value " .. vore .. " " .. vn }
  end
  local cmd, name, n, ore = line:match("DO:%s*(%a+)%s+([%w_%-]+)%s*(%d*)%s*([%w_]*)")
  local rule = ALLOWED[cmd]
  if rule == nil or not turtles[name] then return nil end
  if rule then
    n = math.max(rule[1], math.min(rule[2], tonumber(n) or rule[3]))
  else
    n = nil
  end
  if (cmd ~= "harvest" and cmd ~= "explore") or ore == "" then ore = nil end
  return { cmd = cmd, name = name, n = n, ore = ore,
    line = cmd .. " " .. name .. (n and (" " .. n) or "") .. (ore and (" " .. ore) or "") }
end

function M.parseActions(text, turtles)
  local answer = text:gsub("\n?DO:[^\n]*", "")
  local acts = {}
  for line in text:gmatch("DO:[^\n]*") do
    acts[#acts + 1] = parseOne(line, turtles)
    if #acts == 3 then break end
  end
  return answer, acts
end

return M
