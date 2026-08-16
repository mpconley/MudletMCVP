--- MCVP lifecycle: negotiation, GMCP handlers, re-request discipline, cache.
-- Uses only Mudlet APIs confirmed present in both desktop Mudlet and
-- mudlet-web (sendGMCP, registerAnonymousEventHandler, tempTimer,
-- getMudletHomeDir, table.save/table.load, raiseEvent), so the package runs
-- unchanged on either client. All protocol logic lives in mcvp/merge.lua;
-- this file only wires it to the wire.
-- @module mcvp

mcvp = mcvp or {}
assert(mcvp.merge, "MCVPMerge must load before MCVPLoader - check scripts.json order")

mcvp._state = mcvp._state or mcvp.merge.new()
mcvp._handlers = mcvp._handlers or {}
-- One-shot re-request discipline: while one is pending, no path may issue
-- another. The server throttles rebuilds and answers identical-version
-- Catalogs from a held copy, so retry loops gain nothing and are forbidden.
mcvp._rerequestPending = false
-- Versions held earlier this session, for the defensive regression rule.
-- Opaque versions cannot be ordered, so "older" is only detectable as
-- "seen before and not current".
mcvp._seenVersions = mcvp._seenVersions or {}

local CACHE_FILE = "mcvp-cache.lua"

local function cachePath()
  return getMudletHomeDir() .. "/" .. CACHE_FILE
end

--- Send the bare-package re-request, at most one in flight.
-- @param delay optional seconds to wait first (the version-regression rule
--        schedules past the server's rebuild throttle window)
function mcvp.rerequest(delay)
  if mcvp._rerequestPending then return end
  mcvp._rerequestPending = true
  local fire = function() sendGMCP("Client.Vocabulary") end
  if delay and delay > 0 then
    tempTimer(delay, fire)
  else
    fire()
  end
end

local function persist()
  -- Best effort: a cache miss only costs a re-parse on the next session
  pcall(table.save, cachePath(), { version = mcvp._state.version, categories = mcvp._state.categories })
end

local function restore()
  local cached = {}
  local ok = pcall(table.load, cachePath(), cached)
  if ok and type(cached.version) == "string" and type(cached.categories) == "table" then
    mcvp._state.version = cached.version
    mcvp._state.categories = cached.categories
    mcvp._seenVersions[cached.version] = true
  end
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

  -- Any arriving Catalog satisfies a pending re-request
  mcvp._rerequestPending = false

  if payload.version == mcvp._state.version then
    -- Identical version: either the throttle's held copy answering a
    -- re-request (success, nothing to do) or a pagination frame (merged
    -- additively by the engine). Both are handled by applying.
    mcvp.merge.applyCatalog(mcvp._state, payload)
    announce()
    return
  end

  -- Defensive regression rule: a version seen earlier this session but no
  -- longer current means a served copy older than state we have already
  -- merged past. Keep merged state; one re-request after the server's
  -- throttle window. Expected unreachable against conforming servers.
  if payload.version and mcvp._seenVersions[payload.version] then
    mcvp.rerequest(12)
    return
  end

  if mcvp.merge.applyCatalog(mcvp._state, payload) then
    mcvp._seenVersions[mcvp._state.version] = true
    persist()
    announce()
  end
end

function mcvp._onUpdate()
  local payload = gmcp and gmcp.Client and gmcp.Client.Vocabulary and gmcp.Client.Vocabulary.Update
  if type(payload) ~= "table" then return end

  local ok, why = mcvp.merge.applyUpdate(mcvp._state, payload)
  if ok then
    mcvp._seenVersions[mcvp._state.version] = true
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
-- category, maxPriority, biasable, correctable, leading.
function mcvp.entries(opts)
  return mcvp.merge.entries(mcvp._state, opts)
end

function mcvp.version()
  return mcvp._state.version
end

function mcvp.start()
  mcvp.stop()
  restore()
  mcvp._handlers.catalog = registerAnonymousEventHandler("gmcp.Client.Vocabulary.Catalog", mcvp._onCatalog)
  mcvp._handlers.update = registerAnonymousEventHandler("gmcp.Client.Vocabulary.Update", mcvp._onUpdate)
  mcvp._handlers.protocol = registerAnonymousEventHandler("sysProtocolEnabled", mcvp._onGmcpEnabled)
  -- If GMCP is already up (package installed mid-session), advertise now;
  -- harmless before negotiation, where the server ignores unknown tokens.
  pcall(sendGMCP, 'Core.Supports.Add ["Client.Vocabulary 1"]')
end

function mcvp.stop()
  for key, id in pairs(mcvp._handlers) do
    if id then killAnonymousEventHandler(id) end
    mcvp._handlers[key] = nil
  end
  mcvp._rerequestPending = false
end

mcvp.start()
