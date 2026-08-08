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
    function f:Enable() rawset(self, "enabled", true) end
    function f:Disable() rawset(self, "enabled", false) end
    function f:IsEnabled() return rawget(self, "enabled") ~= false end
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
-- GetInboxText is what marks a mail READ on 1.12 -- there is no separate call.
-- The stub models that side effect, because it is the whole point of calling it.
readCalls = 0
GetInboxText = function(i)
    readCalls = readCalls + 1
    local m = INBOX[i]
    if m then m.wasRead = 1 end
end
MiniMapMailFrame = CreateFrame("Frame", "MiniMapMailFrame")
MiniMapMailFrame:Show()
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
ClearCursor = function() cursor = nil end
CursorHasItem = function() return cursor ~= nil end

GetContainerItemInfo = function(bag, slot)
    local it = BAGS[bag] and BAGS[bag][slot]
    if not it then return nil end
    return it.texture, it.count
end
GetContainerItemLink = function(bag, slot)
    local it = BAGS[bag] and BAGS[bag][slot]
    if not it then return nil end
    return "|cff1eff00|Hitem:1:0:0:0|h[" .. it.name .. "]|h|r"
end
PickupContainerItem = function(bag, slot)
    local it = BAGS[bag] and BAGS[bag][slot]
    if it then cursor = { bag = bag, slot = slot, item = it } end
end
SplitContainerItem = function() end
useContainerCalls = 0
UseContainerItem = function() useContainerCalls = useContainerCalls + 1 end

ClickSendMailItemButton = function()
    if cursor then
        if not failAttach then
            attachSlot = cursor.item
            BAGS[cursor.bag][cursor.slot] = nil
        end
        cursor = nil
    else
        attachSlot = nil        -- empty cursor picks the attachment back up
    end
end
GetSendMailItem = function()
    if not attachSlot then return nil end
    return attachSlot.name, attachSlot.texture, attachSlot.count
end
SetSendMailMoney = function(c) sendMoneyAmt = c or 0 end
SetSendMailCOD   = function(c) sendCODAmt = c or 0 end

SendMail = function(to, subject, body)
    table.insert(SENT, { to = to, subject = subject, body = body,
        item = attachSlot and attachSlot.name or nil,
        count = attachSlot and attachSlot.count or nil,
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
    local n, seen = 0, table.getn(SENT)
    while send.sending and n < (limit or 60) do
        sdriver.scripts.OnUpdate()
        local now = table.getn(SENT)
        if now > seen then
            seen = now
            fire("MAIL_SEND_SUCCESS")
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
check(not ok and why == "nothing to send", "empty mail rejected", why)
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

print("== send: an item that will not attach stops the batch ==")
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
failAttach = true
send.Start("Ann", "x", "", 0, false, false)
pumpSend()
failAttach = false
check(not send.sending, "aborted")
check(table.getn(SENT) == 0, "NOTHING was sent -- no empty mail went out",
      table.getn(SENT))
check(send.Count() == 2, "attachments kept so the user can retry", send.Count())

print("== send: MAIL_FAILED aborts the batch ==")
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
send.Start("Ann", "x", "", 0, false, false)
sdriver.scripts.OnUpdate()          -- first mail issued
check(table.getn(SENT) == 1, "first mail out")
fire("MAIL_FAILED")
check(not send.sending, "run aborted on failure")
check(send.Count() == 2, "attachment list preserved")

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
fire("MAIL_INBOX_UPDATE")
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

print("== send UI: COD-all is greyed until COD is checked ==")
A.ui.sendCOD:SetChecked(false)
A.ui.sendCODAll:SetChecked(true)     -- stale state from a previous send
A.ui.RefreshSend()
check(A.ui.sendCODAll:GetChecked() == false,
      "a disabled COD-all cannot stay checked")
check(A.ui.sendCODAll:IsEnabled() == false, "and is greyed out")
A.ui.sendCOD:SetChecked(true)
A.ui.RefreshSend()
check(A.ui.sendCODAll:IsEnabled() == true, "checking COD enables it")
A.ui.sendCODAll:SetChecked(true)
A.ui.RefreshSend()
check(A.ui.sendCODAll:GetChecked() == true, "and it stays checked while COD is on")
A.ui.sendCOD:SetChecked(false)
A.ui.RefreshSend()
check(A.ui.sendCODAll:IsEnabled() == false, "unchecking COD greys it again")
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

print("== log: sent mail is logged per mail, on confirmation ==")
A.db.ClearLog()
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
send.Start("Ann", "supplies", "", 5000, false, false)
pumpSend()
local sent = A.db.Log("sent")
check(table.getn(sent) == 2, "one entry per mail", table.getn(sent))
check(sent[1].who == "Ann", "recipient recorded")
check(sent[1].subject == "supplies [1/2]", "the actual subject sent",
      sent[1].subject)
check(sent[1].item == "Silk Cloth", "item recorded")
check(sent[1].count == 20, "stack count recorded", sent[1].count)
check(sent[1].money == 5000, "gold on the first entry", sent[1].money)
check(sent[2].money == 0, "not on the second", sent[2].money)

print("== log: COD is logged as COD, not as gold ==")
A.db.ClearLog()
stockBags()
send.Attach(0, 1)
send.Start("Ann", "cod parcel", "", 2500, true, false)
pumpSend()
sent = A.db.Log("sent")
check(sent[1].cod == 2500, "cod recorded", sent[1].cod)
check(sent[1].money == 0, "and not counted as attached gold", sent[1].money)

print("== log: a mail the server rejected is not logged ==")
A.db.ClearLog()
stockBags()
send.Attach(0, 1); send.Attach(0, 2)
send.Start("Ann", "x", "", 0, false, false)
sdriver.scripts.OnUpdate()      -- first mail issued, not yet confirmed
check(table.getn(A.db.Log("sent")) == 0, "nothing logged before confirmation")
fire("MAIL_FAILED")
check(table.getn(A.db.Log("sent")) == 0, "and nothing after a failure",
      table.getn(A.db.Log("sent")))

print("== log: the logEnabled setting is honoured ==")
A.db.ClearLog()
A.db.SetSetting("logEnabled", false)
stockBags()
send.Attach(0, 1)
send.Start("Ann", "quiet", "", 0, false, false)
pumpSend()
check(table.getn(A.db.Log("sent")) == 0, "logging off records nothing")
A.db.SetSetting("logEnabled", true)

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
-- Large-inbox stress: the reported "freezes with 11+ mails"
-- =========================================================================
-- The inbox list shows ROWS = 10, so 11 mails is exactly where the scroll
-- path first engages -- the natural place for an unbounded repaint or a
-- scroll/update recursion to hide. A field report said the client froze
-- opening mail at 11+; the audit found no such loop, and this pins that:
-- open a 15-mail box, absorb an update burst (the real client fires
-- MAIL_INBOX_UPDATE repeatedly while headers resolve), idle a thousand
-- ticks, then Open All the lot. Everything here must terminate in bounded
-- steps or the suite itself hangs -- which is the point.

print("== stress: 15-mail inbox opens, idles and Open-Alls ==")
A.db.ClearLedger()
INBOX = {}
do
    local i = 1
    while i <= 15 do
        if math.mod(i, 3) == 0 then
            table.insert(INBOX, mail{ sender = AH,
                subject = "Auction successful: Runecloth", money = 1000 + i })
        elseif math.mod(i, 3) == 1 then
            table.insert(INBOX, mail{ sender = "Bob",
                subject = "stuff " .. i, item = "Copper Ore" })
        else
            table.insert(INBOX, mail{ sender = "Ann",
                subject = "note " .. i, money = 50 })
        end
        i = i + 1
    end
end
fire("MAIL_SHOW")
A.ui.SelectSubTab("Inbox")
do
    local u = 1
    while u <= 10 do fire("MAIL_INBOX_UPDATE"); u = u + 1 end
    local t = 1
    while t <= 1000 do driver.scripts.OnUpdate(); t = t + 1 end
end
check(true, "15-mail box: open + update burst + idle ticks all return")
check(take.HasWork(take.MODE_OPEN), "work seen in the big inbox")
take.Start(take.MODE_OPEN)
do
    local steps = pump(2000)
    check(not take.running, "15-mail Open All terminates", steps)
    check(steps < 200, "...in bounded steps, used " .. steps)
end
check(table.getn(INBOX) == 0, "the whole box was collectable and got emptied",
    table.getn(INBOX))

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
check(A.ui.checkPfSkin:IsEnabled() == false,
      "but is greyed out with no pfUI to match")

print("== skin: applies when pfUI is present ==")
-- A stub standing in for pfUI's helper environment.
local calls = { backdrop = 0, button = 0, checkbox = 0, editbox = 0,
                slider = 0, close = 0, strip = 0 }
pfUI = {
    GetEnvironment = function()
        return {
            CreateBackdrop  = function() calls.backdrop = calls.backdrop + 1 end,
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

print("== skin: the option is live when pfUI is present ==")
A.ui.SelectSubTab("Courier")
check(A.ui.checkPfSkin:IsEnabled() == true, "no longer greyed")

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
