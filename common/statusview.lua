-- CHRONARCH :: statusview.lua  (shared helper, put it in the computer root)
-- Turns the base's turtle table into lines for the status monitor. Pure: no
-- peripherals, no globals beyond stdlib, so it is fully testable. base.lua maps
-- the colour names to colors.* and draws each line.
--
--   local view = require("statusview")
--   local rows = view.format(turtles, os.clock(), 12)
--   -- rows = { { text = "...", color = "cyan" }, ... }
--
-- turtles: name -> { id = <n>, fuel = <n>, state = <string>, seen = <os.clock> }

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
  rows[#rows + 1] = { text = ("%-10s %-7s %s"):format("NAME", "FUEL", "STATE"), color = "lightGray" }

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
    elseif t.state == "busy" then
      state, color = "busy", "yellow"
    else
      state, color = t.state or "idle", "lime"
    end
    rows[#rows + 1] = {
      text = ("%-10s %-7s %s"):format(name:sub(1, 10), tostring(t.fuel), state),
      color = color,
    }
  end
  return rows
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
    local ores = maps[name] and maps[name].ores or {}
    if #ores > 0 then
      local counts, kinds = {}, {}
      for _, o in ipairs(ores) do
        local k = (tostring(o.name):match("[^:]+$"))
        if not counts[k] then kinds[#kinds + 1] = k end
        counts[k] = (counts[k] or 0) + 1
      end
      table.sort(kinds, function(a, b)
        if counts[a] ~= counts[b] then return counts[a] > counts[b] end
        return a < b
      end)
      local parts = {}
      for i = 1, math.min(6, #kinds) do parts[i] = counts[kinds[i]] .. " " .. kinds[i] end
      line = line .. " Ore it knows nearby: " .. table.concat(parts, ", ") .. "."
    end
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n")
end

-- The AI may end its answer with one line "DO: <command>" (see SYSTEM in
-- bridge/worker.js). Returns the answer without that line, plus the action if
-- it is one we allow, for a turtle we know, with numbers clamped to safe
-- limits. The base still asks the player to confirm with `yes`.
local ALLOWED = { scan = { 1, 16, 8 }, harvest = { 1, 24, 12 }, mine = { 1, 64, 16 }, stop = false }

function M.parseAction(text, turtles)
  local answer = text:gsub("\n?DO:[^\n]*", "")
  local cmd, name, n = text:match("DO:%s*(%a+)%s+([%w_%-]+)%s*(%d*)")
  local rule = ALLOWED[cmd]
  if rule == nil or not turtles[name] then return answer, nil end
  if rule then
    n = math.max(rule[1], math.min(rule[2], tonumber(n) or rule[3]))
  else
    n = nil
  end
  return answer, { cmd = cmd, name = name, n = n,
    line = cmd .. " " .. name .. (n and (" " .. n) or "") }
end

return M
