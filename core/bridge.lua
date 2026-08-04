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
-- STATUS: as of Courier 0.1.0, Aegis: Exchange has NOT yet shipped
-- RecordExternalTxn -- it is Phase 0.2 on that repo's roadmap. So the guard is
-- false in practice today and this module is dormant. That is the expected
-- state and must stay completely silent: a standalone user has done nothing
-- wrong and must never see a warning about a missing optional addon.

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

-- Push one already-deduped, already-locally-recorded transaction into Aegis's
-- ledger.
--
-- Argument order mirrors Aegis's own db.RecordTxn(kind, item, amount, itemId)
-- so the entry it produces is indistinguishable from one Aegis recorded
-- itself -- which is the stated goal of the integration. Courier's extra
-- detail (gross / cut / net) is deliberately NOT sent: it is not part of
-- Aegis's entry shape, and inventing fields on the far side would defeat the
-- point of having a fixed signature.
--
-- The call is wrapped in pcall because the far side is another addon's code:
-- a signature change, a nil field, or an error inside Aegis's ledger must
-- never take down the mailbox the user is standing at. A failed push costs the
-- Aegis mirror of one entry; Courier's own ledger already has it.
--
-- Returns true when the push was made, false otherwise.
function bridge.Push(kind, item, amount, itemId)
    if not bridge.Ready() then return false end
    if not kind or not amount or amount <= 0 then return false end

    local ok = pcall(AegisExchange.RecordExternalTxn, kind, item, amount, itemId)
    if not ok then
        -- Report once per session, not per mail: a broken seam during an
        -- open-all would otherwise spam a line per sale.
        if not bridge.warned then
            bridge.warned = true
            A.Print("Aegis: Exchange rejected a ledger push; Courier's own " ..
                "history is unaffected. Further pushes this session are silent.")
        end
        return false
    end
    return true
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
