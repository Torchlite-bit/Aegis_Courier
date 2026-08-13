-- Aegis: Courier
-- ui/frame.lua
--
-- STANDALONE mailbox window -- Stage A.
--
-- Courier is its OWN top-level frame parented to UIParent. It does NOT tab
-- onto, skin, or parent to the Blizzard MailFrame. When a mailbox opens we
-- hide the Blizzard window and show ours in its place; when it closes we hide
-- ours. This is the same replace-don't-overlay approach Aegis: Exchange uses
-- for the auction house, and for the same reason: with no Blizzard mail frame
-- visible there are no default widgets, backgrounds or 7-row pagination to
-- fight with. The 1.12 client has no taint / protected-frame system, so
-- replacing the window is safe.
--
-- STAGE A SCOPE. This file draws the window and owns the takeover. It renders
-- the inbox READ-ONLY: no taking, no deleting, no open-all, no ledger writes.
-- Those land in Stage B on top of this shell. The two things worth reviewing
-- hard here are HookMailFrame and the deferred hider -- both encode client
-- behaviour that fails silently when it is got wrong.
--
-- The one frame here NOT parented to our window is AegisCourierSwapButton, the
-- "Courier" button we put ON the Blizzard mail frame so the hand-off works
-- both ways. See HookMailFrame.

local A = AegisCourier
A.ui = A.ui or {}
local ui = A.ui
local util = A.util
local db = A.db
local inbox = A.inbox

-- Palette shared with Aegis: Exchange so the two read as one suite.
local C = {
    panelBG = { 0.13, 0.12, 0.10 },
    titleBG = { 0.08, 0.07, 0.05 },
    well    = { 0.05, 0.05, 0.04 },
    gold    = { 1.00, 0.82, 0.00 },
    goldDim = { 0.72, 0.58, 0.32 },
    text    = { 0.87, 0.82, 0.69 },
    amber   = { 0.88, 0.65, 0.19 },
    green   = { 0.56, 0.84, 0.66 },
    dim     = { 0.55, 0.52, 0.45 },
    tabOff  = { 0.21, 0.17, 0.12 },
    tabOn   = { 0.32, 0.27, 0.16 },
    border  = { 0.79, 0.64, 0.15 },
}

local ROW_H         = 28
local ROWS          = 10

-- ---- window geometry -------------------------------------------------------
-- The window height is DERIVED from the list, not picked by eye. It used to be
-- a literal 440, which left the Inbox well 264px tall while its own ten rows
-- needed 4 + 10*28 + 4 = 288. Twenty pixels short -- and 1.12 frames do not
-- clip their children, so the last row simply drew straight through the well
-- border and over the hint line underneath it.
--
-- Every inset below is also used by the anchors themselves, so the arithmetic
-- and the layout cannot drift apart, and changing ROWS now resizes the window
-- to match instead of silently overflowing it again. ui.Geometry() exposes the
-- result and the harness asserts the rows fit.
local LIST_PAD = 4                          -- well edge to first/last row

local PANEL_TOP,  PANEL_BOTTOM  = 68, 28    -- panel inset within the window
-- The Inbox is the tightest of the three panels: a summary line, an action bar
-- and a column header sit above its well, and the hint line sits below it.
local INBOX_TOP,  INBOX_BOTTOM  = 58, 22
local LOG_TOP,    LOG_BOTTOM    = 28, 26
local LEDGER_TOP, LEDGER_BOTTOM = 22, 22

-- Height a list well must have to hold ROWS rows without overflowing.
local LIST_NEED = LIST_PAD + ROWS * ROW_H + LIST_PAD

local WIN_W = 660
local WIN_H = PANEL_TOP + INBOX_TOP + LIST_NEED + INBOX_BOTTOM + PANEL_BOTTOM

-- Well heights the layout above actually produces. Reported by ui.Geometry so
-- the regression test reads the same numbers the anchors use.
local PANEL_H     = WIN_H - PANEL_TOP - PANEL_BOTTOM
local INBOX_WELL  = PANEL_H - INBOX_TOP  - INBOX_BOTTOM
local LOG_WELL    = PANEL_H - LOG_TOP    - LOG_BOTTOM
local LEDGER_WELL = PANEL_H - LEDGER_TOP - LEDGER_BOTTOM

-- Rows required vs. well available, per list. A list whose `need` exceeds its
-- `have` draws outside its well -- the bug above.
function ui.Geometry()
    return {
        need   = LIST_NEED,
        rows   = ROWS,
        rowH   = ROW_H,
        winH   = WIN_H,
        panelH = PANEL_H,
        inbox  = INBOX_WELL,
        log    = LOG_WELL,
        ledger = LEDGER_WELL,
    }
end

local SUBTABS = { "Inbox", "Send", "Log", "Ledger", "Courier" }

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

-- Set `text` on a FontString, shortened with an ellipsis if it would run wider
-- than `maxWidth` pixels. 1.12 has no truncation mode for FontStrings --
-- SetWidth makes long text WRAP onto a second line rather than clip, which
-- inside a fixed-height row looks worse than the overflow it was meant to fix.
-- So we measure with GetStringWidth and cut the string ourselves; binary
-- search keeps it to ~6 SetText calls rather than one per character.
local function SetClipped(fs, text, maxWidth)
    text = text or ""
    fs:SetText(text)
    if not maxWidth or maxWidth <= 0 then return end
    if fs:GetStringWidth() <= maxWidth then return end
    local lo, hi = 0, string.len(text)
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        fs:SetText(string.sub(text, 1, mid) .. "...")
        if fs:GetStringWidth() <= maxWidth then lo = mid else hi = mid - 1 end
    end
    fs:SetText(string.sub(text, 1, lo) .. "...")
end

local function Backdrop(frame, bg, border)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = border and "Interface\\Tooltips\\UI-Tooltip-Border" or nil,
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(bg[1], bg[2], bg[3], 1)
    if border then
        frame:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 0.8)
    end
end

local function Label(parent, template, color)
    local fs = parent:CreateFontString(nil, "OVERLAY",
        template or "GameFontNormalSmall")
    local c = color or C.text
    fs:SetTextColor(c[1], c[2], c[3])
    return fs
end

-- ---------------------------------------------------------------------------
-- Sub-tabs
-- ---------------------------------------------------------------------------

local function MakeSubTab(parent, name)
    local b = CreateFrame("Button", "AegisCourierSubTab" .. name, parent)
    b:SetHeight(24)
    b:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("CENTER", b, "CENTER", 0, 0)
    fs:SetText(name)
    b.label = fs
    b:SetWidth(fs:GetStringWidth() + 30)
    b:SetScript("OnClick", function()
        ui.SelectSubTab(name)
    end)
    return b
end

function ui.SelectSubTab(name)
    -- Leaving the Inbox drops the reader. Coming back should land on the list,
    -- not on whatever mail happened to be open before -- and by then the inbox
    -- may have been emptied under it anyway.
    if name ~= "Inbox" and ui.readerIndex then
        ui.readerIndex = nil
        ui.readerSig = nil
        ui.readerWantBody = nil
        if ui.reader then ui.reader:Hide() end
    end
    ui.selectedSubTab = name
    local n = table.getn(SUBTABS)
    local i = 1
    while i <= n do
        local key = SUBTABS[i]
        local btn = ui.subTabs[key]
        local panel = ui.panels[key]
        -- pfUI's CreateBackdrop replaces the visible border with a child
        -- frame called `backdrop`; tinting the button itself would then do
        -- nothing and every tab would look identical. Tint whichever is real,
        -- checking the type rather than mere truthiness -- `backdrop` is only
        -- a frame once pfUI has actually created one.
        local bd = btn.backdrop
        local target = btn
        if type(bd) == "table" and bd.SetBackdropColor then target = bd end
        if key == name then
            target:SetBackdropColor(C.tabOn[1], C.tabOn[2], C.tabOn[3], 1)
            btn.label:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
            panel:Show()
        else
            target:SetBackdropColor(C.tabOff[1], C.tabOff[2], C.tabOff[3], 1)
            btn.label:SetTextColor(C.text[1], C.text[2], C.text[3])
            panel:Hide()
        end
        i = i + 1
    end
    if db.char and db.char.ui then db.char.ui.tab = name end
    ui.Refresh()
end

-- ---------------------------------------------------------------------------
-- Window construction (once)
-- ---------------------------------------------------------------------------

function ui.BuildWindow()
    if ui.frame then return end

    local f = CreateFrame("Frame", "AegisCourierFrame", UIParent)
    f:SetWidth(WIN_W)
    f:SetHeight(WIN_H)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    Backdrop(f, C.panelBG, true)
    f:Hide()

    -- Restore the saved position, defaulting to centre-ish.
    local point, x, y = db.GetWindowPoint()
    if point then
        f:SetPoint(point, UIParent, point, x, y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    end

    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local p, _, _, px, py = f:GetPoint()
        db.SaveWindowPoint(p, px, py)
    end)
    -- Escape closes the window. UISpecialFrames wants the frame's global NAME.
    table.insert(UISpecialFrames, "AegisCourierFrame")

    -- Closing the window ends the mail session, and it has to live HERE rather
    -- than in ui.CloseWindow: Escape (via UISpecialFrames) and any other
    -- Hide() reach the frame directly without going through our function. If
    -- this were in CloseWindow only, an Escape would leave the player standing
    -- at an open mailbox with NO mail window at all -- ours hidden and the
    -- Blizzard one hidden by the takeover -- and no way back without walking
    -- away from the mailbox.
    --
    -- Guarded two ways: `showBlizzard` means we are handing off and the
    -- session must live, and `closing` stops the MAIL_CLOSED handler's own
    -- Hide() from re-entering.
    f:SetScript("OnHide", function()
        if ui.closing or ui.showBlizzard then return end
        if ui.mailOpen and CloseMail then
            ui.closing = true
            CloseMail()
            ui.closing = false
        end
    end)

    ui.frame = f

    -- ---- title bar ------------------------------------------------------
    local title = CreateFrame("Frame", nil, f)
    title:SetHeight(26)
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    title:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    Backdrop(title, C.titleBG, false)
    ui.titleBar = title

    local titleText = Label(title, "GameFontNormal", C.gold)
    titleText:SetPoint("LEFT", title, "LEFT", 10, 0)
    titleText:SetText("Aegis: Courier  v" .. A.version)

    local close = CreateFrame("Button", "AegisCourierCloseButton", title,
        "UIPanelCloseButton")
    close:SetWidth(28)
    close:SetHeight(28)
    close:SetPoint("RIGHT", title, "RIGHT", 2, 0)
    close:SetScript("OnClick", function() ui.CloseWindow() end)
    close.courierCloseButton = true

    -- Hand back to the stock mail UI. Mirrors the "Courier" button we put on
    -- the Blizzard frame, so the swap works in both directions.
    local blizBtn = CreateFrame("Button", "AegisCourierBlizzButton", title,
        "UIPanelButtonTemplate")
    blizBtn:SetWidth(84)
    blizBtn:SetHeight(19)
    blizBtn:SetPoint("RIGHT", close, "LEFT", -4, 0)
    blizBtn:SetText("Blizzard UI")
    blizBtn:SetScript("OnClick", function() ui.ShowBlizzardMail() end)
    ui.blizBtn = blizBtn

    -- ---- sub-tab strip --------------------------------------------------
    ui.subTabs = {}
    ui.panels  = {}
    local prev = nil
    local n = table.getn(SUBTABS)
    local i = 1
    while i <= n do
        local name = SUBTABS[i]
        local b = MakeSubTab(f, name)
        if prev then
            b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else
            b:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 6, -6)
        end
        ui.subTabs[name] = b
        prev = b

        local panel = CreateFrame("Frame", "AegisCourierPanel" .. name, f)
        panel:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -PANEL_TOP)
        panel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, PANEL_BOTTOM)
        panel:Hide()
        ui.panels[name] = panel

        i = i + 1
    end

    -- ---- footer ---------------------------------------------------------
    local footer = Label(f, "GameFontNormalSmall", C.dim)
    footer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 10)
    ui.footer = footer

    ui.BuildInboxPanel()
    ui.BuildSendPanel()
    ui.BuildLogPanel()
    ui.BuildLedgerPanel()
    ui.BuildCourierPanel()

    local saved = db.char and db.char.ui and db.char.ui.tab
    ui.SelectSubTab(saved or "Inbox")

    -- Optional pfUI styling, applied once the whole window exists. A no-op
    -- when pfUI is absent or the setting is off.
    if A.skin then A.skin.Apply() end
end

-- ---------------------------------------------------------------------------
-- Inbox panel
-- ---------------------------------------------------------------------------

function ui.BuildInboxPanel()
    local panel = ui.panels["Inbox"]

    local summary = Label(panel, "GameFontNormalSmall", C.text)
    summary:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -2)
    ui.inboxSummary = summary

    -- ---- action bar -----------------------------------------------------
    local take = A.take

    local function ActionButton(name, label, width, onClick)
        local b = CreateFrame("Button", "AegisCourierBtn" .. name, panel,
            "UIPanelButtonTemplate")
        b:SetWidth(width)
        b:SetHeight(21)
        b:SetText(label)
        b:SetScript("OnClick", onClick)
        return b
    end

    local openAll = ActionButton("OpenAll", "Open All", 76, function()
        take.Start(take.MODE_OPEN)
    end)
    openAll:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, -16)

    -- No "Take All" button. It ran take.MODE_TAKE -- empty every mail but keep
    -- it -- and it was the mode most exposed to the clock bug fixed alongside
    -- this (see take.Advance): its final step per mail issues no server call,
    -- so the run stalled after the first mail every single time. Open All does
    -- the job users actually wanted and does it correctly. The engine mode
    -- survives for tests; see the note on take.MODE_TAKE.
    local delRead = ActionButton("DeleteRead", "Delete Read", 90, function()
        take.Start(take.MODE_DELETE)
    end)
    delRead:SetPoint("LEFT", openAll, "RIGHT", 4, 0)

    local stop = ActionButton("Stop", "Stop", 56, function()
        take.Stop()
    end)
    stop:SetPoint("LEFT", delRead, "RIGHT", 12, 0)

    ui.btnOpenAll, ui.btnDeleteRead, ui.btnStop = openAll, delRead, stop

    -- Running total for this mailbox visit, to the right of the buttons.
    local collected = Label(panel, "GameFontNormalSmall", C.green)
    collected:SetPoint("LEFT", stop, "RIGHT", 12, 0)
    ui.inboxCollected = collected

    -- Column headers.
    local head = CreateFrame("Frame", nil, panel)
    head:SetHeight(16)
    head:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -42)
    head:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -42)

    local hSender = Label(head, "GameFontNormalSmall", C.goldDim)
    hSender:SetPoint("LEFT", head, "LEFT", 34, 0)
    hSender:SetText("From")

    local hSubject = Label(head, "GameFontNormalSmall", C.goldDim)
    hSubject:SetPoint("LEFT", head, "LEFT", 156, 0)
    hSubject:SetText("Subject")

    -- Money and Left sit further left than the row's right edge to leave a
    -- Return column. Header offsets are the row offsets + 26, because the rows
    -- inset for the scrollbar and this header does not.
    local hMoney = Label(head, "GameFontNormalSmall", C.goldDim)
    hMoney:SetPoint("RIGHT", head, "RIGHT", -122, 0)
    hMoney:SetText("Money")

    local hExpire = Label(head, "GameFontNormalSmall", C.goldDim)
    hExpire:SetPoint("RIGHT", head, "RIGHT", -84, 0)
    hExpire:SetText("Left")

    -- The list well.
    local well = CreateFrame("Frame", nil, panel)
    well:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -INBOX_TOP)
    well:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, INBOX_BOTTOM)
    Backdrop(well, C.well, true)
    ui.inboxWell = well

    local scroll = CreateFrame("ScrollFrame", "AegisCourierInboxScroll", well,
        "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", well, "TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -26, 4)
    -- 1.12 takes (itemHeight, updateFn) -- TWO args. The frame and the scroll
    -- offset arrive as the implicit globals `this` / `arg1`. The offset-first
    -- form is a later-client signature and crashes FrameXML here.
    scroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(ROW_H, ui.RefreshInbox)
    end)
    ui.inboxScroll = scroll

    ui.inboxRows = {}
    local i = 1
    while i <= ROWS do
        local row = CreateFrame("Button", "AegisCourierInboxRow" .. i, well)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", well, "TOPLEFT", 4, -LIST_PAD - (i - 1) * ROW_H)
        row:SetPoint("TOPRIGHT", well, "TOPRIGHT", -26, -LIST_PAD - (i - 1) * ROW_H)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        -- A pfUI border around every row would be noise: these are click
        -- targets, not buttons. See ui/skin.lua.
        row.courierNoSkin = true
        -- Right-click takes this one mail, matching TurtleMail's muscle
        -- memory. Left-click opens the reader.
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function()
            if not row.mailIndex then return end
            -- 1.12 delivers the clicked button in the arg1 GLOBAL.
            if arg1 == "RightButton" then
                A.take.Single(row.mailIndex)
            else
                ui.OpenReader(row.mailIndex)
            end
        end)

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(22)
        icon:SetHeight(22)
        icon:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.icon = icon

        local sender = Label(row, "GameFontNormalSmall", C.text)
        sender:SetPoint("LEFT", row, "LEFT", 32, 0)
        row.sender = sender

        local subject = Label(row, "GameFontNormalSmall", C.text)
        subject:SetPoint("LEFT", row, "LEFT", 154, 0)
        row.subject = subject

        local money = Label(row, "GameFontNormalSmall", C.gold)
        money:SetPoint("RIGHT", row, "RIGHT", -96, 0)
        row.money = money

        local expire = Label(row, "GameFontNormalSmall", C.dim)
        expire:SetPoint("RIGHT", row, "RIGHT", -58, 0)
        row.expire = expire

        -- Return to sender. Parented to the row so it scrolls with it, and
        -- shown only for mail that can actually be returned -- see
        -- ui.RefreshInbox. A dead greyed button on every auction mail would be
        -- worse than an empty cell.
        local ret = CreateFrame("Button", "AegisCourierInboxReturn" .. i, row,
            "UIPanelButtonTemplate")
        ret:SetWidth(52)
        ret:SetHeight(18)
        ret:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        ret:SetText("Return")
        ret:SetScript("OnClick", function()
            ui.ReturnMail(row.mailIndex)
        end)
        ret:Hide()
        row.ret = ret

        row:Hide()
        ui.inboxRows[i] = row
        i = i + 1
    end

    local note = Label(panel, "GameFontNormalSmall", C.dim)
    note:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 4, 4)
    note:SetText("Left-click to read, right-click to take. Return sends it " ..
        "back unopened. COD and GM mail are always skipped.")
    ui.inboxNote = note

    ui.BuildReader(well)
end

-- ---------------------------------------------------------------------------
-- The reader
-- ---------------------------------------------------------------------------
-- Courier replaces the Blizzard mailbox outright, so until now there was no
-- way to read a message at all -- the list showed a subject and nothing else.
--
-- The reader fills the same well as the list and swaps places with it, rather
-- than opening a second window: one mailbox, one panel, and no second frame to
-- keep positioned, skinned and stacked.
--
-- THE EXPIRY RULE. GetInboxText is the only way to obtain a body, and on mail
-- that still holds attachments it drops the expiry to three days (CLAUDE.md
-- rule 17). So the reader NEVER fetches a body just because a row was clicked:
--   * empty mail  -- nothing left to expire, so it opens and reads at once
--   * loaded mail -- header detail opens immediately, the body waits behind an
--                    explicit button that states the cost
-- The header detail (sender, subject, money, attachment, expiry) is free: it
-- all comes from GetInboxHeaderInfo, which the list already read.
function ui.BuildReader(well)
    local r = CreateFrame("Frame", "AegisCourierReader", well)
    r:SetPoint("TOPLEFT", well, "TOPLEFT", LIST_PAD, -LIST_PAD)
    r:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -LIST_PAD, LIST_PAD)
    r:Hide()
    ui.reader = r

    local back = CreateFrame("Button", "AegisCourierReaderBack", r,
        "UIPanelButtonTemplate")
    back:SetWidth(60)
    back:SetHeight(19)
    back:SetPoint("TOPLEFT", r, "TOPLEFT", 2, -2)
    back:SetText("Back")
    back:SetScript("OnClick", function() ui.CloseReader() end)
    ui.readerBack = back

    local from = Label(r, "GameFontNormal", C.gold)
    from:SetPoint("LEFT", back, "RIGHT", 8, 0)
    ui.readerFrom = from

    local expire = Label(r, "GameFontNormalSmall", C.dim)
    expire:SetPoint("TOPRIGHT", r, "TOPRIGHT", -4, -6)
    ui.readerExpire = expire

    local subject = Label(r, "GameFontNormal", C.text)
    subject:SetPoint("TOPLEFT", r, "TOPLEFT", 4, -26)
    ui.readerSubject = subject

    -- Attachment strip: icon, name, and the money the mail carries.
    local icon = r:CreateTexture(nil, "ARTWORK")
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetPoint("TOPLEFT", r, "TOPLEFT", 4, -46)
    ui.readerIcon = icon

    local attach = Label(r, "GameFontNormalSmall", C.text)
    attach:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    ui.readerAttach = attach

    local money = Label(r, "GameFontNormalSmall", C.gold)
    money:SetPoint("TOPRIGHT", r, "TOPRIGHT", -4, -48)
    ui.readerMoney = money

    -- Body. A real ScrollFrame, NOT a FauxScrollFrame: this scrolls one long
    -- FontString rather than recycling rows, which is what FrameXML's own
    -- OpenMailScrollFrame does -- and it sidesteps the mutual recursion that
    -- FauxScrollFrame update functions have to be guarded against.
    local bodyWell = CreateFrame("Frame", nil, r)
    bodyWell:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -70)
    bodyWell:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 0, 26)
    Backdrop(bodyWell, C.well, true)
    ui.readerBodyWell = bodyWell

    local scroll = CreateFrame("ScrollFrame", "AegisCourierReaderScroll",
        bodyWell, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", bodyWell, "TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", bodyWell, "BOTTOMRIGHT", -26, 6)
    ui.readerScroll = scroll

    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(WIN_W - 90)
    child:SetHeight(1)
    scroll:SetScrollChild(child)
    ui.readerBodyChild = child

    local body = Label(child, "GameFontHighlightSmall", C.text)
    body:SetPoint("TOPLEFT", child, "TOPLEFT", 0, 0)
    body:SetWidth(WIN_W - 96)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    ui.readerBody = body

    -- Shown instead of the body for loaded mail, until the player accepts the
    -- three-day cost. The warning is on the button's own line so it cannot be
    -- missed by someone who clicks first and reads second.
    local reveal = CreateFrame("Button", "AegisCourierReaderReveal", r,
        "UIPanelButtonTemplate")
    reveal:SetWidth(110)
    reveal:SetHeight(21)
    reveal:SetPoint("TOPLEFT", bodyWell, "TOPLEFT", 8, -8)
    reveal:SetText("Read message")
    reveal:SetScript("OnClick", function()
        ui.readerWantBody = true
        ui.RefreshReader()
    end)
    ui.readerReveal = reveal

    local warn = Label(r, "GameFontNormalSmall", C.amber)
    warn:SetPoint("TOPLEFT", reveal, "BOTTOMLEFT", 0, -6)
    warn:SetWidth(WIN_W - 110)
    warn:SetJustifyH("LEFT")
    warn:SetText("This mail still holds something. Opening it starts the " ..
        "three-day expiry the game applies to read mail with attachments.")
    ui.readerWarn = warn

    local takeBtn = CreateFrame("Button", "AegisCourierReaderTake", r,
        "UIPanelButtonTemplate")
    takeBtn:SetWidth(70)
    takeBtn:SetHeight(20)
    takeBtn:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 2, 2)
    takeBtn:SetText("Take")
    takeBtn:SetScript("OnClick", function()
        if not ui.readerIndex then return end
        A.take.Single(ui.readerIndex)
    end)
    ui.readerTake = takeBtn

    local retBtn = CreateFrame("Button", "AegisCourierReaderReturn", r,
        "UIPanelButtonTemplate")
    retBtn:SetWidth(70)
    retBtn:SetHeight(20)
    retBtn:SetPoint("LEFT", takeBtn, "RIGHT", 6, 0)
    retBtn:SetText("Return")
    retBtn:SetScript("OnClick", function()
        local idx = ui.readerIndex
        -- Returning removes the mail, so there is nothing left to look at.
        ui.CloseReader()
        ui.ReturnMail(idx)
    end)
    ui.readerReturn = retBtn

    local status = Label(r, "GameFontNormalSmall", C.dim)
    status:SetPoint("LEFT", retBtn, "RIGHT", 10, 0)
    ui.readerStatus = status
end

-- Open the reader on an ABSOLUTE inbox index.
--
-- Refused during a take run: the run deletes mail, and every delete shifts
-- every later index down one, so a held index would quietly start pointing at
-- a different mail.
function ui.OpenReader(index)
    if not index then return false end
    if A.take.running then return false end
    local h = inbox.Header(index)
    if not h then return false end
    ui.readerIndex = index
    -- Remembered so a shifted or replaced mail can be detected rather than
    -- silently rendered as though it were the one that was clicked.
    ui.readerSig = h.sender .. "|" .. h.subject
    ui.readerWantBody = inbox.ReadIsFree(h)
    ui.RefreshInbox()
    return true
end

function ui.CloseReader()
    ui.readerIndex = nil
    ui.readerSig = nil
    ui.readerWantBody = nil
    ui.RefreshInbox()
end

function ui.ReaderOpen()
    return ui.readerIndex ~= nil
end

-- Paint the reader. Returns false if the mail it was showing is gone or has
-- been replaced by a different one, in which case the caller drops back to the
-- list rather than displaying the wrong mail.
function ui.RefreshReader()
    local idx = ui.readerIndex
    if not idx then return false end

    local h = inbox.Header(idx)
    if not h then return false end
    if ui.readerSig and (h.sender .. "|" .. h.subject) ~= ui.readerSig then
        return false
    end

    ui.readerFrom:SetText(h.sender)
    ui.readerExpire:SetText(util.FormatDaysLeft(h.daysLeft) .. " left")

    local subject = h.subject
    if h.auctionKind then
        subject = "|cffffd700[" .. h.auctionKind .. "]|r " ..
            (h.auctionItem or h.subject)
    elseif h.fromAuctionHouse then
        subject = "|cffb0904f[AH]|r " .. subject
    end
    if h.wasReturned then
        subject = "|cffd08050[returned]|r " .. subject
    end
    ui.readerSubject:SetText(subject)

    -- Attachment. There is no GetInboxItemLink on 1.12, so this is a name, a
    -- count and a texture -- never a link, and never an itemID.
    if h.hasItem then
        local item = inbox.Item(idx)
        ui.readerIcon:SetTexture(item and item.texture or inbox.Icon(h))
        ui.readerIcon:Show()
        local label = item and item.name or "attachment"
        if item and item.count and item.count > 1 then
            label = label .. " x" .. item.count
        end
        ui.readerAttach:SetText(label)
    else
        ui.readerIcon:Hide()
        ui.readerAttach:SetText("")
    end

    if h.cod > 0 then
        ui.readerMoney:SetText("|cffd05050COD " ..
            util.FormatMoney(h.cod, false) .. "|r")
    elseif h.money > 0 then
        ui.readerMoney:SetText(util.FormatMoney(h.money, true))
    else
        ui.readerMoney:SetText("")
    end

    -- Body, under the expiry rule at the top of this section.
    if ui.readerWantBody then
        ui.readerReveal:Hide()
        ui.readerWarn:Hide()
        local b = inbox.Body(idx)
        local text = b and b.text
        if b and b.invoice then
            text = ui.InvoiceText(b.invoice) .. (text and ("\n\n" .. text) or "")
        end
        -- A nil body is NOT "no message": on the first read the client has to
        -- ask the server for it and fires MAIL_INBOX_UPDATE when it lands, so
        -- the next refresh fills this in.
        ui.readerBody:SetText(text or "|cff808080Loading...|r")
        ui.readerBody:Show()
        ui.readerScroll:Show()
        if ui.readerBodyChild.SetHeight then
            ui.readerBodyChild:SetHeight(200)
        end
    else
        ui.readerReveal:Show()
        ui.readerWarn:Show()
        ui.readerBody:SetText("")
        ui.readerBody:Hide()
        ui.readerScroll:Hide()
    end

    -- Actions. Take is refused for COD and GM mail everywhere in this addon,
    -- so the button is not offered rather than offered and rejected.
    local canTake = (h.money > 0 or h.hasItem) and h.cod == 0 and not h.isGM
        and not A.take.running
    if canTake then ui.readerTake:Show() else ui.readerTake:Hide() end

    if h.canReply and not h.isGM and not A.take.running then
        ui.readerReturn:Show()
    else
        ui.readerReturn:Hide()
    end

    if h.cod > 0 then
        ui.readerStatus:SetText("COD mail is never collected automatically.")
    elseif h.isGM then
        ui.readerStatus:SetText("GM mail is never collected automatically.")
    else
        ui.readerStatus:SetText("")
    end

    return true
end

-- Render an auction invoice as text. Turtle takes a 5% consignment cut, and
-- the invoice reports it directly, so this shows the server's own numbers
-- rather than deriving them.
function ui.InvoiceText(inv)
    local lines = "|cffffd700Auction invoice|r"
    if inv.item then lines = lines .. "\n" .. inv.item end
    if inv.who then lines = lines .. "\nwith: " .. inv.who end
    if inv.kind == "seller" then
        lines = lines .. "\nsale price: " .. util.FormatMoney(inv.bid, true)
        if inv.consignment and inv.consignment > 0 then
            lines = lines .. "\nhouse cut: " ..
                util.FormatMoney(inv.consignment, true)
        end
        if inv.deposit and inv.deposit > 0 then
            lines = lines .. "\ndeposit returned: " ..
                util.FormatMoney(inv.deposit, true)
        end
    else
        lines = lines .. "\nprice: " .. util.FormatMoney(inv.bid, true)
    end
    return lines
end

-- Enable/disable the action bar for the current state. Called by the take
-- engine whenever a run starts or ends, and on every refresh.
function ui.OnTakeStateChanged()
    if not ui.btnOpenAll then return end
    local take = A.take
    local running = take.running and true or false
    local atMailbox = ui.mailOpen and true or false

    local function SetEnabled(btn, on)
        if on then btn:Enable() else btn:Disable() end
    end

    SetEnabled(ui.btnOpenAll,
        atMailbox and not running and take.HasWork(take.MODE_OPEN))
    SetEnabled(ui.btnDeleteRead,
        atMailbox and not running and take.HasWork(take.MODE_DELETE))
    SetEnabled(ui.btnStop, running)

    if ui.inboxCollected then
        if take.money > 0 or take.items > 0 then
            local txt = util.FormatMoney(take.money, true)
            if take.items > 0 then
                txt = txt .. "  " .. take.items .. " item" ..
                    (take.items == 1 and "" or "s")
            end
            if running then txt = txt .. "  ..." end
            ui.inboxCollected:SetText(txt)
        else
            ui.inboxCollected:SetText(running and "working..." or "")
        end
    end
    ui.RefreshInbox()
end

-- REENTRANCY GUARD, and it is load-bearing. The chain in the 1.12 FrameXML:
--
--   RefreshInbox -> FauxScrollFrame_Update -> scrollBar:SetMinMaxValues /
--   SetValue -> slider OnValueChanged -> GetParent():SetVerticalScroll ->
--   scroll frame OnVerticalScroll -> our handler -> updateFunction() ->
--   RefreshInbox -> ...
--
-- is MUTUAL RECURSION with no exit whenever the scrollbar is live, which is
-- exactly when the inbox holds more than ROWS (10) mails -- at 10 or fewer,
-- FauxScrollFrame_Update takes its Hide() branch and the slider never fires.
-- That was the reported "freeze then crash with 11+ mails": the recursion
-- spins until the stack blows. The guard bounces the re-entrant call; the
-- outer pass reads the (already-clamped) offset immediately after
-- FauxScrollFrame_Update, so the paint stays correct. RefreshLog and
-- RefreshLedger carry the same guard for the same reason.
-- Clear the list out of the way so the reader can have the well. The rows are
-- reused rather than destroyed, so this is just visibility.
function ui.HideInboxRows()
    local i = 1
    while i <= ROWS do
        local row = ui.inboxRows[i]
        if row then
            row.ret:Hide()
            row:Hide()
        end
        i = i + 1
    end
    if ui.inboxScroll then ui.inboxScroll:Hide() end
end

function ui.RefreshInbox()
    if not ui.frame or not ui.frame:IsVisible() then return end
    if ui.selectedSubTab ~= "Inbox" then return end
    if ui.inboxRefreshing then return end
    ui.inboxRefreshing = true

    -- The reader occupies the same well as the list, so exactly one of them is
    -- painted. A take run closes it: the run deletes mail and every delete
    -- shifts the later indices down, so a held index stops meaning what it
    -- meant when it was clicked.
    if ui.readerIndex and A.take.running then ui.CloseReader() end
    if ui.readerIndex then
        if ui.RefreshReader() then
            ui.HideInboxRows()
            ui.reader:Show()
            ui.inboxRefreshing = false
            return
        end
        -- The mail went away or a different one slid into its index; fall
        -- through and repaint the list rather than show the wrong mail.
        ui.readerIndex = nil
        ui.readerSig = nil
        ui.readerWantBody = nil
    end
    if ui.reader then ui.reader:Hide() end
    if ui.inboxScroll then ui.inboxScroll:Show() end

    local mails = inbox.All()
    local total = table.getn(mails)

    local totalN, unread, money = inbox.Summary()
    local parts = totalN .. " mail"
    if totalN ~= 1 then parts = totalN .. " mails" end
    if unread > 0 then parts = parts .. ", " .. unread .. " unread" end
    if money > 0 then
        parts = parts .. "  |  " .. util.FormatMoney(money, true) .. " waiting"
    end
    ui.inboxSummary:SetText(parts)

    FauxScrollFrame_Update(ui.inboxScroll, total, ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.inboxScroll) or 0

    local i = 1
    while i <= ROWS do
        local row = ui.inboxRows[i]
        local h = mails[offset + i]
        if h then
            row.icon:SetTexture(inbox.Icon(h))
            -- Read mail is dimmed, matching the stock inbox's convention.
            local c = h.wasRead and C.dim or C.text
            row.sender:SetTextColor(c[1], c[2], c[3])
            row.subject:SetTextColor(c[1], c[2], c[3])
            SetClipped(row.sender, h.sender, 116)

            -- Tag auction mail. The subject classification is what decides;
            -- the sender only corroborates it.
            local subject = h.subject
            if h.auctionKind then
                subject = "|cffffd700[" .. h.auctionKind .. "]|r " ..
                    (h.auctionItem or h.subject)
            elseif h.fromAuctionHouse then
                subject = "|cffb0904f[AH]|r " .. subject
            end
            if h.wasReturned then
                subject = "|cffd08050[returned]|r " .. subject
            end
            SetClipped(row.subject, subject, 230)

            if h.cod > 0 then
                row.money:SetText("|cffd05050COD " ..
                    util.FormatMoney(h.cod, false) .. "|r")
            elseif h.money > 0 then
                row.money:SetText(util.FormatMoney(h.money, true))
            else
                row.money:SetText("")
            end

            row.expire:SetText(util.FormatDaysLeft(h.daysLeft))
            row.mailIndex = h.index

            -- `canReply` is the same gate FrameXML uses to enable its own
            -- Reply button: auction-house and system mail have it unset and
            -- genuinely cannot be returned. Hidden during a run because
            -- returning removes the mail and shifts every later index, which
            -- would desync the take engine mid-flight.
            if h.canReply and not h.isGM and not A.take.running then
                row.ret:Show()
            else
                row.ret:Hide()
            end
            row:Show()
        else
            row.mailIndex = nil
            row.ret:Hide()
            row:Hide()
        end
        i = i + 1
    end

    ui.inboxRefreshing = false
end

-- ---------------------------------------------------------------------------
-- Send panel
-- ---------------------------------------------------------------------------
--
-- Courier hides the Blizzard mail frame outright, so until this existed there
-- was no way to send mail at all without handing the window back. The send
-- ENGINE (and the reason a 12-item send is really 12 mails) lives in
-- core/send.lua; this is only the form.

local ATTACH_COLS, ATTACH_SIZE = 6, 32
local AUTOCOMPLETE_ROWS = 5

-- A plain checkbox with no SavedVariables binding, for the send form's
-- per-mail toggles. (The settings tab's MakeCheck writes through to the DB and
-- is declared further down, so it is not in scope here anyway.)
local function MakeToggle(parent, name, label)
    local c = CreateFrame("CheckButton", "AegisCourierToggle" .. name, parent,
        "UICheckButtonTemplate")
    c:SetWidth(20)
    c:SetHeight(20)
    local text = getglobal("AegisCourierToggle" .. name .. "Text")
    if text then
        text:SetText(label)
        text:SetTextColor(C.text[1], C.text[2], C.text[3])
    end
    -- Kept so the label can be greyed with the box. CheckButton:Disable()
    -- dims the box art only; on 1.12 the FontString keeps its colour and a
    -- disabled option still reads as available.
    c.labelText = text
    return c
end

-- Enable/disable a MakeToggle checkbox and colour its label to match.
local function SetToggleEnabled(toggle, enabled)
    if enabled then
        toggle:Enable()
        if toggle.labelText then
            toggle.labelText:SetTextColor(C.text[1], C.text[2], C.text[3])
        end
    else
        toggle:Disable()
        if toggle.labelText then
            toggle.labelText:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
        end
    end
end

local function MakeEditBox(name, parent, width, multiline)
    -- The multiline body deliberately gets NO template.
    --
    -- InputBoxTemplate's border is 9-slice art built for a ONE-LINE box: its
    -- Left/Right/Middle textures carry a fixed height. Stretch that template
    -- over a tall multiline frame and the border does not stretch with it --
    -- it stays one line tall and renders as a stray, input-shaped rectangle
    -- floating inside the body area, which is exactly what it looked like.
    -- We already draw our own well behind the body, so the template's border
    -- was never wanted there in the first place.
    local e
    if multiline then
        e = CreateFrame("EditBox", "AegisCourierEdit" .. name, parent)
    else
        e = CreateFrame("EditBox", "AegisCourierEdit" .. name, parent,
            "InputBoxTemplate")
    end
    e:SetWidth(width)
    e:SetHeight(multiline and 96 or 18)
    e:SetAutoFocus(false)      -- otherwise opening the tab steals the keyboard
    e:SetFontObject("GameFontHighlightSmall")
    if multiline then
        e:SetMultiLine(true)
        e:SetMaxLetters(500)
        e:SetTextInsets(4, 4, 4, 4)
    else
        e:SetMaxLetters(64)
    end
    e:SetScript("OnEscapePressed", function() e:ClearFocus() end)
    return e
end

function ui.BuildSendPanel()
    local panel = ui.panels["Send"]
    local send = A.send

    -- ---- recipient ------------------------------------------------------
    local toLbl = Label(panel, "GameFontNormalSmall", C.goldDim)
    toLbl:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, -8)
    toLbl:SetText("To")

    local toBox = MakeEditBox("To", panel, 150)
    toBox:SetPoint("LEFT", toLbl, "RIGHT", 10, 0)
    ui.sendTo = toBox

    -- Browse the whole contact list on demand. Without this the only way to
    -- see who you have mailed is to guess a first letter.
    local acBtn = CreateFrame("Button", "AegisCourierAutoButton", panel)
    acBtn:SetWidth(16)
    acBtn:SetHeight(16)
    acBtn:SetPoint("LEFT", toBox, "RIGHT", 4, 0)
    -- Scrollbar art, deliberately: every FauxScrollFrame in FrameXML uses these
    -- three files, so they are certain to exist on any 1.12 client. The
    -- previous choice drew from Interface\ChatFrame and rendered as nothing.
    acBtn:SetNormalTexture(
        "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up")
    acBtn:SetPushedTexture(
        "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Down")
    acBtn:SetHighlightTexture(
        "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Highlight")
    -- Opt out of the pfUI skin. SkinButton replaces a button's textures with a
    -- flat backdrop and border, which on an ICON button erases the icon and
    -- leaves a small empty box sitting next to the recipient field -- reported,
    -- reasonably, as "a random box that does nothing".
    acBtn.courierNoSkin = true
    acBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(acBtn, "ANCHOR_RIGHT")
        GameTooltip:SetText("Recent recipients")
        GameTooltip:Show()
    end)
    acBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ui.sendAutoButton = acBtn

    -- ---- subject --------------------------------------------------------
    local subjLbl = Label(panel, "GameFontNormalSmall", C.goldDim)
    subjLbl:SetPoint("LEFT", acBtn, "RIGHT", 14, 0)
    subjLbl:SetText("Subject")

    local subjBox = MakeEditBox("Subject", panel, 300)
    subjBox:SetPoint("LEFT", subjLbl, "RIGHT", 10, 0)
    ui.sendSubject = subjBox

    local subjHint = Label(panel, "GameFontNormalSmall", C.dim)
    subjHint:SetPoint("TOPLEFT", toLbl, "BOTTOMLEFT", 0, -6)
    subjHint:SetText("Leave the subject blank to use each item's name.")

    -- ---- autocomplete ---------------------------------------------------
    -- Anchored to the recipient box and drawn above the form so it overlays
    -- rather than pushes anything down.
    local ac = CreateFrame("Frame", "AegisCourierAutoComplete", panel)
    ac:SetWidth(150)
    ac:SetHeight(AUTOCOMPLETE_ROWS * 16 + 8)
    ac:SetPoint("TOPLEFT", toBox, "BOTTOMLEFT", 0, -2)
    ac:SetFrameStrata("DIALOG")
    Backdrop(ac, C.titleBG, true)
    ac:Hide()
    ui.sendAuto = ac

    ui.sendAutoRows = {}
    local i = 1
    while i <= AUTOCOMPLETE_ROWS do
        local b = CreateFrame("Button", "AegisCourierAutoRow" .. i, ac)
        b:SetHeight(16)
        b:SetPoint("TOPLEFT", ac, "TOPLEFT", 4, -4 - (i - 1) * 16)
        b:SetPoint("TOPRIGHT", ac, "TOPRIGHT", -4, -4 - (i - 1) * 16)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        local fs = Label(b, "GameFontNormalSmall", C.text)
        fs:SetPoint("LEFT", b, "LEFT", 4, 0)
        b.label = fs
        b:SetScript("OnClick", function()
            if b.name then
                toBox:SetText(b.name)
                ac:Hide()
                toBox:ClearFocus()
                ui.RefreshSend()
            end
        end)
        b:Hide()
        ui.sendAutoRows[i] = b
        i = i + 1
    end

    toBox:SetScript("OnTextChanged", function()
        ui.UpdateAutoComplete()
        ui.RefreshSend()
    end)
    toBox:SetScript("OnEditFocusLost", function() ac:Hide() end)

    -- Toggle the full list. Clicking the button drops focus from the edit box
    -- first, which hides the list, so this reads as "show" on the next click.
    acBtn:SetScript("OnClick", function()
        if ac:IsVisible() then
            ac:Hide()
        else
            ui.UpdateAutoComplete(true)
        end
    end)
    -- Escape should close the suggestions before it closes the box.
    toBox:SetScript("OnEscapePressed", function()
        if ac:IsVisible() then ac:Hide() else toBox:ClearFocus() end
    end)

    -- ---- body -----------------------------------------------------------
    local bodyWell = CreateFrame("Frame", nil, panel)
    bodyWell:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -46)
    bodyWell:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -46)
    bodyWell:SetHeight(104)
    Backdrop(bodyWell, C.well, true)
    ui.sendBodyWell = bodyWell

    local bodyBox = MakeEditBox("Body", bodyWell, 1, true)
    bodyBox:SetPoint("TOPLEFT", bodyWell, "TOPLEFT", 6, -4)
    bodyBox:SetPoint("BOTTOMRIGHT", bodyWell, "BOTTOMRIGHT", -6, 4)
    ui.sendBody = bodyBox

    -- ---- attachments ----------------------------------------------------
    local attLbl = Label(panel, "GameFontNormalSmall", C.goldDim)
    attLbl:SetPoint("TOPLEFT", bodyWell, "BOTTOMLEFT", 2, -8)
    attLbl:SetText("Attachments")
    ui.sendAttachLabel = attLbl

    local attHint = Label(panel, "GameFontNormalSmall", C.dim)
    attHint:SetPoint("LEFT", attLbl, "RIGHT", 10, 0)
    attHint:SetText("right-click or drag from your bags   |   click a slot to remove")

    ui.sendSlots = {}
    i = 1
    while i <= send.MAX_ATTACHMENTS do
        local col = math.mod(i - 1, ATTACH_COLS)
        local row = math.floor((i - 1) / ATTACH_COLS)
        local b = CreateFrame("Button", "AegisCourierAttach" .. i, panel)
        b:SetWidth(ATTACH_SIZE)
        b:SetHeight(ATTACH_SIZE)
        b:SetPoint("TOPLEFT", attLbl, "BOTTOMLEFT",
            col * (ATTACH_SIZE + 4), -6 - row * (ATTACH_SIZE + 4))
        Backdrop(b, C.well, true)
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
        -- An icon well rather than a button: pfUI backdrop, no button skin.
        b.courierNoSkin = true
        b.courierBackdrop = true

        local icon = b:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", b, "TOPLEFT", 3, -3)
        icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -3, 3)
        b.icon = icon

        local count = Label(b, "GameFontNormalSmall", C.text)
        count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
        b.count = count

        b.slotIndex = i
        -- Clicking an occupied slot removes it; clicking an empty one while
        -- carrying an item attaches that item.
        b:SetScript("OnClick", function()
            if A.send.attachments[b.slotIndex] then
                A.send.Detach(b.slotIndex)
            elseif CursorHasItem and CursorHasItem() then
                A.send.AttachCursor()
            end
        end)
        b:SetScript("OnReceiveDrag", function() A.send.AttachCursor() end)
        ui.sendSlots[i] = b
        i = i + 1
    end

    -- ---- money ----------------------------------------------------------
    local firstSlot = ui.sendSlots[1]
    local moneyLbl = Label(panel, "GameFontNormalSmall", C.goldDim)
    moneyLbl:SetPoint("TOPLEFT", firstSlot, "BOTTOMLEFT",
        0, -6 - (ATTACH_SIZE + 4))
    moneyLbl:SetText("Gold")

    local moneyBox = MakeEditBox("Money", panel, 90)
    moneyBox:SetPoint("LEFT", moneyLbl, "RIGHT", 10, 0)
    moneyBox:SetScript("OnTextChanged", function() ui.RefreshSend() end)
    ui.sendMoney = moneyBox

    local moneyHint = Label(panel, "GameFontNormalSmall", C.dim)
    moneyHint:SetPoint("LEFT", moneyBox, "RIGHT", 8, 0)
    moneyHint:SetText("e.g. 12g 30s")

    local cod = MakeToggle(panel, "COD", "C.O.D. (charge the recipient)")
    cod:SetPoint("TOPLEFT", moneyLbl, "BOTTOMLEFT", -4, -4)
    cod:SetScript("OnClick", function() ui.RefreshSend() end)
    ui.sendCOD = cod

    -- Directly under the C.O.D. box it modifies, indented slightly, and greyed
    -- until C.O.D. is actually on -- it has no meaning otherwise.
    local codAll = MakeToggle(panel, "CODAll", "on every mail, not just the first")
    codAll:SetPoint("TOPLEFT", cod, "BOTTOMLEFT", 14, -2)
    codAll:SetScript("OnClick", function() ui.RefreshSend() end)
    ui.sendCODAll = codAll

    -- ---- cost + actions -------------------------------------------------
    local cost = Label(panel, "GameFontNormalSmall", C.text)
    cost:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 6, 8)
    ui.sendCost = cost

    local sendBtn = CreateFrame("Button", "AegisCourierBtnSend", panel,
        "UIPanelButtonTemplate")
    sendBtn:SetWidth(80)
    sendBtn:SetHeight(22)
    sendBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -6, 4)
    sendBtn:SetText("Send")
    sendBtn:SetScript("OnClick", function() ui.DoSend() end)
    ui.btnSend = sendBtn

    local clearBtn = CreateFrame("Button", "AegisCourierBtnClearSend", panel,
        "UIPanelButtonTemplate")
    clearBtn:SetWidth(70)
    clearBtn:SetHeight(22)
    clearBtn:SetPoint("RIGHT", sendBtn, "LEFT", -4, 0)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function() ui.ClearSendForm() end)
end

-- True while the Send tab is the thing the user is actually looking at, at a
-- mailbox. The bag right-click hook checks this so right-click keeps its
-- normal meaning everywhere else in the game.
function ui.SendAttachActive()
    if not ui.frame or not ui.frame:IsVisible() then return false end
    if ui.selectedSubTab ~= "Send" then return false end
    return ui.mailOpen and true or false
end

-- `showAll` comes from the dropdown button and means "list everyone".
-- Otherwise the list only appears once the user has actually typed something:
-- an empty recipient box matches every contact, which made the suggestions
-- drop open the moment the Send tab was opened and sit on top of the form.
function ui.UpdateAutoComplete(showAll)
    local ac = ui.sendAuto
    if not ac then return end
    local typed = ui.sendTo:GetText() or ""

    if not showAll and typed == "" then
        ac:Hide()
        return
    end

    -- THE BUTTON MEANS "SHOW ME EVERYONE", so it must not filter by whatever
    -- is already in the box. It used to pass the typed text through here like
    -- the typing path does, which meant clicking it with a complete name
    -- already typed matched exactly one contact -- itself -- and then the
    -- exact-match rule below hid the list again. The button appeared to do
    -- nothing at all, which is exactly how it was reported.
    local names = db.MatchContacts(showAll and "" or typed, AUTOCOMPLETE_ROWS)
    local n = table.getn(names)

    if showAll then
        -- The button must always visibly respond, so an empty contact list
        -- says so rather than silently doing nothing -- the same complaint in
        -- a different disguise.
        if n == 0 then
            local row = ui.sendAutoRows[1]
            row.name = nil
            row.label:SetText("|cff808080no saved recipients yet|r")
            row:Show()
            local j = 2
            while j <= AUTOCOMPLETE_ROWS do
                ui.sendAutoRows[j].name = nil
                ui.sendAutoRows[j]:Hide()
                j = j + 1
            end
            ac:SetHeight(24)
            ac:Show()
            return
        end
    else
        -- An exact single match is not a suggestion worth showing. This is a
        -- TYPING rule only: it must never apply to the button, or the button
        -- goes dead the moment a full name is in the box.
        if n == 0 or (n == 1 and names[1] == typed) then
            ac:Hide()
            return
        end
    end

    local i = 1
    while i <= AUTOCOMPLETE_ROWS do
        local row = ui.sendAutoRows[i]
        if names[i] then
            row.name = names[i]
            row.label:SetText(names[i])
            row:Show()
        else
            row.name = nil
            row:Hide()
        end
        i = i + 1
    end
    ac:SetHeight(n * 16 + 8)
    ac:Show()
end

-- Read the money box. Returns copper, or 0 when empty/unparseable.
function ui.SendMoneyValue()
    local raw = ui.sendMoney and ui.sendMoney:GetText() or ""
    return util.ParseMoney(raw) or 0
end

function ui.RefreshSend()
    if not ui.frame or not ui.frame:IsVisible() then return end
    if ui.selectedSubTab ~= "Send" then return end
    local send = A.send

    -- Attachment slots.
    local i = 1
    while i <= send.MAX_ATTACHMENTS do
        local slot = ui.sendSlots[i]
        local a = send.attachments[i]
        if a then
            slot.icon:SetTexture(a.texture)
            slot.count:SetText(a.count > 1 and a.count or "")
        else
            slot.icon:SetTexture(nil)
            slot.count:SetText("")
        end
        i = i + 1
    end

    local n = send.Count()
    ui.sendAttachLabel:SetText("Attachments  " .. n .. "/" ..
        send.MAX_ATTACHMENTS)

    -- "on every mail" only means anything once C.O.D. is on. Uncheck it as
    -- well as greying it, so a disabled box can never sit there checked and
    -- silently apply on the next send.
    local isCOD = ui.sendCOD:GetChecked() and true or false
    SetToggleEnabled(ui.sendCODAll, isCOD)
    if not isCOD then
        ui.sendCODAll:SetChecked(false)
    end

    local money = ui.SendMoneyValue()
    local mails = send.MailCount()
    local postage = send.Postage()

    -- The number the stock UI cannot show, because it never sends a batch.
    local costText = mails .. (mails == 1 and " mail" or " mails") ..
        "  |  postage " .. util.FormatMoney(postage, true)
    if money > 0 then
        if isCOD then
            costText = costText .. "  |  C.O.D. " ..
                util.FormatMoney(money, true) ..
                ((ui.sendCODAll:GetChecked() and mails > 1)
                    and " on each" or " on the first")
        else
            costText = costText .. "  |  sending " ..
                util.FormatMoney(money, true)
        end
    end

    -- Subject and body MUST be passed: they are half of what makes a mail
    -- sendable, and this is the call that decides whether the Send button is
    -- clickable at all. Omitting them greys the button out for every letter --
    -- which is precisely the "cannot send without an item" bug, still live
    -- after send.Start's own Validate call had been fixed.
    local ok, why = send.Validate(ui.sendTo:GetText(), money, isCOD,
        ui.sendSubject:GetText(), ui.sendBody:GetText())
    if send.sending then
        costText = "sending " .. (send.sentCount + 1) .. " of " ..
            send.total .. "..."
        ui.btnSend:Disable()
    elseif ok then
        ui.btnSend:Enable()
    else
        ui.btnSend:Disable()
        if why and why ~= "no recipient" and why ~= "nothing to send" then
            costText = costText .. "  |  |cffd05050" .. why .. "|r"
        end
    end
    ui.sendCost:SetText(costText)
end

function ui.DoSend()
    local send = A.send
    send.Start(ui.sendTo:GetText(), ui.sendSubject:GetText(),
        ui.sendBody:GetText(), ui.SendMoneyValue(),
        ui.sendCOD:GetChecked() and true or false,
        ui.sendCODAll:GetChecked() and true or false)
    ui.RefreshSend()
end

function ui.ClearSendForm()
    A.send.ClearAttachments()
    ui.sendSubject:SetText("")
    ui.sendBody:SetText("")
    ui.sendMoney:SetText("")
    ui.sendCOD:SetChecked(false)
    ui.sendCODAll:SetChecked(false)
    ui.RefreshSend()
end

-- Called by the send engine once a whole batch has gone out.
function ui.OnSendComplete()
    if not ui.sendSubject then return end
    ui.sendSubject:SetText("")
    ui.sendBody:SetText("")
    ui.sendMoney:SetText("")
    ui.sendCOD:SetChecked(false)
    ui.sendCODAll:SetChecked(false)
    -- Blizzard's MailFrame is hidden but still receives MAIL_SEND_SUCCESS, and
    -- its SendMailFrame_Reset calls SetFocus() on ITS recipient box. Take the
    -- keyboard back so the next keystroke does not vanish into a frame the
    -- user cannot see.
    local blizName = getglobal("SendMailNameEditBox")
    if blizName and blizName.ClearFocus then blizName:ClearFocus() end
    ui.RefreshSend()
end

-- ---------------------------------------------------------------------------
-- Log panel
-- ---------------------------------------------------------------------------
--
-- The correspondence log, distinct from the Ledger next door: the Ledger is
-- money (auction sales, with the consignment split), this is who wrote to
-- whom and what was attached, across every mail Courier handled.
--
-- Storage is account-wide with the character on each entry, so "this
-- character only" is a FILTER here rather than a storage decision. TurtleMail
-- stores per-character, which makes "did I send that on my bank alt?"
-- unanswerable; that is the common question, so Courier answers it.

function ui.BuildLogPanel()
    local panel = ui.panels["Log"]
    ui.logDir = "received"

    local function DirButton(name, label, dir)
        local b = CreateFrame("Button", "AegisCourierLogDir" .. name, panel,
            "UIPanelButtonTemplate")
        b:SetWidth(76)
        b:SetHeight(21)
        b:SetText(label)
        b:SetScript("OnClick", function()
            ui.logDir = dir
            ui.RefreshLog()
        end)
        return b
    end

    local recvBtn = DirButton("Received", "Received", "received")
    recvBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", 2, -2)
    local sentBtn = DirButton("Sent", "Sent", "sent")
    sentBtn:SetPoint("LEFT", recvBtn, "RIGHT", 4, 0)
    ui.logRecvBtn, ui.logSentBtn = recvBtn, sentBtn

    local findLbl = Label(panel, "GameFontNormalSmall", C.goldDim)
    findLbl:SetPoint("LEFT", sentBtn, "RIGHT", 16, 0)
    findLbl:SetText("Find")

    -- One search box covers both filters the audit calls for: it matches the
    -- participant, the subject, the item and the auction tag, so "Bob",
    -- "cloth" and "sold" all work without a dropdown widget.
    local findBox = MakeEditBox("LogFind", panel, 130)
    findBox:SetPoint("LEFT", findLbl, "RIGHT", 8, 0)
    findBox:SetScript("OnTextChanged", function() ui.RefreshLog() end)
    ui.logFind = findBox

    local mine = MakeToggle(panel, "LogMine", "this character only")
    mine:SetPoint("LEFT", findBox, "RIGHT", 14, 0)
    mine:SetScript("OnClick", function() ui.RefreshLog() end)
    ui.logMine = mine

    local well = CreateFrame("Frame", nil, panel)
    well:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -LOG_TOP)
    well:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, LOG_BOTTOM)
    Backdrop(well, C.well, true)
    ui.logWell = well

    local scroll = CreateFrame("ScrollFrame", "AegisCourierLogScroll", well,
        "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", well, "TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -26, 4)
    scroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(ROW_H, ui.RefreshLog)
    end)
    ui.logScroll = scroll

    ui.logRows = {}
    local i = 1
    while i <= ROWS do
        local row = CreateFrame("Frame", nil, well)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", well, "TOPLEFT", 6, -LIST_PAD - (i - 1) * ROW_H)
        row:SetPoint("TOPRIGHT", well, "TOPRIGHT", -26, -LIST_PAD - (i - 1) * ROW_H)

        local when = Label(row, "GameFontNormalSmall", C.dim)
        when:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.when = when

        local who = Label(row, "GameFontNormalSmall", C.text)
        who:SetPoint("LEFT", row, "LEFT", 84, 0)
        row.who = who

        local subject = Label(row, "GameFontNormalSmall", C.text)
        subject:SetPoint("LEFT", row, "LEFT", 200, 0)
        row.subject = subject

        local amount = Label(row, "GameFontNormalSmall", C.gold)
        amount:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.amount = amount

        row:Hide()
        ui.logRows[i] = row
        i = i + 1
    end

    local summary = Label(panel, "GameFontNormalSmall", C.dim)
    summary:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 4, 6)
    ui.logSummary = summary

    local clear = CreateFrame("Button", "AegisCourierBtnClearLog", panel,
        "UIPanelButtonTemplate")
    clear:SetWidth(90)
    clear:SetHeight(20)
    clear:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 2)
    clear:SetText("Clear view")
    clear:SetScript("OnClick", function()
        -- Clears the direction currently on screen, not both -- wiping the
        -- half you are not looking at would be a nasty surprise.
        db.ClearLog(ui.logDir)
        ui.RefreshLog()
    end)
end

-- Entries for the current direction, newest first, after filtering.
function ui.LogRows()
    local out = {}
    local entries = db.Log(ui.logDir)
    local find = string.lower(util.Trim(ui.logFind:GetText() or ""))
    local mineOnly = ui.logMine:GetChecked() and true or false
    local me = UnitName and UnitName("player") or nil

    local i = table.getn(entries)
    while i >= 1 do
        local e = entries[i]
        local keep = true
        if mineOnly and me and e.char and e.char ~= me then keep = false end
        if keep and find ~= "" then
            -- Match across everything visible in the row, so one box serves as
            -- both the participant filter and the category filter.
            local hay = string.lower((e.who or "") .. " " .. (e.subject or "")
                .. " " .. (e.item or "") .. " " .. (e.auction or "")
                .. " " .. (e.char or ""))
            if not util.Contains(hay, find) then keep = false end
        end
        if keep then table.insert(out, e) end
        i = i - 1
    end
    return out
end

function ui.RefreshLog()
    if not ui.frame or not ui.frame:IsVisible() then return end
    if ui.selectedSubTab ~= "Log" then return end
    -- Reentrancy guard -- see RefreshInbox for the FrameXML recursion chain.
    if ui.logRefreshing then return end
    ui.logRefreshing = true

    -- Selected direction reads as pressed.
    if ui.logDir == "sent" then
        ui.logRecvBtn:UnlockHighlight()
        ui.logSentBtn:LockHighlight()
    else
        ui.logRecvBtn:LockHighlight()
        ui.logSentBtn:UnlockHighlight()
    end

    local rows = ui.LogRows()
    local total = table.getn(rows)

    FauxScrollFrame_Update(ui.logScroll, total, ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.logScroll) or 0
    local now = time()

    local i = 1
    while i <= ROWS do
        local row = ui.logRows[i]
        local e = rows[offset + i]
        if e then
            row.when:SetText(util.FormatAgo(now - (e.t or now)))
            SetClipped(row.who, e.who or "?", 108)

            local subject = e.subject or ""
            if e.auction then
                subject = "|cffffd700[" .. e.auction .. "]|r " .. subject
            elseif e.returned then
                subject = "|cffd08050[returned]|r " .. subject
            end
            if e.item then
                subject = subject .. "  |cff8fd6a8" .. e.item ..
                    (e.count and e.count > 1 and (" x" .. e.count) or "") .. "|r"
            end
            SetClipped(row.subject, subject, 250)

            if e.cod and e.cod > 0 then
                row.amount:SetText("|cffd05050COD " ..
                    util.FormatMoney(e.cod, false) .. "|r")
            elseif e.money and e.money > 0 then
                local sign = (ui.logDir == "sent") and "-" or "+"
                row.amount:SetText(sign .. util.FormatMoney(e.money, true))
            else
                row.amount:SetText("")
            end
            row:Show()
        else
            row:Hide()
        end
        i = i + 1
    end

    local stored = table.getn(db.Log(ui.logDir))
    local label = (ui.logDir == "sent") and "sent" or "received"
    if stored == 0 then
        ui.logSummary:SetText("Nothing logged yet. Mail is recorded as you " ..
            "collect and send it.")
    elseif total == stored then
        ui.logSummary:SetText(stored .. " " .. label)
    else
        ui.logSummary:SetText(total .. " of " .. stored .. " " .. label ..
            " shown")
    end

    ui.logRefreshing = false
end

-- Return one mail to its sender.
--
-- ReturnInboxItem removes the mail from our inbox and shifts every later index
-- down one, exactly like a delete -- so it must never run while the take
-- engine is walking the inbox.
function ui.ReturnMail(index)
    if not index then return end
    if A.take.running then
        A.Print("finish the current run before returning mail.")
        return
    end
    local h = inbox.Header(index)
    if not h then return end
    if not h.canReply or h.isGM then
        A.Print("that mail cannot be returned to its sender.")
        return
    end
    if not ReturnInboxItem then return end
    ReturnInboxItem(index)
    A.Print("returned \"" .. h.subject .. "\" to " .. h.sender .. ".")
    -- MAIL_INBOX_UPDATE repaints the list once the server confirms.
end

-- ---------------------------------------------------------------------------
-- Ledger panel
-- ---------------------------------------------------------------------------

function ui.BuildLedgerPanel()
    local panel = ui.panels["Ledger"]

    local totals = Label(panel, "GameFontNormalSmall", C.text)
    totals:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -2)
    ui.ledgerTotals = totals

    local well = CreateFrame("Frame", nil, panel)
    well:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -LEDGER_TOP)
    well:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, LEDGER_BOTTOM)
    Backdrop(well, C.well, true)
    ui.ledgerWell = well

    local scroll = CreateFrame("ScrollFrame", "AegisCourierLedgerScroll", well,
        "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", well, "TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -26, 4)
    scroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(ROW_H, ui.RefreshLedger)
    end)
    ui.ledgerScroll = scroll

    ui.ledgerRows = {}
    local i = 1
    while i <= ROWS do
        local row = CreateFrame("Frame", nil, well)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", well, "TOPLEFT", 6, -LIST_PAD - (i - 1) * ROW_H)
        row:SetPoint("TOPRIGHT", well, "TOPRIGHT", -26, -LIST_PAD - (i - 1) * ROW_H)

        local when = Label(row, "GameFontNormalSmall", C.dim)
        when:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.when = when

        local item = Label(row, "GameFontNormalSmall", C.text)
        item:SetPoint("LEFT", row, "LEFT", 88, 0)
        row.item = item

        local amount = Label(row, "GameFontNormalSmall", C.gold)
        amount:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.amount = amount

        row:Hide()
        ui.ledgerRows[i] = row
        i = i + 1
    end

    local note = Label(panel, "GameFontNormalSmall", C.dim)
    note:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 4, 4)
    note:SetText("Entries are written when mail is COLLECTED (Stage B).")
end

function ui.RefreshLedger()
    if not ui.frame or not ui.frame:IsVisible() then return end
    if ui.selectedSubTab ~= "Ledger" then return end
    -- Reentrancy guard -- see RefreshInbox for the FrameXML recursion chain.
    if ui.ledgerRefreshing then return end
    ui.ledgerRefreshing = true

    local led = db.Ledger()
    local total = table.getn(led)
    local income, spend, count = db.LedgerTotals(nil)
    local cut = db.CutTotal(nil)

    if count == 0 then
        ui.ledgerTotals:SetText("No transactions recorded yet.")
    else
        ui.ledgerTotals:SetText(
            count .. " entries  |  in " .. util.FormatMoney(income, true) ..
            "  |  out " .. util.FormatMoney(spend, true) ..
            "  |  cut " .. util.FormatMoney(cut, true))
    end

    FauxScrollFrame_Update(ui.ledgerScroll, total, ROWS, ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.ledgerScroll) or 0
    local now = time()

    local i = 1
    while i <= ROWS do
        local row = ui.ledgerRows[i]
        -- Newest first: walk the array backwards.
        local e = led[total - (offset + i) + 1]
        if e then
            row.when:SetText(util.FormatAgo(now - (e.t or now)))
            SetClipped(row.item, e.item or "?", 300)
            local prefix = (e.kind == "buy") and "-" or "+"
            row.amount:SetText(prefix .. util.FormatMoney(e.amount or 0, true))
            row:Show()
        else
            row:Hide()
        end
        i = i + 1
    end

    ui.ledgerRefreshing = false
end

-- ---------------------------------------------------------------------------
-- Courier panel (settings + integration status)
-- ---------------------------------------------------------------------------

local function MakeCheck(parent, name, label, setting, onChange)
    local c = CreateFrame("CheckButton", "AegisCourierCheck" .. name, parent,
        "UICheckButtonTemplate")
    c:SetWidth(22)
    c:SetHeight(22)
    local text = getglobal("AegisCourierCheck" .. name .. "Text")
    if text then
        text:SetText(label)
        text:SetTextColor(C.text[1], C.text[2], C.text[3])
    end
    c:SetScript("OnClick", function()
        local on = c:GetChecked() and true or false
        db.SetSetting(setting, on)
        if onChange then onChange(on) end
        ui.Refresh()
    end)
    c.setting = setting
    -- Kept so SetToggleEnabled can grey the label with the box; see MakeToggle.
    c.labelText = text
    return c
end

function ui.BuildCourierPanel()
    local panel = ui.panels["Courier"]

    local head = Label(panel, "GameFontNormal", C.gold)
    head:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, -4)
    head:SetText("Settings")

    local takeover = MakeCheck(panel, "Takeover",
        "Replace the Blizzard mailbox window", "takeover",
        function(on)
            if on then
                -- Turning it on mid-session: take over the mailbox we are
                -- standing at right now.
                if ui.mailOpen then ui.OpenWindow() end
            else
                -- Turning it off: hand the mailbox back immediately.
                if ui.mailOpen then ui.ShowBlizzardMail() end
            end
        end)
    takeover:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -12)

    local push = MakeCheck(panel, "Push",
        "Send matched auction mail to Aegis: Exchange", "pushToAegis")
    push:SetPoint("TOPLEFT", takeover, "BOTTOMLEFT", 0, -8)

    local logOn = MakeCheck(panel, "Log",
        "Keep a log of mail sent and collected", "logEnabled")
    logOn:SetPoint("TOPLEFT", push, "BOTTOMLEFT", 0, -8)

    -- Defaults ON, but only ever does anything when pfUI is installed --
    -- skin.Enabled() requires both. When pfUI is absent the box is greyed
    -- below rather than hidden, so it is clear the feature exists and why it
    -- is inactive.
    local pfSkin = MakeCheck(panel, "PfSkin",
        "Match pfUI's look when pfUI is installed", "pfSkin",
        function(on)
            if A.skin then A.skin.OnSettingChanged(on) end
        end)
    pfSkin:SetPoint("TOPLEFT", logOn, "BOTTOMLEFT", 0, -8)

    ui.checkTakeover = takeover
    ui.checkPush = push
    ui.checkLog = logOn
    ui.checkPfSkin = pfSkin

    -- A rule between the two groups. Without it -- and with the Integration
    -- heading previously anchored to `push` rather than to the last checkbox --
    -- the heading was drawn straight on top of the log option.
    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", pfSkin, "BOTTOMLEFT", 0, -14)
    divider:SetPoint("RIGHT", panel, "RIGHT", -8, 0)
    divider:SetTexture(C.goldDim[1], C.goldDim[2], C.goldDim[3], 0.35)

    local integHead = Label(panel, "GameFontNormal", C.gold)
    integHead:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -12)
    integHead:SetText("Integration")

    local integ = Label(panel, "GameFontNormalSmall", C.text)
    integ:SetPoint("TOPLEFT", integHead, "BOTTOMLEFT", 2, -8)
    integ:SetWidth(WIN_W - 48)
    integ:SetJustifyH("LEFT")
    -- The status runs to several lines when Aegis is absent or out of date;
    -- without extra leading the wrapped lines crowd each other.
    integ:SetSpacing(2)
    ui.integStatus = integ

    local stats = Label(panel, "GameFontNormalSmall", C.dim)
    stats:SetPoint("TOPLEFT", integ, "BOTTOMLEFT", 0, -18)
    ui.courierStats = stats
end

-- "1 entry" / "2 entries", so the settings tab does not read like a stub.
local function Plural(n, one, many)
    if n == 1 then return n .. " " .. one end
    return n .. " " .. many
end

function ui.RefreshCourier()
    if not ui.frame or not ui.frame:IsVisible() then return end
    if ui.selectedSubTab ~= "Courier" then return end

    ui.checkTakeover:SetChecked(db.Setting("takeover") and true or false)
    ui.checkPush:SetChecked(db.Setting("pushToAegis") and true or false)
    ui.checkLog:SetChecked(db.Setting("logEnabled") and true or false)
    ui.checkPfSkin:SetChecked(db.Setting("pfSkin") and true or false)

    -- Grey the pfUI option out when pfUI is not there to match. The setting
    -- itself stays on, so installing pfUI later just works.
    local pfHere = A.skin and A.skin.Available()
    SetToggleEnabled(ui.checkPfSkin, pfHere and true or false)
    if ui.checkPfSkin.labelText then
        ui.checkPfSkin.labelText:SetText(pfHere
            and "Match pfUI's look"
            or "Match pfUI's look   (pfUI not installed)")
    end

    local status = A.bridge.StatusText()
    if not AegisExchange then
        status = status ..
            "\n\nAegis: Exchange is not installed. Courier is fully " ..
            "functional on its own and keeps its own transaction history."
    elseif type(AegisExchange.RecordExternalTxn) ~= "function" then
        status = status ..
            "\n\nThe installed Aegis: Exchange predates the Courier " ..
            "integration surface, so nothing is pushed. Courier's own " ..
            "history is unaffected."
    end
    ui.integStatus:SetText(status)

    -- Deliberately NOT db.SeenCount(): Stage B stopped using mail
    -- fingerprints, so it is always 0 and reads as though something is broken.
    ui.courierStats:SetText(
        "Ledger: " .. Plural(table.getn(db.Ledger()), "entry", "entries") ..
        "   |   Log: " .. table.getn(db.Log("received")) .. " received, " ..
        table.getn(db.Log("sent")) .. " sent")
end

-- ---------------------------------------------------------------------------
-- Refresh dispatch
-- ---------------------------------------------------------------------------

function ui.Refresh()
    if not ui.frame or not ui.frame:IsVisible() then return end
    if ui.footer then
        local where = ui.mailOpen and "At mailbox" or "Away from mailbox"
        ui.footer:SetText(where .. "  |  " .. A.bridge.StatusText())
    end
    if ui.selectedSubTab == "Inbox" then
        -- Updates the action bar for the current inbox contents, then repaints
        -- the list. Does not re-enter ui.Refresh.
        ui.OnTakeStateChanged()
    elseif ui.selectedSubTab == "Send" then
        ui.RefreshSend()
    elseif ui.selectedSubTab == "Log" then
        ui.RefreshLog()
    elseif ui.selectedSubTab == "Ledger" then
        ui.RefreshLedger()
    elseif ui.selectedSubTab == "Courier" then
        ui.RefreshCourier()
    end
end

-- ---------------------------------------------------------------------------
-- Mailbox takeover
-- ---------------------------------------------------------------------------
--
-- Two client behaviours make this harder than "hide their frame, show ours",
-- and BOTH fail silently -- the mailbox looks fine and every subsequent
-- TakeInboxItem / TakeInboxMoney / DeleteInboxItem does nothing at all:
--
--   1. MailFrame's XML <OnHide> runs CloseMail(), ending the server-side mail
--      session. So we must hide it WITHOUT that body running.
--   2. MailFrame_OnEvent's MAIL_SHOW branch is, verbatim from 1.12.1 FrameXML:
--
--          ShowUIPanel(MailFrame);
--          if ( not MailFrame:IsVisible() ) then
--              CloseMail();
--              return;
--          end
--
--      so hiding MailFrame SYNCHRONOUSLY from its own OnShow trips that guard
--      and the CLIENT closes the session for us.
--
-- This is the same pair of traps Aegis: Exchange documents for AuctionFrame.
-- If a later change makes the hide synchronous "because it looks cleaner",
-- the mailbox will appear to work and quietly stop taking mail.

-- One-tick deferred hide of the Blizzard mailbox, for trap 2. No flash is
-- visible: our toplevel HIGH-strata window covers the Blizzard frame.
local hider = CreateFrame("Frame", "AegisCourierHider")
hider:Hide()
hider:SetScript("OnUpdate", function()
    hider:Hide()
    if ui.TakeoverActive() and MailFrame and MailFrame:IsVisible() then
        ui.HideBlizzardMail()
    end
end)

function ui.QueueHideBlizzard()
    hider:Show()
end

-- Should we be replacing the Blizzard mailbox right now?
function ui.TakeoverActive()
    if ui.showBlizzard then return false end
    return db.Setting("takeover") and true or false
end

-- Hide the Blizzard mail window WITHOUT closing the mail session (see trap 1).
-- Normal HideUIPanel bookkeeping, minus the session teardown.
function ui.HideBlizzardMail()
    if not MailFrame then return end
    ui.keepSessionOpen = true
    HideUIPanel(MailFrame)
    ui.keepSessionOpen = false
    -- Suppressing the OnHide body also suppressed its HideUIPanel(OpenMailFrame),
    -- so do that one part ourselves -- an orphaned "open mail" window floating
    -- over ours would be able to act on the session behind our back.
    if OpenMailFrame and OpenMailFrame:IsVisible() then
        HideUIPanel(OpenMailFrame)
    end
end

-- Install the save-and-replace hooks. No hooksecurefunc on 1.12 (CLAUDE.md
-- rule 7): we keep the original script and call it from ours.
--
-- MailFrame is a plain FrameXML frame, not load-on-demand, so it exists by
-- ADDON_LOADED and there is no deferred-load dance as there is for the AH.
function ui.HookMailFrame()
    if ui.mailHooked then return end
    if not MailFrame then return end

    ui.orig_MailFrame_OnShow = MailFrame:GetScript("OnShow")
    MailFrame:SetScript("OnShow", function()
        if ui.orig_MailFrame_OnShow then
            ui.orig_MailFrame_OnShow()
        end
        if ui.TakeoverActive() then
            -- QUEUED, never synchronous -- see trap 2 above.
            ui.QueueHideBlizzard()
        end
    end)

    ui.orig_MailFrame_OnHide = MailFrame:GetScript("OnHide")
    MailFrame:SetScript("OnHide", function()
        -- keepSessionOpen: we hid it ourselves to show Courier, so the session
        -- must live. Skip the default body (CloseMail + OpenMailFrame hide +
        -- send-form reset + sound).
        if ui.keepSessionOpen then return end
        if ui.orig_MailFrame_OnHide then
            ui.orig_MailFrame_OnHide()
        end
    end)

    -- "Courier" button ON the Blizzard mail frame, so the hand-off works both
    -- ways. This is the ONE frame we parent to a Blizzard window, and it has
    -- to be: it must appear on THEIR window while ours is hidden, and
    -- parenting gets that show/hide behaviour for free. Everything else
    -- Courier draws lives under UIParent.
    if not ui.swapBtn then
        local b = CreateFrame("Button", "AegisCourierSwapButton", MailFrame,
            "UIPanelButtonTemplate")
        b:SetWidth(70)
        b:SetHeight(19)
        local blizClose = getglobal("MailFrameCloseButton")
        if blizClose then
            b:SetPoint("RIGHT", blizClose, "LEFT", -6, 0)
        else
            b:SetPoint("TOPRIGHT", MailFrame, "TOPRIGHT", -46, -12)
        end
        b:SetText("Courier")
        b:SetScript("OnClick", function() ui.OpenWindow() end)
        ui.swapBtn = b
        if A.skin then A.skin.ApplyExternal() end
    end

    ui.mailHooked = true
end

-- ---------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------

-- Show Courier, hiding the Blizzard mailbox session-safely if it is up.
function ui.OpenWindow()
    ui.BuildWindow()
    ui.showBlizzard = false
    if MailFrame and MailFrame:IsVisible() then
        ui.HideBlizzardMail()
    end
    ui.frame:Show()
    ui.Refresh()
end

-- Hand the mailbox back to the stock UI for this visit.
function ui.ShowBlizzardMail()
    ui.showBlizzard = true
    if ui.frame then ui.frame:Hide() end
    if not ui.mailOpen then return end
    if MailFrame then
        ShowUIPanel(MailFrame)
    end
end

-- Close Courier. When we are at a mailbox this also ENDS the mail session --
-- closing the window the user is looking at should close the mailbox, exactly
-- as clicking the X on the stock frame does. That happens in the frame's
-- OnHide (see BuildWindow) so Escape behaves identically; CloseMail then fires
-- MAIL_CLOSED, which routes back through our handler below.
function ui.CloseWindow()
    if ui.frame then ui.frame:Hide() end
end

function ui.Toggle()
    ui.BuildWindow()
    if ui.frame:IsVisible() then
        ui.CloseWindow()
    else
        ui.OpenWindow()
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

A.RegisterEvent("MAIL_SHOW", function()
    ui.mailOpen = true
    ui.showBlizzard = false
    ui.BuildWindow()
    ui.HookMailFrame()
    -- Starts the take engine's driver: its step clock and the passive
    -- CheckInbox pacing only run while a mailbox is actually open.
    A.take.SetMailboxOpen(true)
    -- Forget the previous visit's unread count. ui.SettleMailIcon reads it
    -- after MAIL_CLOSED, when the inbox can no longer be queried; a value
    -- carried over from a mailbox we emptied last time could otherwise
    -- authorise hiding a genuine new-mail icon. nil means "do not touch it".
    A.inbox.lastUnread = nil
    -- Harvest contacts once per visit rather than per inbox update.
    if A.send and A.send.HarvestContacts then A.send.HarvestContacts() end
    if not ui.TakeoverActive() then return end
    -- Queue rather than hide inline. Our own MAIL_SHOW handler runs after the
    -- client's IsVisible guard so a synchronous hide would in fact be safe
    -- here, but handler ORDER between FrameXML and an addon is not a promise
    -- worth betting a silently-dead mailbox on -- and the deferred path is
    -- already the one the OnShow hook uses.
    ui.QueueHideBlizzard()
    ui.frame:Show()
    -- Flush rather than Refresh: it paints AND seeds inbox.lastUnread, which
    -- the nil above just cleared. It also clears any dirty flag left set by an
    -- update that landed while the driver was hidden.
    A.inbox.Flush()
end)

A.RegisterEvent("MAIL_CLOSED", function()
    ui.mailOpen = false
    ui.showBlizzard = false
    -- Stops the driver and quietly abandons any run in flight -- walking away
    -- from the mailbox ends the session, so there is nothing left to take.
    A.take.SetMailboxOpen(false)
    -- The session is gone, so the index the reader was holding means nothing
    -- now. Drop it here rather than leaving it to be re-read on the next open.
    ui.readerIndex = nil
    ui.readerSig = nil
    ui.readerWantBody = nil
    if ui.reader then ui.reader:Hide() end
    ui.SettleMailIcon()
    if ui.frame then ui.frame:Hide() end
end)

-- Put the minimap's "you have unread mail" icon out when nothing is unread.
--
-- Two separate things had to be true for the icon to clear, and Courier was
-- doing neither:
--
--   1. The mail must be marked READ on the server. There is no "mark read"
--      call on 1.12 -- GetInboxText(index) does it as a side effect. The take
--      engine now calls inbox.MarkRead before emptying a mail.
--   2. The ICON itself must be taken down. It tracks HasNewMail(), which the
--      client does not re-evaluate just because we emptied the inbox, so in
--      vanilla it can stay lit until the next login. Postal solves this the
--      same way: when the mailbox closes with nothing unread left, hide it.
--
-- Gated on the unread count captured while the mailbox was still open --
-- MAIL_CLOSED arrives after the session is gone and the inbox cannot be read
-- from here. Only ever hides when we KNOW nothing was unread, so a genuine
-- notification is never suppressed. New mail fires UPDATE_PENDING_MAIL and
-- FrameXML shows it again.
function ui.SettleMailIcon()
    if A.inbox.lastUnread ~= 0 then return end
    local icon = getglobal("MiniMapMailFrame")
    if icon and icon.Hide then icon:Hide() end
end

-- MAIL_INBOX_UPDATE deliberately has NO handler here. The repaint is driven
-- by inbox.Flush, which the take engine's OnUpdate driver runs at most once
-- per frame -- see the "Coalesced refresh" note in core/inbox.lua. Repainting
-- inside the event storms a first mailbox open produces was what froze the
-- client on a large inbox.

-- ---------------------------------------------------------------------------
-- Slash command
-- ---------------------------------------------------------------------------

A.OnLoad(function()
    -- MailFrame exists at this point (plain FrameXML), so the hooks can go on
    -- immediately rather than waiting for the first mailbox.
    ui.HookMailFrame()

    SLASH_AEGISCOURIER1 = "/courier"
    SLASH_AEGISCOURIER2 = "/acr"
    SlashCmdList["AEGISCOURIER"] = function(msg)
        local cmd = string.lower(util.Trim(msg or ""))
        if cmd == "status" then
            A.Print("integration: " .. A.bridge.StatusText())
            A.Print("ledger: " .. table.getn(db.Ledger()) .. " entries, " ..
                db.SeenCount() .. " tracked mail ids.")
            A.Print("takeover: " ..
                (db.Setting("takeover") and "on" or "off"))
        elseif cmd == "blizzard" then
            ui.ShowBlizzardMail()
            A.Print("handed this visit back to the stock mail window.")
        elseif cmd == "help" then
            A.Print("/courier         - toggle the window")
            A.Print("/courier status  - integration and ledger summary")
            A.Print("/courier blizzard- use the stock mail window this visit")
        else
            ui.Toggle()
        end
    end
end)
