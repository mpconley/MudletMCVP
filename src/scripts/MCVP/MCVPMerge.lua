--- MCVP catalog merge engine.
-- Pure Lua, no Mudlet globals: everything here is testable under busted alone.
-- Implements the client processing requirements of the MUD Client Vocabulary
-- Protocol (Client.Vocabulary 1) and the consumer contract built with the
-- reference server:
--   * removes applied before adds; remove drops every position of a word
--   * add is wholesale replacement; entry identity is (word, position)
--   * Updates apply only when their "from" matches the current merged version
--   * an Update with no baseline is rejected
--   * category defaults are immutable between Catalogs
--   * unknown categories, fields and position values are handled fail-safe
--   * lenient boolean/number decoding, with "protected" failing safe to true
--   * an empty collection sent as "" is read as empty, never as malformed
--   * client-side size bounds, because a catalog comes from an arbitrary peer
-- Loaded first by scripts.json order; MCVPLoader wires it to the wire.
-- @module mcvp.merge

mcvp = mcvp or {}
local merge = {}

local EXPLICIT_FALSE = { ["false"] = true, ["0"] = true }

--- Lenient boolean, fail-safe for protected-style flags: absent is false,
-- present is true unless explicitly false-valued.
function merge.normBool(v)
  if v == nil or v == false or v == 0 then return false end
  if type(v) == "string" and EXPLICIT_FALSE[v:lower()] then return false end
  return true
end

--- Lenient priority: accepts numeric strings, clamps nothing - anything that
-- is not a whole number in 1..3 falls back to the supplied default.
function merge.normPriority(v, default)
  local n = tonumber(v)
  if n and n >= 1 and n <= 3 and n == math.floor(n) then return n end
  return default
end

-- A driver with no distinct empty-array form renders an empty collection as
-- the string "" rather than []. The standard requires reading that as an empty
-- collection and not as a malformed message, because a client that rejects it
-- instead discards a valid Update and breaks its own chain. Returns nil only
-- for a value that is genuinely neither a collection nor an empty one.
local function asCollection(v)
  if v == "" then return {} end
  if type(v) == "table" then return v end
  return nil
end

-- Client-side self-defense. The standard's security section asks clients to
-- enforce their own size bounds when merging, because a catalog arrives from
-- whatever server the player chose to connect to. These sit far above what a
-- conforming game needs - the standard puts a typical catalog on the order of
-- a thousand entries, with tier 1 capped at 300 and tier 2 at 500 - so they
-- never bite a real game; they stop a hostile or broken peer from filling
-- memory and the on-disk cache.
merge.maxCategories = 200
merge.maxEntriesPerCategory = 5000
merge.maxTotalEntries = 20000
merge.maxWordLength = 64
merge.maxAliases = 32

-- One- and two-letter forms are abbreviations. Steering a recognizer toward
-- one risks it preferring the abbreviation to the word it abbreviates, so the
-- standard leaves the shortest words out of biasing while keeping them
-- available to correction and completion.
merge.minBiasLength = 3

local VALID_POSITION = { leading = true, argument = true }

-- Entry identity within a category is (word, position). Keys are built as
-- word .. "|" .. position, and the three position suffixes ("", "leading",
-- "argument") cannot alias one another, so the key stays unique even if a
-- hostile server puts a "|" inside a word. A printable separator rather than
-- NUL is what lets merged state survive table.save/table.load - Lua 5.1's %q
-- does not round-trip embedded NUL bytes.
local function entryKey(word, position)
  return word .. "|" .. (position or "")
end

-- Normalize one wire entry into stored form. Unknown fields are dropped;
-- an unrecognized position value keeps the entry visible but excludes it
-- from correction (fail closed).
local function normEntry(raw, categoryDefaultPriority)
  if type(raw) ~= "table" or type(raw.word) ~= "string" or raw.word == "" then
    return nil
  end
  if #raw.word > merge.maxWordLength then return nil end
  local position, correctable = nil, true
  if raw.position ~= nil then
    if VALID_POSITION[raw.position] then
      position = raw.position
    else
      correctable = false
    end
  end
  local aliases = nil
  local rawAliases = asCollection(raw.aliases)
  if rawAliases then
    aliases = {}
    for _, a in ipairs(rawAliases) do
      if type(a) == "string" and a ~= "" and #aliases < merge.maxAliases then
        aliases[#aliases + 1] = a
      end
    end
    if #aliases == 0 then aliases = nil end
  end
  return {
    word = raw.word,
    priority = merge.normPriority(raw.priority, categoryDefaultPriority),
    protected = merge.normBool(raw.protected),
    position = position,
    correctable = correctable,
    syntax = type(raw.syntax) == "string" and raw.syntax or nil,
    expansion = type(raw.expansion) == "string" and raw.expansion or nil,
    aliases = aliases,
  }
end

--- A fresh, empty state. version == nil means "no baseline yet".
function merge.new()
  return { version = nil, categories = {} }
end

local function countEntries(categories)
  local categoryCount, entryCount = 0, 0
  for _, cat in pairs(categories) do
    categoryCount = categoryCount + 1
    for _ in pairs(cat.entries) do entryCount = entryCount + 1 end
  end
  return categoryCount, entryCount
end

--- Apply a full Catalog.
-- A frame whose version differs from the current one replaces all state; a
-- frame sharing the current version is a pagination frame and merges
-- additively, by category.
-- @return true on success, or nil and a reason
function merge.applyCatalog(state, payload)
  if type(payload) ~= "table" or type(payload.version) ~= "string" or payload.version == "" then
    return nil, "catalog missing version"
  end
  local incoming = asCollection(payload.categories)
  if not incoming then
    return nil, "catalog missing categories"
  end

  -- A Catalog frame sharing the current version is a pagination frame: the
  -- spec has large servers split a Catalog by category across frames with one
  -- version, merged additively. Any other version replaces all state.
  local additive = payload.version == state.version
  local merged = additive and state.categories or {}
  local categoryCount, totalEntries = countEntries(merged)

  for name, cat in pairs(incoming) do
    -- Unknown categories are stored, not dropped: "ignore" in the spec means
    -- "must not break on", and completion may still use them; only consumers
    -- that need semantics (slot binding) restrict to categories they know.
    local rawEntries = type(cat) == "table" and asCollection(cat.entries) or nil
    if type(name) == "string" and rawEntries then
      local replacing = merged[name]
      if replacing or categoryCount < merge.maxCategories then
        if replacing then
          for _ in pairs(replacing.entries) do totalEntries = totalEntries - 1 end
        else
          categoryCount = categoryCount + 1
        end
        local default = merge.normPriority(cat.priority, 3)
        local entries, kept = {}, 0
        for _, raw in ipairs(rawEntries) do
          if kept >= merge.maxEntriesPerCategory or totalEntries >= merge.maxTotalEntries then break end
          local entry = normEntry(raw, default)
          if entry then
            local key = entryKey(entry.word, entry.position)
            if entries[key] == nil then
              kept = kept + 1
              totalEntries = totalEntries + 1
            end
            entries[key] = entry
          end
        end
        merged[name] = { priority = default, entries = entries }
      end
    end
  end

  state.version = payload.version
  state.categories = merged
  return true
end

--- Apply an incremental Update.
-- @return true on success, or nil and one of the reason strings
-- "no baseline" / "from mismatch" / "malformed" - the first two are the
-- caller's cue to fire the one-shot re-request.
function merge.applyUpdate(state, payload)
  if type(payload) ~= "table" or type(payload.version) ~= "string" or payload.version == "" then
    return nil, "malformed"
  end
  if state.version == nil then
    return nil, "no baseline"
  end
  if payload.from ~= state.version then
    return nil, "from mismatch"
  end
  local changes = asCollection(payload.categories)
  if not changes then
    return nil, "malformed"
  end

  -- All removes before any add: remove carries bare words and drops every
  -- position; the same Update's add list re-supplies the survivors.
  for name, delta in pairs(changes) do
    local cat = state.categories[name]
    local removals = type(delta) == "table" and asCollection(delta.remove) or nil
    if cat and removals then
      for _, word in ipairs(removals) do
        if type(word) == "string" then
          for key, entry in pairs(cat.entries) do
            if entry.word == word then cat.entries[key] = nil end
          end
        end
      end
    end
  end

  local _, totalEntries = countEntries(state.categories)

  for name, delta in pairs(changes) do
    local additions = type(delta) == "table" and asCollection(delta.add) or nil
    -- A category appearing is a structural change and must arrive in a full
    -- Catalog; a delta naming an unknown category is tolerated by creating
    -- nothing and skipping it, never by guessing a default.
    local cat = state.categories[name]
    if additions and cat then
      -- Category defaults are immutable between Catalogs: any priority
      -- field on the delta's category object is ignored by design.
      for _, raw in ipairs(additions) do
        local entry = normEntry(raw, cat.priority)
        if entry then
          local key = entryKey(entry.word, entry.position)
          if cat.entries[key] == nil then
            if totalEntries >= merge.maxTotalEntries then break end
            totalEntries = totalEntries + 1
          end
          cat.entries[key] = entry
        end
      end
    end
  end

  state.version = payload.version
  return true
end

--- Iterate entries, optionally filtered: opts.category, opts.maxPriority,
-- opts.biasable (excludes protected, anything above tier 2, and words shorter
-- than merge.minBiasLength), opts.correctable (excludes protected and
-- non-correctable entries, and position mismatches via opts.leading).
--
-- opts.leading is only consulted together with opts.correctable; on its own it
-- filters nothing.
--
-- Order: a biasable result is sorted by tier and then by word, because the
-- caller spends a budget from the front of it. Every other query returns
-- pairs() hash order.
--
-- The entries returned are the stored entries, not copies. Consumers must
-- treat them as read-only: mutating one changes merged state and is written
-- to the on-disk cache by the next persist.
function merge.entries(state, opts)
  opts = opts or {}
  local out = {}
  for name, cat in pairs(state.categories) do
    if not opts.category or opts.category == name then
      for _, entry in pairs(cat.entries) do
        local keep = true
        if opts.maxPriority and entry.priority > opts.maxPriority then keep = false end
        if keep and opts.biasable then
          if entry.protected or entry.priority > 2 or #entry.word < merge.minBiasLength then
            keep = false
          end
        end
        if keep and opts.correctable then
          if entry.protected or not entry.correctable then keep = false end
          if keep and opts.leading ~= nil then
            if opts.leading and entry.position == "argument" then keep = false end
            if not opts.leading and entry.position == "leading" then keep = false end
          end
        end
        if keep then out[#out + 1] = entry end
      end
    end
  end

  -- A biasing list is a budget, and the caller fills it until the budget runs
  -- out - so whatever this returns first is what survives the cut. Category
  -- and entry iteration above is pairs(), which is hash order: unordered, and
  -- different between sessions. Returned that way, a tier 1 word takes its
  -- chances against tier 2 for a place in the list, which is the opposite of
  -- what the protocol says ("tier 2 ... only if the client has room left after
  -- tier 1"), and no two logins bias the same way. Sorting by tier, then by
  -- word so the order is stable across sessions, is what makes the budget mean
  -- what the server said and a measurement repeatable.
  if opts.biasable then
    table.sort(out, function(a, b)
      if a.priority ~= b.priority then return a.priority < b.priority end
      return a.word < b.word
    end)
  end
  return out
end

mcvp.merge = merge
