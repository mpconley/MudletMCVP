-- Contract tests for mcvp.merge - each block names the protocol rule it pins.
dofile("src/scripts/MCVP/MCVPMerge.lua")
local merge = mcvp.merge

local function catalog(version, categories)
  return { version = version, categories = categories }
end

describe("mcvp.merge", function()
  local state

  before_each(function()
    state = merge.new()
    assert.is_true(merge.applyCatalog(state, catalog("v1", {
      commands = { priority = 1, entries = {
        { word = "kill", syntax = "kill %living" },
        { word = "quit", priority = 3, protected = 1 },
        { word = "mudlist", priority = "3" },
      }},
      nicknames = { priority = 1, entries = {
        { word = "zz", position = "argument" },
        { word = "zz", position = "leading", expansion = "zoom zoom" },
      }},
    })))
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

  describe("catalog ingest", function()
    it("applies category defaults and per-entry overrides", function()
      local tier1 = merge.entries(state, { category = "commands", maxPriority = 1 })
      assert.equals(1, #tier1)
      assert.equals("kill", tier1[1].word)
    end)

    it("stores both positions of one word as distinct entries", function()
      assert.equals(2, #merge.entries(state, { category = "nicknames" }))
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
      for _, e in ipairs(merge.entries(state, { category = "commands" })) do
        if e.word == "kill" then
          assert.equals(2, e.priority)
          assert.is_nil(e.syntax) -- replaced wholesale, not patched
        end
      end
    end)
  end)

  describe("fail-safe handling", function()
    it("keeps category defaults immutable across updates", function()
      assert.is_true(merge.applyUpdate(state, { version = "v2", from = "v1", categories = {
        commands = { priority = 3, add = { { word = "peer" } } },
      }}))
      -- New entry inherits the ORIGINAL default (1), not the smuggled 3.
      for _, e in ipairs(merge.entries(state, { category = "commands" })) do
        if e.word == "peer" then assert.equals(1, e.priority) end
      end
    end)

    it("skips deltas naming unknown categories rather than inventing them", function()
      assert.is_true(merge.applyUpdate(state, { version = "v2", from = "v1", categories = {
        mysterycat = { add = { { word = "boo" } } },
      }}))
      assert.equals(0, #merge.entries(state, { category = "mysterycat" }))
    end)

    it("excludes unknown position values from correction but not from listing", function()
      assert.is_true(merge.applyUpdate(state, { version = "v2", from = "v1", categories = {
        commands = { add = { { word = "warp", position = "sideways" } } },
      }}))
      local listed, correctable = false, false
      for _, e in ipairs(merge.entries(state, { category = "commands" })) do
        if e.word == "warp" then listed = true end
      end
      for _, e in ipairs(merge.entries(state, { category = "commands", correctable = true })) do
        if e.word == "warp" then correctable = true end
      end
      assert.is_true(listed)
      assert.is_false(correctable)
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
  end)

  describe("consumer filters", function()
    it("never offers protected words for biasing or correction", function()
      for _, e in ipairs(merge.entries(state, { biasable = true })) do
        assert.is_false(e.protected)
      end
      for _, e in ipairs(merge.entries(state, { correctable = true })) do
        assert.is_false(e.protected)
      end
    end)

    it("honors position in leading vs argument correction pools", function()
      local leading = merge.entries(state, { category = "nicknames", correctable = true, leading = true })
      assert.equals(1, #leading)
      assert.equals("leading", leading[1].position)
    end)
  end)
end)
