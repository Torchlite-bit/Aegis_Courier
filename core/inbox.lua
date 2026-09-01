-- Aegis: Courier
-- core/inbox.lua
--
-- The 1.12 mailbox: reads (A.inbox) and the take engine (A.take).
--
-- Stage A shipped the read layer alone and its header said the take engine
-- would land in "its own module". That was wrong, and deliberately reversed
-- here: a new .lua file means a new .toc line, and 1.12 reads the file list at
-- STARTUP, so it would force every user through a full client restart --
-- the exact cost Stage A's "lay the module set down complete" decision was
-- taken to avoid. The engine lives here instead. The two halves stay cleanly
-- separated below; only the file boundary is gone.
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

-- NOTE ON CACHING. A single flush still reads every header about five times
-- over (UnreadCount, HasWork x3, All, Summary). Memoising those within one
-- flush was tried and DELIBERATELY NOT SHIPPED: the measured saving was small
-- next to the coalescing below (which removes 99.8% of the work in the
-- harness's 200-event storm -- 169,200 header reads down to 282), and
-- a header memo is precisely the kind of stale mail state this addon's
-- correctness depends on never trusting -- the take engine re-reads after
-- every action because "I took it, therefore it is empty" is false. If it is
-- revisited, it must be provably scoped to a read-only flush and never
-- visible to a mutating path.

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
-- is roughly constant for a given mail across sessions.
--
-- It is a DISPLAY value only. It was once the intended basis of a dedupe key,
-- and Stage B deliberately rejected that: bucketing it wide enough to be
-- stable makes two identical stacks sold at the same price in the same hour
-- collide, and a collision silently UNDER-counts. Recording on collection
-- instead (see take.Confirm) removes the need for a fingerprint entirely --
-- an emptied mail has nothing left to book. Do not reintroduce a key built
-- from this field.
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

-- ---------------------------------------------------------------------------
-- Coalesced refresh
-- ---------------------------------------------------------------------------
-- MAIL_INBOX_UPDATE does not arrive once per mailbox visit. On a client that
-- has not yet cached the attached items -- the first open of a session -- it
-- arrives again and again as each item resolves. Courier used to do FIVE full
-- inbox walks plus a ten-row repaint inside every one of those events:
-- measured at 70 mails, that is 352 header reads and ~1,300 subject-pattern
-- parses PER EVENT, and a 100-event storm ran 130,000 parses. On a 1.12
-- client that is seconds of frozen frame.
--
-- So the events no longer do the work. They raise a flag, and the driver
-- below flushes AT MOST ONCE PER FRAME, however many events landed in it.
--
-- What deliberately stays per-event is the take engine's arming: that is the
-- server's acknowledgement clock, one Step per confirmation, and coalescing
-- it would drop steps.
inbox.dirty = false

function inbox.MarkDirty()
    inbox.dirty = true
end

-- Run the once-per-frame work: refresh the unread count and repaint the
-- window. Reads only -- nothing here mutates mail. inbox.lastUnread is
-- refreshed here because MAIL_CLOSED arrives after the session has gone and
-- the inbox cannot be read from there; ui.SettleMailIcon needs the last value
-- we were able to see.
function inbox.Flush()
    inbox.dirty = false
    inbox.lastUnread = inbox.UnreadCount()
    if A.ui and A.ui.Refresh then A.ui.Refresh() end
end

-- Mark a mail READ on the server.
--
-- There is no "mark read" call on 1.12: GetInboxText(index) is what does it,
-- as a side effect of fetching the body. Without it a mail stays unread
-- forever, which leaves the minimap's "you have unread mail" icon lit and
-- makes Delete Read permanently find nothing.
--
-- SIDE EFFECT, and the reason this is not called on mail we merely display:
-- reading a mail that still holds attachments drops its expiry to three days.
-- Only mail we are actively emptying goes through here -- the same rule
-- TurtleMail follows.
function inbox.MarkRead(index)
    if GetInboxText then GetInboxText(index) end
end

-- Does reading this mail cost the player anything?
--
-- GetInboxText marks a mail read, and on mail that still holds money or an
-- item it ALSO drops the expiry to three days. On a mail holding nothing there
-- is nothing left to lose -- the three-day clock applies to the attachments,
-- and clearing the unread flag is what the player wants anyway. So an empty
-- mail can be opened freely and a loaded one only on request.
--
-- COD counts as loaded: the attachment is still there, it just has a price on
-- it, and shortening the window to pay is a real cost.
function inbox.ReadIsFree(h)
    if not h then return false end
    if h.money > 0 then return false end
    if h.cod > 0 then return false end
    if h.hasItem then return false end
    return true
end

-- Fetch a mail's body.
--
-- THIS MARKS THE MAIL READ and, on mail that still holds attachments, drops
-- its expiry to three days -- see inbox.ReadIsFree. Call it only when the
-- player has asked for this specific mail. Never from a refresh, a list paint,
-- or anything that runs on an event.
--
-- Returns nil for a bad index, otherwise a table:
--   text     -- the body. NIL is normal on the first call: the client asks the
--               server for it and fires MAIL_INBOX_UPDATE when it lands, so a
--               caller should re-read rather than render "no message".
--   texture  -- stationery
--   takeable -- the client's own "there is something to take here" flag
--   invoice  -- auction invoice detail when this mail is one, else nil
function inbox.Body(index)
    if not GetInboxText then return nil end
    local text, texture, takeable = GetInboxText(index)
    local out = {
        text     = text,
        texture  = texture,
        takeable = takeable and true or false,
    }
    -- The 1.12 GetInboxText is documented with a fourth `isInvoice` return, but
    -- builds disagree about it and Turtle is a custom build -- so do not gate
    -- on it. Ask for the invoice outright and let a nil answer settle the
    -- question. Ordering matters: FrameXML only reads invoice data after the
    -- body, and so do we.
    if GetInboxInvoiceInfo then
        local kind, item, who, bid, buyout, deposit, consignment =
            GetInboxInvoiceInfo(index)
        if kind then
            out.invoice = {
                kind        = kind,          -- "buyer" / "seller" / ...
                item        = item,
                -- nil when several players were involved, per the API.
                who         = who,
                bid         = bid or 0,
                buyout      = buyout or 0,
                deposit     = deposit or 0,
                consignment = consignment or 0,
            }
        end
    end
    return out
end

-- How many mails are still unread. Tracked while the mailbox is open so the
-- minimap icon can be settled on close, when the inbox is no longer readable.
inbox.lastUnread = nil

function inbox.UnreadCount()
    local unread = 0
    local n = inbox.NumItems()
    local i = 1
    while i <= n do
        local h = inbox.Header(i)
        if h and not h.wasRead then unread = unread + 1 end
        i = i + 1
    end
    return unread
end

-- ===========================================================================
-- Take engine
-- ===========================================================================
--
-- Everything below MUTATES the mailbox. The read layer above never does.
--
-- Shape: a state machine clocked by MAIL_INBOX_UPDATE, processing ONE mail
-- action per step -- the design TurtleMail uses and the reason it is reliable.
-- A `for i = 1, GetInboxNumItems()` loop looks obviously correct and is not:
-- every take and delete mutates the inbox underneath it, the server's replies
-- arrive asynchronously, and the loop runs off the end of a list that is
-- shifting beneath it. The server's own inbox refresh is the only honest clock.
--
-- Index discipline, which is where this kind of engine usually goes wrong:
--   * Deleting a mail SHIFTS every later mail down one, so after a delete we
--     do NOT advance -- the next mail slides into the index we are already on.
--   * Taking money or an item does NOT shift anything, so in a mode that keeps
--     the mail we DO advance once it is empty.
--   * Skipped mail (COD, GM) is stepped over.
--
-- Ledger writes happen on COLLECTION, never on arrival: an entry is only
-- written once the money has verifiably left the mail. See take.Confirm.

A.take = {}
local take = A.take

-- Modes.
--   "open"   -- take money + item, then delete. TurtleMail's Open All.
--   "take"   -- take money + item, KEEP the mail. TurtleMail has no equivalent.
--   "delete" -- delete read mail that is already empty. Takes nothing.
take.MODE_OPEN   = "open"
take.MODE_DELETE = "delete"

-- NOT DEAD CODE, but NO LONGER REACHABLE FROM THE UI.
--
-- MODE_TAKE had a "Take All" button until it was removed: emptying every mail
-- while keeping it is a thing almost nobody wanted, and it was the mode worst
-- hit by the clock bug (see take.Advance) -- its final step per mail issues no
-- server call, so the run stalled after the first mail, every time.
--
-- The mode itself stays because it is the only way to observe an EMPTIED mail
-- that is still in the inbox, which is how a large part of tests/harness.lua
-- inspects what a run actually did -- "open" deletes the evidence. Removing it
-- would mean rewriting those assertions to be weaker. If a caller is ever
-- added back, note it inherits the same self-clocking requirement.
take.MODE_TAKE   = "take"

-- Give up on an index after this many steps with no observable progress, so a
-- mail the server will not hand over can never wedge the run in a tight loop.
-- TurtleMail has no such guard and relies purely on UI_ERROR_MESSAGE.
local MAX_ATTEMPTS = 4

-- Passive CheckInbox() pacing, in OnUpdate ticks. CheckInbox is throttled
-- server-side (CLAUDE.md rule 13); this matches TurtleMail's cadence.
local CHECK_TICKS = 200

take.running = false

local function ResetCounters()
    take.money   = 0     -- copper collected this run
    take.items   = 0     -- items taken this run
    take.mails   = 0     -- mails fully processed this run
    take.sales   = 0     -- auction sales recorded this run
end
ResetCounters()

-- Is there anything at all for `mode` to do? Drives button enable state.
-- Does this mail match the run's filter?
--
-- `only` is nil for an unrestricted run, or "sold" for the Take Sold button.
-- Kept as one predicate so the button's enable state and the engine's skip
-- decision can never disagree -- if HasWork says there is work, the run must
-- find it, or the button lights up and then does nothing.
function take.Matches(h, only)
    if not h then return false end
    if not only then return true end
    if only == "sold" then return h.auctionKind == "sold" end
    return true
end

function take.HasWork(mode, only)
    local n = inbox.NumItems()
    local i = 1
    while i <= n do
        local h = inbox.Header(i)
        if h and not h.isGM and not (h.cod > 0) and take.Matches(h, only) then
            if mode == take.MODE_DELETE then
                if h.wasRead and h.money == 0 and not h.hasItem then
                    return true
                end
            elseif h.money > 0 or h.hasItem then
                return true
            end
        end
        i = i + 1
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Ledger recording
-- ---------------------------------------------------------------------------

-- Record a collected auction sale.
--
-- ONLY "sold" mail becomes a ledger entry, and the distinction is not
-- cosmetic. "Outbid on <item>" mail also carries money -- your own returned
-- bid -- and booking that as income would inflate every total the addon
-- reports. "Auction won" delivers the item with no money at all (the buyer
-- paid at purchase time), and "expired" / "cancelled" return the goods. None
-- of those carry a price, so none of them produce entries.
function take.RecordSale(h)
    if not h or h.auctionKind ~= "sold" then return false end
    if not h.money or h.money <= 0 then return false end

    -- The money that arrives is already NET of the 5% consignment cut.
    local gross, cut, net = A.util.SaleSplit(h.money)
    local item = h.auctionItem or h.subject

    -- Courier's own ledger first -- it is the record of truth and is kept
    -- whether or not Aegis: Exchange is installed.
    A.db.RecordTxn("sale", item, net, nil, gross, cut, net)
    -- Then mirror it. Dormant and harmless when Aegis is absent.
    A.bridge.Push("sale", item, net, nil)

    take.sales = take.sales + 1
    return true
end

-- ---------------------------------------------------------------------------
-- Collection confirmation
-- ---------------------------------------------------------------------------

-- A take is issued, then confirmed on the NEXT inbox update. `pending` holds
-- what we asked for; Confirm decides whether it actually happened.
--
-- This is what "finalize on collection, not arrival" means concretely. Aegis:
-- Exchange's own scanner books a sale the moment the mail is SEEN, which
-- counts gold the player has not received and may never receive. Matching that
-- would be a bug, not compatibility.
function take.Confirm()
    local p = take.pending
    if not p then return end
    take.pending = nil

    local h = inbox.Header(p.index)

    -- Did the mail we acted on still exist, unchanged, with its money intact?
    -- If so the take did NOT happen and we must not book anything.
    local unchanged = h
        and h.subject == p.subject
        and h.sender  == p.sender
        and h.money   == p.money
        and p.money > 0

    if unchanged then
        return false
    end

    -- Otherwise the money left the mail: either the field is now zero, or the
    -- mail is gone entirely (it can only have gone to us -- we are the only
    -- thing acting on this mailbox). Book it.
    if p.money > 0 then
        take.money = take.money + p.money
        take.RecordSale(p.header)
    end
    if p.item then
        take.items = take.items + 1
    end
    return true
end

-- ---------------------------------------------------------------------------
-- The state machine
-- ---------------------------------------------------------------------------

-- Process ONE action at the current index, then return and wait for the
-- server. Never loops over the inbox.
function take.Step()
    if not take.running then return end

    -- Settle the previous action before deciding the next one.
    take.Confirm()

    local n = inbox.NumItems()
    if take.index > n then return take.Finish() end

    local h = inbox.Header(take.index)
    if not h then return take.Finish() end

    -- Wedge guard. It has to count steps that produced NO OBSERVABLE CHANGE,
    -- not steps taken: in "open" mode a successful mail is deleted and we
    -- deliberately do not advance, so a raw action counter climbs right
    -- through healthy mail and eventually skips a live one. Comparing a
    -- signature of what is actually sitting at this index resets the count
    -- whenever the mailbox moved.
    local sig = take.index .. "|" .. h.subject .. "|" .. h.money .. "|" ..
        (h.hasItem and "1" or "0")
    if sig ~= take.lastSig then
        take.lastSig = sig
        take.attempts = 0
    end
    if take.attempts >= MAX_ATTEMPTS then
        take.Advance()
        return
    end

    -- Never auto-pay COD, and never touch GM mail. Both are skipped in every
    -- mode -- this is not a setting, because paying a COD by accident is not
    -- recoverable.
    --
    -- take.codIndex is the single exception and it is deliberately narrow: it
    -- is set by take.PayCOD alone, names ONE absolute index, and is compared
    -- against the index the engine is actually standing on. A run cannot drift
    -- onto a different COD mail and pay it, and Open All -- which never sets
    -- it -- still cannot pay anything at all. GM mail has no exception.
    local codAllowed = take.codIndex ~= nil and take.codIndex == take.index
    if (h.cod > 0 and not codAllowed) or h.isGM then
        take.Advance()
        return
    end

    -- A filtered run steps over everything it was not asked for. Same rule as
    -- every other skip: go through take.Advance so the clock is re-armed
    -- (rule 16) -- a filtered run walks past far more mail than an ordinary
    -- one, so a skip that failed to re-arm here would stall almost at once.
    if not take.Matches(h, take.only) then
        take.Advance()
        return
    end

    -- Snapshot the mail the FIRST time we touch it, for the correspondence
    -- log. It has to happen here: once the money is taken and the item pulled,
    -- the header no longer says what the mail contained, and the attached
    -- item's name is only readable while it is still attached.
    if not take.logSnap and (h.money > 0 or h.hasItem) then
        -- Reading it here is also what clears the server's unread flag for
        -- this mail. Do it before the takes, while the mail definitely still
        -- exists, exactly as TurtleMail's inbox_open does.
        inbox.MarkRead(take.index)

        local attached = nil
        if h.hasItem then attached = inbox.Item(take.index) end
        take.logSnap = {
            who     = h.sender,
            subject = h.subject,
            money   = h.money,
            item    = attached and attached.name or nil,
            count   = attached and attached.count or nil,
            auction = h.auctionKind,
            returned = h.wasReturned,
            -- What this mail COST, if anything. Only ever non-zero on the
            -- confirmed COD path -- nothing else in the addon reaches a COD
            -- mail -- and worth recording because it is money leaving the
            -- player, which the ledger's sale entries would never show.
            cod     = (h.cod > 0) and h.cod or nil,
        }
    end

    if take.mode == take.MODE_DELETE then
        -- Delete-read only removes mail that is already empty AND read, so it
        -- can never destroy an attachment or unclaimed gold.
        if h.wasRead and h.money == 0 and not h.hasItem then
            take.attempts = take.attempts + 1
            DeleteInboxItem(take.index)
            take.mails = take.mails + 1
            -- No advance: the next mail shifts down into this index.
            take.pending = nil
            return
        end
        take.Advance()
        return
    end

    -- Money first: it always succeeds where an item can fail on a full bag.
    if h.money > 0 then
        take.attempts = take.attempts + 1
        take.pending = { index = take.index, subject = h.subject,
            sender = h.sender, money = h.money, item = nil, header = h }
        TakeInboxMoney(take.index)
        return
    end

    if h.hasItem then
        take.attempts = take.attempts + 1
        take.pending = { index = take.index, subject = h.subject,
            sender = h.sender, money = 0, item = true, header = h }
        -- 1.12 mail carries a single attachment, so one call empties it.
        TakeInboxItem(take.index)
        return
    end

    -- The mail is empty, so everything it held is now ours: log it.
    --
    -- Only mail we actually emptied is logged. A take the server refused never
    -- reaches this branch (the wedge guard advances instead), and delete-read
    -- mode does not come through here at all -- an already-empty mail carries
    -- nothing worth recording.
    take.LogSnapshot()

    -- Delete it in "open" mode, keep it in "take" mode.
    if take.mode == take.MODE_OPEN then
        take.attempts = take.attempts + 1
        DeleteInboxItem(take.index)
        take.mails = take.mails + 1
        -- Deliberately no advance -- see the index discipline note at the top.
        return
    end

    take.mails = take.mails + 1
    take.Advance()
end

-- Flush the pending snapshot into the correspondence log.
function take.LogSnapshot()
    local snap = take.logSnap
    take.logSnap = nil
    if not snap then return nil end
    return A.db.LogAdd("received", snap)
end

-- Move to the next mail WITHOUT touching the server.
--
-- THE RUN'S CLOCK INVARIANT: every take.Step must either issue exactly one
-- server call -- and then wait for MAIL_INBOX_UPDATE to arm the next step --
-- or arm itself. There is no third option. take.armed is set by nothing but
-- that event, and the server only sends it after an operation it actually
-- performed, so a step that skips a mail produces no acknowledgement and
-- nothing would ever wake the engine again.
--
-- Every skip funnels through here (COD/GM mail, the wedge guard giving up, a
-- delete-read pass over mail that is not empty-and-read, and the terminal step
-- of a "take" that keeps the mail), so this is the one place that has to
-- re-arm. Leaving it out hung the run mid-inbox with take.running still true:
-- Open All stopped dead at the first COD mail and left everything after it
-- uncollected, and only the Stop button got the user out.
function take.Advance()
    take.index = take.index + 1
    take.attempts = 0
    take.lastSig = nil
    take.pending = nil
    -- Moving on without emptying the mail: drop the snapshot rather than log
    -- a collection that did not happen.
    take.logSnap = nil
    -- Self-clock: no server call was made, so no confirmation is coming.
    -- Advance always increases the index, so this cannot spin -- it walks to
    -- index > NumItems() and Finish() ends the run.
    if take.running then take.armed = true end
end

-- ---------------------------------------------------------------------------
-- Run control
-- ---------------------------------------------------------------------------

function take.Start(mode, only)
    if take.running then return false end
    if not inbox.NumItems or inbox.NumItems() == 0 then return false end
    take.running  = true
    take.mode     = mode or take.MODE_OPEN
    take.only     = only  -- nil = everything; "sold" = auction sales only
    take.codIndex = nil   -- Open All can never pay a COD. See take.Step.
    take.index    = 1
    take.attempts = 0
    take.lastSig  = nil
    take.pending  = nil
    take.logSnap  = nil
    ResetCounters()
    take.armed = true
    if A.ui and A.ui.OnTakeStateChanged then A.ui.OnTakeStateChanged() end
    return true
end

function take.Stop(quiet)
    if not take.running then return end
    -- Settle anything already in flight rather than dropping it: the money may
    -- well have arrived even though the user hit Stop.
    take.Confirm()
    take.running = false
    take.pending = nil
    take.codIndex = nil
    take.only = nil
    inbox.Flush()
    if not quiet then take.Report() end
    if A.ui and A.ui.OnTakeStateChanged then A.ui.OnTakeStateChanged() end
end

function take.Finish()
    take.running = false
    take.pending = nil
    take.codIndex = nil
    take.only = nil
    -- The inbox just changed shape for the last time; refresh now so
    -- inbox.lastUnread is current if the user closes the mailbox immediately
    -- (ui.SettleMailIcon reads it after the session is already gone).
    inbox.Flush()
    take.Report()
    if A.send and A.send.HarvestContacts then A.send.HarvestContacts() end
    if A.ui and A.ui.OnTakeStateChanged then A.ui.OnTakeStateChanged() end
end

function take.Report()
    if take.money <= 0 and take.items <= 0 and take.mails <= 0 then return end
    local parts = {}
    if take.money > 0 then
        table.insert(parts, A.util.FormatMoney(take.money, true) .. " collected")
    end
    if take.items > 0 then
        table.insert(parts, take.items .. " item" ..
            (take.items == 1 and "" or "s"))
    end
    if take.sales > 0 then
        table.insert(parts, take.sales .. " sale" ..
            (take.sales == 1 and "" or "s") .. " logged")
    end
    if table.getn(parts) > 0 then
        A.Print(table.concat(parts, ", ") .. ".")
    end
end

-- Take one specific mail, outside of a run -- the right-click action on a row.
-- Reuses the same machine so there is exactly one code path that mutates mail.
function take.Single(index)
    if take.running then return false end
    local h = inbox.Header(index)
    if not h then return false end
    if h.cod > 0 or h.isGM then
        A.Print("skipped: COD and GM mail are never taken automatically.")
        return false
    end
    if h.money == 0 and not h.hasItem then return false end
    take.running  = true
    take.mode     = take.MODE_OPEN
    take.only     = nil
    take.codIndex = nil
    take.index    = index
    take.attempts = 0
    take.lastSig  = nil
    take.pending  = nil
    take.logSnap  = nil
    ResetCounters()
    take.single   = true
    take.armed    = true
    if A.ui and A.ui.OnTakeStateChanged then A.ui.OnTakeStateChanged() end
    return true
end

-- Is this mail one the player could pay a COD on, and can they afford it?
--
-- Returns ok, reason. Split out from take.PayCOD so the UI can answer "should
-- the button be offered, and if not why" without starting anything -- the same
-- shape as send.Validate, and for the same reason: a rule the UI gates a
-- button on has to be askable without side effects, or the button and the
-- engine drift apart.
function take.CanPayCOD(index)
    if take.running then return false, "busy" end
    local h = inbox.Header(index)
    if not h then return false, "no such mail" end
    if h.isGM then return false, "GM mail" end
    if h.cod <= 0 then return false, "not COD" end
    if GetMoney and (GetMoney() or 0) < h.cod then
        return false, "you cannot afford this COD (" ..
            util.FormatMoney(h.cod, false) .. " needed)"
    end
    return true, nil
end

-- Pay a COD and collect the mail.
--
-- THE ONLY path in this addon that pays a COD, and the only caller is the
-- reader's two-step confirmation -- one click arms, a second click commits.
-- CLAUDE.md rule 21 bars COD from being taken AUTOMATICALLY, which is what
-- Open All, Delete Read and right-click still obey; it does not bar the player
-- from deliberately paying one they are looking at. Before this existed there
-- was no way to pay a COD at all while Courier's takeover held the Blizzard
-- mailbox hidden, and users were disabling the addon to collect their mail.
--
-- Runs on the same single-mail machine as take.Single so there is exactly one
-- code path that mutates mail; the ONLY difference is that it names its index
-- in take.codIndex, which take.Step consults before skipping a COD.
function take.PayCOD(index)
    local ok, why = take.CanPayCOD(index)
    if not ok then
        if why and why ~= "busy" and why ~= "not COD" then
            A.Print(why .. ".")
        end
        return false
    end
    take.running  = true
    take.mode     = take.MODE_OPEN
    take.only     = nil
    take.index    = index
    take.codIndex = index
    take.attempts = 0
    take.lastSig  = nil
    take.pending  = nil
    take.logSnap  = nil
    ResetCounters()
    take.single   = true
    take.armed    = true
    if A.ui and A.ui.OnTakeStateChanged then A.ui.OnTakeStateChanged() end
    return true
end

-- ---------------------------------------------------------------------------
-- Driver
-- ---------------------------------------------------------------------------
-- One hidden frame owns both the step clock and the passive CheckInbox pacing.
-- Shown while a mailbox is open, hidden otherwise, so we burn no OnUpdate
-- anywhere else in the game.

local driver = CreateFrame("Frame", "AegisCourierTaker")
driver:Hide()
local ticks = 0

driver:SetScript("OnUpdate", function()
    if take.armed then
        take.armed = false
        -- A single-mail take finishes as soon as its one mail is done rather
        -- than walking the rest of the inbox.
        if take.single and not take.running then take.single = nil end
        take.Step()
        if take.single and take.running then
            -- After Step, an emptied-and-deleted single mail leaves nothing
            -- pending and nothing in flight: stop rather than continue down
            -- the inbox.
            if not take.pending then
                take.single = nil
                take.Stop()
            end
        end
    end

    -- Coalesced refresh: one flush per frame at most, no matter how many
    -- MAIL_INBOX_UPDATE events landed in it. Runs during a take run too --
    -- the list has to repaint as mail disappears.
    if inbox.dirty then
        inbox.Flush()
    end

    if take.running then return end

    ticks = ticks + 1
    if ticks >= CHECK_TICKS then
        ticks = 0
        if CheckInbox then CheckInbox() end
    end
end)

function take.SetMailboxOpen(open)
    ticks = 0
    if open then
        driver:Show()
    else
        driver:Hide()
        if take.running then take.Stop(true) end
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- The server finished a mailbox operation: arm the next step. This is the
-- clock -- not a timer.
A.RegisterEvent("MAIL_INBOX_UPDATE", function()
    -- Per-event, deliberately: this is the server's acknowledgement clock for
    -- the take engine and must stay one Step per confirmation.
    if take.running then take.armed = true end
    -- Everything else waits for the driver's once-per-frame flush.
    inbox.MarkDirty()
end)

-- Error handling, following TurtleMail's split: a full bag is fatal to the
-- run, a per-item cap is not.
A.RegisterEvent("UI_ERROR_MESSAGE", function(evt, message)
    if not take.running then return end
    if message == INVENTORY_FULL or message == ERR_INV_FULL then
        A.Print("stopped: your bags are full.")
        take.Stop()
    elseif message == ERR_ITEM_MAX_COUNT then
        -- Cannot carry more of this ONE item; step over it and continue.
        -- Advance re-arms (see the clock invariant on take.Advance) -- this
        -- path is where that requirement was originally spotted, and it was
        -- the only place that honoured it.
        take.pending = nil
        take.Advance()
    end
end)
