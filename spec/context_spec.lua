-- Contract tests for mcvp.context - the half of in-reach binding that no game
-- owns. Adapters are represented here by the updates they produce, since what
-- a game sends is out of scope for the protocol and so for these tests. The
-- Mudlet wiring is exercised against spec/mudlet_fake.lua rather than skipped,
-- so bound() and the handlers it reports on are actually covered.
local fake = dofile("spec/mudlet_fake.lua")

local function thing(id, name, slot)
  return { id = id, name = name, slot = slot }
end

describe("mcvp.context", function()
  local state, m, context

  before_each(function()
    m = fake.install()
    dofile("src/scripts/MCVP/MCVPContext.lua")
    context = mcvp.context
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

    it("keeps an apostrophe inside a word, which is one spoken word", function()
      assert.same({ "orc's", "rusty", "short", "sword" }, context.nouns("an orc's rusty short-sword"))
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
      assert.same({ "lantern", "sword" }, context.words(state))
    end)

    it("adds one thing and removes one thing", function()
      context.apply(state, { place = "room", add = thing(1, "A torch", "%item") })
      assert.same({ "torch" }, context.words(state))
      context.apply(state, { place = "room", remove = 1 })
      assert.same({}, context.words(state))
    end)

    it("removes a thing whatever type the adapter spells its id as", function()
      -- A game that lists objects under JSON numbers but removes them by a
      -- quoted string would otherwise strand them in reach for the session,
      -- silently, each one still spending a slot of the biasing budget.
      context.apply(state, { place = "room", add = thing(42, "A torch", "%item") })
      context.apply(state, { place = "room", remove = "42" })
      assert.same({}, context.words(state))

      context.apply(state, { place = "room", add = thing("7", "A sword", "%item") })
      context.apply(state, { place = "room", remove = 7 })
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
      assert.same({ "coin", "lucky", "torch" }, context.words(state, { slot = "%item" }))
    end)

    it("answers by slot class", function()
      assert.same({ "elf", "old" }, context.words(state, { slot = "%living" }))
    end)

    it("returns the same order every time, so a cut budget cuts the same words", function()
      -- Context is spent before the catalog, so this list is the more likely
      -- one to be truncated; hash order would bias differently every sample.
      local first = context.words(state)
      for _ = 1, 5 do assert.same(first, context.words(state)) end
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
      assert.is_nil(context.payloadFor("gmcp.Char.Items.List", { Char = { Items = 5 } }))
    end)
  end)

  describe("register", function()
    local function adapter(events, read)
      return { events = events, read = read or function() return nil end }
    end

    it("refuses an adapter that cannot read a payload", function()
      assert.has_error(function() context.register({}) end)
      assert.has_error(function() context.register(nil) end)
    end)

    it("refuses an adapter whose events are not a list, and stays bound to the old one", function()
      -- The likeliest adapter typo is a bare event name instead of a
      -- one-element list. Accepting it and failing later would leave bound()
      -- answering "yes" with nothing wired - the one wrong answer it exists
      -- to prevent, because a consumer then reads an empty in-reach list as
      -- "nothing is here" rather than "nobody is telling us".
      local good = adapter({ "gmcp.Char.Items.List" })
      context.register(good)
      assert.has_error(function()
        context.register({ read = function() end, events = "gmcp.Char.Items.List" })
      end)
      assert.is_true(context.bound())
      assert.equals(1, #m.registeredEvents())
    end)

    it("wires a handler for every event the adapter names", function()
      context.register(adapter({ "gmcp.Char.Items.List", "gmcp.Room.Chars" }))
      assert.same({ "gmcp.Char.Items.List", "gmcp.Room.Chars" }, m.registeredEvents())
    end)

    it("folds the live payload into state when its event fires", function()
      context.register(adapter({ "gmcp.Char.Items.List" }, function(_, payload)
        return { place = "room", replace = { thing(1, payload.name, "%item") } }
      end))
      _G.gmcp = { Char = { Items = { List = { name = "A brass lantern" } } } }
      m.fire("gmcp.Char.Items.List")
      assert.same({ "brass", "lantern" }, context.inScope())
    end)

    it("does not swallow an adapter that throws", function()
      -- An adapter is third-party per-game code. A silent pcall here would
      -- turn a broken adapter into a permanently empty in-reach list with no
      -- symptom; letting it raise puts it in Mudlet's error console.
      context.register(adapter({ "gmcp.Char.Items.List" }, function() error("bad adapter") end))
      _G.gmcp = { Char = { Items = { List = {} } } }
      assert.has_error(function() m.fire("gmcp.Char.Items.List") end)
    end)

    it("kills every handler it registered when it unregisters", function()
      context.register(adapter({ "gmcp.Char.Items.List", "gmcp.Room.Chars" }))
      context.unregister()
      assert.equals(2, #m.killed)
      assert.equals(0, #m.registeredEvents())
    end)

    it("clears what was in reach, which the next update repopulates", function()
      context.register(adapter({ "gmcp.Char.Items.List" }))
      context.apply(context.state, { place = "room", add = thing(1, "A torch", "%item") })
      assert.same({ "torch" }, context.inScope())
      context.register(adapter({ "gmcp.Char.Items.List" }))
      assert.same({}, context.inScope())
    end)

    -- A package being uninstalled tears down after its replacement has
    -- already registered, so an unqualified unregister takes the new adapter
    -- down with the old one
    it("ignores an unregister from an adapter that is no longer bound", function()
      local old, new = adapter({}), adapter({})
      context.register(old)
      context.register(new)
      assert.is_false(context.unregister(old))
      assert.is_true(context.bound(), "the replacement was unregistered by its predecessor")
      assert.is_true(context.unregister(new))
      assert.is_false(context.bound())
    end)

    it("reports whether anyone is telling us what is in reach", function()
      context.unregister()
      assert.is_false(context.bound())
      context.register(adapter({}))
      assert.is_true(context.bound())
      context.unregister()
      assert.is_false(context.bound())
    end)
  end)
end)
