-- Lifecycle tests: the wire-facing rules that live in init.lua rather than
-- the merge engine - one-shot re-request discipline, no-baseline recovery,
-- the version-regression defensive rule, and negotiation. Mudlet globals are
-- stubbed; each test drives the registered handlers directly.

describe("mcvp lifecycle", function()
  local sent, timers, events

  local function catalogPayload(version)
    _G.gmcp = { Client = { Vocabulary = { Catalog = {
      version = version,
      categories = { commands = { priority = 1, entries = { { word = "kill" } } } },
    }}}}
  end

  local function updatePayload(version, from)
    _G.gmcp = { Client = { Vocabulary = { Update = {
      version = version, from = from,
      categories = { commands = { add = { { word = "peer" } } } },
    }}}}
  end

  before_each(function()
    sent, timers, events = {}, {}, {}
    _G.sendGMCP = function(msg) sent[#sent + 1] = msg end
    _G.tempTimer = function(delay, fn) timers[#timers + 1] = { delay = delay, fn = fn } end
    _G.raiseEvent = function(name, ...) events[#events + 1] = name end
    _G.registerAnonymousEventHandler = function() return #sent + math.random(1000) end
    _G.killAnonymousEventHandler = function() end
    _G.getMudletHomeDir = function() return "." end
    _G.table.save = function() end
    _G.table.load = function() end
    _G.gmcp = nil
    _G.mcvp = nil
    dofile("src/scripts/MCVP/MCVPMerge.lua")
    dofile("src/scripts/MCVP/MCVPLoader.lua")
  end)

  it("advertises Client.Vocabulary 1 on start and on GMCP negotiation", function()
    assert.equals('Core.Supports.Add ["Client.Vocabulary 1"]', sent[1])
    mcvp._onGmcpEnabled(nil, "GMCP")
    assert.equals('Core.Supports.Add ["Client.Vocabulary 1"]', sent[#sent])
    local count = #sent
    mcvp._onGmcpEnabled(nil, "MSDP")
    assert.equals(count, #sent) -- other protocols do not re-advertise
  end)

  it("recovers from an Update with no baseline via a single re-request", function()
    updatePayload("v2", "v1")
    mcvp._onUpdate()
    assert.equals("Client.Vocabulary", sent[#sent])
    -- Second fault while pending must NOT send again (one-shot discipline)
    local count = #sent
    mcvp._onUpdate()
    assert.equals(count, #sent)
  end)

  it("clears the pending re-request when any Catalog arrives", function()
    updatePayload("v2", "v1")
    mcvp._onUpdate()             -- pending now
    catalogPayload("v2")
    mcvp._onCatalog()            -- satisfies it
    updatePayload("v9", "v8")    -- new fault: from mismatch
    mcvp._onUpdate()
    assert.equals("Client.Vocabulary", sent[#sent])
    assert.equals("v2", mcvp.version()) -- mismatched update was discarded
  end)

  it("applies a chained Update and announces it", function()
    catalogPayload("v1")
    mcvp._onCatalog()
    updatePayload("v2", "v1")
    mcvp._onUpdate()
    assert.equals("v2", mcvp.version())
    assert.equals("mcvp.updated", events[#events])
  end)

  it("treats an identical-version Catalog as success, not a stall", function()
    catalogPayload("v1")
    mcvp._onCatalog()
    local requests = #sent
    catalogPayload("v1")
    mcvp._onCatalog()
    assert.equals("v1", mcvp.version())
    assert.equals(requests, #sent) -- no re-request issued
  end)

  it("keeps merged state on version regression and schedules one delayed re-request", function()
    catalogPayload("v1")
    mcvp._onCatalog()
    updatePayload("v2", "v1")
    mcvp._onUpdate()
    -- A served copy bearing the superseded v1 arrives (transport fault class)
    catalogPayload("v1")
    mcvp._onCatalog()
    assert.equals("v2", mcvp.version())          -- merged state kept
    assert.equals(1, #timers)                     -- re-request deferred...
    assert.is_true(timers[1].delay >= 10)         -- ...past the throttle window
    timers[1].fn()
    assert.equals("Client.Vocabulary", sent[#sent])
  end)
end)
