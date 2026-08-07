-- Aegis: Courier
-- core/bridge.lua
--
-- The ENTIRE Aegis: Exchange integration surface. One function call, one
-- direction: Courier -> Aegis. Nothing else in this addon may touch Aegis.
--
-- Rules this file exists to enforce (CLAUDE.md, "Aegis: Exchange integration"):
--   * Detection is a guard, never a dependency. Courier must be fully useful
--     with AegisExchange == nil, and the .toc deliberately declares no
--     OptionalDeps -- load order between two independent addons is not
--     something we want to depend on. Everything here re-checks at call time.
--   * NEVER read or write AegisExchangeDB / AegisExchangeCharDB.
--   * The push is a MIRROR of Courier's own ledger write, never a substitute.
--
-- STATUS: LIVE. Aegis: Exchange shipped RecordExternalTxn in its v1.1.7, so
-- the guard is true whenever both addons are installed. It stays completely
-- silent when Aegis is absent -- a standalone user has done nothing wrong and
-- must never see a warning about a missing optional addon.
--
-- It was dormant for longer than it looked. This module was written against
-- Aegis's roadmap before that API existed, was never exercised against the
-- real thing, and shipped calling it with the wrong argument shape (see
-- bridge.Push). Nothing surfaced, because a mis-shaped call is refused rather
-- than raised. If you change anything here, verify it against Aegis's actual
-- core/db.lua rather than against this file's own assumptions.

local A = AegisCourier
A.bridge = {}
local bridge = A.bridge

-- The integration contract version Courier was written against. Aegis is
-- expected to expose AegisExchange.INTEGRATION_VERSION; when it is higher than
-- this, the signature may have changed in ways we do not know about, so we
-- stand down rather than risk a silent miscount.
bridge.SUPPORTED_VERSION = 1

-- Populated by bridge.Detect(). Informational only -- never trust a cached
-- value at call time, because Aegis can load after us.
bridge.available = false
bridge.remoteVersion = nil

-- Is the seam usable RIGHT NOW? Re-evaluated on every call rather than read
-- from a flag: addon load order is not guaranteed, and a user can in principle
-- have Aegis load after Courier.
function bridge.Ready()
    if not A.db.Setting("pushToAegis") then return false end
    if not AegisExchange then return false end
    if type(AegisExchange.RecordExternalTxn) ~= "function" then return false end
    local v = AegisExchange.INTEGRATION_VERSION
    -- A missing version means the very first implementation, which is v1.
    if v == nil then return true end
    if type(v) ~= "number" then return false end
    return v <= bridge.SUPPORTED_VERSION
end

-- Push one already-locally-recorded transaction into Aegis's ledger.
--
-- ONE TABLE, not positional arguments. This is worth stating loudly because
-- getting it wrong FAILS SILENTLY: Aegis validates with `type(txn) ~= "table"`
-- and RETURNS false -- it does not error -- so a pcall around a positional
-- call reports success while every entry is dropped. Courier shipped exactly
-- that bug, and its own test double had the same wrong signature, so the
-- suite agreed with it. Field names below are Aegis's, from that repo's
-- core/db.lua integration block; keep them in step with its
-- INTEGRATION_VERSION.
--
-- Courier's extra detail (gross / cut / net) is deliberately NOT sent: it is
-- not part of Aegis's entry shape, and inventing fields on the far side would
-- defeat the point of having a fixed signature.
--
-- NO `key` IS SENT, deliberately. Aegis exposes MailTxnKey for callers that
-- book mail on ARRIVAL, and it buckets subject+money+arrival-hour -- the exact
-- fingerprint inbox.lua's Stage B note rejects, because two identical stacks
-- sold at one price in one hour collide and a collision silently UNDER-counts.
-- Courier books on COLLECTION instead: an emptied mail has nothing left to
-- book, so it cannot be counted twice and needs no fingerprint. Sending a key
-- would trade a bounded, one-time overlap at handover (mail Aegis already
-- booked on arrival that is still sitting uncollected when Courier arrives)
-- for a permanent undercount. A missing sale is invisible; a doubled one is at
-- least conspicuous. Do not "fix" this by reintroducing a key.
--
-- The call is wrapped in pcall because the far side is another addon's code:
-- a signature change, a nil field, or an error inside Aegis's ledger must
-- never take down the mailbox the user is standing at. A failed push costs the
-- Aegis mirror of one entry; Courier's own ledger already has it.
--
-- Returns true when Aegis confirmed the entry, false otherwise.
function bridge.Push(kind, item, amount, itemId)
    if not bridge.Ready() then return false end
    if not kind or not amount or amount <= 0 then return false end

    local ok, accepted, why = pcall(AegisExchange.RecordExternalTxn, {
        kind   = kind,
        item   = item,
        amount = amount,
        itemId = itemId,
    })

    -- THREE outcomes, and only the first is success. Checking pcall's `ok`
    -- alone is what made the original bug invisible: `ok` is true whenever
    -- Aegis merely REFUSED the payload rather than blowing up.
    if ok and accepted then return true end

    -- Report once per session, not per mail: a broken seam during an
    -- open-all would otherwise spam a line per sale.
    if not bridge.warned then
        bridge.warned = true
        local reason
        if not ok then
            reason = "it errored"
        else
            reason = why or "refused"
        end
        A.Print("Aegis: Exchange did not record a sale (" .. reason ..
            "). Courier's own history is unaffected. Further pushes this " ..
            "session are silent.")
    end
    return false
end

-- Detect Aegis once at load, for the status line and /courier status. This is
-- reporting only -- bridge.Ready() is the authority at call time.
function bridge.Detect()
    bridge.available = (AegisExchange ~= nil)
        and (type(AegisExchange.RecordExternalTxn) == "function")
    if bridge.available then
        bridge.remoteVersion = AegisExchange.INTEGRATION_VERSION or 1
    end
end

-- A short human-readable integration state, for the window footer and
-- /courier status.
function bridge.StatusText()
    if not AegisExchange then
        return "standalone"
    end
    if type(AegisExchange.RecordExternalTxn) ~= "function" then
        -- Aegis is installed but predates the integration surface. Not an
        -- error: Aegis's own mail scanner is handling its ledger.
        return "Aegis found (no integration surface yet)"
    end
    if not bridge.Ready() then
        if not A.db.Setting("pushToAegis") then
            return "Aegis found (push disabled)"
        end
        return "Aegis found (contract v" ..
            tostring(AegisExchange.INTEGRATION_VERSION) ..
            " unsupported)"
    end
    return "linked to Aegis: Exchange"
end

A.OnLoad(bridge.Detect)
