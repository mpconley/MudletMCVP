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

local VALID_POSITION = { leading = true, argument = true }

-- Entry identity within a category is (word, position). The separator is a
-- printable character words cannot contain (the spec constrains word to
-- lowercase ASCII), so merged state survives table.save/table.load - Lua 5.1's
-- %q does not round-trip embedded NUL bytes.
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
  local position, correctable = nil, true
  if raw.position ~= nil then
    if VALID_POSITION[raw.position] then
      position = raw.position
    else
      correctable = false
    end
  end
  local aliases = nil
  if type(raw.aliases) == "table" then
    aliases = {}
    for _, a in ipairs(raw.aliases) do
      if type(a) == "string" and a ~= "" then aliases[#aliases + 1] = a end
    end
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

--- Apply a full Catalog, replacing all state.
-- @return true on success, or nil and a reason
function merge.applyCatalog(state, payload)
  if type(payload) ~= "table" or type(payload.version) ~= "string" or payload.version == "" then
    return nil, "catalog missing version"
  end
  if type(payload.categories) ~= "table" then
    return nil, "catalog missing categories"
  end

  -- A Catalog frame sharing the current version is a pagination frame: the
  -- spec has large servers split a Catalog by category across frames with one
  -- version, merged additively. Any other version replaces all state.
  local additive = payload.version == state.version
  local categories = additive and state.categories or {}
  for name, cat in pairs(payload.categories) do
    -- Unknown categories are stored, not dropped: "ignore" in the spec means
    -- "must not break on", and completion may still use them; only consumers
    -- that need semantics (slot binding) restrict to categories they know.
    if type(name) == "string" and type(cat) == "table" and type(cat.entries) == "table" then
      local default = merge.normPriority(cat.priority, 3)
      local entries = {}
      for _, raw in ipairs(cat.entries) do
        local entry = normEntry(raw, default)
        if entry then entries[entryKey(entry.word, entry.position)] = entry end
      end
      categories[name] = { priority = default, entries = entries }
    end
  end

  state.version = payload.version
  state.categories = categories
  return true
end

--- Apply an incremental Update.
-- @return true on success, or nil and one of the reason strings
-- "no baseline" / "from mismatch" / "malformed" - the first two are the
-- caller's cue to fire the one-shot re-request.
function merge.applyUpdate(state, payload)
  if type(payload) ~= "table" or type(payload.version) ~= "string" then
    return nil, "malformed"
  end
  if state.version == nil then
    return nil, "no baseline"
  end
  if payload.from ~= state.version then
    return nil, "from mismatch"
  end
  local changes = payload.categories
  if type(changes) ~= "table" then
    return nil, "malformed"
  end

  -- All removes before any add: remove carries bare words and drops every
  -- position; the same Update's add list re-supplies the survivors.
  for name, delta in pairs(changes) do
    local cat = state.categories[name]
    if cat and type(delta) == "table" and type(delta.remove) == "table" then
      for _, word in ipairs(delta.remove) do
        if type(word) == "string" then
          for key, entry in pairs(cat.entries) do
            if entry.word == word then cat.entries[key] = nil end
          end
        end
      end
    end
  end

  for name, delta in pairs(changes) do
    if type(delta) == "table" and type(delta.add) == "table" then
      local cat = state.categories[name]
      if not cat then
        -- A category appearing is a structural change and must arrive in a
        -- full Catalog; a delta naming an unknown category is tolerated by
        -- creating nothing and skipping it, never by guessing a default.
        cat = nil
      else
        -- Category defaults are immutable between Catalogs: any priority
        -- field on the delta's category object is ignored by design.
        for _, raw in ipairs(delta.add) do
          local entry = normEntry(raw, cat.priority)
          if entry then cat.entries[entryKey(entry.word, entry.position)] = entry end
        end
      end
    end
  end

  state.version = payload.version
  return true
end

--- Iterate entries, optionally filtered: opts.category, opts.maxPriority,
-- opts.biasable (excludes protected and anything above tier 2),
-- opts.correctable (excludes protected, non-correctable, and %-position
-- mismatches via opts.leading).
function merge.entries(state, opts)
  opts = opts or {}
  local out = {}
  for name, cat in pairs(state.categories) do
    if not opts.category or opts.category == name then
      for _, entry in pairs(cat.entries) do
        local keep = true
        if opts.maxPriority and entry.priority > opts.maxPriority then keep = false end
        if keep and opts.biasable and (entry.protected or entry.priority > 2) then keep = false end
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
