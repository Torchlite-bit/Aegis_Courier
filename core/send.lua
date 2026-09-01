-- Aegis: Courier
-- core/send.lua
--
-- Outgoing mail: the attachment list and the send engine.
--
-- WHY THIS EXISTS AT ALL. Vanilla mail carries exactly ONE attachment per
-- message -- there is a single slot and a single GetSendMailItem(). "Mail 12
-- items at once" is therefore not a bigger slot, it is TWELVE MAILS sent back
-- to back, each with one item, driven off MAIL_SEND_SUCCESS. That is what
-- TurtleMail does and it is the only way it can work on this client. The user
-- pays postage per mail, so the cost preview must multiply.
--
-- ADDING A .LUA FILE COSTS A CLIENT RESTART (1.12 reads the .toc at startup).
-- Stage B deliberately avoided that by hosting the take engine in
-- core/inbox.lua, where it genuinely belonged. Sending has no such home: it is
-- not the inbox, not the DB, not the UI. So this file is added and 0.3.0 is
-- marked **restart** in CHANGELOG.md -- the escape hatch CLAUDE.md documents,
-- used deliberately rather than by accident.
--
-- The C API used here (SendMail, ClickSendMailItemButton, GetSendMailItem,
-- SetSendMailMoney, SetSendMailCOD, GetSendMailPrice) is all engine-level, NOT
-- FrameXML Lua, so it works with the Blizzard MailFrame hidden -- which is the
-- state Courier keeps it in. Only the thin wrappers (SendMailFrame_SendMail
-- and friends) live in FrameXML, and we do not use them.

local A = AegisCourier
A.send = {}
local send = A.send
local util = A.util

-- Attachment slots we offer. Vanilla sends one item per mail regardless; this
-- is purely how many we will queue up in one go. TurtleMail allows 21; 12 fits
-- a clean grid and is already more than a bag's worth of distinct stacks.
send.MAX_ATTACHMENTS = 12

-- Re-attempts allowed for a SINGLE mail before the batch gives up. Reset on
-- every success, so this is a per-mail budget, not a per-batch one.
send.MAX_RETRIES = 3

send.attachments = {}   -- array of { bag, slot, name, texture, count }
send.sending     = false
send.queue       = nil  -- attachments remaining this run
send.total       = 0    -- mails this run will produce
send.sentCount   = 0

-- ---------------------------------------------------------------------------
-- Cursor tracking
-- ---------------------------------------------------------------------------
-- 1.12 has NO GetCursorInfo(). Once an item is on the cursor the client will
-- only tell you THAT one is there (CursorHasItem()), never which. So the only
-- way to know what the user is dragging is to remember where it came from --
-- we save-and-replace the container pickup functions and record the origin.
-- This is the standard vanilla trick and the one TurtleMail uses.

send.cursorItem = nil   -- { bag, slot } most recently picked up

local orig_PickupContainerItem
local orig_UseContainerItem
local orig_SplitContainerItem

local function RememberCursor(bag, slot)
    send.cursorItem = { bag = bag, slot = slot }
end

-- ---------------------------------------------------------------------------
-- Locating an attachment at send time
-- ---------------------------------------------------------------------------
-- A queued attachment is a bag COORDINATE, and 1.12 gives us nothing better:
-- there is no handle on a stack, so {bag, slot} is the only address available.
-- It is also not stable. Between queueing an item and actually mailing it --
-- which on a 12-item batch can be a minute and eleven mails later -- the stack
-- can be locked by the server, can move, or can leave the bags entirely.
--
-- Trusting the coordinate produced the reported "could not attach X -- send
-- stopped": the run walked into a locked or moved slot, PickupContainerItem
-- silently did nothing, and the whole remaining queue was thrown away.
--
-- Worse, the old verification only asked whether SOMETHING was attached. If a
-- different item had moved into the remembered slot, that check passed and the
-- wrong item was mailed. Everything below exists to make the address good
-- again at the moment of use, and to fail one ITEM rather than the batch.

send.SLOT_OK     = "ok"      -- coordinate is good (possibly after relocating)
send.SLOT_LOCKED = "locked"  -- the server holds it; wait, do not touch
send.SLOT_GONE   = "gone"    -- not in the bags at all

-- Find an UNLOCKED stack called `name`.
--
-- Returns bag, slot, false when one is found. When none is usable, returns
-- nil, nil, sawLocked -- the flag distinguishing "it is here but the server has
-- it" from "it is not here", which is the difference between waiting and
-- giving up. 1.12 has containers 0 (backpack) through 4.
function send.FindItemSlot(name)
    if not GetContainerNumSlots or not GetContainerItemLink then
        return nil, nil, false
    end
    if type(name) ~= "string" or name == "" or name == "?" then
        return nil, nil, false
    end
    local sawLocked = false
    local bag = 0
    while bag <= 4 do
        local slots = GetContainerNumSlots(bag) or 0
        local slot = 1
        while slot <= slots do
            local link = GetContainerItemLink(bag, slot)
            if link and util.ItemNameFromLink(link) == name then
                -- THIRD return. GetContainerItemInfo gives
                -- texture, itemCount, locked, quality, readable -- and
                -- PickupContainerItem on a locked slot is a silent no-op, so
                -- reading past the second value is not optional.
                local _, _, locked = GetContainerItemInfo(bag, slot)
                if locked then
                    sawLocked = true
                else
                    return bag, slot, false
                end
            end
            slot = slot + 1
        end
        bag = bag + 1
    end
    return nil, nil, sawLocked
end

-- Re-validate a queued attachment against the bags RIGHT NOW, rewriting its
-- coordinate in place if the stack moved. Never called from a paint or an
-- event -- only from the step that is about to pick the item up.
function send.ResolveSlot(att)
    if not att then return send.SLOT_GONE end
    -- A client without the container API is not one we can second-guess; the
    -- old blind behaviour is the only option there.
    if not GetContainerItemInfo then return send.SLOT_OK end

    local texture, _, locked = GetContainerItemInfo(att.bag, att.slot)
    if texture then
        if locked then return send.SLOT_LOCKED end
        local link = GetContainerItemLink and GetContainerItemLink(att.bag, att.slot)
        local here = link and util.ItemNameFromLink(link)
        -- `here` nil means the link could not be read; there is nothing to
        -- compare against, so trust the coordinate rather than invent a fault.
        if not att.name or att.name == "?" or not here or here == att.name then
            return send.SLOT_OK
        end
    end

    -- The slot is empty, or something else is sitting in it. Names are all we
    -- have to go on -- there is no itemID from a bag slot worth trusting here.
    local bag, slot, sawLocked = send.FindItemSlot(att.name)
    if bag then
        att.bag, att.slot = bag, slot
        return send.SLOT_OK
    end
    if sawLocked then return send.SLOT_LOCKED end
    return send.SLOT_GONE
end

-- Read what is in a bag slot. GetContainerItemLink is present on 1.12, so the
-- NAME is obtainable here -- unlike the inbox, which has no link at all.
function send.SlotInfo(bag, slot)
    if not GetContainerItemInfo then return nil end
    local texture, count = GetContainerItemInfo(bag, slot)
    if not texture then return nil end
    local name
    if GetContainerItemLink then
        name = util.ItemNameFromLink(GetContainerItemLink(bag, slot))
    end
    return { bag = bag, slot = slot, name = name or "?",
        texture = texture, count = count or 1 }
end

function send.InstallHooks()
    if send.hooked then return end

    orig_PickupContainerItem = PickupContainerItem
    PickupContainerItem = function(bag, slot)
        RememberCursor(bag, slot)
        return orig_PickupContainerItem(bag, slot)
    end

    orig_SplitContainerItem = SplitContainerItem
    SplitContainerItem = function(bag, slot, amount)
        RememberCursor(bag, slot)
        return orig_SplitContainerItem(bag, slot, amount)
    end

    -- Right-click in a bag attaches instead of using the item -- but ONLY
    -- while our Send tab is actually in front of the user at a mailbox.
    -- Everywhere else right-click keeps its normal meaning, so eating food or
    -- opening a container still works exactly as it always did.
    orig_UseContainerItem = UseContainerItem
    UseContainerItem = function(bag, slot, onself)
        if A.ui and A.ui.SendAttachActive and A.ui.SendAttachActive() then
            if send.Attach(bag, slot) then return end
        end
        return orig_UseContainerItem(bag, slot, onself)
    end

    send.hooked = true
end

-- ---------------------------------------------------------------------------
-- Attachment list
-- ---------------------------------------------------------------------------

function send.Count()
    return table.getn(send.attachments)
end

-- Is this bag slot already queued? Attaching the same stack twice would send
-- the first mail then fail on the second, because the item has moved.
function send.IndexOf(bag, slot)
    local n = send.Count()
    local i = 1
    while i <= n do
        local a = send.attachments[i]
        if a.bag == bag and a.slot == slot then return i end
        i = i + 1
    end
    return nil
end

-- Is this stack something the mail will actually carry?
--
-- Ported from TurtleMail's `sendmail_pickup_mailable`, and the technique is
-- the only one 1.12 offers: there is no "can this be mailed" flag anywhere in
-- the API, so the only way to find out is to TRY it and put it straight back.
-- Five calls, no server round trip, no event -- the attachment slot is client
-- state until SendMail is called.
--
--     empty the slot -> pick the stack up -> attach -> look -> take it back off
--
-- This is asked when the user ADDS an item to the list, which is the whole
-- point. Courier used to discover it mid-batch and report "this item cannot be
-- mailed" from inside the send loop, where it was both too late to act on and
-- wrong: the same message fired on a perfectly mailable Formula whose attach
-- had merely lost a race. A question with a definite answer belongs where the
-- user can still do something about it.
function send.IsMailable(bag, slot)
    -- Needs a LIVE mail session. Without one the attach silently does nothing
    -- and GetSendMailItem answers nil for everything -- which would condemn
    -- every item in the game as unmailable. Away from a mailbox, say yes and
    -- let the send loop find out.
    if not send.atMailbox then return true end
    if not ClickSendMailItemButton or not GetSendMailItem then return true end
    -- Never while a batch is in flight: this moves the attachment slot.
    if send.sending then return true end

    if ClearCursor then ClearCursor() end
    ClickSendMailItemButton()
    if ClearCursor then ClearCursor() end

    if orig_PickupContainerItem then
        orig_PickupContainerItem(bag, slot)
    else
        PickupContainerItem(bag, slot)
    end
    ClickSendMailItemButton()
    local ok = GetSendMailItem() and true or false
    -- Take it back off whatever the answer was, and put the cursor down. The
    -- slot must be left exactly as it was found -- this is a probe, not a
    -- send, and anything left attached here would be posted by the next mail.
    ClickSendMailItemButton()
    if ClearCursor then ClearCursor() end
    return ok
end

function send.Attach(bag, slot)
    if send.sending then return false end
    if send.Count() >= send.MAX_ATTACHMENTS then
        A.Print("attachment list is full (" .. send.MAX_ATTACHMENTS .. ").")
        return false
    end
    if send.IndexOf(bag, slot) then return false end
    local info = send.SlotInfo(bag, slot)
    if not info then return false end
    if not send.IsMailable(bag, slot) then
        A.Print((info.name or "that item") .. " cannot be mailed.")
        return false
    end
    table.insert(send.attachments, info)
    if A.ui and A.ui.RefreshSend then A.ui.RefreshSend() end
    return true
end

-- Attach whatever the cursor is carrying, using the origin we recorded.
function send.AttachCursor()
    if not send.cursorItem then return false end
    local c = send.cursorItem
    local ok = send.Attach(c.bag, c.slot)
    if ok and ClearCursor then ClearCursor() end
    return ok
end

function send.Detach(index)
    if send.sending then return false end
    if not send.attachments[index] then return false end
    table.remove(send.attachments, index)
    if A.ui and A.ui.RefreshSend then A.ui.RefreshSend() end
    return true
end

function send.ClearAttachments()
    send.attachments = {}
    if A.ui and A.ui.RefreshSend then A.ui.RefreshSend() end
end

-- ---------------------------------------------------------------------------
-- Cost
-- ---------------------------------------------------------------------------

-- Number of mails a send will produce: one per attachment, minimum one.
function send.MailCount()
    local n = send.Count()
    if n < 1 then return 1 end
    return n
end

-- Total postage. Per MAIL, not per send -- this is the number the stock UI
-- gets wrong for a multi-item send because it never imagines one.
function send.Postage()
    if not GetSendMailPrice then return 0 end
    return (GetSendMailPrice() or 0) * send.MailCount()
end

-- Everything leaving the player's purse: postage plus any attached money.
-- COD money is COLLECTED, not spent, so it is excluded.
function send.TotalCost(money, isCOD)
    local total = send.Postage()
    if money and money > 0 and not isCOD then
        total = total + money
    end
    return total
end

-- Can this be sent? Returns (ok, reasonText).
function send.Validate(to, money, isCOD, subject, body)
    if send.sending then return false, "already sending" end
    if type(to) ~= "string" or util.Trim(to) == "" then
        return false, "no recipient"
    end
    -- A LETTER IS A MAIL. This used to refuse anything carrying neither an
    -- item nor gold, on the theory that such a mail is "almost always a
    -- mistake" -- which is simply wrong. Writing to someone is the most
    -- ordinary use of a mailbox there is, and refusing it made the Send tab
    -- unusable for anything but parcels.
    --
    -- What is genuinely a mistake is a mail with NOTHING in it: no item, no
    -- gold, no subject and no body. That is still refused, and it is the only
    -- thing that is.
    if send.Count() == 0 and (not money or money <= 0)
        and util.Trim(subject or "") == ""
        and util.Trim(body or "") == "" then
        return false, "nothing to send"
    end
    if isCOD and send.Count() == 0 then
        return false, "COD needs an item"
    end
    local need = send.TotalCost(money, isCOD)
    if GetMoney and need > (GetMoney() or 0) then
        return false, "not enough gold (" .. util.FormatMoney(need, false) ..
            " needed)"
    end
    return true, nil
end

-- ---------------------------------------------------------------------------
-- The send engine
-- ---------------------------------------------------------------------------

-- Begin a send. `money` is copper; when `isCOD` it is charged to the
-- RECIPIENT instead of attached. `codAll` applies the COD to every mail of a
-- batch rather than only the first -- the distinction TurtleMail exposes,
-- because "50g COD" on a 10-item batch means very different things.
function send.Start(to, subject, body, money, isCOD, codAll)
    local ok, why = send.Validate(to, money, isCOD, subject, body)
    if not ok then
        A.Print("cannot send: " .. (why or "?"))
        return false
    end

    send.to      = util.Trim(to)
    send.subject = util.Trim(subject or "")
    send.body    = body or ""
    send.money   = money or 0
    send.isCOD   = isCOD and true or false
    send.codAll  = codAll and true or false

    -- Work on a copy: the user's attachment list stays intact until the whole
    -- batch succeeds, so a failure halfway leaves something to retry.
    send.queue = {}
    local n = send.Count()
    local i = 1
    while i <= n do
        table.insert(send.queue, send.attachments[i])
        i = i + 1
    end

    send.total     = send.MailCount()
    send.sentCount = 0
    send.skipped   = 0
    send.sentRec   = nil    -- opened by the first confirmed mail, not here
    -- Wall clock for the batch. GetTime is the client's high-resolution timer;
    -- time() is whole seconds and would round a fast batch to nothing. This
    -- exists because "is it faster now?" was not answerable by feel -- a batch
    -- that reports its own cost turns that into a number.
    send.startedAt = (GetTime and GetTime()) or nil
    send.retries   = 0
    send.inFlight  = nil
    send.sending   = true
    send.Arm()
    if A.ui and A.ui.RefreshSend then A.ui.RefreshSend() end
    return true
end

-- Compose the subject for mail number `n` of the batch.
function send.SubjectFor(n, attachment)
    local subject = send.subject
    if subject == "" then
        -- Auto-subject from the item, matching TurtleMail: "Silk Cloth (20)".
        if attachment then
            subject = attachment.name or "?"
            if attachment.count and attachment.count > 1 then
                subject = subject .. " (" .. attachment.count .. ")"
            end
        else
            subject = "(no subject)"
        end
    elseif send.total > 1 then
        subject = subject .. " [" .. n .. "/" .. send.total .. "]"
    end
    -- Vanilla caps the subject; keep well inside it.
    if string.len(subject) > 64 then
        subject = string.sub(subject, 1, 64)
    end
    return subject
end

-- Send ONE mail. Called once per step, then we wait for MAIL_SEND_SUCCESS.
-- How often to re-check a slot the server has locked, and how many times
-- before we conclude it is never coming back. ~2s, which is far longer than a
-- normal lock and still short enough not to look like a hang.
send.LOCK_WAIT      = 0.1
send.MAX_LOCK_WAITS = 20

-- Give up on ONE attachment and carry on with the rest of the batch.
--
-- This is the whole point of the change. Failing an item costs the user that
-- item; failing the batch costs them everything still queued and makes them
-- rebuild the list by hand -- which is what "send stopped" used to do, and the
-- same mistake MAIL_FAILED was already fixed for.
local function SkipAttachment(att, why)
    A.Print("skipped " .. ((att and att.name) or "an item") .. " -- " .. why)
    send.skipped = (send.skipped or 0) + 1
    -- Keep the "sending 3 of 10" counter honest about what is left to do.
    if send.total and send.total > 1 then send.total = send.total - 1 end
    send.inFlight = nil
    send.lastSent = nil
    if send.queue and table.getn(send.queue) > 0 then
        send.Arm(0)
    else
        send.Finish()
    end
end

-- The stack is busy: put it back at the head of the queue and look again in a
-- moment, within a budget, rather than blaming the item.
--
-- Shared by the two ways a busy stack shows itself. The cached `locked` flag
-- is one of them; a pickup that quietly does nothing is the other, and it is
-- the one that reached users as "the game would not attach it". Both are the
-- same transient condition and both deserve the same patience, so they share
-- one budget -- otherwise an item could alternate between them and wait
-- forever.
--
-- Returns true when the caller should return immediately (still waiting), and
-- false once the budget is spent and the attachment has been skipped.
local function WaitForBusySlot(attachment)
    attachment.lockWaits = (attachment.lockWaits or 0) + 1
    if attachment.lockWaits <= send.MAX_LOCK_WAITS then
        table.insert(send.queue, 1, attachment)
        send.inFlight = nil
        send.Arm(send.LOCK_WAIT)
        return true
    end
    -- Busy for two solid seconds. Treat it as unreachable rather than hold the
    -- rest of the batch hostage to one stack.
    SkipAttachment(attachment, "your bags are busy with it.")
    return false
end

function send.Step()
    if not send.sending then return end

    local attachment = nil
    if send.queue and table.getn(send.queue) > 0 then
        attachment = table.remove(send.queue, 1)
    end
    -- Held until the server confirms, so a rejected mail can be put back at
    -- the head of the queue and retried rather than losing the whole batch.
    send.inFlight = attachment

    if attachment then
        -- THE FAST PATH, and it is TurtleMail's, call for call:
        --
        --     ClearCursor(); ClickSendMailItemButton(); ClearCursor()
        --     PickupContainerItem(bag, slot)
        --     ClickSendMailItemButton()
        --     if not GetSendMailItem() then ... end
        --
        -- Nothing is inspected BEFORE the pickup. Courier used to re-resolve
        -- the coordinate and poll `locked` on every item first, which is
        -- correct but expensive: relocating costs a full walk of five bags
        -- with a link read and a pattern match per slot, and a `locked` slot
        -- costs a 0.1s wait -- and `locked` reads set right after the previous
        -- mail's BAG_UPDATE constantly. Paid per item, that is most of the gap
        -- users measured against TurtleMail side by side.
        --
        -- The insight is that the check is only worth paying for when
        -- something actually went wrong, and the attach VERIFICATION below
        -- already detects that for free. So: charge ahead like TurtleMail, and
        -- fall back to the careful path only on failure. A healthy item now
        -- costs exactly what it costs TurtleMail; a problem item still gets
        -- every bit of the relocating and lock-waiting it used to.
        --
        -- The FIRST click still has to happen, and before anything else: a
        -- mail the server refused leaves its item sitting in the attachment
        -- slot rather than back in the bags, and the attach below cannot land
        -- while it is parked there. ClearCursor on either side so a stray
        -- cursor item cannot be posted by mistake, and so the item this click
        -- lifts off goes home.
        if ClearCursor then ClearCursor() end
        ClickSendMailItemButton()
        if ClearCursor then ClearCursor() end

        if orig_PickupContainerItem then
            orig_PickupContainerItem(attachment.bag, attachment.slot)
        else
            PickupContainerItem(attachment.bag, attachment.slot)
        end
        ClickSendMailItemButton()

        -- Verify the attach landed AND that it landed with the RIGHT item.
        --
        -- "Is something attached?" is not the same question as "is the thing I
        -- queued attached?" -- a stack that moved out and was replaced passes
        -- the first and mails the WRONG item to the recipient, silently. This
        -- is the one check TurtleMail does not make and the one place Courier
        -- deliberately does not copy it (CLAUDE.md rule 24).
        local onSlot = GetSendMailItem and GetSendMailItem()
        local wrong = onSlot and attachment.name and attachment.name ~= "?"
            and onSlot ~= attachment.name

        if GetSendMailItem and (not onSlot or wrong) then
            -- Take whatever is on the slot back off before it can be posted,
            -- and put the cursor down, so the recovery below starts from the
            -- same clean state the step began with.
            if onSlot then ClickSendMailItemButton() end
            if ClearCursor then ClearCursor() end

            -- RECOVERY. Now -- and only now -- pay for the careful path.
            local status = send.ResolveSlot(attachment)
            if status == send.SLOT_LOCKED then
                -- The stack is busy. Routine: the previous mail's BAG_UPDATE
                -- has not landed. Wait rather than blaming the item.
                WaitForBusySlot(attachment)
                return
            end
            if status == send.SLOT_GONE then
                SkipAttachment(attachment, "it is no longer in your bags.")
                return
            end
            -- The slot resolved clean, so the coordinate is good now even
            -- though the attach just failed on it -- either the stack moved
            -- and ResolveSlot has rewritten the address, or the server was
            -- holding it a moment ago with `locked` not yet set. Both are
            -- worth one more attempt, on the same budget, rather than a
            -- verdict about the item.
            if wrong then
                -- Exception: a different item really was in the slot. Say so,
                -- because retrying an address that resolves to the wrong stack
                -- is how the wrong thing gets mailed.
                SkipAttachment(attachment, "it moved in your bags mid-send.")
                return
            end
            WaitForBusySlot(attachment)
            return
        end
    end

    -- Money rides on the FIRST mail only, otherwise a 10-item batch would send
    -- the same gold ten times. COD is a charge to the recipient, so it can
    -- legitimately repeat -- but only when the user asked for that.
    --
    -- Only ever touch the channel we are actually using. The previous version
    -- zeroed BOTH on every later mail, which meant a plain gold send called
    -- SetSendMailCOD(0) on mails 2..n -- poking the outgoing mail into COD
    -- mode with a zero amount purely to clear something that was never set.
    -- TurtleMail never calls either setter unless an amount applies, and it is
    -- the implementation known to work on this client.
    local n = send.sentCount + 1
    local appliedMoney = 0
    if send.money > 0 then
        local applies = (n == 1) or (send.isCOD and send.codAll)
        if applies then
            appliedMoney = send.money
            if send.isCOD then
                if SetSendMailCOD then SetSendMailCOD(send.money) end
            else
                if SetSendMailMoney then SetSendMailMoney(send.money) end
            end
        elseif send.isCOD then
            -- COD, first-mail-only: clear the COD we set, nothing else.
            if SetSendMailCOD then SetSendMailCOD(0) end
        else
            -- Gold, first-mail-only: clear the gold we set, nothing else.
            if SetSendMailMoney then SetSendMailMoney(0) end
        end
    end

    local subject = send.SubjectFor(n, attachment)

    -- Remember what THIS mail carried so it can be logged once the server
    -- confirms it. Each mail of a batch is a real, separate mail and gets its
    -- own log entry.
    send.lastSent = {
        who     = send.to,
        subject = subject,
        item    = attachment and attachment.name or nil,
        count   = attachment and attachment.count or nil,
        -- Carried for the sent box's reader. A sent mail leaves the client
        -- entirely -- there is no API to read one back -- so anything the
        -- reader will want has to be captured here or it is gone for good.
        texture = attachment and attachment.texture or nil,
        money   = (not send.isCOD) and appliedMoney or 0,
        cod     = send.isCOD and appliedMoney or 0,
    }

    SendMail(send.to, subject, send.body)
end

function send.Abort()
    -- Anything still in flight was never sent; put it back on the list so the
    -- user can retry rather than discovering it silently vanished.
    if send.inFlight and send.queue then
        table.insert(send.queue, 1, send.inFlight)
    end
    send.inFlight = nil
    send.sending = false
    send.lastSent = nil
    send.queue = nil
    send.armed = false
    if A.ui and A.ui.RefreshSend then A.ui.RefreshSend() end
end

function send.Finish()
    send.sending = false
    send.queue = nil
    send.armed = false
    A.db.AddContact(send.to)
    -- Measured, not estimated. Kept on send.lastElapsed so it can be asserted
    -- rather than eyeballed.
    send.lastElapsed = nil
    if send.startedAt and GetTime then
        send.lastElapsed = GetTime() - send.startedAt
    end

    if send.sentCount > 0 then
        local line = "sent " .. send.sentCount .. " mail" ..
            (send.sentCount == 1 and "" or "s") .. " to " .. send.to
        if send.lastElapsed then
            line = line .. " in " .. util.FormatSeconds(send.lastElapsed)
        end
        -- Say what was left behind. A partial run that reports only its
        -- successes reads as a complete one, and the user never goes looking
        -- for the item still sitting in their bags.
        if (send.skipped or 0) > 0 then
            line = line .. " (" .. send.skipped .. " skipped)"
        end
        A.Print(line .. ".")
    elseif (send.skipped or 0) > 0 then
        A.Print("nothing was sent: all " .. send.skipped ..
            " attachments were unavailable.")
    end
    -- A run that got NOTHING out leaves the compose form alone. Every item is
    -- still in the player's bags in that case -- the game refused to attach
    -- them, or they were busy -- and wiping the list would make them rebuild a
    -- twelve-item selection by hand to try again.
    if send.sentCount > 0 then
        send.attachments = {}
        send.subject = ""
        send.body = ""
        send.money = 0
    end
    if A.ui and A.ui.OnSendComplete then A.ui.OnSendComplete() end
end

-- ---------------------------------------------------------------------------
-- Driver
-- ---------------------------------------------------------------------------
-- Every send is issued from an OnUpdate tick, never straight out of the event
-- handler that triggered it. Calling SendMail from inside MAIL_SEND_SUCCESS
-- means re-entering the mail system while the client is still unwinding the
-- previous send; TurtleMail defers through a flag consumed in its OnUpdate for
-- exactly this reason, and a batch send is the one place it matters.

local driver = CreateFrame("Frame", "AegisCourierSender")
driver:Hide()
local waited = 0

-- THERE IS NO SETTLE. The next mail goes out on the next OnUpdate frame after
-- the server's acknowledgement, which is exactly what TurtleMail does.
--
-- Courier used to ESCALATE a delay: every MAIL_FAILED added 0.3s, up to 0.9s,
-- and KEPT it for the rest of the batch, on the theory that a server which
-- refused once will refuse again. The effect was that one hiccup on mail two
-- taxed all ten remaining mails -- nearly nine seconds on a twelve-item send
-- -- and refusals are common enough in the field that users paid it often.
--
-- TurtleMail has no such delay and does not need one, which is the evidence
-- that this was insuring against the wrong thing. What actually makes a batch
-- survive a refusal is the MAIL_FAILED retry below, and that is per mail and
-- resets on success. If a pause between mails ever looks necessary again,
-- MEASURE it -- do not reintroduce a delay every mail pays for one mail's
-- problem.
send.SETTLE = 0

-- Pause before re-attempting the ONE mail the server just refused. It applies
-- to that mail alone and never to the rest of the batch.
send.RETRY_WAIT = 0.3

driver:SetScript("OnUpdate", function()
    if not send.armed then
        driver:Hide()
        waited = 0
        return
    end
    -- 1.12 passes the frame delta in the arg1 GLOBAL, not as a parameter.
    waited = waited + (arg1 or 0)
    if waited < (send.wait or 0) then return end
    waited = 0
    send.armed = false
    send.Step()
end)

-- `wait` is seconds to hold off before the next Step; nil means immediately.
function send.Arm(wait)
    send.wait = wait or 0
    waited = 0
    send.armed = true
    driver:Show()
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- Purely an ACCELERATOR for a step waiting on a locked slot: when the lock
-- clears, go now instead of burning the rest of the 100ms re-check.
--
-- It must never be the only thing that wakes the run. This event is not a
-- promise -- it does not reliably fire for every lock transition on every
-- server build, and a run that depended on it would hang exactly the way the
-- take engine did before its clock invariant was fixed. The timed re-check in
-- send.Step is the real mechanism; this only makes it feel quicker.
A.RegisterEvent("ITEM_LOCK_CHANGED", function()
    if not send.sending then return end
    if send.armed and (send.wait or 0) > 0 then
        send.Arm(0)
    end
end)

A.RegisterEvent("MAIL_SEND_SUCCESS", function()
    if not send.sending then return end
    send.sentCount = send.sentCount + 1
    send.retries = 0            -- progress: the next mail gets a clean budget
    send.inFlight = nil         -- this one is the server's problem now
    -- Recorded on CONFIRMATION, matching the take engine: a mail the server
    -- never accepted is not a mail you sent. This is also why nothing hooks
    -- SendMail itself -- the call returning tells you nothing, and MAIL_FAILED
    -- can still arrive afterwards.
    if send.lastSent then
        -- The sent box groups a batch into ONE record. The record is opened by
        -- the first mail the server confirms rather than by pressing Send, so
        -- a batch that got nothing out leaves nothing behind, and one abandoned
        -- halfway keeps exactly what actually went.
        if not send.sentRec then
            send.sentRec = A.db.SentBegin(send.to, send.subject,
                (not send.isCOD) and send.money or 0,
                send.isCOD and send.money or 0,
                send.body)
        end
        A.db.SentAdd(send.sentRec, send.lastSent.item, send.lastSent.count,
            send.lastSent.texture)
        send.lastSent = nil
    end
    if send.queue and table.getn(send.queue) > 0 then
        send.Arm(0)   -- more items: next mail on the very next frame
    else
        send.Finish()
    end
end)

-- A rejected mail no longer throws the rest of the batch away.
--
-- MAIL_FAILED means the mail did NOT go out, so putting the attachment back
-- and trying again cannot duplicate anything -- which is what makes a retry
-- safe here. Courier previously abandoned the whole run on the first refusal,
-- so a user mailing twelve items and hitting one transient rejection on the
-- second lost the other ten and had to start over. That is the behaviour
-- being reported, whatever is provoking the refusal underneath.
--
-- The budget is per-mail and resets on every success, so a long batch is not
-- capped globally; only a mail that fails repeatedly gives up.
A.RegisterEvent("MAIL_FAILED", function()
    if not send.sending then return end

    send.retries = (send.retries or 0) + 1
    if send.retries <= send.MAX_RETRIES then
        -- Put the attachment back at the head of the queue. sentCount did not
        -- move, so the retry re-derives the same mail number, the same subject
        -- and the same money placement.
        if send.inFlight then
            table.insert(send.queue, 1, send.inFlight)
            send.inFlight = nil
        end
        send.lastSent = nil
        send.Arm(send.RETRY_WAIT)
        return
    end

    -- Out of budget. Report what we know, and leave the unsent attachments in
    -- the list so the user can hit Send again rather than rebuilding it.
    local left = send.queue and table.getn(send.queue) or 0
    if send.inFlight then
        table.insert(send.queue, 1, send.inFlight)
        send.inFlight = nil
        left = left + 1
    end
    A.Print("the server kept rejecting mail " .. (send.sentCount + 1) ..
        " of " .. send.total .. " (" .. send.sentCount .. " sent, " ..
        left .. " still attached). Try again, or send them individually.")
    send.Abort()
end)

-- Anyone who mails us is by definition reachable, so harvest the name. This
-- is the same source TurtleMail uses, minus its hook on GetInboxHeaderInfo --
-- we already read every header in inbox.All().
--
-- NOT on MAIL_INBOX_UPDATE. That event storms on a first mailbox open while
-- the client resolves uncached items, and this walks every header -- one of
-- the five full inbox walks per event that made a big mailbox freeze the
-- client. Contact names do not need per-event freshness: the set can only
-- change when the inbox itself changes, so opening the mailbox and finishing
-- a take run are the only moments worth harvesting at.
function send.HarvestContacts()
    if not A.inbox then return 0 end
    local added = 0
    local n = A.inbox.NumItems()
    local i = 1
    while i <= n do
        local h = A.inbox.Header(i)
        -- canReply excludes the auction house and other system senders.
        if h and h.canReply and not h.isGM and not h.fromAuctionHouse then
            A.db.AddContact(h.sender)
            added = added + 1
        end
        i = i + 1
    end
    return added
end

-- The mail session, tracked here rather than read off the UI: send.IsMailable
-- probes the real attachment slot and must never do so without a live session.
send.atMailbox = false
A.RegisterEvent("MAIL_SHOW",   function() send.atMailbox = true  end)
A.RegisterEvent("MAIL_CLOSED", function() send.atMailbox = false end)

A.OnLoad(function()
    send.InstallHooks()
    if UnitName then A.db.AddContact(UnitName("player")) end
end)
