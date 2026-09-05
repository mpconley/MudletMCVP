# MudletMCVP

The Mudlet consumer package for the [MUD Client Vocabulary Protocol](https://wiki.mudlet.org/w/Standards:MUD_Client_Vocabulary_Protocol) (MCVP) — `Client.Vocabulary` over GMCP.

The package negotiates `Client.Vocabulary 1`, maintains the merged vocabulary catalog (full Catalogs, chained incremental Updates, version cache), and exposes it to other packages through `mcvp.entries()`, `mcvp.version()` and the `mcvp.updated` event. Consumers include speech-to-text biasing and correction, tab-completion, and command discovery. Per the standard, nothing about recognition, completion or correction ever flows back to any server.

`mcvp.entries()` returns the stored entries rather than copies, so consumers must treat them as read-only. With `biasable = true` the result is ordered by tier and then by word, because the caller spends a small budget from the front of it.

## Caching

The merged catalog is cached on disk per character, and a catalog names no character, so a game tells the package which one this is:

```lua
mcvp.setCacheKey("Tamarindo")   -- enables the cache for this character
```

Until that is called nothing is written to disk. A catalog carries that character's own shortcuts, and one Mudlet profile may be used by several characters, so a package that cannot name the character does not cache at all rather than risk serving one character's vocabulary to another. Nothing else depends on it: the server sends a full Catalog every session, and the cache only pre-populates state before the first frame arrives.

## In-reach binding

The catalog carries what a game publishes and rarely changes. It deliberately does not carry the things standing in front of a character, so the standard has a client bind its `%item` and `%living` slots from whatever room and inventory data the game already sends. Which messages carry that data is per-game, so it arrives as an adapter:

```lua
mcvp.context.register({
  events = { "gmcp.Char.Items.List" },
  read = function(event, payload) ... end,  -- returns an update, or nil to ignore
})
```

`mcvp.context.inScope()` and `mcvp.context.displayNames()` answer what is in reach, optionally by slot class; `mcvp.context.bound()` reports whether any adapter is wired, which is what lets a consumer tell "nothing is in reach" from "nobody is telling us". `mcvp.context.unregister(adapter)` unbinds only that adapter. In-reach state is held for the session only and is never written to the catalog cache.

# Muddler

GitHub Actions use [Muddler](https://github.com/demonnic/muddler) to build a release upon each push to main.

# Tests

The merge engine, lifecycle rules, catalog cache and in-reach binding are covered by [busted](https://lunarmodules.github.io/busted/) specs that run without Mudlet, against the fakes in [spec/mudlet_fake.lua](spec/mudlet_fake.lua):

```
luarocks --lua-version 5.1 install busted
busted spec
```

Each test names the protocol rule it pins. The specs are the executable form of the client processing requirements in the standard.

# Remember

* Update the version in the [mfile](mfile) configuration before merging.

See also [this guidance](https://mud.gesslar.dev/muddler.html) from [@gesslar](https://github.com/gesslar).
