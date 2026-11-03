-- CHRONARCH :: oremap.lua  (shared helper, put it in the base root)
-- Draws a top-down map of ore for the monitor: a coloured title bar, a N/S/W/E
-- compass, HOME (+) in the middle, the turtle (@) where it is, each ore a solid
-- coloured cell, and a colour legend with counts. It auto-scales so the whole
-- area fits — one cell can be several blocks — so it works for a close scan
-- (1:1) and for a big live harvest alike. Pure: returns rows ready for
-- monitor.blit, so the layout stays testable.
--
--   local oremap = require("oremap")
--   local rows = oremap.render(ores, w, h, { name=, total=, turtle={x=,z=} })
--   for r = 1, #rows do mon.setCursorPos(1, r); mon.blit(rows[r].text, rows[r].fg, rows[r].bg) end
--
-- ores: list of { name=, x=, y=, z= } relative to HOME (where the turtle began).
-- info.turtle: the turtle's current position (home frame); omit for a plain scan.

local M = {}

local BY_WORD = {
  coal = "gray", iron = "white", copper = "orange", gold = "yellow",
  diamond = "cyan", emerald = "lime", redstone = "red", lapis = "blue",
  quartz = "pink", zinc = "lightBlue", tin = "lightGray", lead = "purple",
  silver = "lightGray", uranin = "lime", antimony = "magenta", sal = "cyan",
  netherite = "brown", debris = "brown", allthemodium = "green",
}

function M.color(name)
  local s = (tostring(name):match("[^:]+$") or ""):lower()
  for word, c in pairs(BY_WORD) do
    if s:find(word, 1, true) then return c end
  end
  return "lightBlue"
end

function M.short(name)
  return (tostring(name):match("[^:]+$")) or tostring(name)
end

local BLIT = { white = "0", orange = "1", magenta = "2", lightBlue = "3", yellow = "4",
  lime = "5", pink = "6", gray = "7", lightGray = "8", cyan = "9", purple = "a",
  blue = "b", brown = "c", green = "d", red = "e", black = "f" }
local function hex(name) return BLIT[name] or "0" end

local function sortedByDistDesc(ores)
  local s = {}
  for _, o in ipairs(ores or {}) do s[#s + 1] = o end
  table.sort(s, function(a, b)
    local da = math.abs(a.x or 0) + math.abs(a.z or 0)
    local db = math.abs(b.x or 0) + math.abs(b.z or 0)
    return da > db
  end)
  return s
end

-- Centre + blocks-per-cell scale so every ore and the turtle fit in the frame.
local function fit(ores, turtle, w, h)
  local bottom = h - 2
  local cx = math.floor(w / 2) + 1
  local cy = math.floor((2 + bottom) / 2)
  local halfW = math.max(1, math.floor((w - 2) / 2) - 1)
  local halfH = math.max(1, math.floor((bottom - 3) / 2) - 1)
  local reach = 1
  for _, o in ipairs(ores or {}) do reach = math.max(reach, math.abs(o.x or 0), math.abs(o.z or 0)) end
  if turtle then reach = math.max(reach, math.abs(turtle.x or 0), math.abs(turtle.z or 0)) end
  local scale = math.max(1, math.ceil(reach / halfW), math.ceil(reach / halfH))
  return cx, cy, bottom, scale, reach
end

local function toCell(cx, cy, scale, x, z)
  return cx + math.floor((x or 0) / scale + 0.5), cy + math.floor((z or 0) / scale + 0.5)
end

local function simple(ores, w, h)
  local CH, FG, BG = {}, {}, {}
  for r = 1, h do
    CH[r], FG[r], BG[r] = {}, {}, {}
    for c = 1, w do CH[r][c], FG[r][c], BG[r][c] = " ", "0", "f" end
  end
  local cx, cy = math.floor(w / 2) + 1, math.floor(h / 2) + 1
  for _, o in ipairs(sortedByDistDesc(ores)) do
    local col, row = cx + (o.x or 0), cy + (o.z or 0)
    if col >= 1 and col <= w and row >= 1 and row <= h and not (col == cx and row == cy) then
      CH[row][col], BG[row][col] = " ", hex(M.color(o.name))
    end
  end
  CH[cy][cx], FG[cy][cx] = "+", "4"
  local rows = {}
  for r = 1, h do rows[r] = { text = table.concat(CH[r]), fg = table.concat(FG[r]), bg = table.concat(BG[r]) } end
  return rows
end

function M.render(ores, w, h, info)
  if w < 16 or h < 9 then return simple(ores, w, h) end
  info = info or {}
  ores = ores or {}

  local CH, FG, BG = {}, {}, {}
  for r = 1, h do
    CH[r], FG[r], BG[r] = {}, {}, {}
    for c = 1, w do CH[r][c], FG[r][c], BG[r][c] = " ", "0", "f" end
  end
  local function put(r, c, ch, fg, bg)
    if r >= 1 and r <= h and c >= 1 and c <= w then
      CH[r][c], FG[r][c] = ch, fg
      if bg then BG[r][c] = bg end
    end
  end
  local function putText(r, c, text, fg, bg)
    for i = 1, #text do put(r, c + i - 1, text:sub(i, i), fg, bg) end
  end

  local cx, cy, bottom, scale, reach = fit(ores, info.turtle, w, h)

  -- title bar (cyan strip)
  for c = 1, w do put(1, c, " ", "f", "9") end
  local title = ("CHRONARCH  ORE MAP   %s   r%d  1:%d   %s ores"):format(
    tostring(info.name or "?"), reach, scale, tostring(info.total or #ores))
  putText(1, 2, title:sub(1, w - 2), "f", "9")

  -- frame + compass
  for c = 1, w do put(2, c, "-", "8"); put(bottom, c, "-", "8") end
  for r = 2, bottom do put(r, 1, "|", "8"); put(r, w, "|", "8") end
  for _, rc in ipairs({ { 2, 1 }, { 2, w }, { bottom, 1 }, { bottom, w } }) do put(rc[1], rc[2], "+", "8") end
  put(2, cx, "N", "e"); put(bottom, cx, "S", "e")
  put(cy, 1, "W", "e"); put(cy, w, "E", "e")

  local function inMap(r, c) return c >= 2 and c <= w - 1 and r >= 3 and r <= bottom - 1 end

  -- ore cells
  for _, o in ipairs(sortedByDistDesc(ores)) do
    local col, row = toCell(cx, cy, scale, o.x, o.z)
    if inMap(row, col) and not (col == cx and row == cy) then put(row, col, " ", "f", hex(M.color(o.name))) end
  end

  -- home in the middle, turtle where it is
  put(cy, cx, "+", "4", "f")
  if info.turtle then
    local tcol, trow = toCell(cx, cy, scale, info.turtle.x, info.turtle.z)
    if inMap(trow, tcol) then put(trow, tcol, "@", "d", "f") end
  end

  -- legend with counts
  local order, counts = {}, {}
  for _, o in ipairs(ores) do
    local s = M.short(o.name)
    if not counts[s] then order[#order + 1] = { short = s, color = hex(M.color(o.name)) } end
    counts[s] = (counts[s] or 0) + 1
  end
  table.sort(order, function(a, b)
    if counts[a.short] ~= counts[b.short] then return counts[a.short] > counts[b.short] end
    return a.short < b.short
  end)
  local lr, lc = bottom + 1, 1
  for _, item in ipairs(order) do
    local label = ("%d %s"):format(counts[item.short], item.short)
    local need = 2 + 1 + #label + 2
    if lc + need - 1 > w then
      lr, lc = lr + 1, 1
      if lr > h then putText(h, w - 3, "...", "8"); break end
    end
    put(lr, lc, " ", "f", item.color); put(lr, lc + 1, " ", "f", item.color)
    putText(lr, lc + 3, label, "8")
    lc = lc + need
  end

  local rows = {}
  for r2 = 1, h do rows[r2] = { text = table.concat(CH[r2]), fg = table.concat(FG[r2]), bg = table.concat(BG[r2]) } end
  return rows
end

-- Which ore is under a tap at monitor cell (tx, ty)? Mirrors render's layout and
-- scale. Returns the nearest ore to that spot (with its coords), or nil.
function M.hitTest(ores, w, h, tx, ty, info)
  info = info or {}
  if w < 16 or h < 9 then
    local cx, cy = math.floor(w / 2) + 1, math.floor(h / 2) + 1
    for _, o in ipairs(ores or {}) do
      if cx + (o.x or 0) == tx and cy + (o.z or 0) == ty then return o end
    end
    return nil
  end
  local cx, cy, bottom, scale = fit(ores, info.turtle, w, h)
  if not (tx >= 2 and tx <= w - 1 and ty >= 3 and ty <= bottom - 1) then return nil end
  local dx, dz = (tx - cx) * scale, (ty - cy) * scale
  local best, bestD
  for _, o in ipairs(ores or {}) do
    local d = math.abs((o.x or 0) - dx) + math.abs((o.z or 0) - dz)
    if d <= scale and (not bestD or d < bestD) then best, bestD = o, d end
  end
  return best
end

return M
