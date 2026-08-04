-- Aegis: Courier
-- core/db.lua
--
-- SavedVariables: Courier's OWN ledger and settings. This is maintained
-- whether or not Aegis: Exchange is installed -- a standalone user gets full
-- transaction history, and a user who later uninstalls Aegis keeps theirs.
--
-- Declared in Aegis_Courier.toc:
--   CourierDB      -- account-wide. Ledger, dedupe keys, settings.
--   CourierCharDB  -- per-character. Window position and UI state.
--
-- The ledger entry shape is deliberately a SUPERSET of Aegis: Exchange's
-- (core/db.lua there: `{ t, kind, item, amount, id }`). The five shared fields
-- carry identical meanings, so an entry pushed across the bridge is
-- indistinguishable from one Aegis recorded itself; the extra fields (gross /
-- cut / net) are Courier's own and are never sent.
--
-- IMPORTANT: both globals are nil until ADDON_LOADED fires for
-- "Aegis_Courier". db.Init is queued via A.OnLoad and runs exactly then.

local A = AegisCourier
A.db = {}
local db = A.db

-- Bump when the on-disk shape changes so we can migrate old data.
local DB_VERSION = 1

-- Cap on retained transactions so SavedVariables stays small.
local LEDGER_MAX = 500

-- Dedupe keys are kept with the time they were recorded so they can be pruned.
-- Aegis's equivalent table grows without bound; ours must not, because Courier
-- writes a key for every auction mail a character ever collects.
--
-- The window has to outlive the longest gap between seeing the same mail twice.
-- Mail expires after 30 days, so a key older than that can never match a mail
-- still in an inbox.
local SEEN_MAX_AGE = 31 * 86400

-- Defaults for every user setting. db.Setting falls back to these, so adding a
-- new setting here is enough -- no migration of old saves needed.
local SETTING_DEFAULTS = {
    -- Take over the mailbox window. Off = stay out of the way entirely and let
    -- the Blizzard mail frame behave normally.
    takeover     = true,
    -- Push matched transactions to Aegis: Exchange when it is installed and
    -- exposes the integration seam. No effect when it is absent.
    pushToAegis  = true,
    -- Never auto-open COD mail. This mirrors TurtleMail and is deliberately
    -- not exposed as an "off" switch in Stage A -- auto-paying COD by accident
    -- is unrecoverable.
    skipCOD      = true,
    -- Match pfUI's look when pfUI is installed.
    pfSkin       = true,
}

-- Default shape of the account-wide DB.
local function DefaultAccountDB()
    return {
        version = DB_VERSION,
        -- Sales and purchases matched from mail. Array of
        --   { t, kind = "sale"|"buy", item, amount, id, gross, cut, net }
        -- `amount` mirrors Aegis: for a sale it is the money that actually
        -- arrived (net), which is what Aegis's own scanner records.
        ledger     = {},
        -- Dedupe: stable mail key -> epoch first seen. Pruned by SEEN_MAX_AGE.
        ledgerSeen = {},
        -- User settings, read through db.Setting.
        settings   = {},
    }
end

-- Default shape of the per-character DB.
local function DefaultCharDB()
    return {
        version = DB_VERSION,
        ui      = {},   -- window position, open tab
    }
end

-- Fill in any missing default keys on `target` without clobbering existing
-- values. Copies one level of nested default tables.
local function ApplyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            if type(v) == "table" then
                local inner = {}
                for k2, v2 in pairs(v) do
                    inner[k2] = v2
                end
                target[k] = inner
            else
                target[k] = v
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

-- Read a user setting, falling back to its default when unset.
function db.Setting(key)
    local s = db.account and db.account.settings
    local v = s and s[key]
    if v == nil then return SETTING_DEFAULTS[key] end
    return v
end

-- Write a user setting (account-wide).
function db.SetSetting(key, value)
    if not db.account then return end
    if not db.account.settings then db.account.settings = {} end
    db.account.settings[key] = value
end

-- ---------------------------------------------------------------------------
-- Bootstrap
-- ---------------------------------------------------------------------------

-- Drop dedupe keys older than SEEN_MAX_AGE. Runs once at load, which is often
-- enough -- the table only grows by a handful of keys per mailbox visit.
local function PruneSeen()
    local seen = db.account and db.account.ledgerSeen
    if not seen then return end
    local cutoff = time() - SEEN_MAX_AGE
    local stale = {}
    for key, when in pairs(seen) do
        -- Entries written before keys carried a timestamp stored `true`; treat
        -- those as current rather than dropping history we cannot date.
        if type(when) == "number" and when < cutoff then
            table.insert(stale, key)
        end
    end
    local n = table.getn(stale)
    local i = 1
    while i <= n do
        seen[stale[i]] = nil
        i = i + 1
    end
end

-- Runs after ADDON_LOADED (queued via A.OnLoad below). The SavedVariables
-- globals exist by now: either a saved table, an empty table on first login,
-- or nil which we replace with defaults.
function db.Init()
    if CourierDB == nil then
        CourierDB = DefaultAccountDB()
    end
    ApplyDefaults(CourierDB, DefaultAccountDB())
    CourierDB.version = DB_VERSION

    if CourierCharDB == nil then
        CourierCharDB = DefaultCharDB()
    end
    ApplyDefaults(CourierCharDB, DefaultCharDB())
    CourierCharDB.version = DB_VERSION

    db.account = CourierDB
    db.char    = CourierCharDB

    PruneSeen()
end

-- ---------------------------------------------------------------------------
-- Ledger
-- ---------------------------------------------------------------------------

-- Append a transaction. `kind` is "sale" (money in) or "buy" (money out).
--
-- `amount` is the money that actually changed hands. For an auction sale that
-- is the NET proceeds -- the same number Aegis: Exchange records -- so totals
-- agree across both addons. `gross` / `cut` / `net` are Courier's extra detail
-- and may be nil for transactions where the split is not known.
--
-- Returns the stored entry, or nil when the write was rejected.
function db.RecordTxn(kind, item, amount, itemId, gross, cut, net)
    if not db.account then return nil end
    if not amount or amount <= 0 then return nil end
    local led = db.account.ledger
    if not led then led = {}; db.account.ledger = led end
    local entry = {
        t      = time(),
        kind   = kind,
        item   = item or "?",
        amount = amount,
        id     = itemId,
        gross  = gross,
        cut    = cut,
        net    = net,
    }
    table.insert(led, entry)
    -- Prune oldest beyond the cap.
    while table.getn(led) > LEDGER_MAX do
        table.remove(led, 1)
    end
    return entry
end

function db.Ledger()
    return (db.account and db.account.ledger) or {}
end

-- Income / spend / count over transactions at or after `sinceEpoch`
-- (nil = all time). Mirrors Aegis's db.LedgerTotals so the two report the
-- same numbers over the same window.
function db.LedgerTotals(sinceEpoch)
    local income, spend, n = 0, 0, 0
    local led = db.Ledger()
    local i = 1
    while i <= table.getn(led) do
        local e = led[i]
        if not sinceEpoch or (e.t and e.t >= sinceEpoch) then
            if e.kind == "sale" then
                income = income + (e.amount or 0)
            elseif e.kind == "buy" then
                spend = spend + (e.amount or 0)
            end
            n = n + 1
        end
        i = i + 1
    end
    return income, spend, n
end

-- Total consignment cut paid over the same window, which Aegis cannot report
-- because it never records the split.
function db.CutTotal(sinceEpoch)
    local total = 0
    local led = db.Ledger()
    local i = 1
    while i <= table.getn(led) do
        local e = led[i]
        if e.cut and (not sinceEpoch or (e.t and e.t >= sinceEpoch)) then
            total = total + e.cut
        end
        i = i + 1
    end
    return total
end

function db.ClearLedger()
    if not db.account then return end
    db.account.ledger = {}
    db.account.ledgerSeen = {}
end

-- ---------------------------------------------------------------------------
-- Dedupe
-- ---------------------------------------------------------------------------
-- Same contract as Aegis's WasSeen / MarkSeen, reimplemented here because
-- Courier keeps its own ledger and must never read Aegis's SavedVariables
-- (CLAUDE.md, integration rule 2). Ours stores a timestamp rather than `true`
-- so keys can be aged out.

-- Has this mail dedupe key been recorded already?
function db.WasSeen(key)
    if not db.account or not key then return false end
    local seen = db.account.ledgerSeen
    return (seen and seen[key]) and true or false
end

function db.MarkSeen(key)
    if not db.account or not key then return end
    if not db.account.ledgerSeen then db.account.ledgerSeen = {} end
    db.account.ledgerSeen[key] = time()
end

function db.SeenCount()
    if not db.account or not db.account.ledgerSeen then return 0 end
    return A.util.CountKeys(db.account.ledgerSeen)
end

-- ---------------------------------------------------------------------------
-- Per-character UI state
-- ---------------------------------------------------------------------------

function db.SaveWindowPoint(point, x, y)
    if not db.char then return end
    if not db.char.ui then db.char.ui = {} end
    db.char.ui.point = point
    db.char.ui.x = x
    db.char.ui.y = y
end

function db.GetWindowPoint()
    local ui = db.char and db.char.ui
    if not ui or not ui.point then return nil end
    return ui.point, ui.x, ui.y
end

-- Register the bootstrap with the load queue.
A.OnLoad(db.Init)
