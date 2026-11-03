-- tests/net.lua : a tiny multi-computer CC: Tweaked emulator.
--
-- Enough of CraftOS to run the REAL rednet.lua and parallel.lua on several
-- computers at once: per-computer event queue, timers, os.pullEvent(Raw),
-- a wireless modem on each, and a shared "ether" that carries modem_message
-- events between them. A discrete-event scheduler advances virtual time only
-- when every computer is blocked, so message delivery always beats timeouts.
--
-- Returns a constructor:  local sim = (load(net))()  then
--   sim.setSources{ bit32=, parallel=, rednet=, expect=, chronarch= }
--   sim.addComputer{ id=, label=, secret=, src=, withTurtle=, withShell= }
--   sim.run(maxSteps)
--   sim.results() / sim.errors

return function()
  local sim = { computers = {}, clock = 0, stop = false, errors = {},
                _results = {}, state = {} }
  local sources

  -- Shared, stateless standard library handed to every computer.
  local SAFE = {
    assert = assert, error = error, pcall = pcall, xpcall = xpcall,
    select = select, type = type, tostring = tostring, tonumber = tonumber,
    pairs = pairs, ipairs = ipairs, next = next, rawget = rawget, rawset = rawset,
    rawequal = rawequal, rawlen = rawlen, setmetatable = setmetatable,
    getmetatable = getmetatable, unpack = table.unpack, _VERSION = _VERSION,
    math = math, string = string, table = table, coroutine = coroutine,
  }

  -- CC APIs (rednet, parallel) don't `return` a table: they assign their
  -- functions as globals of their own environment. Load each into a private
  -- env (that falls back to the computer's globals) and harvest what it defined.
  local function loadApi(src, name, baseEnv)
    local apiEnv = setmetatable({}, { __index = baseEnv })
    apiEnv._G = apiEnv
    local ret = load(src, name, "t", apiEnv)()
    if type(ret) == "table" then return ret end
    local api = {}
    for k, v in pairs(apiEnv) do if k ~= "_G" then api[k] = v end end
    return api
  end

  local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[deepcopy(k)] = deepcopy(val) end
    return out
  end

  -- What an equipped Geo Scanner "sees": iron at d1, coal at d3, diamond at d4,
  -- and one non-ore that must be ignored.
  local SCAN_FIELD = {
    { x = 1, y = 0, z = 0, name = "minecraft:iron_ore", tags = { ["c:ores"] = true } },
    { x = 0, y = -2, z = 1, name = "minecraft:coal_ore", tags = { ["c:ores"] = true } },
    { x = -3, y = 1, z = 0, name = "minecraft:diamond_ore", tags = { ["c:ores"] = true } },
    { x = 2, y = 0, z = 0, name = "minecraft:stone", tags = {} },
  }

  function sim.record(k, v)
    local list = sim._results[k]
    if not list then list = {}; sim._results[k] = list end
    list[#list + 1] = v
  end

  function sim.results() return sim._results end

  -- Carry one modem_message to every other computer listening on the channel.
  local function transmit(fromC, channel, reply, payload)
    for _, C in ipairs(sim.computers) do
      if C ~= fromC and not C.dead and C.modem.channels[channel] then
        C.queue[#C.queue + 1] = table.pack("modem_message", "right", channel, reply, deepcopy(payload), 1)
      end
    end
  end

  function sim.setSources(src)
    sources = src
    -- expect module is stateless; load it once and hand it to every rednet.
    sim.expectModule = load(sources.expect, "expect.lua", "t",
      setmetatable({}, { __index = SAFE }))()
    -- bit32 is stateless too; run the shim once and share the table.
    local benv = setmetatable({}, { __index = SAFE })
    load(sources.bit32, "bit32", "t", benv)()
    SAFE.bit32 = benv.bit32
  end

  local function osFor(C)
    local os = {}
    os.getComputerID = function() return C.id end
    os.getComputerLabel = function() return C.label end
    os.clock = function() return sim.clock end
    os.time = function() return 0 end
    os.day = function() return 0 end
    os.epoch = function() return math.floor(sim.clock * 1000) end
    os.queueEvent = function(name, ...) C.queue[#C.queue + 1] = table.pack(name, ...) end
    os.startTimer = function(dt)
      C.timerSeq = C.timerSeq + 1
      C.timers[C.timerSeq] = sim.clock + math.max(0, dt or 0)
      return C.timerSeq
    end
    os.cancelTimer = function(id) C.timers[id] = nil end
    os.pullEventRaw = function(...) return coroutine.yield(...) end
    os.pullEvent = function(filter)
      while true do
        local e = table.pack(coroutine.yield(filter))
        if e[1] == "terminate" then error("Terminated", 0) end
        if filter == nil or e[1] == filter then return table.unpack(e, 1, e.n) end
      end
    end
    os.sleep = function(t)
      local id = os.startTimer(t or 0)
      while true do
        local _, p = os.pullEvent("timer")
        if p == id then return end
      end
    end
    return os
  end

  local function peripheralFor(C)
    local methods = { "isWireless", "open", "close", "closeAll", "isOpen", "transmit" }
    C.modem = { channels = {} }
    C.modem.impl = {
      isWireless = function() return true end,
      open = function(ch) C.modem.channels[ch] = true end,
      close = function(ch) C.modem.channels[ch] = nil end,
      closeAll = function() C.modem.channels = {} end,
      isOpen = function(ch) return C.modem.channels[ch] == true end,
      transmit = function(ch, reply, payload) transmit(C, ch, reply, payload) end,
    }
    local modemWrapper = {}
    for _, m in ipairs(methods) do modemWrapper[m] = function(...) return C.modem.impl[m](...) end end
    local p = {
      getNames = function() return { "right" } end,
      isPresent = function(s) return s == "right" end,
      getType = function(s)
        if s == "right" then return "modem" end
        if s == "left" and C.equip and C.equip.left and C.equip.left.name == "advancedperipherals:chunk_controller" then
          C.anchored = (C.anchored or 0) + 1 -- the controller got worn at least for a moment
          return "chunky"
        end
        return nil
      end,
      hasType = function(s, t) return s == "right" and t == "modem" end,
      getMethods = function(s) return s == "right" and methods or nil end,
      call = function(s, m, ...)
        assert(s == "right", "no peripheral " .. tostring(s))
        return C.modem.impl[m](...)
      end,
      getName = function(x) return type(x) == "string" and x or "right" end,
    }
    p.find = function(ptype, filter)
      if ptype ~= "modem" then return nil end
      if filter and not filter("right", modemWrapper) then return nil end
      return modemWrapper
    end
    -- The modem is on "right"; a Geo Scanner shows up on "left" once equipped.
    p.wrap = function(side)
      if side == "right" then return modemWrapper end
      if side == "left" and C.equip and C.equip.left
         and C.equip.left.name == "advancedperipherals:geo_scanner" then
        return { scanBlocks = function() return deepcopy(SCAN_FIELD) end }
      end
      return nil
    end
    return p
  end

  local function fsFor(C)
    return {
      exists = function(path) return C.secret ~= nil and (path == "/chronarch.key" or path == "chronarch.key") end,
      open = function(_, _)
        local read = false
        return {
          readAll = function() if read then return nil end read = true; return C.secret end,
          close = function() end,
        }
      end,
    }
  end

  function sim.addComputer(opts)
    local C = { id = opts.id, label = opts.label, secret = opts.secret,
                fuel = opts.fuel or 800, src = opts.src, queue = {}, timers = {},
                timerSeq = 0, prints = {}, dead = false }
    local env = setmetatable({}, { __index = SAFE })
    env._G = env
    env.os = osFor(C)
    env.peripheral = peripheralFor(C)
    env.fs = fsFor(C)
    env.print = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
      C.prints[#C.prints + 1] = table.concat(parts, " ")
    end
    env.write = function() end
    env.term = { isColor = function() return false end, getSize = function() return 51, 19 end }
    if opts.withTurtle then
      C.sel = 1
      C.inv = {}
      C.equip = { left = opts.toolItem or false, right = false }
      if opts.scanner then C.inv[3] = { name = "advancedperipherals:geo_scanner", count = 1 } end
      if opts.controller then C.inv[4] = { name = "advancedperipherals:chunk_controller", count = 1 } end
      local function equipSide(side)
        local tmp = C.equip[side]
        C.equip[side] = C.inv[C.sel] or false
        C.inv[C.sel] = tmp or nil
        return true
      end
      env.turtle = {
        getFuelLevel = function() return C.fuel end,
        select = function(n) C.sel = n; return true end,
        getSelectedSlot = function() return C.sel end,
        getItemCount = function(n) local it = C.inv[n or C.sel]; return it and (it.count or 1) or 0 end,
        getItemDetail = function(n) return C.inv[n or C.sel] end,
        equipLeft = function() return equipSide("left") end,
        equipRight = function() return equipSide("right") end,
      }
    end
    if opts.withShell then
      env.shell = { run = function(prog, ...)
        env.print("mine " .. table.concat({ ... }, " "))
        env.print("Finished (done)")
        return true
      end }
    end
    env.dofile = function(path)
      -- tiny_require returns a require() function; CC uses it in parallel/textutils.
      if path:find("tiny_require") then
        return function(name)
          if name == "cc.expect" then return sim.expectModule end
          if name == "cc.strings" then return { wrap = function(s) return { s } end } end
          if name == "cc.internal.exception" then
            return {
              try_barrier = function(_, fn, ...) return fn(...) end,
              wrap_error = function(param) return param end,
            }
          end
          error("require not supported: " .. name)
        end
      end
      if path:find("expect") then return sim.expectModule end
      error("dofile not supported: " .. path)
    end
    env.require = function(name)
      if name == "chronarch" then return env.__chronarch end
      if name == "orescan" then return env.__orescan end
      if name == "navigate" then return env.__navigate end
      error("require not supported: " .. name)
    end
    -- scenario hooks for driver scripts
    env.SECRET = C.secret
    env.record = sim.record
    env.state = sim.state
    env.stop = function() sim.stop = true end

    env.parallel = loadApi(sources.parallel, "parallel.lua", env)
    env.rednet = loadApi(sources.rednet, "rednet.lua", env)
    env.__chronarch = load(sources.chronarch, "chronarch.lua", "t", env)()
    if sources.orescan then env.__orescan = load(sources.orescan, "orescan.lua", "t", env)() end
    if sources.navigate then env.__navigate = load(sources.navigate, "navigate.lua", "t", env)() end
    C.programFn = assert(load(C.src, C.label, "t", env))
    C.env = env
    C.mainFn = function() env.parallel.waitForAny(env.rednet.run, C.programFn) end
    sim.computers[#sim.computers + 1] = C
    return C
  end

  local function step(C, ev)
    if C.dead then return end
    local ok, err
    if ev then
      ok, err = coroutine.resume(C.co, table.unpack(ev, 1, ev.n))
    else
      ok, err = coroutine.resume(C.co)
    end
    if not ok then
      sim.errors[#sim.errors + 1] = C.label .. ": " .. tostring(err)
      C.dead = true
    elseif coroutine.status(C.co) == "dead" then
      C.dead = true
    end
  end

  function sim.run(maxSteps)
    for _, C in ipairs(sim.computers) do
      C.co = coroutine.create(C.mainFn)
      step(C, nil) -- boot: run to the first blocking pullEvent
      if sim.stop then return end
    end
    local steps = 0
    while not sim.stop and steps < maxSteps do
      steps = steps + 1
      local delivered = false
      for _, C in ipairs(sim.computers) do
        while (not C.dead) and #C.queue > 0 and not sim.stop do
          step(C, table.remove(C.queue, 1))
          delivered = true
        end
        if sim.stop then break end
      end
      if sim.stop then break end
      if not delivered then
        -- everyone blocked: advance virtual time to the earliest timer
        local best, bestC, bestId
        for _, C in ipairs(sim.computers) do
          if not C.dead then
            for id, t in pairs(C.timers) do
              if not best or t < best then best, bestC, bestId = t, C, id end
            end
          end
        end
        if not best then break end -- nothing left to do
        sim.clock = math.max(sim.clock, best)
        bestC.timers[bestId] = nil
        bestC.queue[#bestC.queue + 1] = table.pack("timer", bestId)
      end
    end
  end

  return sim
end
