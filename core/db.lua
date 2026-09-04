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
    -- Keep a log of mail sent and collected. On by default: it is capped, and
    -- a log you have to know to switch on is one you never have when you want
    -- it. (TurtleMail defaults its log off.)
    logEnabled   = true,
}

-- Entries retained per direction. Two capped arrays, so the log cannot grow
-- without bound however long the account lives.
local LOG_MAX = 250

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
        --
        -- UNUSED by the take engine, deliberately. Stage B established that
        -- recording on collection makes a mail fingerprint unnecessary (an
        -- emptied mail has nothing left to book), and that any fingerprint
        -- built from `daysLeft` collides for identical sales. Kept as
        -- primitives; do not wire them back into the take path.
        ledgerSeen = {},
        -- User settings, read through db.Setting.
        settings   = {},
        -- Correspondence log: what was actually sent and collected.
        --
        -- ACCOUNT-WIDE, deliberately, where TurtleMail's is per-character.
        -- Each entry carries the character it belongs to, so a per-character
        -- view is a filter rather than a storage decision -- and "did I send
        -- that on my bank alt?", which is the question people actually have,
        -- becomes answerable instead of structurally impossible.
        log        = { sent = {}, received = {} },
        -- The sent box: one record per SEND, not per mail.
        --
        -- Vanilla mail carries one attachment, so mailing 12 items to a bank
        -- alt is 12 separate mails and the server has no idea they belong
        -- together. That grouping is ours to invent and can only be captured
        -- at send time -- it cannot be read back afterwards. See db.SentBegin.
        --
        -- Keys are DELIBERATELY SHORT (`n`/`c` rather than `name`/`count`).
        -- SavedVariables is written out as Lua SOURCE and re-parsed at every
        -- login, so every key name is spelled out once per record; across a
        -- month of bank-alt runs that is the difference between a tidy file
        -- and a slow load.
        sent       = {},
        -- Recipient autocomplete: realm|faction -> { name -> lastSeenEpoch }.
        -- Scoped that way because you cannot mail across a realm, and mailing
        -- the opposing faction is not possible either -- so a flat account-wide
        -- list would offer names that can never be valid.
        contacts   = {},
    }
end

-- Contact names older than this are dropped at load. Matches TurtleMail's
-- 30-day window: a name you have not seen in a month is noise in a dropdown.
local CONTACT_MAX_AGE = 30 * 86400

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

-- Forward declaration: db.Init calls this, but the contacts section that
-- defines it sits further down the file, and a `local function` declared later
-- is not in scope up here.
local PruneContacts

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
    PruneContacts()
    -- Age out the sent box here rather than on a timer: ADDON_LOADED is the
    -- only moment the DB is guaranteed present, and it is also when a stale
    -- box would otherwise be paid for in load time.
    db.SentPrune()
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
-- Correspondence log
-- ---------------------------------------------------------------------------
-- Distinct from the ledger. The ledger is money: auction sales, with the
-- consignment split, and it only ever books "sold" mail. The log is a record
-- of correspondence -- who, what subject, what was attached -- across every
-- mail Courier actually handled, auction or not.

local function LogBucket(dir)
    if not db.account then return nil end
    if not db.account.log then db.account.log = { sent = {}, received = {} } end
    if dir ~= "sent" then dir = "received" end
    if not db.account.log[dir] then db.account.log[dir] = {} end
    return db.account.log[dir]
end

-- Append a log entry. `dir` is "sent" or "received".
--
-- `entry` is stored as given plus a timestamp and the acting character, so a
-- per-character view is a filter over account-wide data rather than a
-- separate store. Honours the logEnabled setting; callers need not check.
function db.LogAdd(dir, entry)
    if not db.account or not entry then return nil end
    if not db.Setting("logEnabled") then return nil end
    local bucket = LogBucket(dir)
    if not bucket then return nil end

    entry.t = entry.t or time()
    if not entry.char and UnitName then
        entry.char = UnitName("player")
    end
    table.insert(bucket, entry)
    while table.getn(bucket) > LOG_MAX do
        table.remove(bucket, 1)
    end
    return entry
end

-- ---------------------------------------------------------------------------
-- The sent box
-- ---------------------------------------------------------------------------
-- Two bounds, not one. An age bound alone is unbounded for a heavy bank-alt
-- user, and one runaway session should not leave a file that costs seconds to
-- re-parse at every login. Whichever bites first wins.
db.SENT_DAYS = 30
db.SENT_MAX  = 500

-- Drop records older than SENT_DAYS, then trim to SENT_MAX. Returns how many
-- went. Called from db.Init and again whenever a record is opened.
function db.SentPrune()
    local box = db.account and db.account.sent
    if not box then return 0 end
    local n = table.getn(box)
    if n == 0 then return 0 end

    -- 30 days in seconds. No modulo and no integer division anywhere here --
    -- Lua 5.0 has neither.
    local cutoff = time() - (db.SENT_DAYS * 86400)

    -- Records are appended in time order, so everything to drop is a PREFIX.
    -- Find where the survivors start and rebuild ONCE: table.remove(box, 1) in
    -- a loop shifts the whole array on every call, which goes quadratic on the
    -- first login after a long absence -- precisely when the box is biggest.
    local first = 1
    while first <= n and (box[first].t or 0) < cutoff do
        first = first + 1
    end

    local keep = n - first + 1
    if keep > db.SENT_MAX then first = first + (keep - db.SENT_MAX) end
    if first == 1 then return 0 end

    local out = {}
    local i = first
    while i <= n do
        table.insert(out, box[i])
        i = i + 1
    end
    db.account.sent = out
    return first - 1
end

-- Open a record for a batch. Called by the FIRST confirmed mail of a send, not
-- by pressing Send: a batch the server never accepted anything from leaves no
-- record behind, exactly as the ledger books nothing for a mail it never
-- emptied.
--
-- Honours the same logEnabled setting as the correspondence log -- a user who
-- turned logging off did not mean "except this".
-- The message body is the one unbounded field in a record -- everything else
-- is a name, a number or a short string. Capped so a single long letter cannot
-- dominate a file that is re-parsed as Lua source at every login.
db.SENT_BODY_MAX = 500

function db.SentBegin(to, subject, money, cod, body)
    if not db.account then return nil end
    if not db.Setting("logEnabled") then return nil end
    if not db.account.sent then db.account.sent = {} end
    -- A monotonic id, because `t` is NOT an identity. time() has one-second
    -- resolution, so two sends a moment apart share a timestamp -- and the
    -- reader uses this to notice a record shifting under its index. A
    -- timestamp-based check would silently pass for exactly the sends most
    -- likely to be confused with each other.
    db.account.sentSeq = (db.account.sentSeq or 0) + 1
    local rec = {
        id    = db.account.sentSeq,
        t     = time(),
        to    = to or "?",
        s     = subject or "",
        char  = (UnitName and UnitName("player")) or nil,
        mails = 0,
        money = money or 0,
        cod   = cod or 0,
        items = {},
    }
    -- Stored only if there is one. An empty body should not cost a key in
    -- every record of a parcel-only sender's history.
    if type(body) == "string" and body ~= "" then
        if string.len(body) > db.SENT_BODY_MAX then
            rec.body = string.sub(body, 1, db.SENT_BODY_MAX) .. "..."
        else
            rec.body = body
        end
    end
    table.insert(db.account.sent, rec)
    db.SentPrune()
    return rec
end

-- Append one CONFIRMED mail to an open record. A batch abandoned halfway keeps
-- whatever actually went out, rather than being recorded as complete or lost
-- entirely.
-- `texture` is the item's icon path, captured at attach time. Records written
-- before it existed simply have no `x` field, and the reader falls back rather
-- than showing a hole -- a sent mail cannot be re-read to fill it in.
-- `link` is the "item:id:enchant:suffix:unique" string, captured from the bag
-- slot at send time. It is what lets the reader show the item's REAL tooltip;
-- records written before it was captured simply have no `l` and fall back to
-- the name, which is the rule for everything in this box -- a sent mail cannot
-- be re-read, so nothing here is ever backfilled.
function db.SentAdd(rec, itemName, count, texture, link)
    if not rec then return nil end
    rec.mails = rec.mails + 1
    if itemName then
        table.insert(rec.items,
            { n = itemName, c = count or 1, x = texture, l = link })
    end
    return rec
end

function db.SentBox()
    return (db.account and db.account.sent) or {}
end

function db.ClearSentBox()
    if db.account then db.account.sent = {} end
end

function db.Log(dir)
    return LogBucket(dir) or {}
end

-- Clearing the "sent" direction clears the SENT BOX, because that is what the
-- Sent view actually shows now -- leaving the box behind would make the Clear
-- button look broken.
function db.ClearLog(dir)
    if not db.account then return end
    if dir == "sent" then db.ClearSentBox() end
    if not dir then db.ClearSentBox() end
    if dir then
        local bucket = LogBucket(dir)
        if bucket then
            local n = table.getn(bucket)
            while n > 0 do
                table.remove(bucket)
                n = n - 1
            end
        end
    else
        db.account.log = { sent = {}, received = {} }
    end
end

-- ---------------------------------------------------------------------------
-- Recipient autocomplete
-- ---------------------------------------------------------------------------

-- Key for the current realm + faction. GetCVar("realmName") is the 1.12 way to
-- get the realm; UnitFactionGroup gives "Alliance"/"Horde".
local function ContactKey()
    local realm = "?"
    if GetCVar then realm = GetCVar("realmName") or "?" end
    local faction = "?"
    if UnitFactionGroup then faction = UnitFactionGroup("player") or "?" end
    return realm .. "|" .. faction
end

local function ContactBucket()
    if not db.account then return nil end
    if not db.account.contacts then db.account.contacts = {} end
    local key = ContactKey()
    if not db.account.contacts[key] then db.account.contacts[key] = {} end
    return db.account.contacts[key]
end

-- Remember a name we have corresponded with. Called for anyone who mails us
-- (they are by definition reachable) and for every successful send.
function db.AddContact(name)
    if type(name) ~= "string" or name == "" then return end
    local bucket = ContactBucket()
    if not bucket then return end
    bucket[name] = time()
end

function db.ForgetContacts()
    if not db.account then return end
    db.account.contacts[ContactKey()] = {}
end

-- Names beginning with `prefix`, case-insensitive, most-recently-seen first.
-- Returns an array, capped at `limit`.
function db.MatchContacts(prefix, limit)
    local out = {}
    local bucket = ContactBucket()
    if not bucket then return out end
    if type(prefix) ~= "string" then prefix = "" end
    local lower = string.lower(prefix)
    local n = string.len(lower)

    local matches = {}
    for name, seen in pairs(bucket) do
        if n == 0 or string.sub(string.lower(name), 1, n) == lower then
            table.insert(matches, { name = name, seen = seen or 0 })
        end
    end
    table.sort(matches, function(a, b)
        if a.seen == b.seen then return a.name < b.name end
        return a.seen > b.seen
    end)
    local count = table.getn(matches)
    local i = 1
    while i <= count and (not limit or table.getn(out) < limit) do
        table.insert(out, matches[i].name)
        i = i + 1
    end
    return out
end

-- Defined against the forward declaration above.
function PruneContacts()
    if not db.account or not db.account.contacts then return end
    local cutoff = time() - CONTACT_MAX_AGE
    for key, bucket in pairs(db.account.contacts) do
        local stale = {}
        for name, seen in pairs(bucket) do
            if type(seen) ~= "number" or seen < cutoff then
                table.insert(stale, name)
            end
        end
        local n = table.getn(stale)
        local i = 1
        while i <= n do
            bucket[stale[i]] = nil
            i = i + 1
        end
    end
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

-- Window SIZE, stored per character alongside the position. Separate from the
-- scale below: a taller window shows MORE rows (vanilla frames never reflow,
-- so that is all extra height can do), while scale makes the same window
-- physically bigger. On a large screen you want both.
function db.SaveWindowSize(w, h)
    if not db.char then return end
    if not db.char.ui then db.char.ui = {} end
    db.char.ui.width  = math.floor(w or 0)
    db.char.ui.height = math.floor(h or 0)
end

function db.GetWindowSize()
    local u = db.char and db.char.ui
    if not u then return nil end
    return u.width, u.height
end

-- Window SCALE, also per character. Clamped by the UI; stored raw here.
function db.SaveWindowScale(v)
    if not db.char then return end
    if not db.char.ui then db.char.ui = {} end
    db.char.ui.scale = v
end

function db.GetWindowScale()
    local u = db.char and db.char.ui
    return u and u.scale or nil
end

function db.GetWindowPoint()
    local ui = db.char and db.char.ui
    if not ui or not ui.point then return nil end
    return ui.point, ui.x, ui.y
end

-- Register the bootstrap with the load queue.
A.OnLoad(db.Init)
