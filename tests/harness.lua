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
local function newRegion()
    local r = { visible = true }
    setmetatable(r, { __index = function() return function() end end })
    function r:SetText(t) self.text = t end
    function r:GetText() return self.text end
    function r:GetStringWidth() return string.len(self.text or "") * 6 end
    function r:SetTexture(t) self.texture = t end
    function r:Show() self.visible = true end
    function r:Hide() self.visible = false end
    function r:IsVisible() return self.visible end
    return r
end

CreateFrame = function(kind, name, parent, template)
    local f = { name = name, kind = kind, template = template,
                scripts = {}, events = {}, visible = false, checked = false }
    setmetatable(f, { __index = function() return function() end end })
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

FauxScrollFrame_Update = function() end
FauxScrollFrame_GetOffset = function() return 0 end
FauxScrollFrame_OnVerticalScroll = function() end

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
GetInboxHeaderInfo = function(i)
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
GetInboxText = function() end
TakeInboxMoney = function(i)
    local m = INBOX[i]
    if not m or failTakeMoney then return end
    m.money = 0
end
TakeInboxItem = function(i)
    local m = INBOX[i]
    if not m or failTakeItem then return end
    m.itemName = nil
    m.hasItem = nil
end
DeleteInboxItem = function(i)
    if INBOX[i] then table.remove(INBOX, i) end
end

ERR_INV_FULL = "Your bags are full."
INVENTORY_FULL = "Inventory is full."
ERR_ITEM_MAX_COUNT = "You cannot carry any more of those items."

-- MailFrame as FrameXML builds it: an OnHide that ends the session.
MailFrame = CreateFrame("Frame", "MailFrame")
MailFrame:SetScript("OnHide", function() CloseMail() end)
OpenMailFrame = CreateFrame("Frame", "OpenMailFrame")
MailFrameCloseButton = CreateFrame("Button", "MailFrameCloseButton")

-- ---- Load the addon in .toc order ---------------------------------------
local files = { "core/init.lua", "core/util.lua", "core/db.lua",
                "core/bridge.lua", "core/inbox.lua", "ui/frame.lua" }
for _, f in ipairs(files) do assert(loadfile(f))() end

local A = AegisCourier
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

print("== bridge: with Aegis present ==")
local pushed = {}
AegisExchange = {
    INTEGRATION_VERSION = 1,
    RecordExternalTxn = function(kind, item, amount, itemId)
        table.insert(pushed, { kind = kind, item = item, amount = amount, id = itemId })
    end,
}
check(A.bridge.Ready() == true, "bridge ready")
check(A.bridge.Push("sale", "Silk Cloth", 9500, 4306) == true, "push succeeds")
check(table.getn(pushed) == 1, "one entry pushed")
check(pushed[1].kind == "sale" and pushed[1].item == "Silk Cloth"
      and pushed[1].amount == 9500 and pushed[1].id == 4306,
      "argument order matches Aegis db.RecordTxn(kind,item,amount,itemId)")
-- A future contract version we do not understand must stand us down.
AegisExchange.INTEGRATION_VERSION = 99
check(A.bridge.Ready() == false, "unsupported contract version stands down")
AegisExchange.INTEGRATION_VERSION = 1
-- An error on the far side must not propagate.
AegisExchange.RecordExternalTxn = function() error("boom") end
check(A.bridge.Push("sale", "x", 1) == false, "far-side error swallowed")
-- The user's own setting wins.
AegisExchange.RecordExternalTxn = function() end
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
local function pump(limit)
    local n = 0
    while take.running and n < (limit or 400) do
        driver.scripts.OnUpdate()
        if take.running then fire("MAIL_INBOX_UPDATE") end
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
             wasReturned = nil, textCreated = nil, canReply = 1,
             isGM = t.gm and 1 or nil }
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
AegisExchange = {
    INTEGRATION_VERSION = 1,
    RecordExternalTxn = function(kind, item, amount, itemId)
        table.insert(pushed2, { kind = kind, item = item, amount = amount })
    end,
}
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

print("")
if failures == 0 then
    print("ALL " .. checks .. " CHECKS PASSED")
else
    print(failures .. " of " .. checks .. " CHECKS FAILED")
    os.exit(1)
end
