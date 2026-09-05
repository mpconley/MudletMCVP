-- Lifecycle tests: the wire-facing rules that live in MCVPLoader.lua rather
-- than the merge engine - one-shot re-request discipline, no-baseline
-- recovery, the version-regression defensive rule, and negotiation. Mudlet is
-- represented by spec/mudlet_fake.lua; each test drives the handlers the
-- package actually registered.
local fake = dofile("spec/mudlet_fake.lua")

local COMMANDS = { commands = { priority = 1, entries = { { word = "kill" } } } }

describe("mcvp lifecycle", function()
  local m

  local function catalogPayload(version, categories)
    _G.gmcp = { Client = { Vocabulary = { Catalog = {
      version = version, categories = categories or COMMANDS,
    }}}}
  end

  local function updatePayload(version, from)
    _G.gmcp = { Client = { Vocabulary = { Update = {
      version = version, from = from,
      categories = { commands = { add = { { word = "peer" } } } },
    }}}}
  end

  before_each(function()
    m = fake.install()
    fake.loadPackage()
  end)

  it("advertises Client.Vocabulary 1 on start and on GMCP negotiation", function()
    assert.equals('Core.Supports.Add ["Client.Vocabulary 1"]', m.sent[1])
    mcvp._onGmcpEnabled(nil, "GMCP")
    assert.equals('Core.Supports.Add ["Client.Vocabulary 1"]', m.sent[#m.sent])
    local count = #m.sent
    mcvp._onGmcpEnabled(nil, "MSDP")
    assert.equals(count, #m.sent) -- other protocols do not re-advertise
  end)

  it("listens on exactly the events the protocol arrives on", function()
    -- A typo in any of these names means the package hears nothing at all in
    -- production; calling the handlers directly would never notice.
    assert.same({
      "gmcp.Client.Vocabulary.Catalog",
      "gmcp.Client.Vocabulary.Update",
      "sysProtocolEnabled",
    }, m.registeredEvents())
  end)

  it("merges a Catalog delivered through its registered event handler", function()
    catalogPayload("v1")
    m.fire("gmcp.Client.Vocabulary.Catalog")
    assert.equals("v1", mcvp.version())
    assert.equals(1, #mcvp.entries())
  end)

  it("recovers from an Update with no baseline via a single re-request", function()
    updatePayload("v2", "v1")
    mcvp._onUpdate()
    assert.equals(1, m.rerequests())
    -- Second fault while pending must NOT send again (one-shot discipline)
    mcvp._onUpdate()
    assert.equals(1, m.rerequests())
  end)

  it("clears the pending re-request when any Catalog arrives", function()
    updatePayload("v2", "v1")
    mcvp._onUpdate()             -- pending now
    catalogPayload("v2")
    mcvp._onCatalog()            -- satisfies it
    updatePayload("v9", "v8")    -- new fault: from mismatch
    mcvp._onUpdate()
    assert.equals(2, m.rerequests())
    assert.equals("v2", mcvp.version()) -- mismatched update was discarded
  end)

  it("applies a chained Update and announces it", function()
    catalogPayload("v1")
    mcvp._onCatalog()
    updatePayload("v2", "v1")
    mcvp._onUpdate()
    assert.equals("v2", mcvp.version())
    assert.equals("mcvp.updated", m.events[#m.events].name)
    assert.equals("v2", m.events[#m.events].value)
  end)

  it("treats an identical-version Catalog as success, not a stall", function()
    catalogPayload("v1")
    mcvp._onCatalog()
    catalogPayload("v1")
    mcvp._onCatalog()
    assert.equals("v1", mcvp.version())
    assert.equals(0, m.rerequests()) -- no re-request issued
  end)

  it("discards a Catalog it cannot apply without announcing or spending recovery", function()
    -- On a fresh session both versions are nil, so a Catalog with no version
    -- must not be mistaken for an identical-version frame.
    updatePayload("v2", "v1")
    mcvp._onUpdate()                       -- pending re-request
    local announced = #m.events
    _G.gmcp = { Client = { Vocabulary = { Catalog = { categories = COMMANDS } } } }
    mcvp._onCatalog()
    assert.equals(announced, #m.events)    -- consumers were not told anything changed
    assert.is_nil(mcvp.version())
    -- The broken frame recovered nothing, so the chain break is still pending
    -- and a later fault must not be able to issue a second request.
    updatePayload("v9", "v8")
    mcvp._onUpdate()
    assert.equals(1, m.rerequests())
  end)

  describe("a Catalog bearing a version held earlier in the session", function()
    before_each(function()
      catalogPayload("v1")
      mcvp._onCatalog()
      updatePayload("v2", "v1")
      mcvp._onUpdate()
    end)

    it("is applied, because a full Catalog is authoritative by construction", function()
      -- The version is stable for identical content, so a player creating and
      -- then deleting a shortcut returns the catalog to a version this client
      -- already held. Discarding it would reject the server's current state.
      catalogPayload("v1")
      mcvp._onCatalog()
      assert.equals("v1", mcvp.version())
    end)

    it("never answers a recurring version with a re-request", function()
      -- Re-requesting would be answered with the same catalog, and answering
      -- it that way again is the retry loop the standard forbids.
      for _ = 1, 5 do
        catalogPayload("v1")
        mcvp._onCatalog()
        for _, timer in ipairs(m.timers) do timer.fn() end
      end
      assert.equals(0, m.rerequests())
      assert.equals(0, #m.timers)
      assert.equals("v1", mcvp.version())
    end)
  end)

  describe("re-request discipline", function()
    it("does not latch itself off when the send fails", function()
      _G.sendGMCP = function() error("not connected") end
      mcvp.rerequest()
      assert.is_false(mcvp._rerequestPending)
      _G.sendGMCP = function(msg) m.sent[#m.sent + 1] = msg end
      mcvp.rerequest()
      assert.equals(1, m.rerequests())
    end)

    it("drops a scheduled re-request that a Catalog already satisfied", function()
      updatePayload("v2", "v1")
      mcvp._onUpdate()              -- no baseline: one re-request, sent at once
      mcvp._rerequestPending = false
      mcvp.rerequest(12)            -- and a caller schedules a delayed one
      assert.equals(1, #m.timers)
      catalogPayload("v4")
      mcvp._onCatalog()             -- a Catalog arrives first and satisfies it
      local before = m.rerequests()
      for _, timer in ipairs(m.timers) do timer.fn() end
      assert.equals(before, m.rerequests())  -- one fault never yields two requests
    end)

    it("is disarmed by stop(), so a torn-down package never talks to the server", function()
      mcvp.rerequest(12)
      assert.equals(1, #m.timers)
      mcvp.stop()
      m.timers[1].fn()
      assert.equals(0, m.rerequests())
    end)
  end)
end)

describe("mcvp fault injection", function()
  local m

  before_each(function()
    m = fake.install()
    fake.loadPackage(true)
  end)

  it("drops exactly one armed Update, and the chain break recovers", function()
    _G.gmcp = { Client = { Vocabulary = { Catalog = { version = "v1", categories = COMMANDS } } } }
    mcvp._onCatalog()

    mcvp.debug.dropNextUpdate()
    _G.gmcp = { Client = { Vocabulary = { Update = {
      version = "v2", from = "v1", categories = { commands = { add = { { word = "peer" } } } },
    }}}}
    mcvp._onUpdate()                       -- dropped: simulated transport loss
    assert.equals("v1", mcvp.version())

    _G.gmcp = { Client = { Vocabulary = { Update = {
      version = "v3", from = "v2", categories = { commands = { add = { { word = "wave" } } } },
    }}}}
    mcvp._onUpdate()                       -- from mismatch -> one re-request
    assert.equals("v1", mcvp.version())
    assert.equals(1, m.rerequests())
  end)

  it("reports state for the integration checklist", function()
    _G.gmcp = { Client = { Vocabulary = { Catalog = { version = "v1", categories = {
      commands = { priority = 1, entries = { { word = "kill" }, { word = "quit", protected = true } } },
    }}}}}
    mcvp._onCatalog()
    mcvp.debug.status()
    local line = m.echoes[#m.echoes]
    assert.is_truthy(line:find("version=v1", 1, true))
    assert.is_truthy(line:find("entries=2", 1, true))
    assert.is_truthy(line:find("biasable=1", 1, true))  -- quit is protected
  end)
end)
