-- CHRONARCH :: buddycmd.lua  (on the pocket computer)
-- Turns what you type into a buddy order. Pure, so it is tested.
--
--   local buddy = require("buddycmd")
--   local act, err = buddy.parse("xhoxi come here", { xhoxi = true }, "xhoxi")
--   -- act = { to = "xhoxi", cmd = "come" }
--
-- The turtle's name can be left out when only one turtle is around (or one
-- was used last). Words, in any order after the name:
--   come / here     come to me          follow        keep coming to me
--   stay / stop     stop where you are  home          go home and unload
--   stash / unload  empty into the ender chest
--   dig [here] [r]  mine the ore around me (radius r, default 8)
--   light / torch   put a torch down

local M = {}

local VERBS = {
  come = "come", here = "come", follow = "follow", stay = "stop", stop = "stop",
  home = "home", stash = "stash", unload = "stash", dig = "dig", mine = "dig",
  light = "light", torch = "light",
}

function M.parse(line, known, default)
  local words = {}
  for w in tostring(line):lower():gmatch("[%w_%-]+") do words[#words + 1] = w end
  if #words == 0 then return nil, "type an order, e.g. come here" end
  local to = default
  if known[words[1]] then
    to = table.remove(words, 1)
  elseif default == nil then
    local only, n = nil, 0
    for k in pairs(known) do only, n = k, n + 1 end
    if n == 1 then to = only end
  end
  if not to then return nil, "which turtle? start with its name" end
  local cmd, r
  for _, w in ipairs(words) do
    if not cmd and VERBS[w] then cmd = VERBS[w] end
    if tonumber(w) then r = tonumber(w) end
  end
  if not cmd then return nil, "unknown order: " .. table.concat(words, " ") end
  local act = { to = to, cmd = cmd }
  if cmd == "dig" then act.radius = math.max(2, math.min(24, r or 8)) end
  return act
end

return M
