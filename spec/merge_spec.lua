-- Contract tests for mcvp.merge - each block names the protocol rule it pins.
dofile("src/scripts/MCVP/MCVPMerge.lua")
local merge = mcvp.merge

local function catalog(version, categories)
  return { version = version, categories = categories }
end

-- Look an entry up by name. Tests that loop over entries with an "if the word
-- matches" guard pass vacuously when the entry is missing entirely, which is
-- exactly the failure they are meant to catch.
local function byWord(entries, word)
  for _, entry in ipairs(entries) do
    if entry.word == word then return entry end
  end
  return nil
end

local function words(entries)
  local out = {}
  for _, entry in ipairs(entries) do out[#out + 1] = entry.word end
  return out
end

describe("mcvp.merge", function()
  local state

  before_each(function()
    state = merge.new()
    assert.is_true(merge.applyCatalog(state, catalog("v1", {
      commands = { priority = 1, entries = {
        { word = "kill", syntax = "kill %living" },
        { word = "recall", protected = true },
        { word = "quit", priority = 3, protected = 1 },
        { word = "mudlist", priority = "3" },
      }},
      nicknames = { priority = 1, entries = {
        { word = "zz", position = "argument" },
        { word = "zz", position = "leading", expansion = "zoom zoom" },
      }},
    })))
  end)

  describe("biasable ordering", function()
    -- The consumer fills a small budget from the front of this list, so the
    -- order decides which words are biased at all.
    before_each(function()
      state = merge.new()
      assert.is_true(merge.applyCatalog(state, catalog("v2", {
        commands = { priority = 2, entries = {
          { word = "zebra", priority = 1 },
          { word = "alpha" },
          { word = "bravo" },
        }},
        socials = { priority = 2, entries = {
          { word = "aardvark" },
          { word = "yak", priority = 1 },
        }},
        helptopics = { priority = 3, entries = { { word = "combat" } } },
      })))
    end)

    it("puts every tier 1 word ahead of every tier 2 word, across categories", function()
      assert.same({ "yak", "zebra", "aardvark", "alpha", "bravo" },
                  words(merge.entries(state, { biasable = true })))
    end)

    it("orders within a tier by word, so two sessions bias identically", function()
      local first = words(merge.entries(state, { biasable = true }))
      assert.same(first, words(merge.entries(state, { biasable = true })))
      assert.same({ "aardvark", "alpha", "bravo" }, { first[3], first[4], first[5] })
    end)

    it("still excludes tier 3, which is never biased toward", function()
      for _, word in ipairs(words(merge.entries(state, { biasable = true }))) do
        assert.not_equals("combat", word)
      end
    end)
  end)

  describe("field encoding", function()
    it("accepts every boolean wire form, failing safe for protected", function()
      assert.is_true(merge.normBool(true))
      assert.is_true(merge.normBool(1))
      assert.is_true(merge.normBool("true"))
      assert.is_true(merge.normBool("TRUE"))
      assert.is_true(merge.normBool("yes"))         -- unknown present value -> protected
      assert.is_false(merge.normBool(false))
      assert.is_false(merge.normBool(0))
      assert.is_false(merge.normBool("0"))
      assert.is_false(merge.normBool("False"))
      assert.is_false(merge.normBool(nil))          -- absent -> false
    end)

    it("accepts numeric strings for priority and defaults anything invalid", function()
      assert.equals(2, merge.normPriority("2", 1))
      assert.equals(1, merge.normPriority("x", 1))
      assert.equals(1, merge.normPriority(7, 1))
      assert.equals(3, merge.normPriority(nil, 3))
    end)
  end)

  -- "A client MUST therefore treat an empty string where an array or object is
  -- expected as an empty collection, not as a malformed message - the
  -- distinction matters, because a client that rejects the message instead
  -- discards a valid Update and breaks its own chain."
  describe("empty collections from drivers with no empty-array form", function()
    it("reads a Catalog whose categories object arrives as an empty string", function()
      local fresh = merge.new()
      assert.is_true(merge.applyCatalog(fresh, catalog("v1", "")))
      assert.equals("v1", fresh.version)
      assert.equals(0, #merge.entries(fresh))
    end)

    it("keeps a category whose entries arrive as an empty string", function()
      local fresh = merge.new()
      assert.is_true(merge.applyCatalog(fresh, catalog("v1", {
        commands = { priority = 1, entries = { { word = "kill" } } },
        socials = { priority = 2, entries = "" },
      })))
      assert.is_not_nil(fresh.categories.socials)
      assert.equals(0, #merge.entries(fresh, { category = "socials" }))
    end)

    it("lets a later Update add into a category that arrived empty", function()
      -- The divergence this prevents: dropping the empty category makes the
      -- Update's add a no-op against an unknown category, and the version
      -- still advances, so the from-chain can never detect the loss.
      local fresh = merge.new()
      assert.is_true(merge.applyCatalog(fresh, catalog("v1", {
        socials = { priority = 2, entries = "" },
      })))
      assert.is_true(merge.applyUpdate(fresh, {
        version = "v2", from = "v1",
        categories = { socials = { add = { { word = "wave" } } } },
      }))
      assert.same({ "wave" }, words(merge.entries(fresh, { category = "socials" })))
    end)

    it("treats an Update with an empty-string categories object as an empty delta", function()
      assert.is_true(merge.applyUpdate(state, { version = "v2", from = "v1", categories = "" }))
      assert.equals("v2", state.version)
    end)

    it("treats empty-string add, remove and aliases as empty", function()
      assert.is_true(merge.applyUpdate(state, { version = "v2", from = "v1", categories = {
        commands = { add = "", remove = "" },
      }}))
      assert.is_not_nil(byWord(merge.entries(state, { category = "commands" }), "kill"))

      local fresh = merge.new()
      assert.is_true(merge.applyCatalog(fresh, catalog("v1", {
        directions = { priority = 1, entries = { { word = "north", aliases = "" } } },
      })))
      assert.is_nil(byWord(merge.entries(fresh), "north").aliases)
    end)
  end)

  describe("catalog ingest", function()
    it("applies category defaults and per-entry overrides", function()
      local tier1 = merge.entries(state, { category = "commands", maxPriority = 1 })
      assert.is_not_nil(byWord(tier1, "kill"))
      assert.is_nil(byWord(tier1, "mudlist"))       -- overridden to tier 3
      assert.equals(3, byWord(merge.entries(state), "mudlist").priority)
    end)

    it("stores both positions of one word as distinct entries", function()
      assert.equals(2, #merge.entries(state, { category = "nicknames" }))
    end)

    it("stores categories it does not recognize rather than dropping them", function()
      local fresh = merge.new()
      assert.is_true(merge.applyCatalog(fresh, catalog("v1", {
        futurecat = { priority = 2, entries = { { word = "warp" } } },
      })))
      assert.is_not_nil(byWord(merge.entries(fresh), "warp"))
    end)

    it("keeps aliases, dropping members that are not usable words", function()
      local fresh = merge.new()
      assert.is_true(merge.applyCatalog(fresh, catalog("v1", {
        directions = { priority = 1, entries = {
          { word = "north", aliases = { "n", "", 5, "nor" } },
        }},
      })))
      assert.same({ "n", "nor" }, byWord(merge.entries(fresh), "north").aliases)
    end)

    it("never lists an alias as an entry of its own", function()
      local fresh = merge.new()
      merge.applyCatalog(fresh, catalog("v1", {
        directions = { priority = 1, entries = { { word = "north", aliases = { "n" } } } },
      }))
      assert.equals(1, #merge.entries(fresh))
      assert.is_nil(byWord(merge.entries(fresh), "n"))
    end)

    it("has no baseline before any catalog", function()
      local fresh = merge.new()
      local ok, err = merge.applyUpdate(fresh, { version = "v2", from = "v1", categories = {} })
      assert.is_nil(ok)
      assert.equals("no baseline", err)
    end)
  end)

  describe("update chain", function()
    it("rejects a from mismatch", function()
      local ok, err = merge.applyUpdate(state, { version = "v3", from = "v2", categories = {} })
      assert.is_nil(ok)
      assert.equals("from mismatch", err)
      assert.equals("v1", state.version)
    end)

    it("advances the version on success", function()
      assert.is_true(merge.applyUpdate(state, { version = "v2", from = "v1", categories = {} }))
      assert.equals("v2", state.version)
    end)

    it("rejects an Update carrying an empty version, which no Catalog can bear", function()
      local ok, err = merge.applyUpdate(state, { version = "", from = "v1", categories = {} })
      assert.is_nil(ok)
      assert.equals("malformed", err)
      assert.equals("v1", state.version)
    end)

    it("reaches the same state as the Catalog the server would send instead", function()
      -- "After applying an Update, the client's merged state equals the
      -- Catalog the server would send at that moment."
      local function canonical(s)
        local out = {}
        for _, entry in ipairs(merge.entries(s)) do
          out[#out + 1] = table.concat({
            entry.word, entry.position or "", entry.priority,
            tostring(entry.protected), entry.syntax or "",
          }, "|")
        end
        table.sort(out)
        return out
      end

      assert.is_true(merge.applyUpdate(state, { version = "v2", from = "v1", categories = {
        commands = { remove = { "mudlist" }, add = { { word = "peer" } } },
        nicknames = { remove = { "zz" }, add = { { word = "zz", position = "leading" } } },
      }}))

      local equivalent = merge.new()
      assert.is_true(merge.applyCatalog(equivalent, catalog("v2", {
        commands = { priority = 1, entries = {
          { word = "kill", syntax = "kill %living" },
          { word = "recall", protected = true },
          { word = "quit", priority = 3, protected = 1 },
          { word = "peer" },
        }},
        nicknames = { priority = 1, entries = { { word = "zz", position = "leading" } } },
      })))

      assert.same(canonical(equivalent), canonical(state))
    end)
  end)

  describe("removes before adds", function()
    it("drops all positions on remove and keeps the same-update survivor", function()
      -- The reference server's worked case: [zz/argument, zz/leading] -> [zz/leading]
      assert.is_true(merge.applyUpdate(state, { version = "v2", from = "v1", categories = {
        nicknames = { remove = { "zz" }, add = { { word = "zz", position = "leading" } } },
      }}))
      local left = merge.entries(state, { category = "nicknames" })
      assert.equals(1, #left)
      assert.equals("leading", left[1].position)
    end)

    it("treats add as wholesale replacement (cap-ripple priority-only change)", function()
      assert.is_true(merge.applyUpdate(state, { version = "v2", from = "v1", categories = {
        commands = { add = { { word = "kill", priority = 2 } } },
      }}))
      local kill = byWord(merge.entries(state, { category = "commands" }), "kill")
      assert.is_not_nil(kill)
      assert.equals(2, kill.priority)
      assert.is_nil(kill.syntax) -- replaced wholesale, not patched
    end)
  end)

  describe("fail-safe handling", function()
    it("keeps category defaults immutable across updates", function()
      assert.is_true(merge.applyUpdate(state, { version = "v2", from = "v1", categories = {
        commands = { priority = 3, add = { { word = "peer" } } },
      }}))
      -- New entry inherits the ORIGINAL default (1), not the smuggled 3.
      local peer = byWord(merge.entries(state, { category = "commands" }), "peer")
      assert.is_not_nil(peer)
      assert.equals(1, peer.priority)
    end)

    it("skips deltas naming unknown categories rather than inventing them", function()
      assert.is_true(merge.applyUpdate(state, { version = "v2", from = "v1", categories = {
        mysterycat = { add = { { word = "boo" } } },
      }}))
      assert.equals(0, #merge.entries(state, { category = "mysterycat" }))
    end)

    it("keeps an unrecognized position as its own identity", function()
      -- Identity is (word, position). Folding an unrecognized value onto the
      -- same word with no position would let wire order decide which of the
      -- two survives, and half the orderings lose the fail-closed one.
      local fresh = merge.new()
      assert.is_true(merge.applyCatalog(fresh, catalog("v1", {
        commands = { priority = 1, entries = {
          { word = "warp" },
          { word = "warp", position = "sideways" },
        }},
      })))
      assert.equals(2, #merge.entries(fresh, { category = "commands" }))
      -- The plain one is still correctable; the unrecognized one never is.
      assert.equals(1, #merge.entries(fresh, { category = "commands", correctable = true }))
    end)

    it("keys entries so a separator inside a word or position cannot collide", function()
      local fresh = merge.new()
      assert.is_true(merge.applyCatalog(fresh, catalog("v1", {
        commands = { priority = 1, entries = {
          { word = "a|b" },
          { word = "a", position = "b|" },
          { word = "a" },
        }},
      })))
      assert.equals(3, #merge.entries(fresh, { category = "commands" }))
    end)

    it("excludes unknown position values from correction but not from listing", function()
      assert.is_true(merge.applyUpdate(state, { version = "v2", from = "v1", categories = {
        commands = { add = { { word = "warp", position = "sideways" } } },
      }}))
      assert.is_not_nil(byWord(merge.entries(state, { category = "commands" }), "warp"))
      assert.is_nil(byWord(merge.entries(state, { category = "commands", correctable = true }), "warp"))
    end)
  end)

  describe("size bounds against a hostile or broken peer", function()
    it("stops merging entries past the total cap", function()
      local cap = merge.maxTotalEntries
      merge.maxTotalEntries = 3
      local ok, fresh = pcall(function()
        local s = merge.new()
        local entries = {}
        for i = 1, 50 do entries[i] = { word = "word" .. i } end
        assert.is_true(merge.applyCatalog(s, catalog("v1", {
          commands = { priority = 1, entries = entries },
        })))
        return s
      end)
      merge.maxTotalEntries = cap
      assert.is_true(ok)
      assert.equals(3, #merge.entries(fresh))
    end)

    it("drops a word longer than any real command", function()
      local fresh = merge.new()
      assert.is_true(merge.applyCatalog(fresh, catalog("v1", {
        commands = { priority = 1, entries = {
          { word = string.rep("a", merge.maxWordLength + 1) },
          { word = "kill" },
        }},
      })))
      assert.same({ "kill" }, words(merge.entries(fresh)))
    end)

    it("drops an alias longer than any real command", function()
      local fresh = merge.new()
      merge.applyCatalog(fresh, catalog("v1", {
        commands = { priority = 1, entries = { { word = "kill", aliases = {
          string.rep("z", merge.maxWordLength + 1), "k",
        }}}},
      }))
      assert.same({ "k" }, byWord(merge.entries(fresh), "kill").aliases)
    end)

    it("caps the aliases carried on one entry", function()
      local many = {}
      for i = 1, merge.maxAliases + 10 do many[i] = "alias" .. i end
      local fresh = merge.new()
      merge.applyCatalog(fresh, catalog("v1", {
        commands = { priority = 1, entries = { { word = "kill", aliases = many } } },
      }))
      assert.equals(merge.maxAliases, #byWord(merge.entries(fresh), "kill").aliases)
    end)
  end)

  describe("pagination", function()
    it("merges same-version Catalog frames additively, by category", function()
      assert.is_true(merge.applyCatalog(state, catalog("v1", {
        socials = { priority = 2, entries = { { word = "wave" } } },
      })))
      -- The earlier frame's categories survive; the new one joins them
      assert.equals(1, #merge.entries(state, { category = "socials" }))
      assert.is_true(#merge.entries(state, { category = "commands" }) > 0)
    end)

    it("replaces all state when the version differs", function()
      assert.is_true(merge.applyCatalog(state, catalog("v2", {
        socials = { priority = 2, entries = { { word = "wave" } } },
      })))
      assert.equals(0, #merge.entries(state, { category = "commands" }))
    end)

    it("replaces a category wholesale when two frames of one version repeat it", function()
      -- The standard has servers split a Catalog *by category*; a repeated
      -- category is the server contradicting itself, and the later frame wins.
      assert.is_true(merge.applyCatalog(state, catalog("v1", {
        commands = { priority = 1, entries = { { word = "wave" } } },
      })))
      assert.same({ "wave" }, words(merge.entries(state, { category = "commands" })))
    end)
  end)

  describe("consumer filters", function()
    it("never offers a protected word for biasing, at any tier", function()
      -- recall is tier 1 and protected: the tier rule alone would let it
      -- through, so this is the assertion that pins the safety flag.
      assert.is_not_nil(byWord(merge.entries(state), "recall"))
      assert.is_nil(byWord(merge.entries(state, { biasable = true }), "recall"))
      assert.is_nil(byWord(merge.entries(state, { correctable = true }), "recall"))
    end)

    it("leaves one- and two-letter forms out of biasing but keeps them listed", function()
      assert.is_not_nil(byWord(merge.entries(state, { category = "nicknames" }), "zz"))
      assert.is_nil(byWord(merge.entries(state, { biasable = true }), "zz"))
      assert.is_not_nil(byWord(merge.entries(state, { correctable = true, leading = true }), "zz"))
    end)

    it("honors position in leading vs argument correction pools", function()
      local leading = merge.entries(state, { category = "nicknames", correctable = true, leading = true })
      assert.equals(1, #leading)
      assert.equals("leading", leading[1].position)
    end)
  end)
end)
