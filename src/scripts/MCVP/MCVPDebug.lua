--- Debug helpers for integration testing. Safe to ship: nothing here runs
-- until a function is called by hand - the package installs scripts only, no
-- aliases, so these are plain globals typed at the Lua prompt. Arming persists
-- until the next Update arrives; neither a reload nor mcvp.stop() clears it.
-- @module mcvp.debug

mcvp = mcvp or {}
mcvp.debug = mcvp.debug or {}

--- Arm the fault injector: the next Client.Vocabulary.Update is discarded
-- before processing, simulating a transport-lost frame. The Update after it
-- then fails the from-chain check, which must recover via exactly one
-- re-request - the behaviour this exists to exercise against a live server.
function mcvp.debug.dropNextUpdate()
  mcvp._dropNextUpdate = true
  echo("\n[mcvp] armed: next Update will be dropped\n")
end

--- One-line state summary for the integration checklist.
function mcvp.debug.status()
  local total = #mcvp.entries()
  local biasable = #mcvp.entries({ biasable = true })
  echo(string.format("\n[mcvp] version=%s entries=%d biasable=%d rerequestPending=%s dropArmed=%s\n",
    tostring(mcvp.version()), total, biasable,
    tostring(mcvp._rerequestPending), tostring(mcvp._dropNextUpdate or false)))
end
