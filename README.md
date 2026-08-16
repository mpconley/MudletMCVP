# MudletMCVP

The Mudlet consumer package for the [MUD Client Vocabulary Protocol](https://wiki.mudlet.org/w/Standards:MUD_Client_Vocabulary_Protocol) (MCVP) — `Client.Vocabulary` over GMCP.

The package negotiates `Client.Vocabulary 1`, maintains the merged vocabulary catalog (full Catalogs, chained incremental Updates, version cache), and exposes it to other packages through `mcvp.entries()`, `mcvp.version()` and the `mcvp.updated` event. Consumers include speech-to-text biasing and correction, tab-completion, and command discovery. Per the standard, nothing about recognition, completion or correction ever flows back to any server.

# Muddler

GitHub Actions use [Muddler](https://github.com/demonnic/muddler) to build a release upon each push to main.

# Tests

The merge engine and lifecycle rules are covered by [busted](https://lunarmodules.github.io/busted/) specs that run without Mudlet:

```
luarocks --lua-version 5.1 install busted
busted spec
```

Each test names the protocol rule it pins. The specs are the executable form of the client processing requirements in the standard.

# Remember

* Update the version in the [mfile](mfile) configuration before merging.

See also [this guidance](https://mud.gesslar.dev/muddler.html) from [@gesslar](https://github.com/gesslar).
