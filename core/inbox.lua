-- Aegis: Courier
-- core/inbox.lua
--
-- READ-ONLY accessors over the 1.12 mailbox API.
--
-- Stage A scope: this module reads and classifies. It does NOT take money,
-- take items, delete mail, or write to the ledger -- that engine is Stage B
-- and lands in its own module. Keeping the read layer separate means the
-- open-all state machine can be built and reasoned about without also owning
-- the parsing rules.
--
-- Two client facts shape everything here (CLAUDE.md rules 8-10):
--   * GetInboxHeaderInfo returns 13 values and `daysLeft` is FRACTIONAL DAYS.
--   * There is NO GetInboxItemLink on 1.12 -- an attached item is a NAME and a
--     TEXTURE, with no link and no itemID. Item identity must come from the
--     name, which is also why the subject line matters so much.

local A = AegisCourier
A.inbox = {}
local inbox = A.inbox
local util = A.util

-- ---------------------------------------------------------------------------
-- Auction mail classification
-- ---------------------------------------------------------------------------
-- Built from the CLIENT's own localized subject formats rather than hardcoded
-- English literals. This is the technique TurtleMail uses and it is the
-- correct one: on a deDE/ruRU client the subject is German/Russian, and a
-- literal "Auction successful: " match silently logs nothing at all.
--
-- Each entry pairs our internal kind with the global holding its format. The
-- globals are FrameXML-level and exist before any addon loads; the `or`
-- fallbacks are belt-and-braces for a server build that dropped one.
local SUBJECT_FORMATS = {
    { kind = "sold",      fmt = AUCTION_SOLD_MAIL_SUBJECT     or "Auction successful: %s" },
    { kind = "won",       fmt = AUCTION_WON_MAIL_SUBJECT      or "Auction won: %s" },
    { kind = "expired",   fmt = AUCTION_EXPIRED_MAIL_SUBJECT  or "Auction expired: %s" },
    { kind = "cancelled", fmt = AUCTION_REMOVED_MAIL_SUBJECT  or "Auction cancelled: %s" },
    { kind = "outbid",    fmt = AUCTION_OUTBID_MAIL_SUBJECT   or "Outbid on %s" },
}

-- Known auction-house sender names, normalized (runs of whitespace collapsed).
-- Normalizing matters: the name observed in the wild for Thunder Bluff carries
-- a DOUBLE space, and matching the raw string would miss it on any realm that
-- sends the single-spaced form -- or vice versa.
local AUCTION_SENDERS = {}
do
    local names = {
        "Stormwind Auction House",
        "Alliance Auction House",
        "Darnassus Auction House",
        "Undercity Auction House",
        "Thunder Bluff Auction House",
        "Horde Auction House",
        "Blackwater Auction House",
        "Booty Bay Auction House",
        "Gadgetzan Auction House",
        "Everlook Auction House",
        "Ironforge Auction House",
        "Orgrimmar Auction House",
    }
    local n = table.getn(names)
    local i = 1
    while i <= n do
        AUCTION_SENDERS[util.Normalize(names[i])] = true
        i = i + 1
    end
end

-- Is this sender an auction house?
--
-- The explicit set is the fast path; the suffix test catches realms and
-- locales whose auction-house names we have not enumerated. Neither is
-- authoritative on its own -- SUBJECT classification is what actually decides
-- whether a mail is an auction transaction, and the sender only decorates the
-- row. Do not gate ledger writes on this function alone.
function inbox.IsAuctionSender(sender)
    if type(sender) ~= "string" then return false end
    local norm = util.Normalize(sender)
    if AUCTION_SENDERS[norm] then return true end
    return util.Contains(norm, "Auction House")
end

-- Classify a subject line. Returns (kind, itemName) where kind is one of
-- "sold" / "won" / "expired" / "cancelled" / "outbid", or nil for ordinary
-- mail.
--
-- Matching is anchored through util.SubjectItem, so "Auction successful: X"
-- only matches when the subject genuinely starts with that stem -- a player
-- mailing you with the subject "re: Auction successful: nice" does not parse
-- as a sale.
function inbox.ClassifySubject(subject)
    if type(subject) ~= "string" or subject == "" then return nil end
    local n = table.getn(SUBJECT_FORMATS)
    local i = 1
    while i <= n do
        local entry = SUBJECT_FORMATS[i]
        local item = util.SubjectItem(subject, entry.fmt)
        if item and item ~= "" then
            return entry.kind, item
        end
        i = i + 1
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Header reads
-- ---------------------------------------------------------------------------

function inbox.NumItems()
    if not GetInboxNumItems then return 0 end
    return GetInboxNumItems() or 0
end

-- Read one mail header into a named table.
--
-- `index` is ABSOLUTE, 1..inbox.NumItems() -- the 7-per-page layout is a
-- FrameXML display convention and is not a limit on what we can read
-- (CLAUDE.md rule 9).
--
-- Derived fields:
--   auctionKind / auctionItem  -- from the subject (nil for ordinary mail)
--   fromAuctionHouse           -- from the sender
--   arrival                    -- approximate epoch the mail was SENT
--
-- On `arrival`: 1.12 gives us no mail id and no send time. `daysLeft` counts
-- DOWN in real time while time() counts UP, so time() - (30 - daysLeft)*86400
-- is roughly constant for a given mail across sessions. That makes it useful
-- for display and as an INPUT to a dedupe key -- but it is an approximation,
-- not an identity, and the dedupe design that consumes it is deliberately
-- deferred to Stage B (see docs/turtlemail-audit.md, "Note on mail identity").
function inbox.Header(index)
    if not GetInboxHeaderInfo then return nil end
    local packageIcon, stationeryIcon, sender, subject, money, codAmount,
          daysLeft, hasItem, wasRead, wasReturned, textCreated, canReply,
          isGM = GetInboxHeaderInfo(index)

    -- A valid mail always has a subject slot; a nil return means the index is
    -- out of range or the inbox has not arrived from the server yet.
    if subject == nil and sender == nil and money == nil then return nil end

    local h = {
        index          = index,
        packageIcon    = packageIcon,
        stationeryIcon = stationeryIcon,
        -- FrameXML substitutes UNKNOWN for a nil sender; do the same so every
        -- consumer does not have to.
        sender         = sender or (UNKNOWN or "Unknown"),
        subject        = subject or "",
        money          = money or 0,
        cod            = codAmount or 0,
        daysLeft       = daysLeft or 0,
        -- `hasItem` is an item count on some builds and boolean-ish on others.
        -- Test truthiness only, never == true.
        hasItem        = (hasItem and true or false),
        wasRead        = (wasRead and true or false),
        wasReturned    = (wasReturned and true or false),
        textCreated    = (textCreated and true or false),
        canReply       = (canReply and true or false),
        isGM           = (isGM and true or false),
    }

    h.auctionKind, h.auctionItem = inbox.ClassifySubject(h.subject)
    h.fromAuctionHouse = inbox.IsAuctionSender(h.sender)
    -- Vanilla mail lives 30 days.
    h.arrival = math.floor(time() - (30 - h.daysLeft) * 86400)

    return h
end

-- The icon FrameXML would show for a mail: the package icon when there is an
-- attachment (and it is not a GM mail), otherwise the stationery.
function inbox.Icon(h)
    if not h then return nil end
    if h.packageIcon and not h.isGM then return h.packageIcon end
    return h.stationeryIcon
end

-- Attached item, as far as 1.12 will tell us: name, texture, count, quality.
-- NO link, NO itemID (CLAUDE.md rule 10).
function inbox.Item(index)
    if not GetInboxItem then return nil end
    local name, texture, count, quality = GetInboxItem(index)
    if not name then return nil end
    return { name = name, texture = texture, count = count or 1,
        quality = quality }
end

-- Walk the whole inbox, newest index first is NOT guaranteed -- indices are in
-- server order -- so callers that care about time should sort on `arrival`.
-- Returns an array of headers.
function inbox.All()
    local out = {}
    local n = inbox.NumItems()
    local i = 1
    while i <= n do
        local h = inbox.Header(i)
        if h then table.insert(out, h) end
        i = i + 1
    end
    return out
end

-- Counts for the window's summary line: total, unread, and total money sitting
-- in the inbox waiting to be collected.
function inbox.Summary()
    local total, unread, money = 0, 0, 0
    local n = inbox.NumItems()
    local i = 1
    while i <= n do
        local h = inbox.Header(i)
        if h then
            total = total + 1
            if not h.wasRead then unread = unread + 1 end
            money = money + h.money
        end
        i = i + 1
    end
    return total, unread, money
end
