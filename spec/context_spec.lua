-- Contract tests for mcvp.context - the half of in-reach binding that no game
-- owns. Adapters are represented here by the updates they produce, since what
-- a game sends is out of scope for the protocol and so for these tests.
dofile("src/scripts/MCVP/MCVPContext.lua")
local context = mcvp.context

local function thing(id, name, slot)
  return { id = id, name = name, slot = slot }
end

describe("mcvp.context", function()
  local state

  before_each(function()
    state = context.newState()
  end)

  describe("nouns", function()
    it("drops the article a player never says", function()
      assert.same({ "bottle", "beer" }, context.nouns("A bottle of beer"))
      assert.same({ "torch" }, context.nouns("A torch"))
    end)

    it("keeps every content word, so either can be spoken", function()
      assert.same({ "lucky", "coin" }, context.nouns("A lucky coin"))
    end)

    it("drops words too short to be worth biasing toward", function()
      assert.same({ "old", "elf" }, context.nouns("An old elf"))
    end)

    it("says nothing about nothing", function()
      assert.same({}, context.nouns(nil))
      assert.same({}, context.nouns(""))
    end)
  end)

  describe("apply", function()
    it("replaces everything known about one place", function()
      context.apply(state, { place = "room", replace = { thing(1, "A torch", "%item") } })
      context.apply(state, { place = "room", replace = { thing(2, "A sword", "%item") } })
      assert.same({ "sword" }, context.words(state))
    end)

    it("leaves other places alone when one is replaced", function()
      context.apply(state, { place = "inv", replace = { thing(1, "A lantern", "%item") } })
      context.apply(state, { place = "room", replace = { thing(2, "A sword", "%item") } })
      assert.same({ "lantern", "sword" }, (function()
        local words = context.words(state)
        table.sort(words)
        return words
      end)())
    end)

    it("adds one thing and removes one thing", function()
      context.apply(state, { place = "room", add = thing(1, "A torch", "%item") })
      assert.same({ "torch" }, context.words(state))
      context.apply(state, { place = "room", remove = 1 })
      assert.same({}, context.words(state))
    end)

    it("ignores an update that names no place", function()
      context.apply(state, { replace = { thing(1, "A torch", "%item") } })
      context.apply(state, { place = "", add = thing(2, "A sword", "%item") })
      assert.same({}, context.words(state))
    end)

    it("ignores an entry with no id or no name, which cannot be spoken or replaced", function()
      context.apply(state, { place = "room", replace = {
        { name = "A torch", slot = "%item" },
        thing(2, "", "%item"),
        thing(3, "A sword", "%item"),
      }})
      assert.same({ "sword" }, context.words(state))
    end)
  end)

  describe("what is in reach", function()
    before_each(function()
      context.apply(state, { place = "room", replace = {
        thing(1, "A torch", "%item"),
        thing(2, "A torch", "%item"),
        thing(3, "An old elf", "%living"),
      }})
      context.apply(state, { place = "inv", replace = { thing(4, "A lucky coin", "%item") } })
    end)

    it("says a word once however many copies are present", function()
      local words = context.words(state, { slot = "%item" })
      table.sort(words)
      assert.same({ "coin", "lucky", "torch" }, words)
    end)

    it("answers by slot class", function()
      assert.same({ "old", "elf" }, context.words(state, { slot = "%living" }))
    end)

    it("gives display names for a person to read", function()
      assert.same({ "An old elf" }, context.names(state, { slot = "%living" }))
    end)
  end)

  describe("payloadFor", function()
    it("finds a message's contents by its own event name", function()
      local gmcp = { Char = { Items = { List = { location = "room" } } } }
      assert.same({ location = "room" }, context.payloadFor("gmcp.Char.Items.List", gmcp))
    end)

    it("returns nothing for a message that has not arrived", function()
      assert.is_nil(context.payloadFor("gmcp.Char.Items.List", { Char = {} }))
      assert.is_nil(context.payloadFor("gmcp.Char.Items.List", nil))
    end)
  end)

  describe("register", function()
    it("refuses an adapter that cannot read a payload", function()
      assert.has_error(function() context.register({}) end)
      assert.has_error(function() context.register(nil) end)
    end)

    it("reports whether anyone is telling us what is in reach", function()
      context.unregister()
      assert.is_false(context.bound())
      context.register({ events = {}, read = function() return nil end })
      assert.is_true(context.bound())
      context.unregister()
      assert.is_false(context.bound())
    end)
  end)
end)
