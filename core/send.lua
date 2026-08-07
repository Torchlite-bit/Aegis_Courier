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

function send.Attach(bag, slot)
    if send.sending then return false end
    if send.Count() >= send.MAX_ATTACHMENTS then
        A.Print("attachment list is full (" .. send.MAX_ATTACHMENTS .. ").")
        return false
    end
    if send.IndexOf(bag, slot) then return false end
    local info = send.SlotInfo(bag, slot)
    if not info then return false end
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
function send.Validate(to, money, isCOD)
    if send.sending then return false, "already sending" end
    if type(to) ~= "string" or util.Trim(to) == "" then
        return false, "no recipient"
    end
    if send.Count() == 0 and (not money or money <= 0) then
        -- A bodiless, itemless, moneyless mail is legal but almost always a
        -- mistake, and vanilla requires a subject anyway.
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
    local ok, why = send.Validate(to, money, isCOD)
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
        -- Clear whatever may be in the slot, then place ours. ClearCursor
        -- between the two so a stray cursor item cannot be posted by mistake.
        if ClearCursor then ClearCursor() end
        ClickSendMailItemButton()
        if ClearCursor then ClearCursor() end

        if orig_PickupContainerItem then
            orig_PickupContainerItem(attachment.bag, attachment.slot)
        else
            PickupContainerItem(attachment.bag, attachment.slot)
        end
        ClickSendMailItemButton()

        -- Verify the attach actually landed. The stack may have moved, been
        -- sold, or be soulbound -- in which case SendMail would post an EMPTY
        -- mail and the item would silently stay behind.
        if GetSendMailItem and not GetSendMailItem() then
            if ClearCursor then ClearCursor() end
            A.Print("could not attach " .. (attachment.name or "item") ..
                " -- send stopped.")
            send.Abort()
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
    if send.sentCount > 0 then
        A.Print("sent " .. send.sentCount .. " mail" ..
            (send.sentCount == 1 and "" or "s") .. " to " .. send.to .. ".")
    end
    -- The batch succeeded, so the composed mail is done with.
    send.attachments = {}
    send.subject = ""
    send.body = ""
    send.money = 0
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

-- Seconds to let the mail system settle between a confirmed send and the next
-- one. Courier used to issue the next mail on the very next OnUpdate frame,
-- about 16ms after the server's acknowledgement, and batches were coming back
-- with the second mail rejected. This is a mitigation rather than a proven
-- root cause -- see the MAIL_FAILED handler, which is what actually makes a
-- batch survive a rejection -- but it costs a few seconds on a 12-item send
-- and removes a whole class of race.
send.SETTLE = 0.3

-- Longer pause before re-attempting a mail the server just refused.
send.RETRY_WAIT = 1.0

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

A.RegisterEvent("MAIL_SEND_SUCCESS", function()
    if not send.sending then return end
    send.sentCount = send.sentCount + 1
    send.retries = 0            -- progress: the next mail gets a clean budget
    send.inFlight = nil         -- this one is the server's problem now
    -- Logged on CONFIRMATION, matching the take engine: a mail the server
    -- never accepted is not a mail you sent.
    if send.lastSent then
        A.db.LogAdd("sent", send.lastSent)
        send.lastSent = nil
    end
    if send.queue and table.getn(send.queue) > 0 then
        send.Arm(send.SETTLE)   -- more items: next mail once things settle
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
A.RegisterEvent("MAIL_INBOX_UPDATE", function()
    if not A.inbox then return end
    local n = A.inbox.NumItems()
    local i = 1
    while i <= n do
        local h = A.inbox.Header(i)
        -- canReply excludes the auction house and other system senders.
        if h and h.canReply and not h.isGM and not h.fromAuctionHouse then
            A.db.AddContact(h.sender)
        end
        i = i + 1
    end
end)

A.OnLoad(function()
    send.InstallHooks()
    if UnitName then A.db.AddContact(UnitName("player")) end
end)
