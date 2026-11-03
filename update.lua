-- CHRONARCH :: update.lua
-- Pulls the latest code from the public GitHub repo and writes it onto THIS
-- computer, picking the right set of files for its role (turtle or base).
-- The repo is public, so no token is needed. The secret /chronarch.key is
-- never fetched or touched.
--
--   update            update this computer, then reboot (hold Ctrl+R)
--
-- First time on a fresh computer (bootstrap), get this one file, then it keeps
-- itself up to date after that:
--   single-player world -> just copy update.lua into the computer's folder
--   server              -> pastebin get <code> update   (once)

local USER   = "xhoxe2"
local REPO   = "chronarch"
local BRANCH = "main"
local API = ("https://api.github.com/repos/%s/%s/commits/%s"):format(USER, REPO, BRANCH)
local RAW -- set in run(): pinned to the latest commit, see latestRaw()

-- raw.githubusercontent.com caches a branch for ~5 minutes, so an update right
-- after a push could pull the old code. A commit's files never change, so ask
-- GitHub for the latest commit id and download from that exact commit. If the
-- API is unreachable (60 calls/hour without a token), fall back to the branch.
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

-- local filename on this computer  ->  path inside the repo
local COMMON = {
  ["chronarch.lua"] = "common/chronarch.lua",
  ["update.lua"]    = "update.lua",
}
local TURTLE = {
  ["startup.lua"]  = "turtle/agent.lua",
  ["mine.lua"]     = "turtle/mine.lua",
  ["orescan.lua"]  = "common/orescan.lua",
  ["navigate.lua"] = "common/navigate.lua",
}
local BASE = {
  ["startup.lua"]    = "base/base.lua",
  ["statusview.lua"] = "common/statusview.lua",
  ["oremap.lua"]     = "common/oremap.lua",
}

-- Which files this computer needs, by role. Turtles have the global `turtle`.
local function plan(isTurtle)
  local files = {}
  for k, v in pairs(COMMON) do files[k] = v end
  for k, v in pairs(isTurtle and TURTLE or BASE) do files[k] = v end
  return files
end

-- Download one file and write it. Returns (true) or (false, reason). An empty
-- body (e.g. a 404 page that still returned) is treated as a failure so we
-- never overwrite good code with junk.
local function fetch(localPath, repoPath)
  local res, err = http.get(RAW .. repoPath)
  if not res then return false, err or "no response" end
  local data = res.readAll()
  res.close()
  if not data or #data == 0 then return false, "empty body" end
  local f, ferr = fs.open(localPath, "w")
  if not f then return false, ferr or "cannot write" end
  f.write(data)
  f.close()
  return true
end

local function run()
  if not http then
    print("HTTP is off in the CC config; cannot update.")
    return
  end
  local isTurtle = turtle ~= nil
  local ref
  RAW, ref = latestRaw()
  print(("CHRONARCH update (%s) <- %s/%s @ %s"):format(isTurtle and "turtle" or "base", USER, REPO, ref:sub(1, 7)))

  local files = plan(isTurtle)
  local names = {}
  for k in pairs(files) do names[#names + 1] = k end
  table.sort(names) -- stable, readable output order

  local ok, fail = 0, 0
  for _, localPath in ipairs(names) do
    local good, why = fetch(localPath, files[localPath])
    if good then
      ok = ok + 1
      print("  ok   " .. localPath)
    else
      fail = fail + 1
      print("  FAIL " .. localPath .. " (" .. tostring(why) .. ")")
    end
  end

  print(("Done: %d ok, %d failed."):format(ok, fail))
  if fail == 0 then
    print("Reboot to run the new code: hold Ctrl+R.")
  else
    print("Some files failed. Check HTTP, then run update again.")
  end
end

run()
