--- What is in reach right now: the nouns a player is about to say.
--
-- The catalog carries what a game publishes and rarely changes - verbs,
-- socials, channels, shortcuts. It deliberately does not carry the things
-- standing in front of you, because those turn over constantly and versioning
-- them would defeat the caching the protocol is built on. The standard's
-- answer is that a client binds its %item and %living slots from whatever
-- room and inventory data the game already sends, and samples that when it
-- needs them.
--
-- This is the half of that binding no game owns: extracting the words a
-- player would actually speak from a display name, holding what is present,
-- and answering "what is in reach" by slot. Which messages carry that data,
-- and how to read one, is per-game and arrives as an adapter - the protocol
-- describes no schema for it, so neither does this.
--
-- Everything above the wiring section is pure and tested without Mudlet.
-- @module mcvp.context

mcvp = mcvp or {}
local context = {}

-- Words that are never what a player says to refer to a thing. "A bottle of
-- beer" is spoken as "get beer" or "get bottle"; nobody says the article.
-- A game with its own noise words can add to this.
context.notSpoken = {
  a = true, an = true, the = true, of = true, some = true,
  ["and"] = true, with = true,
}

-- Short words make poor biasing and correction targets - they collide with
-- everything - and the same floor is applied to catalog words
context.minNounLength = 3

--- The words a player would actually say to refer to something, from the name
-- the game displays for it. Returns an array, lowercased, in reading order.
function context.nouns(displayName)
  local out, seen = {}, {}
  for word in tostring(displayName or ""):lower():gmatch("[%a']+") do
    if #word >= context.minNounLength and not context.notSpoken[word] and not seen[word] then
      seen[word] = true
      out[#out + 1] = word
    end
  end
  return out
end

function context.newState()
  return { places = {} }
end

local function placeIn(state, name)
  if type(name) ~= "string" or name == "" then return nil end
  state.places[name] = state.places[name] or {}
  return state.places[name]
end

--- Whether an adapter handed over something this can hold. An entry needs an
-- id to be replaceable and a name to be spoken; the slot may be absent, which
-- means the game declined to classify it rather than that it is unclassified.
local function usable(entry)
  return type(entry) == "table" and entry.id ~= nil and type(entry.name) == "string" and entry.name ~= ""
end

--- Fold one adapter update into the state. The three shapes are all a game
-- needs to describe what is in reach: everything here now, one thing arrived,
-- one thing left. An update naming no place, or carrying none of the three,
-- is ignored rather than guessed at.
function context.apply(state, update)
  local place = type(update) == "table" and placeIn(state, update.place)
  if not place then return state end

  if type(update.replace) == "table" then
    for id in pairs(place) do place[id] = nil end
    for _, entry in pairs(update.replace) do
      if usable(entry) then
        place[entry.id] = { name = entry.name, slot = entry.slot }
      end
    end
  elseif update.add ~= nil then
    if usable(update.add) then
      place[update.add.id] = { name = update.add.name, slot = update.add.slot }
    end
  elseif update.remove ~= nil then
    place[update.remove] = nil
  end

  return state
end

--- Every distinct noun in reach. Deduplicated because a room can hold thirty
-- torches, and thirty copies of one word would spend a biasing budget on
-- nothing. opts.slot selects one slot class; omit it for everything.
function context.words(state, opts)
  opts = opts or {}
  local out, seen = {}, {}
  for _, place in pairs(state.places) do
    for _, entry in pairs(place) do
      if not opts.slot or entry.slot == opts.slot then
        for _, word in ipairs(context.nouns(entry.name)) do
          if not seen[word] then
            seen[word] = true
            out[#out + 1] = word
          end
        end
      end
    end
  end
  return out
end

--- The full display names in reach, which is what a test harness prompts with
-- and what a person would read.
function context.names(state, opts)
  opts = opts or {}
  local out, seen = {}, {}
  for _, place in pairs(state.places) do
    for _, entry in pairs(place) do
      if (not opts.slot or entry.slot == opts.slot) and not seen[entry.name] then
        seen[entry.name] = true
        out[#out + 1] = entry.name
      end
    end
  end
  return out
end

-- Live state and the Mudlet wiring below; everything above is pure.

context.state = context.state or context.newState()
context._handlers = context._handlers or {}
context._adapter = context._adapter or nil

--- The payload a GMCP event carries, by walking the event's own name.
-- "gmcp.Char.Items.List" is gmcp.Char.Items.List, which is what makes the
-- wiring generic: an adapter names its messages and gets their contents.
function context.payloadFor(event, root)
  local node = root
  if node == nil then return nil end
  for step in tostring(event):gsub("^gmcp%.", ""):gmatch("[^%.]+") do
    if type(node) ~= "table" then return nil end
    node = node[step]
  end
  return node
end

--- Take over in-reach binding for this game.
-- adapter.events lists the GMCP events that carry the data, and
-- adapter.read(event, payload) turns one of them into an update for apply()
-- or nil to ignore it. Registering replaces any previous adapter, so a
-- package reloading its scripts does not end up wired twice.
function context.register(adapter)
  assert(type(adapter) == "table", "mcvp.context.register needs an adapter table")
  assert(type(adapter.read) == "function", "an adapter needs a read(event, payload) function")

  context.unregister()
  context._adapter = adapter

  if type(registerAnonymousEventHandler) ~= "function" then return end

  for _, event in ipairs(adapter.events or {}) do
    context._handlers[event] = registerAnonymousEventHandler(event, function()
      local update = adapter.read(event, context.payloadFor(event, gmcp))
      if update then
        context.apply(context.state, update)
      end
    end)
  end
end

function context.unregister()
  if type(killAnonymousEventHandler) == "function" then
    for _, id in pairs(context._handlers) do
      killAnonymousEventHandler(id)
    end
  end
  context._handlers = {}
  context._adapter = nil
  context.state = context.newState()
end

--- Whether a game's adapter is wired up, which is what a consumer checks
-- before treating an empty answer as "nothing in reach" rather than "nobody
-- is telling us".
function context.bound()
  return context._adapter ~= nil
end

--- What is in reach, from the live state.
function context.inScope(opts)
  return context.words(context.state, opts)
end

function context.displayNames(opts)
  return context.names(context.state, opts)
end

mcvp.context = context
