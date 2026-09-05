-- A stand-in for the Mudlet APIs this package uses, faithful on the points
-- that matter to the code under test:
--   * table.load fills the table passed as its second argument, and raises
--     when the file is absent - the contract MCVPLoader's pcall relies on
--   * table.save deep-copies, so a cached table is not an alias of live state
--   * event handlers are keyed by the name they registered for, so a test can
--     assert which events the package listens to and fire them by name
--   * tempTimer hands back a callable, so a scheduled re-request can be run
-- Stubbing these as no-ops is what previously hid the cache defects.
local fake = {}

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, item in pairs(v) do out[k] = deepcopy(item) end
  return out
end

fake.deepcopy = deepcopy

--- Install the fakes as globals and return a handle for inspecting them.
-- @param opts.files optional map of path -> table, the on-disk cache at start
function fake.install(opts)
  opts = opts or {}
  local m = {
    sent = {}, timers = {}, events = {}, echoes = {},
    handlers = {}, killed = {},
    files = deepcopy(opts.files or {}),
    nextId = 0,
  }

  _G.sendGMCP = function(msg) m.sent[#m.sent + 1] = msg end
  _G.tempTimer = function(delay, fn)
    m.timers[#m.timers + 1] = { delay = delay, fn = fn }
    return #m.timers
  end
  _G.raiseEvent = function(name, value) m.events[#m.events + 1] = { name = name, value = value } end
  _G.echo = function(text) m.echoes[#m.echoes + 1] = text end
  _G.getMudletHomeDir = function() return "/fake-profile" end

  _G.registerAnonymousEventHandler = function(event, fn)
    m.nextId = m.nextId + 1
    m.handlers[#m.handlers + 1] = { id = m.nextId, event = event, fn = fn }
    return m.nextId
  end
  _G.killAnonymousEventHandler = function(id)
    m.killed[#m.killed + 1] = id
    for i, handler in ipairs(m.handlers) do
      if handler.id == id then table.remove(m.handlers, i) break end
    end
  end

  _G.table.save = function(path, t) m.files[path] = deepcopy(t) end
  _G.table.load = function(path, into)
    local stored = m.files[path]
    if not stored then error("mcvp fake: no such file " .. tostring(path)) end
    for k, v in pairs(deepcopy(stored)) do into[k] = v end
  end

  _G.gmcp = nil
  _G.mcvp = nil

  --- Every event name currently registered, in registration order.
  function m.registeredEvents()
    local names = {}
    for _, handler in ipairs(m.handlers) do names[#names + 1] = handler.event end
    return names
  end

  function m.handlerFor(event)
    for _, handler in ipairs(m.handlers) do
      if handler.event == event then return handler.fn end
    end
    return nil
  end

  --- Invoke every handler registered for an event, as Mudlet would.
  function m.fire(event)
    for _, handler in ipairs(m.handlers) do
      if handler.event == event then handler.fn() end
    end
  end

  function m.cachePath(key)
    return "/fake-profile/mcvp-cache-" .. (key or "hero") .. ".lua"
  end

  function m.cache(key)
    return m.files[m.cachePath(key)]
  end

  function m.setCache(value, key)
    m.files[m.cachePath(key)] = value
  end

  --- How many bare re-requests have been sent.
  function m.rerequests()
    local n = 0
    for _, msg in ipairs(m.sent) do
      if msg == "Client.Vocabulary" then n = n + 1 end
    end
    return n
  end

  return m
end

--- Load the package fresh, in scripts.json order.
function fake.loadPackage(withDebug)
  dofile("src/scripts/MCVP/MCVPMerge.lua")
  dofile("src/scripts/MCVP/MCVPLoader.lua")
  if withDebug then dofile("src/scripts/MCVP/MCVPDebug.lua") end
end

return fake
