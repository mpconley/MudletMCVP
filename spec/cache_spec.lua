-- The on-disk catalog cache. This path had no coverage while table.save and
-- table.load were stubbed as no-ops, which is what let two state-loss defects
-- live in it; spec/mudlet_fake.lua models the real contract instead.
local fake = dofile("spec/mudlet_fake.lua")

local CACHE = "/fake-profile/mcvp-cache-hero.lua"

local function catalog(version, categories)
  _G.gmcp = { Client = { Vocabulary = { Catalog = { version = version, categories = categories } } } }
end

local COMMANDS = { commands = { priority = 1, entries = { { word = "kill" } } } }
local SOCIALS = { socials = { priority = 2, entries = { { word = "wave" } } } }

describe("mcvp catalog cache", function()
  it("writes a catalog one session can restore in the next", function()
    local first = fake.install()
    fake.loadPackage()
    mcvp.setCacheKey("hero")
    catalog("v1", COMMANDS)
    mcvp._onCatalog()
    assert.is_not_nil(first.cache())

    local second = fake.install({ files = first.files })
    fake.loadPackage()
    mcvp.setCacheKey("hero")
    assert.equals("v1", mcvp.version())
    assert.equals(1, #mcvp.entries())
    assert.is_true(second.rerequests() == 0)
  end)

  it("caches every frame of a paginated Catalog, not just the first", function()
    -- Frames after the first share the version, so a cache missing them is
    -- truncated while still labelled with the complete catalog's version -
    -- and a same-version Catalog merges additively, so it never self-repairs.
    local m = fake.install()
    fake.loadPackage()
    mcvp.setCacheKey("hero")
    catalog("v1", COMMANDS)
    mcvp._onCatalog()
    catalog("v1", SOCIALS)
    mcvp._onCatalog()

    assert.equals(2, #mcvp.entries())
    assert.is_not_nil(m.cache().categories.commands)
    assert.is_not_nil(m.cache().categories.socials)
  end)

  it("keeps merged state that is newer than the cache when the package reloads", function()
    -- Mudlet re-runs the scripts on a package update or a script edit, and
    -- mcvp._state deliberately survives that. Restoring over it would replace
    -- current state with whatever the last persist happened to hold.
    local m = fake.install()
    fake.loadPackage()
    mcvp.setCacheKey("hero")
    catalog("v1", COMMANDS)
    mcvp._onCatalog()
    catalog("v2", { commands = { priority = 1, entries = { { word = "kill" }, { word = "wave" } } } })
    mcvp._onCatalog()
    m.setCache({ version = "v0", categories = {
      old = { priority = 3, entries = { ["stale|"] = {
        word = "stale", priority = 3, protected = false, correctable = true,
      }}},
    }})

    dofile("src/scripts/MCVP/MCVPLoader.lua")   -- the reload

    assert.equals("v2", mcvp.version())
    assert.equals(2, #mcvp.entries())
  end)

  it("rejects a cache whose entries are not shaped like merged state", function()
    -- A hand-edited, truncated or foreign-written cache reaches consumers
    -- through mcvp.entries(), where a wrong field type raises inside the
    -- consumer's own call stack rather than anywhere near the cache.
    local m = fake.install({ files = { [CACHE] = { version = "v1", categories = {
      commands = { priority = 1, entries = { ["peer|"] = { word = "peer" } } },  -- no priority
    }}}})
    fake.loadPackage()
    mcvp.setCacheKey("hero")

    assert.is_nil(mcvp.version())
    assert.equals(0, #mcvp.entries())
    assert.has_no.errors(function() mcvp.entries({ biasable = true }) end)
    assert.has_no.errors(function() mcvp.entries({ maxPriority = 1 }) end)
    assert.is_true(#m.echoes > 0)   -- and says so, rather than failing later
  end)

  it("rejects a cached category that is missing its entries table", function()
    fake.install({ files = { [CACHE] = { version = "v1", categories = {
      commands = { priority = 1 },
    }}}})
    fake.loadPackage()
    mcvp.setCacheKey("hero")
    assert.is_nil(mcvp.version())
    assert.has_no.errors(function() mcvp.entries({ biasable = true }) end)
  end)

  it("writes nothing to disk until a game names the character", function()
    -- The protocol carries no character identifier, so a client that has not
    -- been told which character this is cannot key a cache safely. Not
    -- caching costs one re-parse; caching under the profile would serve one
    -- character's vocabulary, and their own shortcuts, to another.
    local m = fake.install()
    fake.loadPackage()                 -- deliberately no setCacheKey
    catalog("v1", COMMANDS)
    mcvp._onCatalog()

    assert.equals("v1", mcvp.version())      -- still merged and usable
    assert.equals(1, #mcvp.entries())
    local written = 0
    for _ in pairs(m.files) do written = written + 1 end
    assert.equals(0, written)
  end)

  it("never serves one character's catalog to another on the same profile", function()
    local m = fake.install()
    fake.loadPackage()
    mcvp.setCacheKey("alice")
    catalog("v1", { nicknames = { priority = 1, entries = { { word = "alicehome" } } } })
    mcvp._onCatalog()

    -- Bob logs in on the same Mudlet profile.
    fake.install({ files = m.files })
    fake.loadPackage()
    mcvp.setCacheKey("bob")
    assert.is_nil(mcvp.version())
    assert.equals(0, #mcvp.entries())

    -- ...and Alice still finds her own.
    fake.install({ files = m.files })
    fake.loadPackage()
    mcvp.setCacheKey("alice")
    assert.equals("v1", mcvp.version())
    assert.equals(1, #mcvp.entries())
  end)

  it("names a character that is not already a safe file name", function()
    local m = fake.install()
    fake.loadPackage()
    mcvp.setCacheKey("../../etc/passwd")
    catalog("v1", COMMANDS)
    mcvp._onCatalog()
    for path in pairs(m.files) do
      assert.is_nil(path:find("%.%."), "a character name must not escape the profile directory")
    end
  end)

  it("starts clean when there is no cache at all", function()
    local m = fake.install()
    fake.loadPackage()
    mcvp.setCacheKey("hero")
    assert.is_nil(mcvp.version())
    assert.equals(0, #mcvp.entries())
    assert.equals(0, #m.echoes)   -- a first run is not an error
  end)

  it("cannot let a stale cached category outlive the server's catalog", function()
    -- A cached category the server no longer sends must not survive a Catalog
    -- bearing the same version, or nothing can ever retract it.
    fake.install({ files = { [CACHE] = { version = "v1", categories = {
      commands = { priority = 1, entries = { ["kill|"] = {
        word = "kill", priority = 1, protected = false, correctable = true,
      }}},
      ghost = { priority = 1, entries = { ["oldword|"] = {
        word = "oldword", priority = 1, protected = false, correctable = true,
      }}},
    }}}})
    fake.loadPackage()
    mcvp.setCacheKey("hero")
    assert.equals("v1", mcvp.version())

    catalog("v1", COMMANDS)   -- the server's authoritative v1 has no ghost
    mcvp._onCatalog()

    local words = {}
    for _, entry in ipairs(mcvp.entries()) do words[#words + 1] = entry.word end
    table.sort(words)
    assert.same({ "kill" }, words)
  end)
end)
