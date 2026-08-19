-- Stubbed WoW 1.12 / Lua 5.0 environment for testing Aegis: Courier off-client.
-- Run with lua5.1 from the repo root.

-- ---- Lua 5.0 shims (we run on 5.1 here; the addon targets 5.0) -----------
math.mod = math.fmod
string.gfind = string.gmatch
time = os.time   -- WoW exposes time() as a global

local failures, checks = 0, 0
local function check(cond, label, extra)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        print("  FAIL: " .. label .. (extra and ("  [" .. tostring(extra) .. "]") or ""))
    end
end

-- ---- Frame mock ----------------------------------------------------------
--
-- The fallback below absorbs the hundreds of widget methods the addon calls
-- without implementing each one. It must NOT do the same for data fields: an
-- earlier version returned a no-op function for every unknown key, so
-- `frame.text` and `frame.backdrop` came back as functions -- truthy, and
-- silently wrong wherever the addon tested them. That cost two debugging
-- rounds before it was pinned down.
--
-- WoW widget methods are CamelCase (SetPoint, GetObjectType); the fields this
-- addon and pfUI attach are lowercase (backdrop, labelText, mailIndex). So the
-- initial capital is the discriminator: methods get a no-op, data fields get
-- nil like a real table. Accessors additionally use rawget.
local function MockIndex(_, key)
    if type(key) == "string" and string.find(key, "^%u") then
        return function() end
    end
    return nil
end

local function newRegion()
    local r = { visible = true }
    setmetatable(r, { __index = MockIndex })
    function r:SetText(t) rawset(self, "text", t) end
    function r:GetText() return rawget(self, "text") end
    function r:GetStringWidth() return string.len(rawget(self, "text") or "") * 6 end
    function r:SetTexture(t) self.texture = t end
    function r:Show() self.visible = true end
    function r:Hide() self.visible = false end
    function r:IsVisible() return self.visible end
    return r
end

CreateFrame = function(kind, name, parent, template)
    local f = { name = name, kind = kind, template = template,
                scripts = {}, events = {}, children = {},
                visible = false, checked = false }
    setmetatable(f, { __index = MockIndex })
    -- Real parent/child wiring, so anything that WALKS the frame tree (the
    -- pfUI skin does) is actually exercised rather than silently traversing an
    -- empty list. Regions from CreateFontString/CreateTexture are deliberately
    -- not children, matching GetChildren's real behaviour.
    if type(parent) == "table" and rawget(parent, "children") then
        table.insert(parent.children, f)
    end
    function f:GetChildren() return unpack(rawget(self, "children") or {}) end
    function f:GetObjectType() return rawget(self, "kind") or "Frame" end
    function f:SetScript(k, fn) self.scripts[k] = fn end
    function f:GetScript(k) return self.scripts[k] end
    function f:HasScript() return true end
    function f:RegisterEvent(e) self.events[e] = true end
    function f:CreateFontString() return newRegion() end
    function f:CreateTexture() return newRegion() end
    function f:GetRegions() return newRegion() end
    function f:IsVisible() return self.visible end
    function f:GetChecked() return self.checked end
    function f:SetChecked(v) self.checked = v and true or false end
    -- EditBoxes are frames, so text lives here too, not only on regions.
    -- rawget throughout: see the note above newRegion.
    function f:SetText(t) rawset(self, "text", t) end
    function f:GetText() return rawget(self, "text") end
    -- REAL focus tracking. There was none: SetFocus fell through to the
    -- CamelCase no-op, so a Tab chain could be entirely broken and the suite
    -- would agree with it. Exactly one widget holds focus at a time, as on the
    -- client.
    -- REAL size and frame level. Both were CamelCase no-ops, so GetHeight
    -- returned nil -- which matters now that the row count is computed FROM
    -- the frame's height. A mock that cannot report a size cannot test a
    -- resizable window at all.
    -- Backdrop colours, tracked for real. The button system is ENTIRELY
    -- colour -- there are no textures to inspect -- so a mock that swallows
    -- SetBackdropColor can only ever assert "it did not error", which is
    -- exactly how a button that looks disabled but still clicks ships.
    function f:SetBackdropColor(r, g, b, a)
        rawset(self, "bdColor", { r, g, b, a })
    end
    function f:GetBackdropColor()
        local c = rawget(self, "bdColor")
        if not c then return nil end
        return c[1], c[2], c[3], c[4]
    end
    function f:SetBackdropBorderColor(r, g, b, a)
        rawset(self, "bdBorder", { r, g, b, a })
    end
    function f:GetBackdropBorderColor()
        local c = rawget(self, "bdBorder")
        if not c then return nil end
        return c[1], c[2], c[3], c[4]
    end
    function f:SetWidth(w) rawset(self, "w", w) end
    function f:SetHeight(h) rawset(self, "h", h) end
    function f:GetWidth() return rawget(self, "w") or 0 end
    function f:GetHeight() return rawget(self, "h") or 0 end
    function f:SetFrameLevel(n) rawset(self, "level", n) end
    function f:GetFrameLevel() return rawget(self, "level") or 1 end
    function f:SetFocus() focusedBox = self end
    function f:ClearFocus() if focusedBox == self then focusedBox = nil end end
    function f:HasFocus() return focusedBox == self end
    function f:Enable() rawset(self, "enabled", true) end
    function f:Disable() rawset(self, "enabled", false) end
    -- 1/nil, NOT true/false -- that is what the real 1.12 widget returns, and
    -- RepaintButton branches on it. A mock answering `false` where the client
    -- answers `nil` hides any caller that compares against one specifically.
    function f:IsEnabled()
        if rawget(self, "enabled") == false then return nil end
        return 1
    end
    function f:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
    function f:Show()
        self.visible = true
        if self.scripts.OnShow then self.scripts.OnShow() end
    end
    function f:Hide()
        self.visible = false
        if self.scripts.OnHide then self.scripts.OnHide() end
    end
    if name then _G[name] = f end
    -- Blizzard names child regions like "<name>Text" for check buttons.
    if name and template == "UICheckButtonTemplate" then
        _G[name .. "Text"] = newRegion()
    end
    return f
end

getglobal = function(n) return _G[n] end
setglobal = function(n, v) _G[n] = v end

UIParent = CreateFrame("Frame", "UIParent")
UISpecialFrames = {}
DEFAULT_CHAT_FRAME = { messages = {} }
function DEFAULT_CHAT_FRAME:AddMessage(m) table.insert(self.messages, m) end

UNKNOWN = "Unknown"
TURTLE_WOW_VERSION = "1.18.1"

ShowUIPanel = function(f) if f then f:Show() end end
HideUIPanel = function(f) if f then f:Hide() end end

-- FauxScrollFrame, modelled faithfully from the 1.12.1 FrameXML
-- (UIPanelTemplates.lua/.xml) -- the previous no-op stubs are why the 11+ mail
-- freeze was unreachable by any test.
--
-- The load-bearing quirk: on a LIVE scrollbar (numItems > numToDisplay),
-- SetMinMaxValues / a value clamp re-fires the slider's OnValueChanged, whose
-- template body is GetParent():SetVerticalScroll(arg1), which fires the scroll
-- frame's OnVerticalScroll SYNCHRONOUSLY -- re-entering whatever update
-- function the addon wired in. At numToDisplay or fewer items the real code
-- takes the frame:Hide() branch and the slider never fires, which is exactly
-- why the crash threshold sat at ROWS + 1 = 11 mails. A quiet scrollbar at
-- value 0 also does not fire, which is why a freshly opened, unscrolled
-- 54-mail inbox could still paint once.
scrollRefires = 0
FauxScrollFrame_Update = function(frame, numItems, numToDisplay, itemHeight)
    local value = rawget(frame, "value") or 0
    if numItems <= numToDisplay then
        -- scrollBar:SetValue(0); frame:Hide() -- dormant unless that clamped.
        rawset(frame, "value", 0)
        rawset(frame, "offset", 0)
        return
    end
    local max = (numItems - numToDisplay) * itemHeight
    local clamped = value
    if clamped > max then clamped = max end
    rawset(frame, "value", clamped)
    -- Live scrollbar with a nonzero value (or a clamp): OnValueChanged ->
    -- SetVerticalScroll -> OnVerticalScroll, synchronously, mid-Update.
    if clamped > 0 or clamped ~= value then
        scrollRefires = scrollRefires + 1
        local script = frame.scripts and frame.scripts.OnVerticalScroll
        if script then
            local oldThis, oldArg1 = this, arg1
            this, arg1 = frame, clamped
            script()
            this, arg1 = oldThis, oldArg1
        end
    end
end
FauxScrollFrame_GetOffset = function(frame)
    return rawget(frame, "offset") or 0
end
FauxScrollFrame_SetOffset = function(frame, offset)
    rawset(frame, "offset", offset)
end
-- The real 2-arg 1.12 signature: frame and value arrive as this/arg1 globals.
FauxScrollFrame_OnVerticalScroll = function(itemHeight, updateFunction)
    rawset(this, "value", arg1)
    rawset(this, "offset", math.floor((arg1 / itemHeight) + 0.5))
    updateFunction()
end

SlashCmdList = {}

-- Auction subject formats, exactly as 1.12.1 GlobalStrings.lua defines them.
AUCTION_SOLD_MAIL_SUBJECT    = "Auction successful: %s"
AUCTION_WON_MAIL_SUBJECT     = "Auction won: %s"
AUCTION_EXPIRED_MAIL_SUBJECT = "Auction expired: %s"
AUCTION_REMOVED_MAIL_SUBJECT = "Auction cancelled: %s"
AUCTION_OUTBID_MAIL_SUBJECT  = "Outbid on %s"

-- ---- Mail API mock -------------------------------------------------------
local INBOX = {}
closeMailCalls = 0
CloseMail = function() closeMailCalls = closeMailCalls + 1 end
CheckInbox = function() end

GetInboxNumItems = function() return table.getn(INBOX) end
-- Counts every raw header read. The storm test below asserts on this directly:
-- a walk of the whole inbox is the unit of work that made a big mailbox freeze
-- the client, so the only honest way to prove the coalescing works is to count
-- the reads themselves rather than trust a paint counter.
headerReads = 0
GetInboxHeaderInfo = function(i)
    headerReads = headerReads + 1
    local m = INBOX[i]
    if not m then return nil end
    -- The verified 13-value 1.12 signature.
    return m.packageIcon, m.stationeryIcon, m.sender, m.subject, m.money,
           m.cod, m.daysLeft, m.hasItem, m.wasRead, m.wasReturned,
           m.textCreated, m.canReply, m.isGM
end
GetInboxItem = function(i)
    local m = INBOX[i]
    if not m or not m.itemName then return nil end
    return m.itemName, "tex", m.itemCount or 1, 1
end

-- Mutating mail API. `failTakeMoney` / `failTakeItem` let a test simulate the
-- server refusing, which is the case the engine must never book a ledger
-- entry for.
failTakeMoney, failTakeItem = false, false
-- GetInboxText is what marks a mail READ on 1.12 -- there is no separate call.
-- The stub models that side effect, because it is the whole point of calling it.
readCalls = 0
GetInboxText = function(i)
    readCalls = readCalls + 1
    local m = INBOX[i]
    if not m then return nil end
    m.wasRead = 1
    -- THE side effect the whole reader design is built around: reading mail
    -- that still holds something drops its expiry to three days. Modelled here
    -- so a test can prove the reader does not trigger it behind the player's
    -- back -- an assertion about daysLeft is worth more than one about which
    -- function got called.
    if (m.money or 0) > 0 or m.hasItem or (m.cod or 0) > 0 then
        if (m.daysLeft or 30) > 3 then m.daysLeft = 3 end
    end
    -- The body is not always there on the first call: the client asks the
    -- server for it and fires MAIL_INBOX_UPDATE when it arrives. Mail flagged
    -- bodyDelay withholds it once, so the "Loading..." path gets exercised.
    if m.bodyDelay then
        m.bodyDelay = nil
        return nil, m.stationery
    end
    local takeable = ((m.money or 0) > 0 or m.hasItem) and true or false
    return m.body, m.stationery, takeable
end
-- Auction invoices. Returns nil for ordinary mail, exactly as the real call
-- does, which is what inbox.Body uses to decide whether a mail is an invoice.
GetInboxInvoiceInfo = function(i)
    local m = INBOX[i]
    if not m or not m.invoice then return nil end
    local v = m.invoice
    return v.kind, v.item, v.who, v.bid, v.buyout, v.deposit, v.consignment
end
-- The client's high-resolution timer. Advanced by the send pump so an elapsed
-- time can be asserted rather than eyeballed.
fakeClock = 0
GetTime = function() return fakeClock end
-- Whichever EditBox currently holds the keyboard, or nil.
focusedBox = nil
MiniMapMailFrame = CreateFrame("Frame", "MiniMapMailFrame")
MiniMapMailFrame:Show()
-- Counts operations the SERVER would have to perform. The pump below clocks
-- the engine off this and nothing else, because on a real client
-- MAIL_INBOX_UPDATE is the server acknowledging an operation it actually did
-- -- it does not arrive because an addon felt like stepping.
serverCalls = 0
TakeInboxMoney = function(i)
    serverCalls = serverCalls + 1
    local m = INBOX[i]
    if not m or failTakeMoney then return end
    m.money = 0
end
TakeInboxItem = function(i)
    serverCalls = serverCalls + 1
    local m = INBOX[i]
    if not m or failTakeItem then return end
    m.itemName = nil
    m.hasItem = nil
end
DeleteInboxItem = function(i)
    serverCalls = serverCalls + 1
    if INBOX[i] then table.remove(INBOX, i) end
end
returned = {}
ReturnInboxItem = function(i)
    local m = INBOX[i]
    if not m then return end
    table.insert(returned, m.sender)
    -- Like a delete, this removes the mail and shifts every later index down.
    table.remove(INBOX, i)
end

ERR_INV_FULL = "Your bags are full."
INVENTORY_FULL = "Inventory is full."
ERR_ITEM_MAX_COUNT = "You cannot carry any more of those items."

-- ---- outgoing mail + bags ------------------------------------------------
BAGS = {}            -- BAGS[bag][slot] = { name, texture, count }
SENT = {}            -- every SendMail call, in order
playerMoney = 10000000
attachSlot = nil     -- the single vanilla attachment slot
cursor = nil
sendMoneyAmt, sendCODAmt = 0, 0
failAttach = false   -- simulate an item that will not attach
failSend = false     -- simulate the server rejecting a mail

GetMoney = function() return playerMoney end
GetSendMailPrice = function() return 30 end
GetCVar = function(k) return k == "realmName" and "TestRealm" or "" end
UnitFactionGroup = function() return "Alliance" end
UnitName = function() return "Tester" end
-- Cursor and attachment slot, modelled the way the real client behaves,
-- because the retry path depends on it: picking an item up REMOVES it from the
-- bag, ClearCursor puts it BACK where it came from, and clicking the
-- attachment button with an empty cursor takes the attached item back off.
-- The old stub modelled none of that, which is why nothing here could exercise
-- a send that the server refuses.
-- Picking an item up LEAVES it in the bag slot, flagged locked -- it only
-- really moves once it is dropped somewhere. (That locked flag is why
-- TurtleMail hooks GetContainerItemInfo.) So ClearCursor just drops the
-- reference; the bag was never changed.
ClearCursor = function() cursor = nil end
CursorHasItem = function() return cursor ~= nil end

-- texture, itemCount, locked, quality, readable -- the 1.12 signature. The
-- THIRD value is the one that matters: the addon has to read it, because
-- PickupContainerItem on a locked slot is a silent no-op on the real client.
-- A slot is locked while its item is on the cursor, or while a test pins it.
GetContainerItemInfo = function(bag, slot)
    local it = BAGS[bag] and BAGS[bag][slot]
    if not it then return nil end
    local locked = it.locked
    if cursor and cursor.bag == bag and cursor.slot == slot then locked = 1 end
    return it.texture, it.count, locked, 1, nil
end
-- The backpack is bag 0 and always has 16 slots; a nil BAGS entry is a bag the
-- character does not have equipped.
GetContainerNumSlots = function(bag)
    if type(bag) ~= "number" or bag < 0 or bag > 4 then return 0 end
    if bag == 0 or BAGS[bag] then return 16 end
    return 0
end
GetContainerItemLink = function(bag, slot)
    local it = BAGS[bag] and BAGS[bag][slot]
    if not it then return nil end
    return "|cff1eff00|Hitem:1:0:0:0|h[" .. it.name .. "]|h|r"
end
-- Test hook for the race the post-attach name check exists to catch: the slot
-- verified a moment ago, but the server hands us a different stack when the
-- pickup actually lands. Nothing but a name comparison after the fact can see
-- this, so the mock has to be able to produce it.
swapPickupWith = nil
PickupContainerItem = function(bag, slot)
    if swapPickupWith then
        bag, slot = swapPickupWith.bag, swapPickupWith.slot
        swapPickupWith = nil
    end
    local it = BAGS[bag] and BAGS[bag][slot]
    if not it then return end
    -- A LOCKED SLOT DOES NOT RESPOND. No error, no event, nothing on the
    -- cursor -- this silent no-op is what produced "could not attach" in the
    -- field, and a mock that ignored the flag could never reproduce it.
    if it.locked then return end
    cursor = { bag = bag, slot = slot, item = it }
end
SplitContainerItem = function() end
useContainerCalls = 0
UseContainerItem = function() useContainerCalls = useContainerCalls + 1 end

ClickSendMailItemButton = function()
    if cursor then
        if not failAttach then
            attachSlot = cursor
            -- NOW it leaves the bag: it is committed to the mail.
            BAGS[cursor.bag][cursor.slot] = nil
        end
        cursor = nil
    elseif attachSlot then
        -- Empty cursor takes the attachment back off: it returns to the slot
        -- it came from and ends up on the cursor. This is the path a retry
        -- after a refused mail goes through.
        BAGS[attachSlot.bag] = BAGS[attachSlot.bag] or {}
        BAGS[attachSlot.bag][attachSlot.slot] = attachSlot.item
        cursor = attachSlot
        attachSlot = nil
    end
end
GetSendMailItem = function()
    if not attachSlot then return nil end
    return attachSlot.item.name, attachSlot.item.texture, attachSlot.item.count
end
moneyCalls, codCalls = 0, 0
SetSendMailMoney = function(c) moneyCalls = moneyCalls + 1; sendMoneyAmt = c or 0 end
SetSendMailCOD   = function(c) codCalls = codCalls + 1; sendCODAmt = c or 0 end

-- Every SendMail gets exactly one of MAIL_SEND_SUCCESS / MAIL_FAILED back, as
-- on the real client. `failSendCount` makes the server refuse the next N.
sendAttempts, failSendCount, lastSendFailed = 0, 0, false
SendMail = function(to, subject, body)
    sendAttempts = sendAttempts + 1
    if failSendCount > 0 then
        failSendCount = failSendCount - 1
        lastSendFailed = true
        -- A refused mail keeps its attachment: nothing left the client.
        return
    end
    lastSendFailed = false
    table.insert(SENT, { to = to, subject = subject, body = body,
        item = attachSlot and attachSlot.item.name or nil,
        count = attachSlot and attachSlot.item.count or nil,
        money = sendMoneyAmt, cod = sendCODAmt })
    attachSlot = nil
    sendMoneyAmt, sendCODAmt = 0, 0
end

-- MailFrame as FrameXML builds it: an OnHide that ends the session.
MailFrame = CreateFrame("Frame", "MailFrame")
MailFrame:SetScript("OnHide", function() CloseMail() end)
OpenMailFrame = CreateFrame("Frame", "OpenMailFrame")
MailFrameCloseButton = CreateFrame("Button", "MailFrameCloseButton")

-- ---- Load the addon in .toc order ---------------------------------------
local files = { "core/init.lua", "core/util.lua", "core/db.lua",
                "core/bridge.lua", "core/inbox.lua", "core/send.lua",
                "ui/frame.lua", "ui/skin.lua" }
for _, f in ipairs(files) do assert(loadfile(f))() end

local A = AegisCourier
-- Click a button the way the CLIENT would. A real 1.12 Button does not
-- dispatch OnClick while disabled -- the widget gates it, which is why
-- ui.MakeButton (and Exchange's original) only wraps Enable/Disable for
-- APPEARANCE and adds no Lua guard. Calling btn.scripts.OnClick() directly
-- reaches past that gate and tests something the player cannot do.
local function Click(btn)
    if not btn or not btn.scripts or not btn.scripts.OnClick then return false end
    if btn.IsEnabled and not btn:IsEnabled() then return false end
    btn.scripts.OnClick()
    return true
end

local function fire(e, a1)
    event, arg1 = e, a1
    A.Dispatch()
end

print("== load ==")
fire("ADDON_LOADED", "Aegis_Courier")
check(A.loaded, "ADDON_LOADED ran init callbacks")
check(type(CourierDB) == "table", "CourierDB created")
check(type(CourierCharDB) == "table", "CourierCharDB created")
check(type(CourierDB.ledger) == "table", "ledger table present")
check(SlashCmdList["AEGISCOURIER"] ~= nil, "slash command registered")

print("== util.SaleSplit (5% consignment) ==")
local gross, cut, net = A.util.SaleSplit(9500)
check(net == 9500, "net is what arrived", net)
check(gross - cut == net, "gross - cut reconciles to net", gross .. "-" .. cut)
check(gross == 10000, "9500 net implies 10000 gross", gross)
check(cut == 500, "cut is 500", cut)
local g2, c2, n2 = A.util.SaleSplit(0)
check(g2 == 0 and c2 == 0 and n2 == 0, "zero is safe")
-- The wrong formula (net * 1.05) would give 9975 here, not 10000.
check(A.util.SaleSplit(1) >= 1, "tiny amounts do not go negative")

print("== util.SubjectItem / inbox.ClassifySubject ==")
local kind, item = A.inbox.ClassifySubject("Auction successful: Silk Cloth")
check(kind == "sold" and item == "Silk Cloth", "sold parsed", tostring(kind) .. "/" .. tostring(item))
kind, item = A.inbox.ClassifySubject("Auction won: Black Lotus")
check(kind == "won" and item == "Black Lotus", "won parsed")
kind, item = A.inbox.ClassifySubject("Outbid on Arcanite Bar")
check(kind == "outbid" and item == "Arcanite Bar", "outbid parsed")
kind, item = A.inbox.ClassifySubject("Auction expired: Copper Ore")
check(kind == "expired" and item == "Copper Ore", "expired parsed")
kind, item = A.inbox.ClassifySubject("Auction cancelled: Linen Cloth")
check(kind == "cancelled" and item == "Linen Cloth", "cancelled parsed")
check(A.inbox.ClassifySubject("Hey there") == nil, "ordinary mail unclassified")
check(A.inbox.ClassifySubject("re: Auction successful: nice") == nil,
      "unanchored lookalike rejected")
check(A.inbox.ClassifySubject("") == nil, "empty subject safe")
check(A.inbox.ClassifySubject(nil) == nil, "nil subject safe")
-- Item names that themselves contain the stem must survive.
kind, item = A.inbox.ClassifySubject("Auction successful: Auction won: Thing")
check(kind == "sold" and item == "Auction won: Thing", "greedy item name kept", tostring(item))

print("== localized subject formats ==")
-- Prove the matching is not English-specific: swap the globals for a locale
-- whose placeholder is not at the end, reload inbox.lua, re-test.
AUCTION_SOLD_MAIL_SUBJECT = "Verkauf von %s erfolgreich"
assert(loadfile("core/inbox.lua"))()
kind, item = A.inbox.ClassifySubject("Verkauf von Seidenstoff erfolgreich")
check(kind == "sold" and item == "Seidenstoff", "non-terminal placeholder parsed", tostring(item))
AUCTION_SOLD_MAIL_SUBJECT = "Auction successful: %s"
assert(loadfile("core/inbox.lua"))()

print("== inbox.Header field mapping ==")
INBOX = {
    { packageIcon = "pkg", stationeryIcon = "st", sender = "Stormwind Auction House",
      subject = "Auction successful: Silk Cloth", money = 9500, cod = 0,
      daysLeft = 29.5, hasItem = nil, wasRead = nil, wasReturned = nil,
      textCreated = nil, canReply = 1, isGM = nil },
    { packageIcon = "pkg", stationeryIcon = "st", sender = "Bob",
      subject = "hi", money = 0, cod = 500, daysLeft = 0.25,
      hasItem = 1, wasRead = 1, wasReturned = 1, textCreated = nil,
      canReply = 1, isGM = nil },
    { packageIcon = nil, stationeryIcon = "st", sender = nil,
      subject = "GM stuff", money = 0, cod = 0, daysLeft = 5,
      hasItem = nil, wasRead = nil, wasReturned = nil, textCreated = nil,
      canReply = nil, isGM = 1 },
}
local h1 = A.inbox.Header(1)
check(h1.money == 9500, "money read", h1.money)
check(h1.cod == 0, "cod read")
check(h1.auctionKind == "sold", "auction kind from subject")
check(h1.auctionItem == "Silk Cloth", "auction item from subject")
check(h1.fromAuctionHouse == true, "AH sender recognised")
check(h1.wasRead == false, "unread mapped to false not nil")
local h2 = A.inbox.Header(2)
check(h2.cod == 500, "COD amount read", h2.cod)
check(h2.wasReturned == true, "wasReturned is field 10")
check(h2.hasItem == true, "hasItem truthy-mapped")
check(h2.auctionKind == nil, "player mail not classified")
local h3 = A.inbox.Header(3)
check(h3.isGM == true, "isGM is field 13")
check(h3.sender == "Unknown", "nil sender substituted")
check(A.inbox.Header(99) == nil, "out-of-range index returns nil")
local total, unread, money = A.inbox.Summary()
check(total == 3 and unread == 2 and money == 9500, "summary counts",
      total .. "/" .. unread .. "/" .. money)
-- Double-spaced AH name normalises.
check(A.inbox.IsAuctionSender("Thunder Bluff  Auction House"), "double-space AH name")
check(A.inbox.IsAuctionSender("Everlook Auction House"), "neutral AH name")
check(not A.inbox.IsAuctionSender("Bob"), "player is not an AH")
check(not A.inbox.IsAuctionSender(nil), "nil sender safe")

print("== util.FormatDaysLeft (fractional DAYS) ==")
check(A.util.FormatDaysLeft(29.5) == "29d", "days", A.util.FormatDaysLeft(29.5))
check(A.util.FormatDaysLeft(0.25) == "6h", "sub-day becomes hours", A.util.FormatDaysLeft(0.25))
check(A.util.FormatDaysLeft(0.0005) == "1m", "floor clamps to 1m", A.util.FormatDaysLeft(0.0005))

print("== db ledger + dedupe ==")
A.db.RecordTxn("sale", "Silk Cloth", 9500, nil, 10000, 500, 9500)
A.db.RecordTxn("buy", "Black Lotus", 20000)
local income, spend, n = A.db.LedgerTotals(nil)
check(income == 9500, "income totalled", income)
check(spend == 20000, "spend totalled", spend)
check(n == 2, "entry count", n)
check(A.db.CutTotal(nil) == 500, "cut totalled", A.db.CutTotal(nil))
check(A.db.RecordTxn("sale", "x", 0) == nil, "zero amount rejected")
local e = A.db.Ledger()[1]
check(e.t and e.kind and e.item and e.amount, "entry carries Aegis's 5 fields")
check(not A.db.WasSeen("k1"), "unseen key")
A.db.MarkSeen("k1")
check(A.db.WasSeen("k1"), "marked key is seen")
check(type(CourierDB.ledgerSeen["k1"]) == "number", "seen key stores a timestamp")

print("== bridge: dormant with no Aegis ==")
check(AegisExchange == nil, "no Aegis in this environment")
check(A.bridge.Ready() == false, "bridge not ready")
check(A.bridge.Push("sale", "Silk Cloth", 9500) == false, "push is a no-op")
check(A.bridge.StatusText() == "standalone", "status reads standalone", A.bridge.StatusText())

-- A FAITHFUL stand-in for Aegis: Exchange's RecordExternalTxn, ported from
-- that repo's core/db.lua under the "Companion-addon integration surface"
-- heading. Every behaviour below is one Courier depends on:
--
--   * it takes ONE TABLE, not positional arguments;
--   * it RETURNS false plus a reason for a bad payload -- it does NOT error,
--     so a pcall around it reports success either way;
--   * it returns true when the entry is recorded.
--
-- This fake used to take (kind, item, amount, itemId), mirroring the mistake
-- in bridge.Push rather than the real addon. Both agreed, so 346 checks
-- passed over a seam that dropped every entry on the floor. A mock written
-- from the caller's assumption tests nothing; this one is written from the
-- far side's source and disagrees with a wrong caller on purpose.
--
-- If Aegis's INTEGRATION_VERSION ever moves past 1, re-port this from there.
function FakeAegis(sink)
    return {
        INTEGRATION_VERSION = 1,
        RecordExternalTxn = function(txn)
            if type(txn) ~= "table" then
                return false, "payload must be a table"
            end
            if txn.kind ~= "sale" and txn.kind ~= "buy" then
                return false, "kind must be 'sale' or 'buy'"
            end
            if type(txn.amount) ~= "number" or txn.amount <= 0 then
                return false, "amount must be a positive number of copper"
            end
            table.insert(sink, {
                kind = txn.kind, item = txn.item,
                amount = txn.amount, id = txn.itemId, key = txn.key,
            })
            return true
        end,
    }
end

print("== bridge: with Aegis present ==")
local pushed = {}
AegisExchange = FakeAegis(pushed)
check(A.bridge.Ready() == true, "bridge ready")
check(A.bridge.Push("sale", "Silk Cloth", 9500, 4306) == true, "push succeeds")
check(table.getn(pushed) == 1, "one entry pushed")
check(pushed[1].kind == "sale" and pushed[1].item == "Silk Cloth"
      and pushed[1].amount == 9500 and pushed[1].id == 4306,
      "the payload reaches Aegis as a TABLE with the documented field names")

-- No dedup key is sent, and that is deliberate. Aegis's MailTxnKey buckets
-- subject+money+arrival-hour, which is exactly the fingerprint inbox.lua's
-- Stage B note rejects: two identical stacks sold at one price in one hour
-- collide, and a collision silently UNDER-counts. Courier books on
-- COLLECTION, so an emptied mail cannot be booked twice and no key is
-- needed. Sending one would trade a bounded, one-time handover overlap for
-- a permanent undercount.
check(pushed[1].key == nil, "no dedup key is sent (see inbox.lua Stage B note)")

-- A future contract version we do not understand must stand us down.
AegisExchange.INTEGRATION_VERSION = 99
check(A.bridge.Ready() == false, "unsupported contract version stands down")
AegisExchange.INTEGRATION_VERSION = 1

-- An error on the far side must not propagate.
AegisExchange.RecordExternalTxn = function() error("boom") end
check(A.bridge.Push("sale", "x", 1) == false, "far-side error swallowed")

-- ...and neither must a REFUSAL, which is the far more likely failure: Aegis
-- returns false rather than erroring, so a bridge that only inspects pcall's
-- ok flag reports success and loses the entry. That is precisely how the
-- positional-call bug survived. Push must report what Aegis actually said.
AegisExchange.RecordExternalTxn = function() return false, "payload must be a table" end
check(A.bridge.Push("sale", "x", 1) == false, "a REFUSAL is reported as failure")
AegisExchange.RecordExternalTxn = function() return true end
check(A.bridge.Push("sale", "x", 1) == true, "and acceptance as success")

-- The user's own setting wins.
A.db.SetSetting("pushToAegis", false)
check(A.bridge.Ready() == false, "push disabled by setting")
A.db.SetSetting("pushToAegis", true)
AegisExchange = nil

print("== takeover: the two silent-failure traps ==")
closeMailCalls = 0
-- Client MAIL_SHOW path: ShowUIPanel(MailFrame) happens first, then the event.
ShowUIPanel(MailFrame)
check(MailFrame:IsVisible(), "client showed MailFrame")
fire("MAIL_SHOW")
check(A.ui.mailOpen == true, "mailOpen set")
-- TRAP 2: the hide must NOT have happened synchronously.
check(MailFrame:IsVisible(), "MailFrame still visible in the same frame (deferred hide)")
check(closeMailCalls == 0, "no CloseMail during MAIL_SHOW")
check(A.ui.frame:IsVisible(), "Courier window shown")
-- Now let the deferred hider tick.
local hider = getglobal("AegisCourierHider")
check(hider ~= nil, "hider frame exists")
hider.scripts.OnUpdate()
-- TRAP 1: hidden, but the session must survive.
check(not MailFrame:IsVisible(), "MailFrame hidden after one tick")
check(closeMailCalls == 0, "session survived the takeover hide")

print("== takeover: a normal hide still ends the session ==")
closeMailCalls = 0
MailFrame:Show()
MailFrame:Hide()   -- somebody else hiding it, e.g. the client on MAIL_CLOSED
check(closeMailCalls == 1, "original OnHide body ran", closeMailCalls)

print("== takeover: hand-off to the Blizzard UI ==")
closeMailCalls = 0
A.ui.ShowBlizzardMail()
check(not A.ui.frame:IsVisible(), "Courier window hidden")
check(MailFrame:IsVisible(), "Blizzard mail shown")
check(closeMailCalls == 0, "hand-off did not close the session")
-- While handed off, the hider must not snatch it back.
hider.scripts.OnUpdate()
check(MailFrame:IsVisible(), "hider respects showBlizzard")
-- And back again.
A.ui.OpenWindow()
check(A.ui.frame:IsVisible() and not MailFrame:IsVisible(), "swapped back to Courier")
check(closeMailCalls == 0, "swapping back kept the session")

print("== takeover: closing Courier closes the mailbox ==")
closeMailCalls = 0
A.ui.CloseWindow()
check(closeMailCalls == 1, "CloseWindow ended the session", closeMailCalls)
fire("MAIL_CLOSED")
check(A.ui.mailOpen == false, "mailOpen cleared")
check(not A.ui.frame:IsVisible(), "window hidden on MAIL_CLOSED")

print("== takeover: Escape must not strand the player ==")
-- UISpecialFrames hides the frame DIRECTLY, never via ui.CloseWindow.
check(UISpecialFrames[1] == "AegisCourierFrame", "registered with UISpecialFrames")
ShowUIPanel(MailFrame)
fire("MAIL_SHOW")
hider.scripts.OnUpdate()
check(A.ui.frame:IsVisible() and not MailFrame:IsVisible(), "took over again")
closeMailCalls = 0
A.ui.frame:Hide()   -- exactly what Escape does
check(closeMailCalls == 1, "Escape ended the mail session", closeMailCalls)
fire("MAIL_CLOSED")
check(A.ui.mailOpen == false, "mailOpen cleared after Escape")

print("== takeover: MAIL_CLOSED hide does not re-close ==")
ShowUIPanel(MailFrame)
fire("MAIL_SHOW")
hider.scripts.OnUpdate()
closeMailCalls = 0
fire("MAIL_CLOSED")   -- client-initiated close: session is already gone
check(closeMailCalls == 0, "no redundant CloseMail from the MAIL_CLOSED path",
      closeMailCalls)

print("== takeover disabled by setting ==")
A.db.SetSetting("takeover", false)
closeMailCalls = 0
ShowUIPanel(MailFrame)
fire("MAIL_SHOW")
hider.scripts.OnUpdate()
check(MailFrame:IsVisible(), "Blizzard mailbox left alone when takeover is off")
check(closeMailCalls == 0, "no session damage when takeover is off")
A.db.SetSetting("takeover", true)

print("== refresh paths run clean ==")
fire("MAIL_CLOSED")
A.ui.OpenWindow()
A.ui.SelectSubTab("Inbox")
A.ui.SelectSubTab("Ledger")
A.ui.SelectSubTab("Courier")
fire("MAIL_INBOX_UPDATE")
check(true, "all three tabs refreshed without error")

-- =========================================================================
-- Stage B: the take engine
-- =========================================================================

local take = A.take
local driver = getglobal("AegisCourierTaker")
check(driver ~= nil, "take driver frame exists")

-- One tick of our OnUpdate, then the server's reply. That reply is the engine's
-- clock -- the whole design rests on not driving this from a timer.
--
-- The reply is FAITHFUL: MAIL_INBOX_UPDATE is fired only when the step
-- actually asked the server to do something. An earlier version of this pump
-- fired it every iteration regardless, which hand-fed the engine a clock a
-- real client would never provide -- and hid a bug where any step that skipped
-- a mail (COD, GM, wedge guard, the terminal step of a "take") issued no call,
-- got no acknowledgement, and hung the run for good. 388 checks passed over
-- that stall. A mock more generous than the server cannot fail.
local function pump(limit)
    local n = 0
    while take.running and n < (limit or 400) do
        local before = serverCalls
        driver.scripts.OnUpdate()
        -- No operation issued means no acknowledgement is coming; the engine
        -- has to have armed itself or it is wedged. Keep pumping frames so a
        -- self-armed step still runs, but never invent a server reply.
        if serverCalls ~= before and take.running then
            fire("MAIL_INBOX_UPDATE")
        end
        n = n + 1
    end
    return n
end

local function mail(t)
    return { packageIcon = "pkg", stationeryIcon = "st",
             sender = t.sender or "Bob", subject = t.subject or "hi",
             money = t.money or 0, cod = t.cod or 0,
             daysLeft = t.daysLeft or 20, hasItem = t.item and 1 or nil,
             itemName = t.item, wasRead = t.read and 1 or nil,
             wasReturned = nil, textCreated = nil,
             canReply = t.canReply == false and nil or 1,
             isGM = t.gm and 1 or nil,
             body = t.body, invoice = t.invoice, bodyDelay = t.bodyDelay }
end

local AH = "Stormwind Auction House"

print("== take: Open All ==")
A.db.ClearLedger()
INBOX = {
    mail{ sender = AH, subject = "Auction successful: Silk Cloth", money = 9500 },
    mail{ sender = "Bob", subject = "here you go", item = "Copper Ore" },
    mail{ sender = "Ann", subject = "pay up", money = 100, cod = 5000 },
    mail{ sender = "GM", subject = "ticket", money = 700, gm = true },
    mail{ sender = AH, subject = "Auction successful: Black Lotus", money = 190000 },
}
check(take.HasWork(take.MODE_OPEN), "HasWork sees collectable mail")
check(take.Start(take.MODE_OPEN), "run started")
local steps = pump()
check(not take.running, "run finished", steps)
check(table.getn(INBOX) == 2, "only COD + GM mail remain", table.getn(INBOX))
check(INBOX[1].cod == 5000, "COD mail untouched")
check(INBOX[1].money == 100, "COD mail money not taken")
check(INBOX[2].isGM == 1, "GM mail untouched")
check(INBOX[2].money == 700, "GM mail money not taken")
check(take.money == 199500, "collected total", take.money)
check(take.items == 1, "one item taken", take.items)

local led = A.db.Ledger()
check(table.getn(led) == 2, "two sales booked", table.getn(led))
check(led[1].item == "Silk Cloth", "item name from subject", led[1].item)
check(led[1].amount == 9500, "amount is NET", led[1].amount)
check(led[1].gross == 10000, "gross derived", led[1].gross)
check(led[1].cut == 500, "5% cut derived", led[1].cut)
check(led[1].gross - led[1].cut == led[1].amount, "entry reconciles")
check(led[2].item == "Black Lotus", "second sale booked")

print("== take: only 'sold' mail books income ==")
A.db.ClearLedger()
INBOX = {
    -- Outbid mail returns YOUR OWN BID. Booking it as income would inflate
    -- every total the addon reports.
    mail{ sender = AH, subject = "Outbid on Arcanite Bar", money = 50000 },
    -- Won mail delivers the item; the buyer already paid, so there is no price.
    mail{ sender = AH, subject = "Auction won: Righteous Orb", item = "Righteous Orb" },
    mail{ sender = AH, subject = "Auction expired: Copper Ore", item = "Copper Ore" },
    mail{ sender = AH, subject = "Auction cancelled: Linen Cloth", item = "Linen Cloth" },
}
take.Start(take.MODE_OPEN)
pump()
check(table.getn(INBOX) == 0, "all four collected", table.getn(INBOX))
check(take.money == 50000, "outbid refund WAS collected", take.money)
check(table.getn(A.db.Ledger()) == 0, "but nothing booked as a sale",
      table.getn(A.db.Ledger()))
local income = A.db.LedgerTotals(nil)
check(income == 0, "income stays zero", income)

print("== take: Take All keeps the mail ==")
A.db.ClearLedger()
INBOX = {
    mail{ sender = AH, subject = "Auction successful: Silk Cloth", money = 9500 },
    mail{ sender = "Bob", subject = "gift", item = "Copper Ore" },
}
take.Start(take.MODE_TAKE)
pump()
check(table.getn(INBOX) == 2, "mails kept", table.getn(INBOX))
check(INBOX[1].money == 0, "money taken")
check(INBOX[2].itemName == nil, "item taken")
check(take.money == 9500, "money counted")
check(table.getn(A.db.Ledger()) == 1, "sale still booked")

print("== take: re-running does not double-count ==")
-- The dedupe claim: recording on COLLECTION means an emptied mail has nothing
-- left to book, so a second pass over the same inbox is inert. No arrival
-- fingerprint, so no chance of two identical sales colliding into one.
local before = table.getn(A.db.Ledger())
take.Start(take.MODE_TAKE)
pump()
check(table.getn(A.db.Ledger()) == before, "second pass booked nothing",
      table.getn(A.db.Ledger()))
check(take.money == 0, "and collected nothing", take.money)

print("== take: two identical sales both book ==")
-- The exact case an arrival-bucket key would have collapsed into one entry.
A.db.ClearLedger()
INBOX = {
    mail{ sender = AH, subject = "Auction successful: Silk Cloth", money = 9500 },
    mail{ sender = AH, subject = "Auction successful: Silk Cloth", money = 9500 },
}
take.Start(take.MODE_OPEN)
pump()
check(table.getn(A.db.Ledger()) == 2, "both identical sales booked",
      table.getn(A.db.Ledger()))
local inc2 = A.db.LedgerTotals(nil)
check(inc2 == 19000, "income counts both", inc2)

print("== take: Delete Read is conservative ==")
INBOX = {
    mail{ sender = "Bob", subject = "read and empty", read = true },
    mail{ sender = "Ann", subject = "unread and empty" },
    mail{ sender = "Cid", subject = "read with gold", money = 500, read = true },
    mail{ sender = "Dot", subject = "read with item", item = "Copper Ore", read = true },
}
take.Start(take.MODE_DELETE)
pump()
check(table.getn(INBOX) == 3, "only the read+empty mail was deleted",
      table.getn(INBOX))
check(INBOX[1].subject == "unread and empty", "unread kept")
check(INBOX[2].money == 500, "unclaimed gold kept")
check(INBOX[3].itemName == "Copper Ore", "unclaimed item kept")
check(take.money == 0, "delete mode takes nothing")

print("== take: a failed take books nothing and never deletes ==")
A.db.ClearLedger()
INBOX = { mail{ sender = AH, subject = "Auction successful: Silk Cloth", money = 9500 } }
failTakeMoney = true
take.Start(take.MODE_OPEN)
pump()
failTakeMoney = false
check(table.getn(INBOX) == 1, "mail survived a failed take", table.getn(INBOX))
check(INBOX[1].money == 9500, "money still in the mail")
check(table.getn(A.db.Ledger()) == 0, "nothing booked",
      table.getn(A.db.Ledger()))
check(take.money == 0, "nothing counted")

print("== take: never deletes a mail still holding an item ==")
INBOX = { mail{ sender = "Bob", subject = "gift", item = "Copper Ore" } }
failTakeItem = true
take.Start(take.MODE_OPEN)
pump()
failTakeItem = false
check(table.getn(INBOX) == 1, "mail survived", table.getn(INBOX))
check(INBOX[1].itemName == "Copper Ore", "item NOT destroyed by a delete")

print("== take: bag-full aborts, item-cap skips ==")
INBOX = {
    mail{ sender = "Bob", subject = "a", item = "Copper Ore" },
    mail{ sender = "Ann", subject = "b", money = 100 },
}
failTakeItem = true
take.Start(take.MODE_OPEN)
driver.scripts.OnUpdate()          -- issues TakeInboxItem
fire("UI_ERROR_MESSAGE", ERR_INV_FULL)
check(not take.running, "ERR_INV_FULL stopped the run")
failTakeItem = false

INBOX = {
    mail{ sender = "Bob", subject = "a", item = "Copper Ore" },
    mail{ sender = AH, subject = "Auction successful: Silk Cloth", money = 9500 },
}
A.db.ClearLedger()
failTakeItem = true
take.Start(take.MODE_OPEN)
driver.scripts.OnUpdate()
fire("UI_ERROR_MESSAGE", ERR_ITEM_MAX_COUNT)
check(take.running, "ERR_ITEM_MAX_COUNT did not stop the run")
failTakeItem = false
pump()
check(table.getn(A.db.Ledger()) == 1, "run continued past the capped item",
      table.getn(A.db.Ledger()))

print("== take: wedge guard ==")
-- A mail the server simply will not hand over must not spin forever.
INBOX = { mail{ sender = "Bob", subject = "stuck", money = 100 },
          mail{ sender = "Ann", subject = "fine", money = 200 } }
failTakeMoney = true
take.Start(take.MODE_TAKE)
local n = pump(100)
failTakeMoney = false
check(not take.running, "run terminated rather than wedging", n)
check(n < 100, "and did so promptly", n)

print("== take: right-click a single mail ==")
A.db.ClearLedger()
INBOX = {
    mail{ sender = "Bob", subject = "keep me", money = 300 },
    mail{ sender = AH, subject = "Auction successful: Silk Cloth", money = 9500 },
}
check(take.Single(2), "single take started")
pump()
check(not take.running, "single take finished")
check(table.getn(INBOX) == 1, "only the clicked mail was taken",
      table.getn(INBOX))
check(INBOX[1].money == 300, "the other mail is untouched")
check(table.getn(A.db.Ledger()) == 1, "its sale was booked")

print("== take: COD is never taken by right-click either ==")
INBOX = { mail{ sender = "Ann", subject = "pay up", money = 100, cod = 5000 } }
check(take.Single(1) == false, "single take refuses COD")
check(INBOX[1].money == 100, "COD mail untouched")

print("== take: pushes to Aegis when the seam is live ==")
A.db.ClearLedger()
local pushed2 = {}
AegisExchange = FakeAegis(pushed2)
INBOX = { mail{ sender = AH, subject = "Auction successful: Silk Cloth", money = 9500 } }
take.Start(take.MODE_OPEN)
pump()
check(table.getn(pushed2) == 1, "one push", table.getn(pushed2))
check(pushed2[1].kind == "sale" and pushed2[1].item == "Silk Cloth"
      and pushed2[1].amount == 9500, "pushed the NET, matching Aegis's shape")
check(table.getn(A.db.Ledger()) == 1, "and kept its own entry")
AegisExchange = nil

print("== take: driver only runs at a mailbox ==")
take.SetMailboxOpen(true)
check(driver.visible, "driver shown at a mailbox")
INBOX = { mail{ sender = "Bob", subject = "x", money = 100 } }
take.Start(take.MODE_TAKE)
take.SetMailboxOpen(false)
check(not driver.visible, "driver hidden away from a mailbox")
check(not take.running, "run abandoned when the mailbox closed")

print("== take: action bar enable state ==")
A.ui.mailOpen = true
INBOX = { mail{ sender = "Bob", subject = "x", money = 100 } }
A.ui.OpenWindow()
A.ui.SelectSubTab("Inbox")
check(A.ui.btnOpenAll ~= nil, "action bar built")
check(take.HasWork(take.MODE_OPEN), "work available")
INBOX = {}
check(not take.HasWork(take.MODE_OPEN), "no work on an empty inbox")
check(not take.HasWork(take.MODE_DELETE), "nothing to delete either")
A.ui.OnTakeStateChanged()
check(true, "action bar refresh runs clean on an empty inbox")

-- =========================================================================
-- Stage C: sending mail
-- =========================================================================

local send = A.send
local sdriver = getglobal("AegisCourierSender")
check(sdriver ~= nil, "send driver frame exists")

-- Our tick issues one mail; the server then confirms it. Sending a batch from
-- inside the success handler is exactly what this deferral avoids.
local function pumpSend(limit)
    local n, seenAttempts = 0, sendAttempts
    while send.sending and n < (limit or 60) do
        -- A generous frame delta so any settle/retry wait elapses in one tick.
        -- The fake clock advances with it, so elapsed time is measurable.
        fakeClock = fakeClock + 5
        arg1 = 5
        sdriver.scripts.OnUpdate()
        arg1 = nil
        if sendAttempts > seenAttempts then
            seenAttempts = sendAttempts
            if lastSendFailed then
                fire("MAIL_FAILED")
            else
                fire("MAIL_SEND_SUCCESS")
            end
        end
        n = n + 1
    end
    return n
end

local function stockBags()
    BAGS = { [0] = {
        [1] = { name = "Silk Cloth",   texture = "t1", count = 20 },
        [2] = { name = "Copper Ore",   texture = "t2", count = 5 },
        [3] = { name = "Black Lotus",  texture = "t3", count = 1 },
    } }
    SENT = {}
    attachSlot, cursor = nil, nil
    send.ClearAttachments()
end

print("== util: item links and money parsing ==")
check(A.util.ItemNameFromLink("|cff1eff00|Hitem:2589:0:0:0|h[Linen Cloth]|h|r")
      == "Linen Cloth", "name extracted from link")
check(A.util.ItemNameFromLink(nil) == nil, "nil link safe")
check(A.util.ItemIdFromLink("|Hitem:2589:0:0:0|h") == 2589, "id extracted")
check(A.util.ParseMoney("12g 30s") == 123000, "g+s parsed", A.util.ParseMoney("12g 30s"))
check(A.util.ParseMoney("50") == 500000, "bare number reads as gold",
      A.util.ParseMoney("50"))
check(A.util.ParseMoney("7c") == 7, "copper parsed")
check(A.util.ParseMoney("") == nil, "empty is nil")
check(A.util.ParseMoney("abc") == nil, "junk is nil")

print("== send: attachment list ==")
stockBags()
check(send.Attach(0, 1), "attached first item")
check(send.Count() == 1, "count is 1")
check(send.attachments[1].name == "Silk Cloth", "name resolved from the link",
      send.attachments[1].name)
check(send.attachments[1].count == 20, "stack count kept")
check(send.Attach(0, 1) == false, "same slot cannot be attached twice")
check(send.Attach(0, 99) == false, "empty slot cannot be attached")
check(send.Attach(0, 2), "second item attached")
check(send.Count() == 2, "count is 2")
check(send.Detach(1), "detached")
check(send.Count() == 1 and send.attachments[1].name == "Copper Ore",
      "the right one was removed")
send.ClearAttachments()
check(send.Count() == 0, "cleared")

print("== send: cost is per MAIL, not per send ==")
stockBags()
check(send.MailCount() == 1, "no attachments still means one mail")
check(send.Postage() == 30, "one mail's postage", send.Postage())
send.Attach(0, 1); send.Attach(0, 2); send.Attach(0, 3)
check(send.MailCount() == 3, "three items means three mails")
check(send.Postage() == 90, "postage multiplies", send.Postage())
check(send.TotalCost(5000, false) == 5090, "attached gold is spent",
      send.TotalCost(5000, false))
check(send.TotalCost(5000, true) == 90, "COD gold is collected, not spent",
      send.TotalCost(5000, true))

print("== send: validation ==")
stockBags()
local ok, why = send.Validate("", 0, false)
check(not ok and why == "no recipient", "empty recipient rejected", why)
ok, why = send.Validate("   ", 0, false)
check(not ok, "whitespace recipient rejected")
ok, why = send.Validate("Bob", 0, false)
check(not ok and why == "nothing to send", "wholly empty mail rejected", why)

-- A LETTER IS A MAIL. Courier used to refuse anything carrying neither an item
-- nor gold, which made it impossible to write to anyone -- reported from live
-- play as "can't send without an item attached".
ok, why = send.Validate("Bob", 0, false, "How are you?", "")
check(ok, "a subject alone is sendable", why)
ok, why = send.Validate("Bob", 0, false, "", "just checking in")
check(ok, "a body alone is sendable", why)
ok, why = send.Validate("Bob", 0, false, "How are you?", "long time no see")
check(ok, "subject and body are sendable", why)
ok, why = send.Validate("Bob", 0, false, "   ", "  ")
check(not ok and why == "nothing to send",
      "but whitespace is not content", why)

ok, why = send.Validate("Bob", 5000, true)
check(not ok and why == "COD needs an item", "COD without an item rejected", why)
send.Attach(0, 1)
ok, why = send.Validate("Bob", 0, false)
check(ok, "item alone is sendable", why)
playerMoney = 10
ok, why = send.Validate("Bob", 0, false)
check(not ok, "cannot afford postage", why)
playerMoney = 10000000

print("== send: one item, one mail ==")
stockBags()
send.Attach(0, 1)
check(send.Start("Bob", "hello", "body text", 0, false, false), "send started")
pumpSend()
check(not send.sending, "finished")
check(table.getn(SENT) == 1, "one mail sent", table.getn(SENT))
check(SENT[1].to == "Bob", "recipient")
check(SENT[1].subject == "hello", "subject verbatim for a single mail",
      SENT[1].subject)
check(SENT[1].body == "body text", "body")
check(SENT[1].item == "Silk Cloth", "item attached", tostring(SENT[1].item))
check(send.Count() == 0, "attachment list cleared after success")

print("== send: a plain letter, no attachment and no gold ==")
-- The reported bug, end to end rather than only through Validate: the whole
-- point is that this reaches the server.
stockBags()
SENT = {}
check(send.Count() == 0, "nothing attached")
check(send.Start("Torchlyte", "How are you?", "long time no see", 0, false,
      false), "a letter starts sending")
pumpSend()
check(not send.sending, "finished")
check(table.getn(SENT) == 1, "one letter sent", table.getn(SENT))
check(SENT[1].to == "Torchlyte", "recipient", SENT[1].to)
check(SENT[1].subject == "How are you?", "subject", SENT[1].subject)
check(SENT[1].body == "long time no see", "body", SENT[1].body)
check(SENT[1].item == nil, "and no item rode along", tostring(SENT[1].item))
check(send.MailCount() == 1, "a letter is one mail for postage", send.MailCount())

print("== send: three items become three mails ==")
stockBags()
send.Attach(0, 1); send.Attach(0, 2); send.Attach(0, 3)
send.Start("Ann", "stuff", "", 0, false, false)
pumpSend()
check(table.getn(SENT) == 3, "three mails", table.getn(SENT))
check(SENT[1].subject == "stuff [1/3]", "batch subjects numbered", SENT[1].subject)
check(SENT[3].subject == "stuff [3/3]", "last numbered", SENT[3].subject)
check(SENT[1].item == "Silk Cloth" and SENT[2].item == "Copper Ore"
      and SENT[3].item == "Black Lotus", "one item per mail, in order")
check(send.sentCount == 3, "count tracked")

print("== send: blank subject auto-names from the item ==")
stockBags()
send.Attach(0, 1); send.Attach(0, 3)
send.Start("Ann", "", "", 0, false, false)
pumpSend()
check(SENT[1].subject == "Silk Cloth (20)", "stack count included",
      SENT[1].subject)
check(SENT[2].subject == "Black Lotus", "single item has no count suffix",
      SENT[2].subject)

print("== send: gold rides the FIRST mail only ==")
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
send.Start("Ann", "gold", "", 5000, false, false)
pumpSend()
check(table.getn(SENT) == 2, "two mails")
check(SENT[1].money == 5000, "first mail carries the gold", SENT[1].money)
check(SENT[2].money == 0, "second does NOT resend it", SENT[2].money)

print("== send: COD on the first vs on every mail ==")
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
send.Start("Ann", "cod", "", 5000, true, false)
pumpSend()
check(SENT[1].cod == 5000, "COD on the first", SENT[1].cod)
check(SENT[2].cod == 0, "not on the second", SENT[2].cod)

stockBags()
send.Attach(0, 1); send.Attach(0, 2)
send.Start("Ann", "cod", "", 5000, true, true)
pumpSend()
check(SENT[1].cod == 5000 and SENT[2].cod == 5000, "codAll charges every mail",
      tostring(SENT[1].cod) .. "/" .. tostring(SENT[2].cod))

print("== send: a stack the server has LOCKED is waited for, not abandoned ==")
-- The reported "could not attach X -- send stopped". GetContainerItemInfo's
-- third return is `locked`, and PickupContainerItem on a locked slot does
-- nothing at all -- so a run that ignores the flag attaches nothing, fails its
-- own verification, and used to throw the rest of the queue away.
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
BAGS[0][2].locked = 1                 -- the server is holding Copper Ore
send.Start("Ann", "x", "", 0, false, false)
pumpSend(8)
check(send.sending, "the run is still alive, waiting on the lock")
check(table.getn(SENT) == 1, "the unlocked item went out", table.getn(SENT))
check(SENT[1].item == "Silk Cloth", "and it was the right one", SENT[1].item)
check((send.skipped or 0) == 0, "nothing has been skipped yet", send.skipped)
BAGS[0][2].locked = nil               -- server releases it
pumpSend()
check(not send.sending, "run completes once the lock clears")
check(table.getn(SENT) == 2, "both items sent", table.getn(SENT))
check(SENT[2].item == "Copper Ore", "including the one that was locked",
      SENT[2].item)
check((send.skipped or 0) == 0, "and nothing was skipped", send.skipped)

print("== send: a lock that never clears costs one item, not the batch ==")
stockBags()
send.Attach(0, 1); send.Attach(0, 2); send.Attach(0, 3)
BAGS[0][1].locked = 1                 -- stuck forever
send.Start("Ann", "x", "", 0, false, false)
pumpSend(200)
BAGS[0][1].locked = nil
check(not send.sending, "the run finished rather than hanging")
check(send.skipped == 1, "the stuck item was skipped", send.skipped)
check(table.getn(SENT) == 2, "the other two still went out", table.getn(SENT))
check(BAGS[0][1] ~= nil, "and the stuck item is still in the bag")

print("== send: a stack that MOVED is found again, not lost ==")
-- Bag coordinates are the only address 1.12 gives us and they are not stable:
-- a snapshot taken at queue time can be wrong by the time the batch reaches it.
stockBags()
send.Attach(0, 1)                     -- Silk Cloth at slot 1
send.Attach(0, 2)
BAGS[0][7] = BAGS[0][1]               -- player reshuffles: Silk Cloth -> slot 7
BAGS[0][1] = nil
send.Start("Ann", "x", "", 0, false, false)
pumpSend()
check(not send.sending, "run finished")
check((send.skipped or 0) == 0, "nothing was skipped", send.skipped)
check(table.getn(SENT) == 2, "both mails sent", table.getn(SENT))
check(SENT[1].item == "Silk Cloth", "the moved stack was relocated by name",
      SENT[1].item)

print("== send: a DIFFERENT item in the remembered slot is never mailed ==")
-- First line of defence: ResolveSlot compares names before touching anything.
-- The dangerous case. The old verification asked only "is something
-- attached?", so a stack that had moved out and been replaced sent the
-- REPLACEMENT to the recipient silently. Worse than the visible abort.
stockBags()
send.Attach(0, 1)                     -- queue Silk Cloth
send.Attach(0, 2)                     -- and Copper Ore
-- Silk Cloth leaves the bags entirely; Black Lotus takes its slot.
BAGS[0][1] = { name = "Black Lotus", texture = "t9", count = 1 }
send.Start("Ann", "x", "", 0, false, false)
pumpSend()
check(not send.sending, "run finished")
check(send.skipped == 1, "the vanished item was skipped", send.skipped)
local mailedLotus = false
local mi = 1
while mi <= table.getn(SENT) do
    if SENT[mi].item == "Black Lotus" then mailedLotus = true end
    mi = mi + 1
end
check(mailedLotus == false, "the WRONG item was never mailed")
check(BAGS[0][1] ~= nil and BAGS[0][1].name == "Black Lotus",
      "and it is still safely in the bag")
check(table.getn(SENT) == 1, "the other item still went out", table.getn(SENT))
check(SENT[1].item == "Copper Ore", "and it was the right one", SENT[1].item)

print("== send: a last-instant swap is caught AFTER the attach ==")
-- Second line of defence, and the one the first cannot cover. ResolveSlot
-- verified the slot, but the server can still move the stack in the instant
-- between that check and the pickup landing. Only comparing what actually
-- ended up on the mail against what we queued catches that -- which is why
-- "is something attached?" was never a sufficient question.
stockBags()
send.Attach(0, 1)                      -- queue Silk Cloth, slot verified fine
swapPickupWith = { bag = 0, slot = 3 } -- server hands over Black Lotus instead
send.Start("Ann", "x", "", 0, false, false)
pumpSend()
swapPickupWith = nil
check(send.skipped == 1, "the mismatch was caught", send.skipped)
check(table.getn(SENT) == 0, "and NOTHING was mailed", table.getn(SENT))
check(BAGS[0][3] ~= nil and BAGS[0][3].name == "Black Lotus",
      "the wrong item was put back in the bag, not posted")

print("== send: a partial run reports what it left behind ==")
stockBags()
send.Attach(0, 1); send.Attach(0, 2); send.Attach(0, 3)
BAGS[0][2] = nil                      -- Copper Ore is gone
DEFAULT_CHAT_FRAME.messages = {}
send.Start("Ann", "x", "", 0, false, false)
pumpSend()
check(send.skipped == 1, "one skipped", send.skipped)
check(send.sentCount == 2, "two sent", send.sentCount)
local msgs = DEFAULT_CHAT_FRAME.messages
local saidSkipped = false
local pi = 1
while pi <= table.getn(msgs) do
    if A.util.Contains(msgs[pi], "skipped") then saidSkipped = true end
    pi = pi + 1
end
check(saidSkipped, "the user is told, rather than the run looking complete")

print("== send: an item the game refuses to attach costs only that item ==")
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
failAttach = true
send.Start("Ann", "x", "", 0, false, false)
pumpSend()
failAttach = false
check(not send.sending, "run ended")
check(table.getn(SENT) == 0, "NOTHING was sent -- no empty mail went out",
      table.getn(SENT))
check(send.skipped == 2, "both were skipped rather than aborting the batch",
      send.skipped)
check(send.Count() == 2, "attachments kept so the user can retry", send.Count())

print("== send: MAIL_FAILED aborts the batch ==")
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
send.Start("Ann", "x", "", 0, false, false)
arg1 = 5
sdriver.scripts.OnUpdate()          -- first mail issued
arg1 = nil
check(table.getn(SENT) == 1, "first mail out")
-- One refusal no longer kills the batch; exhaust the budget to abort it.
local guard = 0
while send.sending and guard < 10 do
    fire("MAIL_FAILED")
    guard = guard + 1
end
check(not send.sending, "run aborted once the retry budget ran out")
check(send.Count() == 2, "attachment list preserved")

print("== send: a refused mail is retried, not thrown away ==")
-- The reported symptom: "the server rejected that mail; 1 of 2 sent." One
-- refusal on the second mail used to abandon the whole batch.
stockBags()
A.db.ClearLog()
send.Attach(0, 1); send.Attach(0, 2)
failSendCount = 0
sendAttempts = 0
send.Start("Ann", "batch", "", 0, false, false)
-- Let the first mail go, then make the server refuse exactly once.
arg1 = 5
sdriver.scripts.OnUpdate()
arg1 = nil
fire("MAIL_SEND_SUCCESS")
check(table.getn(SENT) == 1, "first mail out")
failSendCount = 1
pumpSend()
check(not send.sending, "run finished")
check(table.getn(SENT) == 2, "BOTH mails were sent despite the refusal",
      table.getn(SENT))
check(SENT[2].item == "Copper Ore", "the retried mail kept its attachment",
      tostring(SENT[2].item))
check(SENT[2].subject == "batch [2/2]", "and its subject numbering",
      SENT[2].subject)
check(send.Count() == 0, "attachment list cleared on success")

print("== send: a retry does not renumber or duplicate gold ==")
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
sendAttempts = 0
send.Start("Ann", "gold", "", 5000, false, false)
arg1 = 5
sdriver.scripts.OnUpdate()
arg1 = nil
fire("MAIL_SEND_SUCCESS")
check(SENT[1].money == 5000, "gold on the first mail")
failSendCount = 1          -- refuse the second once
pumpSend()
check(table.getn(SENT) == 2, "second mail eventually sent")
check(SENT[2].money == 0, "the retry did NOT resend the gold", SENT[2].money)

print("== send: a persistently refused mail gives up cleanly ==")
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
sendAttempts = 0
failSendCount = 99         -- the server refuses everything
send.Start("Ann", "doomed", "", 0, false, false)
local spins = pumpSend(80)
failSendCount = 0
check(not send.sending, "gave up rather than spinning", spins)
check(table.getn(SENT) == 0, "nothing was sent")
check(send.Count() == 2, "and BOTH attachments are still on the list to retry",
      send.Count())

print("== send: the retry budget is per mail, not per batch ==")
-- A long batch that hits a transient refusal on several different mails must
-- still complete; only one mail failing repeatedly aborts.
stockBags()
send.Attach(0, 1); send.Attach(0, 2); send.Attach(0, 3)
sendAttempts = 0
send.Start("Ann", "long", "", 0, false, false)
local sent, guard3 = 0, 0
while send.sending and guard3 < 200 do
    -- Refuse once before each mail, then let it through.
    if sendAttempts == sent * 2 then failSendCount = 1 end
    arg1 = 5
    sdriver.scripts.OnUpdate()
    arg1 = nil
    if sendAttempts > 0 then
        if lastSendFailed then fire("MAIL_FAILED") else
            fire("MAIL_SEND_SUCCESS")
            sent = table.getn(SENT)
        end
    end
    guard3 = guard3 + 1
end
check(table.getn(SENT) == 3, "all three sent despite a refusal each",
      table.getn(SENT))

print("== send: gold mode never touches the COD channel ==")
-- Zeroing BOTH channels on later mails poked a plain gold send into COD mode
-- with a zero amount. Only the channel in use is ever set.
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
sendAttempts = 0
moneyCalls, codCalls = 0, 0
send.Start("Ann", "g", "", 5000, false, false)
pumpSend()
check(table.getn(SENT) == 2, "two mails sent")
check(codCalls == 0, "SetSendMailCOD was never called for a gold send",
      codCalls)
check(moneyCalls > 0, "SetSendMailMoney was", moneyCalls)

-- ...and the mirror image: a COD send never touches the gold channel.
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
sendAttempts = 0
moneyCalls, codCalls = 0, 0
send.Start("Ann", "c", "", 2500, true, false)
pumpSend()
check(moneyCalls == 0, "SetSendMailMoney was never called for a COD send",
      moneyCalls)
check(codCalls > 0, "SetSendMailCOD was", codCalls)

print("== send: recipient autocomplete ==")
A.db.ForgetContacts()
A.db.AddContact("Bobbie")
A.db.AddContact("Bobby")
A.db.AddContact("Annie")
local m = A.db.MatchContacts("Bob", 5)
check(table.getn(m) == 2, "prefix matched", table.getn(m))
check(A.db.MatchContacts("bob", 5)[1] ~= nil, "match is case-insensitive")
check(table.getn(A.db.MatchContacts("Zed", 5)) == 0, "no false matches")
check(table.getn(A.db.MatchContacts("", 2)) == 2, "limit respected")
-- A successful send remembers the recipient.
stockBags()
send.Attach(0, 1)
send.Start("Carlos", "hi", "", 0, false, false)
pumpSend()
check(table.getn(A.db.MatchContacts("Carl", 5)) == 1, "recipient remembered")

print("== send: contacts harvested from the inbox ==")
A.db.ForgetContacts()
INBOX = {
    mail{ sender = "Wanda", subject = "hello" },
    mail{ sender = AH, subject = "Auction successful: Silk Cloth", money = 10 },
    mail{ sender = "GMBob", subject = "ticket", gm = true },
}
-- The harvest is deliberately NOT on MAIL_INBOX_UPDATE any more: that event
-- storms while the client resolves uncached items, and this walks every header.
fire("MAIL_INBOX_UPDATE")
check(table.getn(A.db.MatchContacts("Wanda", 5)) == 0,
      "the event alone does NOT walk the inbox for contacts")
send.HarvestContacts()
check(table.getn(A.db.MatchContacts("Wanda", 5)) == 1, "player sender kept")
check(table.getn(A.db.MatchContacts("Stormwind", 5)) == 0,
      "auction house not offered as a contact")
check(table.getn(A.db.MatchContacts("GMBob", 5)) == 0, "GM not offered")

print("== send: bag right-click only hijacked on the Send tab ==")
stockBags()
A.ui.mailOpen = true
A.ui.OpenWindow()
A.ui.SelectSubTab("Inbox")
check(not A.ui.SendAttachActive(), "not active on the Inbox tab")
local before = useContainerCalls
UseContainerItem(0, 1)
check(useContainerCalls == before + 1, "right-click passed through to the game")
check(send.Count() == 0, "and attached nothing")

A.ui.SelectSubTab("Send")
check(A.ui.SendAttachActive(), "active on the Send tab at a mailbox")
before = useContainerCalls
UseContainerItem(0, 1)
check(useContainerCalls == before, "right-click intercepted")
check(send.Count() == 1, "and attached the item", send.Count())

A.ui.mailOpen = false
check(not A.ui.SendAttachActive(), "not active away from a mailbox")
A.ui.mailOpen = true

print("== send: drag-to-attach uses the remembered cursor origin ==")
stockBags()
A.ui.SelectSubTab("Send")
PickupContainerItem(0, 2)           -- goes through our hook
check(send.cursorItem ~= nil, "cursor origin remembered")
check(send.AttachCursor(), "attached from the cursor")
check(send.attachments[1].name == "Copper Ore", "the right item",
      send.attachments[1].name)

print("== send UI: autocomplete stays shut until you type ==")
A.db.ForgetContacts()
A.db.AddContact("Torchlyte")
A.db.AddContact("Torchlite")
A.db.AddContact("Subtilizer")
A.ui.SelectSubTab("Send")
A.ui.sendTo:SetText("")
A.ui.UpdateAutoComplete()
check(not A.ui.sendAuto:IsVisible(),
      "empty recipient box does not drop the list open")
A.ui.sendTo:SetText("Torch")
A.ui.UpdateAutoComplete()
check(A.ui.sendAuto:IsVisible(), "typing opens it")
A.ui.sendTo:SetText("")
A.ui.UpdateAutoComplete()
check(not A.ui.sendAuto:IsVisible(), "clearing closes it again")
-- The dropdown button lists everyone regardless of what is typed.
check(A.ui.sendAutoButton ~= nil, "dropdown button exists")
A.ui.sendAutoButton.scripts.OnClick()
check(A.ui.sendAuto:IsVisible(), "button opens the full list on an empty box")
A.ui.sendAutoButton.scripts.OnClick()
check(not A.ui.sendAuto:IsVisible(), "button toggles it shut")
A.ui.sendTo:SetText("Zebra")
A.ui.UpdateAutoComplete()
check(not A.ui.sendAuto:IsVisible(), "no matches means no list")
A.ui.sendTo:SetText("")

-- THE REPORTED BUG. The check above only ever clicked the button with an EMPTY
-- box, which is the one case that worked -- so a dead button passed the suite.
-- With a complete name typed, the button used to filter by that name, match
-- exactly one contact (itself), hit the exact-match rule and hide the list
-- again: it appeared to do nothing whatsoever.
A.ui.sendTo:SetText("Torchlyte")
A.ui.UpdateAutoComplete()
check(not A.ui.sendAuto:IsVisible(),
      "typing a complete name shows no suggestion, correctly")
-- Clear every row first. The mock does not propagate a parent's Hide() to its
-- children, so leftover rows from the previous show would otherwise still look
-- "visible" and the count below would pass on stale state.
local si = 1
while si <= 5 do
    A.ui.sendAutoRows[si].name = nil
    A.ui.sendAutoRows[si].label:SetText("")
    A.ui.sendAutoRows[si]:Hide()
    si = si + 1
end
A.ui.sendAutoButton.scripts.OnClick()
check(A.ui.sendAuto:IsVisible(),
      "but the BUTTON still opens the list with that name in the box")
-- It lists everyone, not just what matches the typed text.
local shown = 0
si = 1
while si <= 5 do
    if A.ui.sendAutoRows[si].visible then shown = shown + 1 end
    si = si + 1
end
check(shown == 3, "all three contacts are listed, not just the typed one", shown)
A.ui.sendAutoButton.scripts.OnClick()
check(not A.ui.sendAuto:IsVisible(), "and it still toggles shut")

-- With no contacts at all the button must still visibly answer, or it is the
-- same "does nothing" complaint wearing a different hat.
A.db.ForgetContacts()
A.ui.sendTo:SetText("")
A.ui.sendAutoButton.scripts.OnClick()
check(A.ui.sendAuto:IsVisible(), "an empty contact list still opens the list")
check(A.util.Contains(rawget(A.ui.sendAutoRows[1].label, "text") or "",
      "no saved recipients"), "and says so",
      rawget(A.ui.sendAutoRows[1].label, "text"))
check(A.ui.sendAutoRows[1].name == nil, "the placeholder row is not clickable")
A.ui.sendAutoButton.scripts.OnClick()
A.db.AddContact("Torchlyte")
A.db.AddContact("Torchlite")
A.db.AddContact("Subtilizer")
A.ui.sendTo:SetText("")

print("== version: the title bar cannot drift from the .toc ==")
-- Two releases shipped with the .toc bumped and this literal left behind, so
-- the in-game title kept reporting an old build and bug reports came in
-- against a version that was not running.
local tocVersion
local tf = io.open("Aegis_Courier.toc", "r")
if tf then
    local line = tf:read("*l")
    while line do
        local _, _, v = string.find(line, "^##%s*Version:%s*(.-)%s*$")
        if v then tocVersion = v end
        line = tf:read("*l")
    end
    tf:close()
end
check(tocVersion ~= nil, "found ## Version in the .toc", tostring(tocVersion))
check(A.version == tocVersion,
      "A.version agrees with the .toc",
      tostring(A.version) .. " vs " .. tostring(tocVersion))

print("== compose: Tab walks the form ==")
-- 1.12 has no Tab-order property on an EditBox; OnTabPressed plus an explicit
-- SetFocus is the whole mechanism, which is why this is worth asserting.
A.ui.mailOpen = true
A.ui.OpenWindow()
A.ui.SelectSubTab("Send")
-- The money field is a THREE-box group now (gold/silver/copper), so the chain
-- threads each of them rather than treating it as one stop.
local chain = { A.ui.sendTo, A.ui.sendSubject, A.ui.sendBody,
                A.ui.sendMoney.g, A.ui.sendMoney.s, A.ui.sendMoney.c }
local names = { "To", "Subject", "Body", "Gold", "Silver", "Copper" }
local nChain = table.getn(chain)

local ci = 1
while ci <= nChain do
    check(chain[ci].scripts.OnTabPressed ~= nil,
          names[ci] .. " handles Tab")
    ci = ci + 1
end

A.ui.sendTo:SetFocus()
check(A.ui.sendTo:HasFocus(), "To has the keyboard")
ci = 1
while ci <= nChain - 1 do
    chain[ci].scripts.OnTabPressed()
    check(chain[ci + 1]:HasFocus(),
          "Tab from " .. names[ci] .. " lands on " .. names[ci + 1])
    check(chain[ci]:HasFocus() == false,
          "and " .. names[ci] .. " gives it up")
    ci = ci + 1
end

-- Copper is the last field. Wrapping means Tab never reads as a dead key.
chain[nChain].scripts.OnTabPressed()
check(A.ui.sendTo:HasFocus(), "Tab from the last field wraps back to To")

-- The multiline body is in the chain deliberately: handling OnTabPressed is
-- also what stops Tab typing a literal tab into the message.
A.ui.sendBody:SetFocus()
A.ui.sendBody:SetText("hello")
A.ui.sendBody.scripts.OnTabPressed()
check(A.ui.sendMoney.g:HasFocus(), "Tab out of the multiline body works")
check(A.ui.sendBody:GetText() == "hello",
      "and does not type a tab character into it",
      A.ui.sendBody:GetText())

-- Escape on the recipient box still closes the autocomplete first; the Tab
-- wiring must not have displaced it.
check(A.ui.sendTo.scripts.OnEscapePressed ~= nil,
      "To still handles Escape")
focusedBox = nil

print("== send UI: the Send BUTTON is clickable for a letter ==")
-- The assertion that was missing when "cannot send without an item" was first
-- fixed. send.Validate and send.Start were both corrected and tested, but
-- ui.RefreshSend calls Validate a SECOND time to decide whether the button is
-- clickable at all -- and it was still passing no subject and no body, so the
-- button stayed greyed and the bug survived the fix untouched.
--
-- Testing the engine is not testing the button. This asserts the thing the
-- player actually has to be able to press.
A.ui.SelectSubTab("Send")
A.send.ClearAttachments()
A.ui.sendCOD:SetChecked(false)
A.ui.sendCODAll:SetChecked(false)
A.ui.sendMoney:SetText("")
A.ui.sendTo:SetText("")
A.ui.sendSubject:SetText("")
A.ui.sendBody:SetText("")
A.ui.RefreshSend()
check(not A.ui.btnSend:IsEnabled(), "an empty form cannot be sent")

A.ui.sendTo:SetText("Subtilizer")
A.ui.RefreshSend()
check(not A.ui.btnSend:IsEnabled(), "a recipient alone is not enough")

A.ui.sendSubject:SetText("test")
A.ui.RefreshSend()
check(A.ui.btnSend:IsEnabled() and true,
      "recipient + subject, no attachment: the button is LIVE")

A.ui.sendSubject:SetText("")
A.ui.sendBody:SetText("hi")
A.ui.RefreshSend()
check(A.ui.btnSend:IsEnabled() and true,
      "recipient + body, no attachment: also live")

-- And pressing it actually sends, rather than merely being enabled.
SENT = {}
A.ui.sendSubject:SetText("test")
A.ui.RefreshSend()
A.ui.btnSend.scripts.OnClick()
pumpSend()
check(table.getn(SENT) == 1, "clicking Send posts the letter", table.getn(SENT))
check(SENT[1].to == "Subtilizer", "to the right person", SENT[1].to)
check(SENT[1].item == nil, "with nothing attached", tostring(SENT[1].item))

A.ui.sendTo:SetText("")
A.ui.sendSubject:SetText("")
A.ui.sendBody:SetText("")
A.ui.RefreshSend()

print("== send UI: COD-all is greyed until COD is checked ==")
A.ui.sendCOD:SetChecked(false)
A.ui.sendCODAll:SetChecked(true)     -- stale state from a previous send
A.ui.RefreshSend()
check(A.ui.sendCODAll:GetChecked() == false,
      "a disabled COD-all cannot stay checked")
check(not A.ui.sendCODAll:IsEnabled(), "and is greyed out")
A.ui.sendCOD:SetChecked(true)
A.ui.RefreshSend()
check(A.ui.sendCODAll:IsEnabled() and true, "checking COD enables it")
A.ui.sendCODAll:SetChecked(true)
A.ui.RefreshSend()
check(A.ui.sendCODAll:GetChecked() == true, "and it stays checked while COD is on")
A.ui.sendCOD:SetChecked(false)
A.ui.RefreshSend()
check(not A.ui.sendCODAll:IsEnabled(), "unchecking COD greys it again")
check(A.ui.sendCODAll:GetChecked() == false, "and clears it")

print("== send: UI refresh paths run clean ==")
A.ui.RefreshSend()
A.ui.ClearSendForm()
check(send.Count() == 0, "Clear empties the form")
A.ui.SelectSubTab("Send")
A.ui.Refresh()
check(true, "send tab refresh runs without error")

-- =========================================================================
-- Stage C.2: the correspondence log
-- =========================================================================

print("== unread flag: taking a mail marks it read ==")
A.ui.mailOpen = true
A.ui.OpenWindow()
readCalls = 0
INBOX = {
    mail{ sender = AH, subject = "Auction successful: Silk Cloth", money = 9500 },
    mail{ sender = "Bob", subject = "gift", item = "Copper Ore" },
}
check(INBOX[1].wasRead == nil, "starts unread")
take.Start(take.MODE_TAKE)     -- keeps the mail, so we can inspect it after
pump()
check(readCalls >= 2, "GetInboxText called for each mail taken", readCalls)
check(INBOX[1].wasRead == 1, "first mail marked read")
check(INBOX[2].wasRead == 1, "second mail marked read")
check(A.inbox.UnreadCount() == 0, "nothing unread left",
      A.inbox.UnreadCount())

print("== unread flag: mail we only LOOK at is never marked read ==")
-- Reading a mail with attachments drops its expiry to three days, so merely
-- displaying the inbox must not do it.
readCalls = 0
INBOX = { mail{ sender = "Bob", subject = "keep me", money = 100 } }
A.ui.SelectSubTab("Inbox")
A.ui.RefreshInbox()
A.inbox.All()
A.inbox.Summary()
check(readCalls == 0, "browsing the inbox marks nothing read", readCalls)
check(INBOX[1].wasRead == nil, "and the mail is still unread")

print("== unread flag: COD and GM mail are not marked read either ==")
readCalls = 0
INBOX = {
    mail{ sender = "Ann", subject = "pay up", money = 100, cod = 5000 },
    mail{ sender = "GM", subject = "ticket", money = 700, gm = true },
}
take.Start(take.MODE_OPEN)
pump()
check(readCalls == 0, "skipped mail is left completely alone", readCalls)
check(INBOX[1].wasRead == nil, "COD mail still unread")

print("== unread flag: Delete Read now has something to find ==")
-- Same root cause: with nothing ever marked read, Delete Read was permanently
-- empty-handed and its button permanently greyed.
INBOX = {
    mail{ sender = "Bob", subject = "gift", item = "Copper Ore" },
    mail{ sender = "Ann", subject = "note", money = 50 },
}
check(take.HasWork(take.MODE_DELETE) == false, "nothing to delete yet")
take.Start(take.MODE_TAKE)      -- empties them but keeps them
pump()
check(table.getn(INBOX) == 2, "mails kept")
check(take.HasWork(take.MODE_DELETE) == true,
      "emptied-and-read mail is now deletable")
take.Start(take.MODE_DELETE)
pump()
check(table.getn(INBOX) == 0, "and Delete Read clears them",
      table.getn(INBOX))

print("== unread flag: the minimap icon is put out on close ==")
INBOX = { mail{ sender = "Bob", subject = "x", money = 100 } }
fire("MAIL_INBOX_UPDATE")
driver.scripts.OnUpdate()       -- the count settles on the coalesced flush
check(A.inbox.lastUnread == 1, "unread tracked while open", A.inbox.lastUnread)
MiniMapMailFrame:Show()
fire("MAIL_CLOSED")
check(MiniMapMailFrame:IsVisible(),
      "icon LEFT ALONE while a mail is still unread")

A.ui.mailOpen = true
A.ui.OpenWindow()
take.Start(take.MODE_OPEN)
pump()
fire("MAIL_INBOX_UPDATE")
driver.scripts.OnUpdate()
check(A.inbox.lastUnread == 0, "nothing unread after the run")
MiniMapMailFrame:Show()
fire("MAIL_CLOSED")
check(not MiniMapMailFrame:IsVisible(), "icon cleared once nothing is unread")

print("== unread flag: an empty inbox also clears it ==")
A.ui.mailOpen = true
A.ui.OpenWindow()
INBOX = {}
fire("MAIL_INBOX_UPDATE")
MiniMapMailFrame:Show()
fire("MAIL_CLOSED")
check(not MiniMapMailFrame:IsVisible(), "no mail means nothing unread")

print("== big inbox: no freeze past ROWS mails ==")
-- The reported crash: 11+ mails (list rows = 10) hang then kill the client.
-- The FrameXML chain FauxScrollFrame_Update -> OnValueChanged ->
-- SetVerticalScroll -> OnVerticalScroll -> updateFunction is mutual recursion
-- unless the refresher bounces re-entry; the mock above reproduces it, so an
-- unguarded RefreshInbox blows the Lua stack right here.
A.ui.mailOpen = true
A.ui.OpenWindow()
A.ui.SelectSubTab("Inbox")

local function bigInbox(n)
    INBOX = {}
    local i = 1
    while i <= n do
        table.insert(INBOX, mail{ sender = "Bob" .. i, subject = "mail " .. i,
            money = 10 })
        i = i + 1
    end
end

-- Row counts derive from ROWS, not literals: the crash threshold IS
-- ROWS + 1, so a hardcoded 11 silently stops testing anything the moment the
-- list grows.
local ROWS_N = A.ui.Geometry().rows

-- Exactly ROWS mails: scrollbar dormant, nothing refires.
bigInbox(ROWS_N)
scrollRefires = 0
check(pcall(A.ui.RefreshInbox) == true, "a full page refreshes cleanly")
check(scrollRefires == 0, "scrollbar dormant at exactly ROWS mails",
      scrollRefires)

-- ROWS + 1, scrolled: the scrollbar is live and refires synchronously.
bigInbox(ROWS_N + 1)
rawset(A.ui.inboxScroll, "value", 28)      -- user has scrolled one row down
scrollRefires = 0
local okBig = pcall(A.ui.RefreshInbox)
check(okBig == true,
      "ROWS+1 mails, scrolled: refresh terminates (the crash case)")
check(scrollRefires > 0, "and the re-entrant scroll path genuinely fired",
      scrollRefires)

-- A full 54-mail box, scrolled deep -- the reporter's screenshot.
bigInbox(54)
rawset(A.ui.inboxScroll, "value", 40 * 28)
check(pcall(A.ui.RefreshInbox) == true, "54 mails, scrolled deep: no freeze")

print("== big inbox: Open All completes while the list shrinks ==")
-- The worst case in play: every delete shifts the list under a live, scrolled
-- scrollbar, so every MAIL_INBOX_UPDATE clamps the value and re-enters.
bigInbox(30)
rawset(A.ui.inboxScroll, "value", 20 * 28)
A.db.ClearLedger()
take.Start(take.MODE_OPEN)
local okRun, err = pcall(pump, 400)
check(okRun == true, "run survived", err)
check(not take.running, "and finished")
check(table.getn(INBOX) == 0, "30-mail box fully emptied", table.getn(INBOX))

print("== storm: MAIL_INBOX_UPDATE is coalesced to one flush per frame ==")
-- A first mailbox open fires MAIL_INBOX_UPDATE once per mail whose item the
-- client still has to resolve from the server, so a full box lands hundreds of
-- events across a handful of frames. Each one used to walk every header about
-- five times over (UnreadCount, HasWork x3, All, Summary) and repaint the list.
-- At 70 mails that is ~350 header reads and a full paint PER EVENT -- the
-- freeze the reporters hit. The events now only raise a flag; the driver does
-- the work once per frame.
A.ui.mailOpen = true
A.ui.OpenWindow()
A.ui.SelectSubTab("Inbox")
bigInbox(70)
rawset(A.ui.inboxScroll, "value", 30 * 28)   -- scrollbar live and scrolled

-- Warm up first, then measure: the very first flush of a visit also seeds
-- inbox.lastUnread, so measuring from a settled state keeps the comparison
-- below honest rather than accidentally passing on a state difference.
A.inbox.MarkDirty()
driver.scripts.OnUpdate()

A.inbox.MarkDirty()
headerReads = 0
driver.scripts.OnUpdate()
local oneFlush = headerReads
check(oneFlush > 0, "a flush does read the inbox", oneFlush)

headerReads = 0
local stormN = 1
while stormN <= 200 do
    fire("MAIL_INBOX_UPDATE")
    stormN = stormN + 1
end
check(headerReads == 0, "200 events did NO inbox work of their own", headerReads)
check(A.inbox.dirty == true, "they only raised the dirty flag")

driver.scripts.OnUpdate()
check(headerReads == oneFlush,
      "200 events cost exactly one flush, not 200",
      headerReads .. " reads vs one flush = " .. oneFlush)
check(A.inbox.dirty == false, "and the frame cleared the flag")

-- Nothing dirty means nothing to do: a quiet frame must not walk the inbox
-- either, or the coalescing just moves the cost from the event to every frame.
headerReads = 0
driver.scripts.OnUpdate()
check(headerReads == 0, "an idle frame does no inbox work at all", headerReads)

print("== storm: the take engine still steps once per confirmation ==")
-- Coalescing must not reach the take engine's clock. MAIL_INBOX_UPDATE is the
-- server's acknowledgement that the last operation landed, and one Step per
-- confirmation is what keeps the run in lockstep with the server instead of
-- racing it. Arming has to stay per-event even though the repaint does not.
bigInbox(3)
A.db.ClearLedger()
take.Start(take.MODE_OPEN)
check(take.running, "run started")
take.armed = false
fire("MAIL_INBOX_UPDATE")
check(take.armed == true, "a confirmation still arms the next step")
local okStorm = pcall(pump, 400)
check(okStorm == true, "and the run completes")
check(table.getn(INBOX) == 0, "emptying the box", table.getn(INBOX))

print("== reader: opening a mail ==")
A.ui.mailOpen = true
A.ui.OpenWindow()
A.ui.SelectSubTab("Inbox")
INBOX = {
    mail{ sender = "Wanda", subject = "hello there", body = "see you at 8" },
    mail{ sender = "Bob", subject = "supplies", money = 500,
          item = "Copper Ore", body = "here you go" },
}
check(A.ui.ReaderOpen() == false, "the list is what shows first")
check(A.ui.OpenReader(1) == true, "left-click opens mail 1")
check(A.ui.ReaderOpen(), "the reader is open")
check(A.ui.reader.visible == true, "and visible")
check(rawget(A.ui.readerFrom, "text") == "Wanda", "sender shown",
      rawget(A.ui.readerFrom, "text"))
check(A.ui.inboxRows[1].visible == false, "the list rows gave up the well")
A.ui.CloseReader()
check(A.ui.ReaderOpen() == false, "Back returns to the list")
check(A.ui.inboxRows[1].visible == true, "and the rows come back")

print("== reader: an empty mail is read at once, a loaded one is not ==")
-- CLAUDE.md rule 17: GetInboxText marks a mail read AND, on mail that still
-- holds something, drops the expiry to three days. So opening a loaded mail
-- must NOT fetch a body until the player asks for it. These assert on the
-- mail's own daysLeft rather than on call counts -- the expiry IS the damage.
INBOX = {
    mail{ sender = "Wanda", subject = "just a note", body = "no strings" },
    mail{ sender = "Bob", subject = "loot", money = 500, item = "Copper Ore",
          body = "enjoy", daysLeft = 29 },
}
A.ui.OpenReader(1)
check(rawget(A.ui.readerBody, "text") == "no strings",
      "an empty mail renders its body immediately",
      rawget(A.ui.readerBody, "text"))
check(INBOX[1].wasRead == 1, "and is marked read, which is what clears the icon")
check(A.ui.readerReveal.visible == false, "no reveal button needed")

A.ui.CloseReader()
local before = readCalls
A.ui.OpenReader(2)
check(readCalls == before, "opening a LOADED mail calls GetInboxText 0 times",
      readCalls - before)
check(INBOX[2].daysLeft == 29, "so its expiry is untouched", INBOX[2].daysLeft)
check(INBOX[2].wasRead == nil, "and it is still unread")
check(A.ui.readerReveal.visible == true, "the reveal button is offered instead")
check(A.ui.readerWarn.visible == true, "with the three-day warning")
check(rawget(A.ui.readerBody, "text") == "", "and no body is shown")
-- Header detail is free: it all comes from GetInboxHeaderInfo.
check(rawget(A.ui.readerFrom, "text") == "Bob", "sender still shown")
check(rawget(A.ui.readerAttach, "text") == "Copper Ore", "attachment named",
      rawget(A.ui.readerAttach, "text"))

-- Now the player accepts the cost.
A.ui.readerReveal.scripts.OnClick()
check(rawget(A.ui.readerBody, "text") == "enjoy", "the body appears on request",
      rawget(A.ui.readerBody, "text"))
check(INBOX[2].daysLeft == 3, "and only NOW does the expiry drop to three days",
      INBOX[2].daysLeft)
check(A.ui.readerReveal.visible == false, "the reveal button steps aside")

print("== reader: a body that has not arrived yet ==")
-- GetInboxText returns nil while the client is still asking the server for the
-- text. That is not an empty message and must not be rendered as one.
INBOX = { mail{ sender = "Wanda", subject = "slow", body = "at last",
                bodyDelay = true } }
A.ui.CloseReader()
A.ui.OpenReader(1)
check(A.util.Contains(rawget(A.ui.readerBody, "text") or "", "Loading"),
      "a nil body reads as loading, not as an empty message",
      rawget(A.ui.readerBody, "text"))
fire("MAIL_INBOX_UPDATE")
driver.scripts.OnUpdate()
check(rawget(A.ui.readerBody, "text") == "at last",
      "and the text lands on the next refresh",
      rawget(A.ui.readerBody, "text"))

print("== reader: auction invoices ==")
INBOX = { mail{ sender = AH, subject = "Auction successful: Silk Cloth",
                money = 9500, body = "",
                invoice = { kind = "seller", item = "Silk Cloth",
                            bid = 10000, buyout = 10000, deposit = 60,
                            consignment = 500 } } }
A.ui.CloseReader()
A.ui.OpenReader(1)
A.ui.readerReveal.scripts.OnClick()
local invText = rawget(A.ui.readerBody, "text") or ""
check(A.util.Contains(invText, "Silk Cloth"), "the invoice names the item")
check(A.util.Contains(invText, "house cut"), "and reports the consignment cut")

print("== reader: it never outlives the mail it is showing ==")
-- A held index is only meaningful while the inbox does not move under it.
-- Three mails, reading the middle one. Deleting mail 1 shifts mail 3 into
-- index 2, so the index STAYS VALID but now addresses a different mail --
-- which is the case a nil-header check alone would sail straight past.
INBOX = {
    mail{ sender = "Wanda", subject = "one" },
    mail{ sender = "Bob", subject = "two" },
    mail{ sender = "Cass", subject = "three" },
}
A.ui.CloseReader()
A.ui.OpenReader(2)
check(A.ui.ReaderOpen(), "reading mail 2")
check(rawget(A.ui.readerFrom, "text") == "Bob", "which is Bob's")
table.remove(INBOX, 1)             -- Cass's mail slides into index 2
check(A.inbox.Header(2) ~= nil, "index 2 is still a real mail")
check(A.inbox.Header(2).sender == "Cass", "but a DIFFERENT one now")
A.ui.RefreshInbox()
check(A.ui.ReaderOpen() == false,
      "a different mail sliding into the index closes the reader")
check(A.ui.inboxRows[1].visible == true, "and the list is painted instead")

INBOX = { mail{ sender = "Wanda", subject = "one" } }
A.ui.OpenReader(1)
check(A.ui.ReaderOpen(), "reading the only mail")
INBOX = {}
A.ui.RefreshInbox()
check(A.ui.ReaderOpen() == false, "an emptied inbox closes the reader too")

print("== reader: it stands aside for a take run ==")
INBOX = {
    mail{ sender = "Bob", subject = "gold", money = 100 },
    mail{ sender = "Ann", subject = "more gold", money = 200 },
}
A.ui.CloseReader()
A.ui.OpenReader(1)
check(A.ui.ReaderOpen(), "reader open before the run")
take.Start(take.MODE_OPEN)
A.ui.RefreshInbox()
check(A.ui.ReaderOpen() == false,
      "a run closes it -- deletes shift every later index")
check(A.ui.OpenReader(1) == false, "and it refuses to reopen mid-run")
pump()
check(not take.running, "run finished")
check(A.ui.OpenReader ~= nil, "the reader is available again afterwards")

print("== reader: leaving the Inbox tab drops it ==")
INBOX = { mail{ sender = "Wanda", subject = "one" } }
A.ui.SelectSubTab("Inbox")
A.ui.OpenReader(1)
check(A.ui.ReaderOpen(), "open on the Inbox tab")
A.ui.SelectSubTab("Log")
check(A.ui.ReaderOpen() == false, "switching tabs closes it")
A.ui.SelectSubTab("Inbox")
check(A.ui.ReaderOpen() == false, "and coming back lands on the list")

print("== reader: COD and GM mail offer no Take button ==")
INBOX = {
    mail{ sender = "Ann", subject = "pay up", money = 100, cod = 5000 },
    mail{ sender = "GM", subject = "ticket", money = 700, gm = true },
}
A.ui.OpenReader(1)
check(A.ui.readerTake.visible == false, "no Take button on COD mail")
check(A.util.Contains(rawget(A.ui.readerStatus, "text") or "", "COD"),
      "and the reason is stated")
A.ui.CloseReader()
A.ui.OpenReader(2)
check(A.ui.readerTake.visible == false, "no Take button on GM mail")
A.ui.CloseReader()

print("== ui: the Take All button is gone ==")
check(A.ui.btnTakeAll == nil, "no Take All button is built")
check(getglobal("AegisCourierBtnTakeAll") == nil, "and no global left behind")
check(A.ui.btnOpenAll ~= nil and A.ui.btnDeleteRead ~= nil and
      A.ui.btnStop ~= nil, "the other three action buttons survive")
-- The mode stays reachable from Lua on purpose: it is how the tests below
-- observe an emptied-but-still-present mail.
check(take.MODE_TAKE == "take", "MODE_TAKE remains available to callers")

print("== geometry: every list's rows fit inside its own well ==")
-- The reported clipping bug: the window was a literal 440 tall, which left the
-- Inbox well 264px while its own ten rows needed 288. 1.12 frames do not clip
-- their children, so row 10 drew through the well border and over the hint
-- line. The mock does not simulate layout, so this asserts the arithmetic the
-- anchors themselves are built from -- change ROWS or an inset and it fires.
local geom = A.ui.Geometry()
check(geom.need == geom.rows * geom.rowH + 8,
      "rows plus padding is what a well must hold", geom.need)
check(geom.inbox >= geom.need,
      "Inbox well holds its rows", geom.inbox .. " have vs " .. geom.need)
check(geom.log >= geom.need,
      "Log well holds its rows", geom.log .. " have vs " .. geom.need)
check(geom.ledger >= geom.need,
      "Ledger well holds its rows", geom.ledger .. " have vs " .. geom.need)
-- The Inbox is the tightest panel, so it is the one that sets the window
-- height. If it ever stops being the binding constraint the window is bigger
-- than it needs to be, which is worth noticing.
check(geom.inbox <= geom.log and geom.inbox <= geom.ledger,
      "the Inbox is still the tightest list, so it sets the window height")
check(geom.winH == geom.panelH + geom.panelTop + geom.panelBottom,
      "window height derives from the panel", geom.winH)
-- The panels must start BELOW the title bar and the tab row. Arithmetic that
-- merely balances can still put a panel on top of the tabs, and 1.12 draws
-- that overlap instead of clipping it.
check(geom.panelTop >= geom.chromeH,
      "panels clear the title bar and tab row",
      geom.panelTop .. " top vs " .. geom.chromeH .. " of chrome")
-- And they must clear the dialog border's 10px art on the sides.
check(geom.side >= 10, "panels clear the window border", geom.side)

-- The footer sits BELOW the content well, on the window itself, so the well's
-- bottom edge has to clear it. It did not: the well ended 16px up while the
-- footer occupied 14..26, and the recessed plate drew straight over the text.
-- Reported from live play as clipping at "At mailbox | linked to Aegis".
check(geom.contentBottom >= geom.footerTop,
      "the content well clears the footer text",
      geom.contentBottom .. " well bottom vs " .. geom.footerTop ..
      " footer top")
-- The footer itself has to clear the dialog border's 10px of art, or it is
-- drawn half-underneath the frame instead of half-underneath the well.
check(geom.footerInset >= 10, "and the footer clears the window border",
      geom.footerInset)

print("== resize: rows are derived from the live window height ==")
-- The dependency used to run ROWS -> height. With a grip it must run the other
-- way, or dragging taller leaves a blank gap instead of showing more mail.
local gr = A.ui.Geometry()
check(gr.minH < gr.defaultH and gr.defaultH < gr.maxH,
      "min < default < max", gr.minH .. " / " .. gr.defaultH .. " / " .. gr.maxH)
check(A.ui.Geometry(gr.minH).rows < A.ui.Geometry(gr.maxH).rows,
      "a taller window shows more rows",
      A.ui.Geometry(gr.minH).rows .. " -> " .. A.ui.Geometry(gr.maxH).rows)
check(A.ui.Geometry(gr.maxH).rows <= gr.maxRows,
      "and never more rows than there are frames built",
      A.ui.Geometry(gr.maxH).rows .. " vs " .. gr.maxRows)
check(A.ui.Geometry(gr.minH).rows >= gr.minRows,
      "nor fewer than the floor", A.ui.Geometry(gr.minH).rows)
-- Absurd heights must clamp rather than produce a negative or vast row count.
check(A.ui.Geometry(10).rows == gr.minRows, "a tiny height clamps to the floor",
      A.ui.Geometry(10).rows)
check(A.ui.Geometry(99999).rows == gr.maxRows, "a huge one clamps to the ceiling",
      A.ui.Geometry(99999).rows)

-- The original clipping invariant still has to hold at EVERY size, not just
-- the one the window happens to open at.
local hs = { gr.minH, gr.defaultH, gr.maxH }
local hn = { "minimum", "default", "maximum" }
local ri = 1
while ri <= 3 do
    local g = A.ui.Geometry(hs[ri])
    check(g.inbox >= g.need, "Inbox rows fit their well at " .. hn[ri],
          g.inbox .. " have vs " .. g.need)
    check(g.log >= g.need, "Log rows fit at " .. hn[ri], g.log)
    check(g.ledger >= g.need, "Ledger rows fit at " .. hn[ri], g.ledger)
    ri = ri + 1
end

check(A.ui.resizeGrip ~= nil, "the resize grip exists")
check(A.ui.resizeGrip.courierNoSkin == true,
      "and opts out of the pfUI skin, which would strip its texture")

print("== resize: the size is remembered, clamped ==")
A.db.SaveWindowSize(700, 600)
local sw, sh = A.db.GetWindowSize()
check(sw == 700 and sh == 600, "a size round-trips", tostring(sw) .. "x" .. tostring(sh))
-- Storage is raw; the clamp happens on restore, because MIN/MAX can change
-- between releases and a window smaller than its contents cannot be recovered
-- from in-game.
A.db.SaveWindowSize(10, 10)
sw, sh = A.db.GetWindowSize()
check(sw == 10, "storage does not clamp", sw)

print("== scale: clamped, stepped, and independent of size ==")
A.db.SaveWindowScale(nil)
check(A.ui.WindowScale() == 1, "defaults to 1", A.ui.WindowScale())
A.ui.StepWindowScale(0.05)
check(A.ui.WindowScale() > 1, "a step up raises it", A.ui.WindowScale())
A.ui.StepWindowScale(nil)
check(A.ui.WindowScale() == 1, "reset returns to 1", A.ui.WindowScale())
local si = 1
while si <= 40 do A.ui.StepWindowScale(0.05) si = si + 1 end
check(A.ui.WindowScale() <= 1.50, "cannot exceed the ceiling", A.ui.WindowScale())
-- The STORED value must be clamped too, not just the value WindowScale hands
-- back. Reading clamps as well, so asserting only on the reader passes even
-- when the writer stores nonsense -- and a saved 3.0 is a latent surprise for
-- anything that reads the DB directly.
check(A.db.GetWindowScale() <= 1.50, "and the stored value is clamped, not just the read",
      A.db.GetWindowScale())
si = 1
while si <= 60 do A.ui.StepWindowScale(-0.05) si = si + 1 end
check(A.ui.WindowScale() >= 0.70, "nor drop below the floor", A.ui.WindowScale())
check(A.db.GetWindowScale() >= 0.70, "stored value clamped at the floor too",
      A.db.GetWindowScale())
A.ui.StepWindowScale(nil)
-- Scale is stored separately from size: someone who scaled but never dragged
-- has no saved width, and restoring must not lose their scale on that account.
A.db.SaveWindowScale(1.25)
check(A.db.GetWindowScale() == 1.25, "scale persists on its own",
      A.db.GetWindowScale())
A.db.SaveWindowScale(nil)

print("== money: the gold/silver/copper group ==")
local mg = A.ui.sendMoney
check(mg.g ~= nil and mg.s ~= nil and mg.c ~= nil, "three boxes exist")
mg:SetText("12g 30s 5c")
check(mg.g:GetText() == "12", "gold box", mg.g:GetText())
check(mg.s:GetText() == "30", "silver box", mg.s:GetText())
check(mg.c:GetText() == "5", "copper box", mg.c:GetText())
check(A.util.ParseMoney(mg:GetText()) == 123005, "round-trips to copper",
      A.util.ParseMoney(mg:GetText()))
-- LEADING zeros blank, trailing ones shown. Exchange shipped [ ][0][11] for
-- 11 copper, where the empty gold box beside a zero silver read as a missing
-- value rather than "no silver".
mg:SetText("11c")
check(mg.g:GetText() == "", "no gold: blank, not 0", "[" .. mg.g:GetText() .. "]")
check(mg.s:GetText() == "", "no silver: blank too", "[" .. mg.s:GetText() .. "]")
check(mg.c:GetText() == "11", "copper shown", mg.c:GetText())
mg:SetText("1g 0s 0c")
check(mg.s:GetText() == "0", "an INNER zero is shown, not blanked",
      "[" .. mg.s:GetText() .. "]")
check(mg.c:GetText() == "0", "and so is a trailing one", "[" .. mg.c:GetText() .. "]")
mg:SetText("")
check(mg:GetText() == "", "empty round-trips as empty", "[" .. mg:GetText() .. "]")
check(A.ui.SendMoneyValue() == 0, "and reads as zero copper",
      A.ui.SendMoneyValue())

print("== geometry: the Sent reader's blocks fit without overlapping ==")
local sg = A.ui.SentGeometry()
check(sg.slots >= send.MAX_ATTACHMENTS,
      "every item a batch can hold has a visible slot -- no scrolling needed",
      sg.slots .. " slots for " .. send.MAX_ATTACHMENTS .. " max items")

-- The window resizes now, so the reader is checked ACROSS THE RANGE rather
-- than at one hand-picked height. The blocks must FIT -- they no longer sum to
-- exactly the reader, because the message well is capped and anything past the
-- cap is deliberately left blank.
local gg = A.ui.Geometry()
local heights = { gg.minH, gg.defaultH, gg.maxH }
local hnames  = { "minimum", "default", "maximum" }
local hi = 1
while hi <= 3 do
    local sgh = A.ui.SentGeometry(heights[hi])
    check(sgh.head + sgh.items + sgh.gap + sgh.bodyH + sgh.foot <= sgh.readerH,
          "reader blocks fit at " .. hnames[hi] .. " size",
          sgh.head + sgh.items + sgh.gap + sgh.bodyH + sgh.foot ..
          " into " .. sgh.readerH)
    -- The floor exists because a 500-character message needs somewhere to go.
    -- Before MIN_H was derived from the reader it collapsed to 36px here.
    check(sgh.bodyH >= sgh.bodyMin,
          "the message well stays usable at " .. hnames[hi] .. " size",
          sgh.bodyH .. " vs floor " .. sgh.bodyMin)
    -- And the ceiling exists because past it the well is empty space, not
    -- more message. v1.5.0 let it reach 204px and it read as a huge blank box.
    check(sgh.bodyH <= sgh.bodyMax,
          "and never grows into empty space at " .. hnames[hi] .. " size",
          sgh.bodyH .. " vs cap " .. sgh.bodyMax)
    hi = hi + 1
end
check(A.ui.SentGeometry(gg.defaultH).bodyH < 204,
      "the default message well is shorter than v1.5.0's",
      A.ui.SentGeometry(gg.defaultH).bodyH)

print("== clock: a step that skips a mail must re-arm itself ==")
-- take.armed is set by nothing but MAIL_INBOX_UPDATE, and the server only
-- sends that after an operation it actually performed. So a step that SKIPS a
-- mail issues no call, gets no acknowledgement, and -- before the self-clock
-- in take.Advance -- hung the run for good with take.running still true.
--
-- These assert on serverCalls directly rather than trusting the pump, because
-- the pump firing an unconditional event is exactly what hid this for 388
-- checks. The mail placed at index 1 is one the engine must step OVER, so the
-- very first step is the silent one.

-- COD at the head: Open All must skip it and still reach the mail behind it.
INBOX = {
    mail{ sender = "Ann", subject = "pay up", money = 100, cod = 5000 },
    mail{ sender = "Bob", subject = "gold", money = 400 },
}
A.db.ClearLedger()
take.Start(take.MODE_OPEN)
local callsBefore = serverCalls
driver.scripts.OnUpdate()          -- the skip step: issues nothing
check(serverCalls == callsBefore, "skipping a COD mail calls the server 0 times")
check(take.armed == true, "and the engine re-armed itself instead of hanging")
check(pump() > 0 and not take.running, "the run then completes")
check(table.getn(INBOX) == 1, "COD mail survives", table.getn(INBOX))
check(INBOX[1].cod == 5000, "and it is the COD one that survived")

-- GM mail at the head: same path.
INBOX = {
    mail{ sender = "GM", subject = "ticket", money = 700, gm = true },
    mail{ sender = "Bob", subject = "gold", money = 400 },
}
take.Start(take.MODE_OPEN)
pump()
check(not take.running, "a GM mail at the head does not hang the run")
check(table.getn(INBOX) == 1, "GM mail survives", table.getn(INBOX))

-- Delete Read walking past mail it must not touch.
INBOX = {
    mail{ sender = "Bob", subject = "unread", money = 0 },
    mail{ sender = "Ann", subject = "read+empty", money = 0, read = true },
}
take.Start(take.MODE_DELETE)
pump()
check(not take.running, "Delete Read does not hang on the first mail it skips")
check(table.getn(INBOX) == 1, "it deleted only the read empty mail",
      table.getn(INBOX))
check(INBOX[1].subject == "unread", "and kept the unread one")

-- The wedge guard's give-up path is a skip too.
-- The second mail carries an ITEM rather than money, because failTakeMoney is
-- a global switch on the stub: leaving it money would refuse that one too and
-- the test would pass for the wrong reason.
INBOX = {
    mail{ sender = "Bob", subject = "stuck", money = 100 },
    mail{ sender = "Ann", subject = "fine", item = "Copper Ore" },
}
failTakeMoney = true               -- the server refuses money forever
take.Start(take.MODE_OPEN)
pump()
failTakeMoney = false
check(not take.running, "the wedge guard giving up does not hang the run")
check(table.getn(INBOX) == 1, "it moved on and cleared the mail it could",
      table.getn(INBOX))
check(INBOX[1].subject == "stuck", "leaving the refused mail alone")

print("== big lists: Log and Ledger carry the same guard ==")
A.db.ClearLog()
local i2 = 1
while i2 <= 15 do
    A.db.LogAdd("received", { who = "Bob" .. i2, subject = "x" })
    i2 = i2 + 1
end
A.ui.SelectSubTab("Log")
rawset(A.ui.logScroll, "value", 28)
check(pcall(A.ui.RefreshLog) == true, "Log refresh terminates at 15 entries")
A.db.ClearLedger()
i2 = 1
while i2 <= 15 do
    A.db.RecordTxn("sale", "Item" .. i2, 100)
    i2 = i2 + 1
end
A.ui.SelectSubTab("Ledger")
rawset(A.ui.ledgerScroll, "value", 28)
check(pcall(A.ui.RefreshLedger) == true,
      "Ledger refresh terminates at 15 entries")
A.db.ClearLedger()
A.db.ClearLog()

print("== inbox: return to sender ==")
A.ui.mailOpen = true
A.ui.OpenWindow()
A.ui.SelectSubTab("Inbox")
returned = {}
INBOX = {
    mail{ sender = "Bob", subject = "wrong person", item = "Copper Ore" },
    mail{ sender = AH, subject = "Auction expired: Silk Cloth",
          item = "Silk Cloth" },
    mail{ sender = "GMBob", subject = "ticket", gm = true },
}
-- canReply is what FrameXML itself gates its Reply button on. The mail helper
-- sets it for every mail, so clear it on the ones the server would not.
INBOX[2].canReply = nil
INBOX[3].canReply = nil

A.ui.RefreshInbox()
check(A.ui.inboxRows[1].ret:IsVisible(), "player mail offers Return")
check(not A.ui.inboxRows[2].ret:IsVisible(),
      "auction mail does not -- it cannot be returned")
check(not A.ui.inboxRows[3].ret:IsVisible(), "GM mail does not either")

A.ui.ReturnMail(1)
check(table.getn(returned) == 1, "returned once", table.getn(returned))
check(returned[1] == "Bob", "to the right sender", returned[1])
check(table.getn(INBOX) == 2, "and the mail left the inbox", table.getn(INBOX))

-- Refusals.
returned = {}
A.ui.ReturnMail(1)      -- now the auction mail, canReply unset
check(table.getn(returned) == 0, "refuses mail that cannot be returned")
A.ui.ReturnMail(nil)
check(table.getn(returned) == 0, "nil index is safe")
A.ui.ReturnMail(99)
check(table.getn(returned) == 0, "out-of-range index is safe")

print("== inbox: Return is unavailable during a run ==")
INBOX = { mail{ sender = "Bob", subject = "x", money = 100 },
          mail{ sender = "Ann", subject = "y", money = 200 } }
returned = {}
take.Start(take.MODE_TAKE)
A.ui.RefreshInbox()
check(not A.ui.inboxRows[1].ret:IsVisible(),
      "hidden while the take engine is walking the inbox")
A.ui.ReturnMail(1)
check(table.getn(returned) == 0,
      "and refused if called anyway -- it would shift indices mid-run")
take.Stop(true)
A.ui.RefreshInbox()
check(A.ui.inboxRows[1].ret:IsVisible(), "back once the run ends")

print("== log: received mail is logged on collection ==")
A.db.ClearLog()
A.db.ClearLedger()
INBOX = {
    mail{ sender = AH, subject = "Auction successful: Silk Cloth", money = 9500 },
    mail{ sender = "Bob", subject = "a gift", item = "Copper Ore" },
    mail{ sender = "Ann", subject = "pay up", money = 100, cod = 5000 },
}
take.Start(take.MODE_OPEN)
pump()
local rec = A.db.Log("received")
check(table.getn(rec) == 2, "two mails logged, COD skipped", table.getn(rec))
check(rec[1].who == AH, "sender recorded", rec[1].who)
check(rec[1].money == 9500, "money recorded", rec[1].money)
check(rec[1].auction == "sold", "auction kind tagged", tostring(rec[1].auction))
check(rec[2].item == "Copper Ore", "attached item name recorded",
      tostring(rec[2].item))
check(rec[2].count == 1, "item count recorded")
check(rec[1].char == "Tester", "acting character recorded", rec[1].char)
check(rec[1].t ~= nil, "timestamped")

print("== log: a mail we never emptied is not logged ==")
A.db.ClearLog()
INBOX = { mail{ sender = "Bob", subject = "stuck", money = 500 } }
failTakeMoney = true
take.Start(take.MODE_TAKE)
pump(60)
failTakeMoney = false
check(table.getn(A.db.Log("received")) == 0,
      "a refused take logs nothing", table.getn(A.db.Log("received")))

print("== log: delete-read logs nothing ==")
A.db.ClearLog()
INBOX = { mail{ sender = "Bob", subject = "old news", read = true } }
take.Start(take.MODE_DELETE)
pump()
check(table.getn(INBOX) == 0, "mail was deleted")
check(table.getn(A.db.Log("received")) == 0,
      "an already-empty mail carries nothing to log")

print("== pacing: a batch starts at full speed and earns any delay ==")
-- Courier used to pause a fixed 0.3s between every mail, which on a 12-item
-- send is 3.6 seconds of pure waiting that TurtleMail does not pay -- it
-- re-arms on the next frame. That constant was chosen when MAIL_FAILED threw
-- the whole batch away; it now retries per mail, so the delay is earned rather
-- than assumed.
A.db.ClearLog()
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
send.Start("Ann", "quick", "", 0, false, false)
check(send.settle == send.SETTLE_MIN,
      "a fresh batch starts at the minimum", send.settle)
pumpSend()
check(send.settle == send.SETTLE_MIN,
      "a clean run never slows itself down", send.settle)

print("== pacing: a batch reports its own elapsed time ==")
-- "Did the speed change?" was not answerable by feel. A batch that measures
-- itself turns it into a number.
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
DEFAULT_CHAT_FRAME.messages = {}
send.Start("Ann", "timed", "", 0, false, false)
pumpSend()
check(send.lastElapsed ~= nil, "the batch measured itself",
      tostring(send.lastElapsed))
check(send.lastElapsed > 0, "and the clock moved", send.lastElapsed)
local saidTime = false
local ti = 1
while ti <= table.getn(DEFAULT_CHAT_FRAME.messages) do
    if A.util.Contains(DEFAULT_CHAT_FRAME.messages[ti], " in ") then
        saidTime = true
    end
    ti = ti + 1
end
check(saidTime, "and it told the user how long it took")
check(A.util.FormatSeconds(4.24) == "4.2s", "seconds format to one decimal",
      A.util.FormatSeconds(4.24))
check(A.util.FormatSeconds(4.26) == "4.3s", "rounding to nearest",
      A.util.FormatSeconds(4.26))
check(A.util.FormatSeconds(0) == "0.0s", "zero is fine")

print("== pacing: SETTLE_MIN really does mean the very next frame ==")
-- Arm(0) sets wait = 0; the driver's guard is `waited < wait`, so with a wait
-- of zero the first tick after arming steps immediately. If this ever became
-- `<=` the batch would silently cost an extra frame per mail.
send.Arm(0)
check(send.armed == true, "armed")
local steppedOn = nil
local origStep = send.Step
send.Step = function() steppedOn = "yes" end
arg1 = 0.016            -- one 60fps frame
sdriver.scripts.OnUpdate()
arg1 = nil
send.Step = origStep
check(steppedOn == "yes", "one frame later, it stepped")
send.armed = false

print("== pacing: a refusal backs off, and the backoff sticks ==")
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
failSendCount = 1                  -- the server refuses the first mail once
send.Start("Ann", "bumpy", "", 0, false, false)
pumpSend()
failSendCount = 0
check(send.settle > send.SETTLE_MIN,
      "the refusal bought a delay", send.settle)
check(send.settle == send.SETTLE_MIN + send.SETTLE_STEP,
      "of exactly one step", send.settle)
check(table.getn(SENT) == 2, "and the batch still completed", table.getn(SENT))

-- It must not creep past the ceiling however bad the connection is.
send.settle = send.SETTLE_MAX
local before = send.settle
fire("MAIL_FAILED")                -- not sending, so this must be inert
check(send.settle == before, "MAIL_FAILED outside a run changes nothing",
      send.settle)

stockBags()
send.Attach(0, 1)
failSendCount = 3
send.Start("Ann", "rough", "", 0, false, false)
pumpSend()
failSendCount = 0
check(send.settle <= send.SETTLE_MAX, "the backoff is capped", send.settle)

-- And the next batch starts optimistic again rather than inheriting it.
stockBags()
send.Attach(0, 1)
send.Start("Ann", "fresh", "", 0, false, false)
check(send.settle == send.SETTLE_MIN,
      "a new batch does not inherit the last one's penalty", send.settle)
pumpSend()

print("== sent box: a batch is ONE record carrying its items ==")
-- Vanilla mail has one attachment per message, so mailing two items is two
-- mails and the server has no notion they belong together. The grouping is
-- ours, and it can only be captured at send time.
A.db.ClearLog()
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
send.Start("Ann", "supplies", "", 5000, false, false)
pumpSend()
local box = A.db.SentBox()
check(table.getn(box) == 1, "two mails, ONE sent-box record", table.getn(box))
local rec = box[1]
check(rec.to == "Ann", "recipient recorded", rec.to)
check(rec.s == "supplies", "the subject as TYPED, not the per-mail numbering",
      rec.s)
check(rec.mails == 2, "both mails counted", rec.mails)
check(table.getn(rec.items) == 2, "both items listed",
      table.getn(rec.items))
check(rec.items[1].n == "Silk Cloth", "item name", rec.items[1].n)
check(rec.items[1].c == 20, "stack count", rec.items[1].c)
check(rec.items[2].n == "Copper Ore", "second item", rec.items[2].n)
check(rec.money == 5000, "gold recorded once for the batch", rec.money)
check(rec.char ~= nil, "and which character sent it", tostring(rec.char))

print("== sent box: COD is recorded as COD, not as gold ==")
A.db.ClearLog()
stockBags()
send.Attach(0, 1)
send.Start("Ann", "cod parcel", "", 2500, true, false)
pumpSend()
rec = A.db.SentBox()[1]
check(rec.cod == 2500, "cod recorded", rec.cod)
check(rec.money == 0, "and not counted as attached gold", rec.money)

print("== sent box: nothing is recorded until the server confirms ==")
A.db.ClearLog()
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
send.Start("Ann", "x", "", 0, false, false)
arg1 = 5
sdriver.scripts.OnUpdate()      -- first mail issued, not yet confirmed
arg1 = nil
check(table.getn(A.db.SentBox()) == 0, "nothing recorded before confirmation")
local guard2 = 0
while send.sending and guard2 < 10 do
    fire("MAIL_FAILED")
    guard2 = guard2 + 1
end
check(table.getn(A.db.SentBox()) == 0,
      "and a batch that got NOTHING out leaves no record at all",
      table.getn(A.db.SentBox()))

print("== sent box: a batch abandoned halfway keeps what did go ==")
-- The record is opened by the first confirmed mail and appended to per
-- confirmation, so a run that dies partway is neither lost nor overstated.
A.db.ClearLog()
stockBags()
send.Attach(0, 1); send.Attach(0, 2); send.Attach(0, 3)
send.Start("Ann", "partial", "", 0, false, false)
arg1 = 5
sdriver.scripts.OnUpdate()
arg1 = nil
fire("MAIL_SEND_SUCCESS")       -- mail 1 lands
arg1 = 5
sdriver.scripts.OnUpdate()
arg1 = nil
local g3 = 0
while send.sending and g3 < 12 do      -- the server then refuses forever
    fire("MAIL_FAILED")
    g3 = g3 + 1
end
check(table.getn(A.db.SentBox()) == 1, "the record exists",
      table.getn(A.db.SentBox()))
rec = A.db.SentBox()[1]
check(rec.mails == 1, "and counts only the mail that actually went", rec.mails)
check(table.getn(rec.items) == 1, "with only that item listed",
      table.getn(rec.items))

print("== sent box: the logEnabled setting is honoured ==")
A.db.ClearLog()
A.db.SetSetting("logEnabled", false)
stockBags()
send.Attach(0, 1)
send.Start("Ann", "quiet", "", 0, false, false)
pumpSend()
check(table.getn(A.db.SentBox()) == 0, "logging off records nothing")
A.db.SetSetting("logEnabled", true)

print("== sent box: pruning by age and by ceiling ==")
A.db.ClearLog()
local boxRef = A.db.SentBox()
-- Append-ordered, oldest first, exactly as the real writer produces them.
table.insert(boxRef, { t = time() - (31 * 86400), to = "Old", s = "a",
    mails = 1, items = {} })
table.insert(boxRef, { t = time() - (29 * 86400), to = "Recent", s = "b",
    mails = 1, items = {} })
table.insert(boxRef, { t = time(), to = "Now", s = "c", mails = 1, items = {} })
local dropped = A.db.SentPrune()
check(dropped == 1, "the 31-day-old record went", dropped)
check(table.getn(A.db.SentBox()) == 2, "two survive",
      table.getn(A.db.SentBox()))
check(A.db.SentBox()[1].to == "Recent", "and the 29-day-old one stayed",
      A.db.SentBox()[1].to)

A.db.ClearLog()
boxRef = A.db.SentBox()
local seed = 1
while seed <= A.db.SENT_MAX + 25 do
    table.insert(boxRef, { t = time(), to = "R" .. seed, s = "x",
        mails = 1, items = {} })
    seed = seed + 1
end
A.db.SentPrune()
check(table.getn(A.db.SentBox()) == A.db.SENT_MAX,
      "the ceiling trims a box that is young but huge",
      table.getn(A.db.SentBox()))
check(A.db.SentBox()[1].to == "R26", "oldest go first", A.db.SentBox()[1].to)
A.db.ClearLog()

print("== buttons: the ported kind x state colour table ==")
-- Ported verbatim from Aegis: Exchange (f84f423). These literals are the
-- CONTRACT: if they drift, the two addons' buttons stop matching and nobody
-- notices until they are side by side. Asserted against the numbers, not
-- against "some colour changed".
local KINDS = {
    primary = { bg = {0.42,0.31,0.13}, over = {0.52,0.39,0.17},
                down = {0.30,0.22,0.09}, border = {0.62,0.49,0.22},
                text = {1.00,0.86,0.48} },
    accent  = { bg = {0.36,0.26,0.56}, over = {0.45,0.33,0.68},
                down = {0.26,0.18,0.40}, border = {0.58,0.45,0.80},
                text = {0.95,0.92,1.00} },
    quiet   = { bg = {0.17,0.16,0.15}, over = {0.27,0.25,0.22},
                down = {0.11,0.10,0.09}, border = {0.13,0.12,0.10},
                text = {0.80,0.71,0.42} },
}
local DIM_BG, DIM_TEXT = 0.55, 0.45

local function near(a, b)
    if a == nil or b == nil then return false end
    local d = a - b
    if d < 0 then d = -d end
    return d < 0.0001
end
local function bgIs(btn, want, what)
    local r, g, b = btn:GetBackdropColor()
    check(near(r, want[1]) and near(g, want[2]) and near(b, want[3]),
          what, tostring(r) .. "," .. tostring(g) .. "," .. tostring(b))
end

local kindNames = { "primary", "accent", "quiet" }
local ki = 1
while ki <= 3 do
    local kind = kindNames[ki]
    local spec = KINDS[kind]
    local b = A.ui.MakeButton(A.ui.frame, kind)
    b:SetText("X")

    bgIs(b, spec.bg, kind .. ": normal plate")
    local br, bgc, bbl = b:GetBackdropBorderColor()
    check(near(br, spec.border[1]) and near(bgc, spec.border[2])
          and near(bbl, spec.border[3]), kind .. ": border")

    b.scripts.OnEnter()
    bgIs(b, spec.over, kind .. ": hover plate")
    b.scripts.OnMouseDown()
    bgIs(b, spec.down, kind .. ": pressed plate")
    b.scripts.OnMouseUp()
    bgIs(b, spec.over, kind .. ": back to hover on release")
    -- A press dragged OFF the button never gets an OnMouseUp, so OnLeave has
    -- to clear BOTH flags or the pressed plate sticks until the next hover.
    b.scripts.OnMouseDown()
    b.scripts.OnLeave()
    bgIs(b, spec.bg, kind .. ": leaving mid-press clears the pressed plate")

    -- Disabled is DERIVED (bg * 0.55), not a fourth hand-picked row. Asserting
    -- the arithmetic means a change to BTN_DIM_BG cannot silently stop being
    -- covered.
    b:Disable()
    bgIs(b, { spec.bg[1]*DIM_BG, spec.bg[2]*DIM_BG, spec.bg[3]*DIM_BG },
         kind .. ": disabled plate is the derived dim, not a literal")
    b:Enable()
    bgIs(b, spec.bg, kind .. ": enabling restores the plate")
    ki = ki + 1
end

print("== buttons: disabled must BLOCK clicks, not just look disabled ==")
-- The trap Exchange's own comment calls out: a bare CreateFrame("Button") has
-- working Enable/Disable with no appearance attached. Get the wrapping wrong
-- and you ship a button that either looks dead and still fires, or looks live
-- and does nothing. Both are invisible in a screenshot.
local fired = 0
local cb = A.ui.MakeButton(A.ui.frame, "primary")
cb:SetText("Go")
cb:SetScript("OnClick", function() fired = fired + 1 end)
check(Click(cb), "an enabled button dispatches")
check(fired == 1, "and its handler ran", fired)
cb:Disable()
check(not cb:IsEnabled(), "it reports itself disabled")
check(Click(cb) == false, "a DISABLED button does not dispatch at all")
check(fired == 1, "so its handler did not run", fired)
cb:Enable()
check(Click(cb), "re-enabling restores dispatch")
check(fired == 2, "and the handler runs again", fired)

print("== buttons: text round-trips through the shadowed accessors ==")
local tb = A.ui.MakeButton(A.ui.frame, "quiet")
tb:SetText("Delete Read")
check(tb:GetText() == "Delete Read", "GetText returns what SetText stored",
      tb:GetText())
-- GetFontString must answer the real label: a template-less button has none
-- registered, and anything measuring a label to clip it would error on nil.
check(tb:GetFontString() ~= nil, "GetFontString answers the label, not nil")
check(rawget(tb:GetFontString(), "text") == "Delete Read",
      "and that label carries the text")

print("== buttons: every converted call site kept its intended kind ==")
-- A sample across the areas rather than all 17: an action-bar button, a
-- per-row button, both readers' Back, and the two primaries.
A.ui.mailOpen = true
A.ui.OpenWindow()
local function kindIs(btn, want, what)
    check(btn and btn.courierKind == want, what,
          tostring(btn and btn.courierKind))
end
kindIs(A.ui.btnOpenAll, "primary", "Open All is the Inbox's primary")
kindIs(A.ui.btnDeleteRead, "quiet", "Delete Read is quiet")
kindIs(A.ui.btnStop, "quiet", "Stop is quiet")
kindIs(A.ui.inboxRows[1].ret, "quiet", "the per-row Return is quiet")
kindIs(A.ui.readerBack, "accent", "the mail reader's Back is accent")
kindIs(A.ui.readerTake, "primary", "Take is the reader's primary")
kindIs(A.ui.sentBack, "accent", "the Sent reader's Back is accent")
kindIs(A.ui.sentCompose, "primary", "Compose-to is the Sent reader's primary")
kindIs(A.ui.btnSend, "primary", "Send is the Compose tab's primary")
kindIs(A.ui.blizBtn, "quiet", "the Blizzard UI toggle is quiet")

print("== buttons: MarkChosen restores each button's OWN prior kind ==")
-- Not a hardcoded "quiet": a row of accent buttons must come back accent.
local m1 = A.ui.MakeButton(A.ui.frame, "quiet")
local m2 = A.ui.MakeButton(A.ui.frame, "accent")
m1.tag, m2.tag = "one", "two"
local row = { m1, m2 }
A.ui.MarkChosen(row, function(b) return b.tag == "one" end)
check(m1.courierKind == "primary", "the chosen one goes primary", m1.courierKind)
check(m2.courierKind == "accent", "the other keeps ITS kind, not quiet",
      m2.courierKind)
A.ui.MarkChosen(row, function(b) return b.tag == "two" end)
check(m2.courierKind == "primary", "choosing the other swaps them")
check(m1.courierKind == "quiet", "and the first returns to where it started",
      m1.courierKind)

print("== tabs: Send is labelled Compose, but its KEY is unchanged ==")
-- The key names the panel frame, the ui.panels entry, the comparison in
-- SendAttachActive, and the remembered tab in db.char.ui.tab. Renaming it to
-- relabel the tab would drop every player onto a different tab after updating.
check(A.ui.subTabs["Send"] ~= nil, "the tab is still keyed Send")
check(rawget(A.ui.subTabs["Send"].label, "text") == "Compose",
      "but reads Compose", rawget(A.ui.subTabs["Send"].label, "text"))
check(getglobal("AegisCourierPanelSend") ~= nil,
      "the panel frame global is unchanged")
check(A.ui.panels["Send"] ~= nil, "and so is the panels entry")
A.ui.SelectSubTab("Send")
check(A.ui.selectedSubTab == "Send", "selection still uses the key")
check(A.ui.SendAttachActive() == true,
      "and the bag hook still recognises the compose tab")

check(A.ui.subTabs["Sent"] ~= nil, "Sent is a tab of its own")
check(rawget(A.ui.subTabs["Sent"].label, "text") == "Sent",
      "labelled plainly", rawget(A.ui.subTabs["Sent"].label, "text"))
check(A.ui.panels["Sent"] ~= nil, "with its own panel")

print("== tabs: the Log tab is received-only now ==")
check(A.ui.logSentBtn == nil, "the Sent/Received toggle is gone")
check(A.ui.logDir == "received", "and the log is fixed to received",
      A.ui.logDir)

print("== Sent tab: a batch is ONE row you can click ==")
A.db.ClearLog()
A.ui.mailOpen = true
A.ui.OpenWindow()
A.ui.SelectSubTab("Sent")
stockBags()
send.Attach(0, 1); send.Attach(0, 2); send.Attach(0, 3)
send.Start("Torchbank", "supplies", "letters and parcels", 0, false, false)
pumpSend()
A.ui.sentFind:SetText("")
A.ui.sentMine:SetChecked(false)
local srows = A.ui.SentRows()
check(table.getn(srows) == 1, "three mails render as ONE row",
      table.getn(srows))
check(srows[1].rec.to == "Torchbank", "recipient", srows[1].rec.to)
check(srows[1].rec.s == "supplies", "subject as typed", srows[1].rec.s)
check(srows[1].rec.mails == 3, "and it cost three mails", srows[1].rec.mails)
check(pcall(A.ui.RefreshSent) == true, "the list paints clean")

-- The find box has to search the item list, or a sent box you cannot search
-- is just a list you scroll.
A.ui.sentFind:SetText("copper")
check(table.getn(A.ui.SentRows()) == 1, "found by an item inside the batch")
A.ui.sentFind:SetText("torchbank")
check(table.getn(A.ui.SentRows()) == 1, "found by recipient")
A.ui.sentFind:SetText("parcels")
check(table.getn(A.ui.SentRows()) == 1, "found by body text")
A.ui.sentFind:SetText("nonesuch")
check(table.getn(A.ui.SentRows()) == 0, "and a miss is a miss")
A.ui.sentFind:SetText("")

print("== Sent tab: the reader replays what was recorded ==")
check(A.ui.SentReaderOpen() == false, "the list shows first")
check(A.ui.OpenSentRecord(1) == true, "clicking a send opens it")
check(A.ui.SentReaderOpen(), "the reader is open")
check(A.ui.sentReader.visible == true, "and visible")
check(A.ui.sentRows[1].visible == false, "the list gave up the well")
check(rawget(A.ui.sentTo, "text") == "Torchbank", "recipient shown",
      rawget(A.ui.sentTo, "text"))
check(rawget(A.ui.sentBody, "text") == "letters and parcels",
      "the body was captured at send time and replays here",
      rawget(A.ui.sentBody, "text"))
check(A.util.Contains(rawget(A.ui.sentMeta, "text") or "", "3 mails"),
      "the meta line says what the send actually cost",
      rawget(A.ui.sentMeta, "text"))
check(A.util.Contains(rawget(A.ui.sentItemsHead, "text") or "", "3 item"),
      "and how many items went", rawget(A.ui.sentItemsHead, "text"))
check(A.util.Contains(rawget(A.ui.sentItemRows[1].label, "text") or "",
      "Silk Cloth"), "the first item is named",
      rawget(A.ui.sentItemRows[1].label, "text"))
check(A.ui.sentItemRows[3].visible == true, "all three item rows shown")
check(A.ui.sentItemRows[4].visible == false, "and no more than that")
-- The icon path is captured at attach time; nothing can recover it later.
check(A.ui.sentItemRows[1].icon.visible == true, "the item icon is shown")
check(rawget(A.ui.sentItemRows[1].icon, "texture") ~= nil,
      "and it has a real texture",
      tostring(rawget(A.ui.sentItemRows[1].icon, "texture")))
-- Through GetText, not rawget: ui.MakeButton shadows SetText/GetText on the
-- object, so the label no longer lands in the mock's own `text` field.
check(A.util.Contains(A.ui.sentCompose:GetText() or "", "Torchbank"),
      "the compose action names the recipient",
      A.ui.sentCompose:GetText())
-- The one action that makes sense here: write to the same person again.
A.ui.sentCompose.scripts.OnClick()
check(A.ui.selectedSubTab == "Send", "it switches to the compose tab",
      A.ui.selectedSubTab)
check(A.ui.sendTo:GetText() == "Torchbank", "with the recipient filled in",
      A.ui.sendTo:GetText())
A.ui.SelectSubTab("Sent")
A.ui.OpenSentRecord(1)
A.ui.CloseSentRecord()
check(A.ui.SentReaderOpen() == false, "Back returns to the list")
check(A.ui.sentRows[1].visible == true, "and the rows come back")

print("== Sent tab: there is nothing to Take or Return ==")
-- A sent mail is GONE from the client -- vanilla has no API to read one back,
-- so this reader replays Courier's own record and has nothing to act on.
check(A.ui.sentTake == nil, "no Take button exists")
check(A.ui.sentReturn == nil, "and no Return button")

print("== Sent tab: old records without body or icons still render ==")
-- Nothing captured before this release can be backfilled: the mail is gone.
A.db.ClearSentBox()
local legacy = A.db.SentBegin("Oldfriend", "legacy", 0, 0)   -- no body passed
A.db.SentAdd(legacy, "Linen Cloth", 5)                       -- no texture
check(A.ui.OpenSentRecord(1) == true, "a legacy record opens")
check(pcall(A.ui.RefreshSent) == true, "and paints without erroring")
check(A.util.Contains(rawget(A.ui.sentBody, "text") or "", "no message"),
      "a missing body says so rather than showing an empty well",
      rawget(A.ui.sentBody, "text"))
check(A.ui.sentItemRows[1].visible == true, "the item still lists")
check(A.ui.sentItemRows[1].icon.visible == false,
      "with its icon simply absent")
A.ui.CloseSentRecord()

print("== Sent tab: the reader never outlives its record ==")
A.db.ClearSentBox()
local r1 = A.db.SentBegin("First", "one", 0, 0)
A.db.SentAdd(r1, "Thing", 1)
local r2 = A.db.SentBegin("Second", "two", 0, 0)
A.db.SentAdd(r2, "Thing", 1)
A.ui.OpenSentRecord(1)
check(rawget(A.ui.sentTo, "text") == "First", "reading the first send")
-- Remove the record being read. Index 1 STAYS VALID -- the second send slides
-- into it -- so a nil check alone sails straight past this and the reader
-- would quietly show a different send under the first one's heading.
table.remove(A.db.SentBox(), 1)
check(A.db.SentBox()[1] ~= nil, "index 1 is still a real record")
check(A.db.SentBox()[1].to == "Second", "but a DIFFERENT one now",
      A.db.SentBox()[1].to)
A.ui.RefreshSent()
check(A.ui.SentReaderOpen() == false,
      "a record shifting under the index closes the reader")
check(A.ui.sentRows[1].visible == true, "and the list is painted instead")

-- And the simpler case: the box emptied entirely.
A.db.ClearSentBox()
local r3 = A.db.SentBegin("Third", "three", 0, 0)
A.db.SentAdd(r3, "Thing", 1)
A.ui.OpenSentRecord(1)
check(A.ui.SentReaderOpen(), "reading again")
A.db.ClearSentBox()
A.ui.RefreshSent()
check(A.ui.SentReaderOpen() == false,
      "clearing the box drops the reader back to the list")

print("== Sent tab: long batches summarise but stay searchable ==")
A.db.ClearSentBox()
local many = A.db.SentBegin("Torchbank", "big", 0, 0)
local mi2 = 1
while mi2 <= 9 do
    A.db.SentAdd(many, "Thing " .. mi2, 1)
    mi2 = mi2 + 1
end
local bigRow = A.ui.SentRow(A.db.SentBox()[1])
check(A.util.Contains(bigRow.item, "Thing 1"), "the first items are named",
      bigRow.item)
check(A.util.Contains(bigRow.item, "+6 more"), "and the rest are counted",
      bigRow.item)
-- The label is truncated for width; SEARCH must not be. A bank-alt send is
-- exactly where an item sits ninth in the list, and "I know I mailed it" is
-- the whole reason to open a sent box.
A.ui.sentFind:SetText("thing 9")
check(table.getn(A.ui.SentRows()) == 1,
      "an item past the visible ones is still findable",
      table.getn(A.ui.SentRows()))
A.ui.sentFind:SetText("")

print("== Sent tab: Clear empties the box ==")
A.db.ClearSentBox()
check(table.getn(A.db.SentBox()) == 0, "the box is empty",
      table.getn(A.db.SentBox()))
check(table.getn(A.ui.SentRows()) == 0, "and so is the view")
A.ui.SelectSubTab("Log")
A.ui.logDir = "received"

print("== log: filtering ==")
A.db.ClearLog()
A.db.LogAdd("received", { who = "Bob", subject = "hello", char = "Tester" })
A.db.LogAdd("received", { who = "Ann", subject = "cloth order",
    item = "Silk Cloth", char = "Tester" })
A.db.LogAdd("received", { who = "Stormwind Auction House",
    subject = "Auction successful: Black Lotus", auction = "sold",
    money = 500, char = "AltGuy" })
A.ui.mailOpen = true
A.ui.OpenWindow()
A.ui.SelectSubTab("Log")
check(A.ui.logDir == "received", "defaults to received")
A.ui.logFind:SetText("")
A.ui.logMine:SetChecked(false)
check(table.getn(A.ui.LogRows()) == 3, "all three shown",
      table.getn(A.ui.LogRows()))
-- Newest first.
check(A.ui.LogRows()[1].who == "Stormwind Auction House", "newest first")
A.ui.logFind:SetText("bob")
check(table.getn(A.ui.LogRows()) == 1, "participant filter, case-insensitive")
A.ui.logFind:SetText("cloth")
check(table.getn(A.ui.LogRows()) == 1, "matches the item too")
A.ui.logFind:SetText("sold")
check(table.getn(A.ui.LogRows()) == 1, "matches the auction category tag")
A.ui.logFind:SetText("zzz")
check(table.getn(A.ui.LogRows()) == 0, "no matches")
A.ui.logFind:SetText("")
-- The cross-alt question TurtleMail's per-character store cannot answer.
A.ui.logMine:SetChecked(true)
check(table.getn(A.ui.LogRows()) == 2, "this-character filter excludes the alt",
      table.getn(A.ui.LogRows()))
A.ui.logMine:SetChecked(false)
check(table.getn(A.ui.LogRows()) == 3, "and the alt is visible again")

print("== log: directions are separate ==")
A.db.ClearLog()
A.db.LogAdd("received", { who = "Bob", subject = "in" })
A.db.LogAdd("sent", { who = "Ann", subject = "out" })
check(table.getn(A.db.Log("received")) == 1, "received bucket")
check(table.getn(A.db.Log("sent")) == 1, "sent bucket")
A.db.ClearLog("sent")
check(table.getn(A.db.Log("sent")) == 0, "clearing one direction")
check(table.getn(A.db.Log("received")) == 1, "leaves the other alone")

print("== log: capped ==")
A.db.ClearLog()
local i = 1
while i <= 300 do
    A.db.LogAdd("received", { who = "Bob", subject = "n" .. i })
    i = i + 1
end
local capped = table.getn(A.db.Log("received"))
check(capped == 250, "capped at 250", capped)
check(A.db.Log("received")[capped].subject == "n300",
      "the newest entry survives", A.db.Log("received")[capped].subject)

print("== log: UI refresh runs clean ==")
A.ui.SelectSubTab("Log")
A.ui.RefreshLog()
A.ui.logDir = "sent"
A.ui.RefreshLog()
A.ui.logDir = "received"
A.ui.Refresh()
check(true, "log tab refreshes in both directions")

-- =========================================================================
-- Stage C.3: the optional pfUI skin
-- =========================================================================

local skin = A.skin
check(skin ~= nil, "skin module loaded")

print("== skin: dormant and harmless without pfUI ==")
check(pfUI == nil, "no pfUI in this environment")
check(skin.Available() == false, "not available")
check(skin.Enabled() == false, "not enabled")
check(skin.Apply() == false, "Apply is a no-op")
A.ui.mailOpen = true
A.ui.OpenWindow()
check(A.ui.frame ~= nil, "and the window still builds fine")
-- Toggling the setting with no pfUI must explain itself, not fail.
skin.OnSettingChanged(true)
check(true, "toggling on without pfUI is safe")

print("== skin: the setting defaults ON ==")
-- So that installing pfUI later just works, with nothing to switch on.
check(A.db.Setting("pfSkin") == true, "pfSkin defaults to on")

print("== skin: the option is greyed when pfUI is absent ==")
A.ui.SelectSubTab("Courier")
check(A.ui.checkPfSkin ~= nil, "the option exists in the Courier tab")
check(A.ui.checkPfSkin:GetChecked() == true, "and reads as on")
check(not A.ui.checkPfSkin:IsEnabled(),
      "but is greyed out with no pfUI to match")

print("== skin: applies when pfUI is present ==")
-- A stub standing in for pfUI's helper environment.
local calls = { backdrop = 0, button = 0, checkbox = 0, editbox = 0,
                slider = 0, close = 0, strip = 0 }
pfUI = {
    GetEnvironment = function()
        return {
            -- REAL pfUI builds a CHILD FRAME and hangs it on frame.backdrop.
            -- Counting the call is not enough: the entire button cooperation
            -- turns on that child existing, RepaintButton resolving to it, and
            -- the label being re-homed onto it. A stub that only counts leaves
            -- all three untested.
            CreateBackdrop  = function(frame)
                calls.backdrop = calls.backdrop + 1
                if frame and not frame.backdrop then
                    frame.backdrop = CreateFrame("Frame", nil, frame)
                end
            end,
            StripTextures   = function() calls.strip = calls.strip + 1 end,
            SkinButton      = function() calls.button = calls.button + 1 end,
            SkinCloseButton = function() calls.close = calls.close + 1 end,
            SkinCheckbox    = function() calls.checkbox = calls.checkbox + 1 end,
            SkinScrollbar   = function() calls.slider = calls.slider + 1 end,
        }
    end,
}
skin.env = nil          -- force a refetch
skin.applied = false
check(skin.Available() == true, "now available")
check(skin.Enabled() == true, "and enabled")
check(skin.Apply() == true, "Apply reports success")
check(skin.applied == true, "and marks itself applied")
check(calls.backdrop > 0, "backdrops applied", calls.backdrop)
check(calls.button > 0, "buttons skinned", calls.button)
check(calls.close > 0, "the close button used pfUI's close skin", calls.close)
check(calls.checkbox > 0, "checkboxes skinned", calls.checkbox)
check(calls.editbox + calls.strip > 0, "edit boxes stripped and backdropped",
      calls.strip)
-- Opt-outs must be honoured: inbox rows and attachment slots are click targets
-- and icon wells, not buttons.
check(A.ui.inboxRows[1].courierSkinned == true, "inbox rows were visited")
check(A.ui.sendSlots[1].courierSkinned == true, "attachment slots were visited")

-- Second pass must not redo the work.
local before = calls.backdrop
skin.Apply()
check(calls.backdrop == before, "a second Apply is idempotent",
      calls.backdrop .. " vs " .. before)

print("== skin: pfUI plates are COLOURED by the button, not replaced ==")
-- The point of the courierButton branch: pfUI supplies the plate's edge and
-- corner art, and RepaintButton then paints THAT child with the same BTN_KIND
-- colours it uses unskinned. Skip the branch and pfUI's generic SkinButton
-- flattens every button to one look, losing primary/accent/quiet entirely.
local pb = A.ui.btnOpenAll
check(pb.courierButton == true, "Open All is one of our drawn buttons")
check(pb.backdrop ~= nil, "pfUI gave it a backdrop child", tostring(pb.backdrop))
check(pb.courierSkinned == true, "and the skin pass claimed it")

-- The CHILD carries the colour now, not the button. This is what breaks if
-- RepaintButton ever caches its target at creation instead of resolving live.
local function childBg(btn)
    if not btn.backdrop or not btn.backdrop.GetBackdropColor then return nil end
    local r, g, b = btn.backdrop:GetBackdropColor()
    return r, g, b
end
-- Enable it explicitly: Open All greys itself out when the inbox has no work,
-- and an incidental disabled state would have this asserting the dimmed
-- derivative instead of the plate colour.
pb:Enable()
local pr, pg, pbl = childBg(pb)
check(pr ~= nil, "the backdrop child was painted at all", tostring(pr))
local function close(a, b) local d = a - b if d < 0 then d = -d end return d < 0.0001 end
check(close(pr, 0.42) and close(pg, 0.31) and close(pbl, 0.13),
      "and painted with primary's own plate colour",
      tostring(pr) .. "," .. tostring(pg) .. "," .. tostring(pbl))

-- Hover still drives the child, not the now-invisible parent backdrop.
pb.scripts.OnEnter()
pr, pg, pbl = childBg(pb)
check(close(pr, 0.52) and close(pg, 0.39) and close(pbl, 0.17),
      "hover repaints the pfUI child too",
      tostring(pr) .. "," .. tostring(pg) .. "," .. tostring(pbl))
pb.scripts.OnLeave()

-- An accent button keeps its purple under pfUI rather than being flattened.
local ab = A.ui.readerBack
ab:Enable()
check(ab.courierKind == "accent", "the reader's Back is accent")
local ar, ag, abl = childBg(ab)
check(ar == nil or (close(ar, 0.36) and close(ag, 0.26) and close(abl, 0.56)),
      "and if painted, painted purple -- not flattened to one plate",
      tostring(ar) .. "," .. tostring(ag) .. "," .. tostring(abl))

-- The label is re-homed onto the backdrop child: a FontString on the child's
-- OVERLAY layer sits above that child's own textures whatever the frame
-- levels around it are. Without it, buttons inside a scroll child came back
-- as blank plates.
check(pb.courierLabelLifted == true, "the label was lifted onto the child")
check(pb:GetText() == "Open All", "and still answers GetText afterwards",
      pb:GetText())

print("== skin: the option is live when pfUI is present ==")
A.ui.SelectSubTab("Courier")
check(A.ui.checkPfSkin:IsEnabled() and true, "no longer greyed")

print("== skin: the user setting still wins ==")
A.db.SetSetting("pfSkin", false)
check(skin.Enabled() == false, "off means off even with pfUI installed")
check(skin.Apply() == false, "and Apply refuses")
A.db.SetSetting("pfSkin", true)
check(skin.Enabled() == true, "back on")

print("== skin: a broken pfUI cannot break Courier ==")
-- Every helper throws. The addon must degrade to "unskinned", not error.
pfUI = {
    GetEnvironment = function()
        return {
            CreateBackdrop  = function() error("boom") end,
            StripTextures   = function() error("boom") end,
            SkinButton      = function() error("boom") end,
            SkinCloseButton = function() error("boom") end,
            SkinCheckbox    = function() error("boom") end,
            SkinScrollbar   = function() error("boom") end,
        }
    end,
}
skin.env = nil
skin.applied = false
check(skin.Apply() == true, "Apply survives a pfUI that throws on every call")

-- A pfUI whose GetEnvironment itself explodes.
pfUI = { GetEnvironment = function() error("boom") end }
skin.env = nil
skin.applied = false
check(skin.Apply() == false, "and one whose environment cannot be fetched")

-- A pfUI missing every helper we want.
pfUI = { GetEnvironment = function() return {} end }
skin.env = nil
skin.applied = false
check(skin.Apply() == true, "and one exposing no helpers at all")

pfUI = nil
skin.env = nil
skin.applied = false

print("== skin: the window still works unskinned ==")
A.ui.SelectSubTab("Inbox")
A.ui.SelectSubTab("Send")
A.ui.SelectSubTab("Log")
A.ui.SelectSubTab("Courier")
check(true, "every tab still selects after the skin passes")

print("")
if failures == 0 then
    print("ALL " .. checks .. " CHECKS PASSED")
else
    print(failures .. " of " .. checks .. " CHECKS FAILED")
    os.exit(1)
end
