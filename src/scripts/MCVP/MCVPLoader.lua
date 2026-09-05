--- MCVP lifecycle: negotiation, GMCP handlers, re-request discipline, cache.
-- Uses only Mudlet APIs confirmed present in both desktop Mudlet and
-- mudlet-web (sendGMCP, registerAnonymousEventHandler,
-- killAnonymousEventHandler, tempTimer, getMudletHomeDir, table.save/
-- table.load, raiseEvent), so the package runs unchanged on either client.
-- Catalog and Update merging lives in MCVPMerge.lua (mcvp.merge); this file
-- owns the wire-facing rules - negotiation, re-request discipline, the
-- version-regression rule, and the cache.
-- @module mcvp

mcvp = mcvp or {}
assert(mcvp.merge, "MCVPMerge must load before MCVPLoader - check scripts.json order")

mcvp._state = mcvp._state or mcvp.merge.new()
mcvp._handlers = mcvp._handlers or {}
-- One-shot re-request discipline: while one is pending, no path may issue
-- another. The server may throttle rebuilds and answer identical-version
-- Catalogs from a held copy, so retry loops gain nothing and the standard
-- forbids them.
mcvp._rerequestPending = false
-- Whether a Catalog has arrived over the wire in this session, as opposed to
-- state we restored from the cache. See _onCatalog.
mcvp._catalogThisSession = mcvp._catalogThisSession or false

-- The cache is keyed by character, never by profile: a catalog describes one
-- character and carries that character's own shortcuts, so two characters on
-- one profile must not share a file. This protocol carries no character
-- identifier - a client obtains one out of band, the way it binds the dynamic
-- slot classes - so a game names the character through mcvp.setCacheKey, and
-- until it does, nothing is written to disk at all.
mcvp._cacheKey = mcvp._cacheKey or nil

local function cachePath()
  if not mcvp._cacheKey then return nil end
  return getMudletHomeDir() .. "/mcvp-cache-" .. mcvp._cacheKey .. ".lua"
end

local function notify(message)
  if type(echo) == "function" then echo("\n[mcvp] " .. message .. "\n") end
end

--- Send the bare-package re-request, at most one in flight.
-- A re-request that a Catalog has already satisfied while it was scheduled is
-- dropped when its timer fires, so the delayed and immediate paths can never
-- produce two requests for one fault.
-- @param delay optional seconds to wait first, for a caller that wants to
--        clear the server's rebuild throttle window before asking
function mcvp.rerequest(delay)
  if mcvp._rerequestPending then return end
  mcvp._rerequestPending = true
  local fire = function()
    -- A Catalog arriving inside the delay clears the flag; so does stop().
    -- Either way this timer has nothing left to recover.
    if not mcvp._rerequestPending then return end
    local ok, err = pcall(sendGMCP, "Client.Vocabulary")
    if not ok then
      -- Nothing is in flight, so a later fault must be free to try again.
      mcvp._rerequestPending = false
      notify("could not request the vocabulary catalog: " .. tostring(err))
    end
  end
  if delay and delay > 0 then
    tempTimer(delay, fire)
  else
    fire()
  end
end

local function persist()
  -- Best effort, and deliberately not an optimisation: an arriving Catalog is
  -- applied in full whether or not the cache hit, so this only pre-populates
  -- state before the first frame of the next session arrives.
  local path = cachePath()
  if not path then return end
  pcall(table.save, path, { version = mcvp._state.version, categories = mcvp._state.categories })
end

-- The cache is the only path into merged state that does not pass through the
-- merge engine's normalization, and it is the least trustworthy one: the file
-- may have been hand-edited, truncated by a crash mid-write, or written by a
-- different version of this package. Anything that does not have the shape
-- normEntry produces is rejected whole - a rejected cache costs one re-parse,
-- while a trusted bad one crashes inside a consumer's call to mcvp.entries().
local function usableCache(categories)
  for name, cat in pairs(categories) do
    if type(name) ~= "string" or type(cat) ~= "table"
      or type(cat.priority) ~= "number" or type(cat.entries) ~= "table" then
      return false
    end
    for _, entry in pairs(cat.entries) do
      if type(entry) ~= "table" or type(entry.word) ~= "string" or entry.word == ""
        or type(entry.priority) ~= "number" or type(entry.protected) ~= "boolean" then
        return false
      end
    end
  end
  return true
end

local function restore()
  -- Re-sourcing the package (a script edit, a package update) re-runs this
  -- file while mcvp._state survives. Merged state we already hold is never
  -- older than the cache, so it wins.
  if mcvp._state.version ~= nil then return end

  local path = cachePath()
  if not path then return end

  local cached = {}
  local ok = pcall(table.load, path, cached)
  if not ok or type(cached.version) ~= "string" or type(cached.categories) ~= "table" then
    return
  end
  if not usableCache(cached.categories) then
    notify("vocabulary cache rejected as malformed; re-fetching from the server")
    return
  end
  mcvp._state.version = cached.version
  mcvp._state.categories = cached.categories
end

local function announce()
  -- Local event for consumers (completion, the stt package's correction
  -- layer). Consumers pull state through mcvp.entries(); per the standard,
  -- nothing about their use of it ever goes back to any server.
  raiseEvent("mcvp.updated", mcvp._state.version or "")
end

function mcvp._onCatalog()
  local payload = gmcp and gmcp.Client and gmcp.Client.Vocabulary and gmcp.Client.Vocabulary.Catalog
  if type(payload) ~= "table" then return end

  -- A full Catalog is authoritative by construction, so it is applied even
  -- when it bears a version this client held earlier in the session. Opaque
  -- versions cannot be ordered, and the version is stable for identical
  -- content, so a catalog whose content has returned to an earlier state
  -- reproduces its earlier version legitimately - a player creating and then
  -- deleting a shortcut is enough. Discarding on that basis would reject the
  -- server's current catalog, and the re-request would be answered with the
  -- same one, which is the retry loop the standard forbids.

  -- A restored cache is not a frame of the Catalog now arriving. The first
  -- Catalog of a session is complete and authoritative, so it replaces the
  -- cache outright; letting it merge additively on a version match would leave
  -- a category the server has since dropped alive in the cache forever, with
  -- nothing able to retract it. Frames after the first share the version
  -- because they are pagination, and those do merge.
  if not mcvp._catalogThisSession then
    mcvp._catalogThisSession = true
    mcvp._state.version = nil
  end

  -- One path for every Catalog. A frame sharing the current version is a
  -- pagination frame or the throttle's held copy answering a re-request; the
  -- merge engine merges it additively. Any other version replaces all state.
  -- A payload the engine rejects satisfies nothing: it neither clears a
  -- pending re-request nor tells consumers anything changed.
  if not mcvp.merge.applyCatalog(mcvp._state, payload) then return end

  mcvp._rerequestPending = false
  persist()
  announce()
end

function mcvp._onUpdate()
  local payload = gmcp and gmcp.Client and gmcp.Client.Vocabulary and gmcp.Client.Vocabulary.Update
  if type(payload) ~= "table" then return end

  -- Fault injection (mcvp.debug.dropNextUpdate): simulate a lost frame so the
  -- from-chain recovery can be exercised against a live server
  if mcvp._dropNextUpdate then
    mcvp._dropNextUpdate = nil
    return
  end

  local ok, why = mcvp.merge.applyUpdate(mcvp._state, payload)
  if ok then
    persist()
    announce()
    return
  end

  -- "no baseline" (Update as first frame of a session) and "from mismatch"
  -- (broken chain - lost frame, server fault) share one recovery: discard
  -- the Update, fire the one-shot re-request. Malformed payloads are
  -- discarded without recovery; they say nothing about chain state.
  if why == "no baseline" or why == "from mismatch" then
    mcvp.rerequest()
  end
end

function mcvp._onGmcpEnabled(_, protocol)
  if protocol ~= "GMCP" then return end
  -- Negotiation: advertise mid-session via Add, the path the reference
  -- server exercises. A fresh session always answers with a full Catalog,
  -- so no re-request accompanies this.
  sendGMCP('Core.Supports.Add ["Client.Vocabulary 1"]')
end

--- Query merged vocabulary. Passes options through to the merge engine:
-- category, maxPriority, biasable, correctable, leading. A biasable result is
-- ordered by tier and then by word, because the caller spends a budget from
-- the front of it; leading is only consulted together with correctable. The
-- entries returned are the stored entries - treat them as read-only.
function mcvp.entries(opts)
  return mcvp.merge.entries(mcvp._state, opts)
end

function mcvp.version()
  return mcvp._state.version
end

--- Name the character this catalog belongs to, which is what enables the
-- on-disk cache. Until a game calls this nothing is persisted: the protocol
-- carries no character identifier, and a cache that cannot name its character
-- would serve one character's vocabulary, and their own shortcuts, to another
-- on the same profile. Pass nil to turn caching off again.
function mcvp.setCacheKey(key)
  if key == nil then
    mcvp._cacheKey = nil
    return
  end
  assert(type(key) == "string" and key ~= "", "mcvp.setCacheKey needs a non-empty string")
  -- Whatever a game calls its characters, this has to be one path segment.
  mcvp._cacheKey = key:gsub("[^%w_%-]", "_")
  -- A game that names the character after the package started still gets the
  -- benefit of the cache, provided nothing has arrived over the wire yet.
  restore()
end

function mcvp.start()
  mcvp.stop()
  restore()
  mcvp._handlers.catalog = registerAnonymousEventHandler("gmcp.Client.Vocabulary.Catalog", mcvp._onCatalog)
  mcvp._handlers.update = registerAnonymousEventHandler("gmcp.Client.Vocabulary.Update", mcvp._onUpdate)
  mcvp._handlers.protocol = registerAnonymousEventHandler("sysProtocolEnabled", mcvp._onGmcpEnabled)
  -- If GMCP is already up (package installed mid-session), advertise now;
  -- harmless before negotiation, where the server ignores unknown tokens.
  if type(sendGMCP) == "function" then
    pcall(sendGMCP, 'Core.Supports.Add ["Client.Vocabulary 1"]')
  end
end

function mcvp.stop()
  for key, id in pairs(mcvp._handlers) do
    if id then killAnonymousEventHandler(id) end
    mcvp._handlers[key] = nil
  end
  -- Also disarms a scheduled re-request: its timer checks this flag before
  -- sending, so a torn-down package never talks to the server.
  mcvp._rerequestPending = false
end

mcvp.start()
