-- CHRONARCH :: probe.lua
-- Scout. Writes everything this computer / turtle / pocket can see into
-- probe-<id>.json, so Claude Code writes code from facts, not from memory:
-- exact CC and Minecraft version, every API function, every attached device
-- and its methods, exact block and item names with tags.
--
-- Read-only: never moves, digs, places or sends anything. A turtle only turns
-- around in place to look at all four sides (use "probe noturn" to skip that).
--
-- Usage: probe          full report
--        probe noturn   turtle does not turn

local args = { ... }
local noTurn = args[1] == "noturn"

-- Device methods that only read and are safe to call. Everything else
-- (transmit, pushItems, scan, shutdown...) is listed but never called.
local SAFE_CALLS = {
  size = true, list = true, getSize = true, isColor = true, isColour = true,
  getTextScale = true, isWireless = true, getID = true, getLabel = true,
  isOn = true, getNamesRemote = true,
}
local MAX_ITEM_DETAILS = 27

-- Helpers ------------------------------------------------------------------
local function stringKeys(t)
  local keys = {}
  for k in pairs(t) do
    if type(k) == "string" then keys[#keys + 1] = k end
  end
  table.sort(keys)
  return keys
end

-- Deep copy that keeps only what JSON can hold (no functions, no cycles).
local function clean(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == "string" or t == "boolean" then return v end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
    return v
  end
  if t ~= "table" or depth > 6 then return nil end
  local out = {}
  for k, val in pairs(v) do
    if type(k) == "string" or type(k) == "number" then
      out[k] = clean(val, depth + 1)
    end
  end
  return out
end

local function packClean(...)
  local res = table.pack(...)
  local out = {}
  for i = 1, res.n do out[i] = clean(res[i]) end
  return out
end

local function inspectBlock(fn)
  local ok, data = fn()
  if ok then return clean(data) end
  return { empty = true }
end

-- Basics -------------------------------------------------------------------
local report = {
  probe_version = 1,
  host = _HOST,
  craftos = os.version(),
  lua = _VERSION,
  id = os.getComputerID(),
  label = os.getComputerLabel(),
  kind = turtle and "turtle" or (pocket and "pocket" or "computer"),
  advanced = term.isColor(),
  day = os.day(),
  time = os.time(),
  epoch_utc = os.epoch and os.epoch("utc") or nil,
  http = { enabled = http ~= nil },
  globals = {},
  apis = {},
  settings = {},
  peripherals = {},
}

if http and http.checkURL then
  local ok, reason = http.checkURL("https://example.com")
  report.http.example_com_allowed = ok
  report.http.reason = reason
end

-- Every API and the functions it has in THIS version of CC.
for _, name in ipairs(stringKeys(_G)) do
  local v = _G[name]
  if type(v) == "function" then
    report.globals[#report.globals + 1] = name
  elseif type(v) == "table" and name ~= "_G" and name ~= "_ENV" then
    local fns = {}
    for _, fname in ipairs(stringKeys(v)) do
      if type(v[fname]) == "function" then fns[#fns + 1] = fname end
    end
    if #fns > 0 then report.apis[name] = fns end
  end
end

if settings and settings.getNames then
  for _, name in ipairs(settings.getNames()) do
    local value = settings.get(name)
    local t = type(value)
    if t == "string" or t == "number" or t == "boolean" then report.settings[name] = value end
  end
end

-- Attached devices ---------------------------------------------------------
local itemCount = 0
for _, name in ipairs(peripheral.getNames()) do
  local entry = { types = packClean(peripheral.getType(name)), methods = {}, values = {} }
  local methods = peripheral.getMethods(name) or {}
  local has = {}
  for _, m in ipairs(methods) do entry.methods[#entry.methods + 1] = m; has[m] = true end
  table.sort(entry.methods)

  for _, m in ipairs(entry.methods) do
    if SAFE_CALLS[m] then
      local res = table.pack(pcall(peripheral.call, name, m))
      if res[1] then
        local values = {}
        for i = 2, res.n do values[#values + 1] = clean(res[i]) end
        entry.values[m] = values
      else
        entry.values[m] = { error = tostring(res[2]) }
      end
    end
  end

  -- Inventories: exact item names and tags of what is inside.
  if has.list and has.getItemDetail then
    local ok, list = pcall(peripheral.call, name, "list")
    if ok and type(list) == "table" then
      entry.items = {}
      local slots = {}
      for slot in pairs(list) do
        if type(slot) == "number" then slots[#slots + 1] = slot end
      end
      table.sort(slots)
      for i = 1, math.min(#slots, MAX_ITEM_DETAILS) do
        local okDetail, detail = pcall(peripheral.call, name, "getItemDetail", slots[i])
        if okDetail and detail then
          local item = clean(detail)
          item.slot = slots[i]
          entry.items[#entry.items + 1] = item
          itemCount = itemCount + 1
        end
      end
    end
  end

  report.peripherals[name] = entry
end

-- Turtle: fuel, upgrades, inventory, blocks around ---------------------------
if turtle then
  local t = { fuel = turtle.getFuelLevel(), inventory = {}, blocks = {} }
  if turtle.getFuelLimit then t.fuel_limit = turtle.getFuelLimit() end
  if turtle.getSelectedSlot then t.selected_slot = turtle.getSelectedSlot() end
  if turtle.getEquippedLeft then
    local ok, item = pcall(turtle.getEquippedLeft)
    if ok then t.equipped_left = clean(item) end
  end
  if turtle.getEquippedRight then
    local ok, item = pcall(turtle.getEquippedRight)
    if ok then t.equipped_right = clean(item) end
  end

  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      local ok, detail = pcall(turtle.getItemDetail, slot, true)
      if not ok then detail = turtle.getItemDetail(slot) end
      local item = clean(detail) or {}
      item.slot = slot
      t.inventory[#t.inventory + 1] = item
      itemCount = itemCount + 1
    end
  end

  t.blocks.up = inspectBlock(turtle.inspectUp)
  t.blocks.down = inspectBlock(turtle.inspectDown)
  if noTurn then
    t.blocks.front = inspectBlock(turtle.inspect)
  else
    for _, side in ipairs({ "front", "right", "back", "left" }) do
      t.blocks[side] = inspectBlock(turtle.inspect)
      turtle.turnRight() -- four turns: ends facing the same way
    end
  end
  report.turtle = t
end

-- Save ---------------------------------------------------------------------
local fileName = ("probe-%d.json"):format(report.id)
local ok, text = pcall(textutils.serializeJSON, report)
if not ok then
  fileName = ("probe-%d.txt"):format(report.id)
  text = textutils.serialize(report)
end
local f = fs.open(fileName, "w")
f.write(text)
f.close()

local devices = 0
for _ in pairs(report.peripherals) do devices = devices + 1 end
print(("Saved %s (%d bytes)"):format(fileName, #text))
print(("%s | %d devices | %d items"):format(tostring(_HOST), devices, itemCount))
print("On a server, upload it with:")
print("  pastebin put " .. fileName)
