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

return M
