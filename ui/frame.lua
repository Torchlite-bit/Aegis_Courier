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

-- Tab KEYS. These are identity, not presentation: they name the panel frame
-- (AegisCourierPanelSend), the ui.panels / ui.subTabs entries, the comparison
-- in ui.SendAttachActive, and the remembered tab persisted in
-- db.char.ui.tab. Renaming one silently drops every player onto a different
-- tab after an update, so a key is never changed to relabel something.
local SUBTABS = { "Inbox", "Send", "Sent", "Log", "Ledger", "Courier" }

-- Display labels, where they differ from the key. "Send" is the compose form;
-- "Sent" is the record of what already went. Calling the first one Send next
-- to the second reads as two views of the same thing, which they are not.
local SUBTAB_LABELS = { Send = "Compose" }

local function SubTabLabel(key)
    return SUBTAB_LABELS[key] or key
end


-- ---- window geometry -------------------------------------------------------
-- THE DEPENDENCY RUNS HEIGHT -> ROWS, and it used to run the other way.
--
-- Until the window could be resized, ROWS was a constant and WIN_H was derived
-- from it. That is backwards once a grip exists: the player sets the height and
-- the list has to work out how many rows fit. Everything below is therefore a
-- function of the LIVE frame height, and the only constant left is the default
-- the window opens at.
--
-- The original bug this arithmetic exists to prevent is still the point: a well
-- 20px shorter than the rows it draws does not clip on 1.12, it draws straight
-- through its own border and over whatever is beneath. ui.Geometry() reports
-- the live numbers and the harness asserts the fit at minimum, default and
-- maximum size rather than at one hand-picked one.
local LIST_PAD = 4                          -- well edge to first/last row

-- ---- window chrome ---------------------------------------------------------
-- The main window wears Aegis: Exchange's dialog frame rather than the thin
-- tooltip border the inner wells use (see WindowBackdrop). That art is 28px
-- deep with 10px insets, so everything inside has to be pushed clear of it --
-- these are the numbers that do it, and every anchor derives from them rather
-- than repeating a literal.
local TITLE_INSET = 12                      -- title bar offset from the corner
local TITLE_H     = 26
local TAB_H       = 24                      -- sub-tab button height
local GAP         = 6

-- ---- content well ----------------------------------------------------------
-- A recessed region holding every panel, matching Exchange's ui.content. The
-- outer dialog frame alone left the panels floating on the window background;
-- this is the sunken plate they sit on, and it is the remaining structural
-- difference between the two addons once the frames matched.
local CONTENT_SIDE   = 14                   -- inset from the window edge

-- The footer ("At mailbox | linked to Aegis: Exchange") lives BELOW the content
-- well, on the window itself. The well's bottom therefore has to clear it, and
-- it did not: the well ended 16px from the bottom while the footer occupied
-- 14..26, so the recessed plate drew straight over the text. Derive the well's
-- bottom from where the footer actually is rather than picking a number that
-- happens to look close.
local FOOTER_INSET = 12                     -- footer baseline from window bottom
local FOOTER_H     = 12                     -- GameFontNormalSmall line height
local CONTENT_BOTTOM = FOOTER_INSET + FOOTER_H + GAP
local CONTENT_TOP    = TITLE_INSET + TITLE_H + GAP + TAB_H + GAP
local PANEL_PAD      = 6                    -- panel inset inside the content well

-- Panels are children of the content well now, so their inset from the WINDOW
-- is the sum of both. Reported by ui.Geometry for the clearance assertions.
local PANEL_SIDE   = CONTENT_SIDE + PANEL_PAD
local PANEL_TOP    = CONTENT_TOP + PANEL_PAD
local PANEL_BOTTOM = CONTENT_BOTTOM + PANEL_PAD

-- The Inbox is the tightest of the panels: a summary line, an action bar and a
-- column header sit above its well, and the hint line sits below it.
local INBOX_TOP,  INBOX_BOTTOM  = 58, 22
local LOG_TOP,    LOG_BOTTOM    = 28, 26
local LEDGER_TOP, LEDGER_BOTTOM = 22, 22

-- ---- Sent reader geometry --------------------------------------------------
-- THREE columns of four rather than two of six. A batch cannot exceed
-- MAX_ATTACHMENTS (12), so 3 x 4 still shows every possible item without
-- scrolling -- but in four rows instead of six, which hands 32px straight to
-- the message below it. Widening beats lengthening here: the reader is far
-- wider than it is tall, and item labels are short.
--
-- Every offset below derives from these; ui.SentGeometry() reports the result
-- and the harness asserts the blocks fit without overlapping.
local SENT_ITEM_COLS = 3
local SENT_ITEM_ROWS = 4                    -- x COLS = 12 = MAX_ATTACHMENTS
local SENT_ITEM_H    = 16

-- Header block: Back/recipient, subject, then one line carrying both the mail
-- count and the item count. Merging those two lines is where another 18px for
-- the message came from.
local SENT_HEAD_H = 60
local SENT_FOOT_H = 26                      -- the Compose button strip
local SENT_GAP    = 8

local SENT_ITEMS_H = SENT_ITEM_ROWS * SENT_ITEM_H
local SENT_BODY_TOP = SENT_HEAD_H + SENT_ITEMS_H + SENT_GAP

-- The message well is BOUNDED AT BOTH ENDS, and both numbers come from the
-- same fact: a stored body cannot exceed db.SENT_BODY_MAX (500 characters),
-- which at this font and width is about seven lines, call it 110px.
--
--   MIN -- below this a message is scrolling for no reason, so the window's
--          own minimum height is derived from it rather than from the inbox
--          list alone. See MIN_H.
--   MAX -- above this the well is mostly empty. v1.5.0 let it stretch to the
--          full reader and it reached 204px, which read as a huge blank box;
--          reported, fairly, as "too long". A record view does not have to
--          fill the screen the way a list does.
local SENT_BODY_MIN = 110
local SENT_BODY_MAX = 150

-- ---- size limits -----------------------------------------------------------
-- DEFAULT_ROWS only sets the height the window first opens at; after that the
-- grip decides. MIN keeps the shortest window still usable as a mailbox, MAX
-- keeps the tallest inside a 1024-high screen.
local DEFAULT_ROWS = 12
local MIN_ROWS     = 6

-- Height needed for a given inbox row count -- the inverse of RowsForHeight.
local function HeightForRows(n)
    return PANEL_TOP + INBOX_TOP + (LIST_PAD + n * ROW_H + LIST_PAD)
        + INBOX_BOTTOM + PANEL_BOTTOM
end

local WIN_W = 660
local WIN_H = HeightForRows(DEFAULT_ROWS)   -- the DEFAULT, no longer a ceiling

-- The floor is whichever panel runs out of room FIRST. That used to be the
-- inbox list; with the Sent reader's fixed header, item grid and button strip
-- it is now the reader, which needs 268px of panel before its message well
-- reaches a usable height. Taking only the list into account left the message
-- box 36px tall at minimum size -- technically laid out, functionally useless.
local SENT_READER_MIN = SENT_HEAD_H + SENT_ITEMS_H + SENT_GAP
    + SENT_BODY_MIN + SENT_FOOT_H
local MIN_H_FOR_READER = SENT_READER_MIN + (LIST_PAD * 2)
    + LOG_TOP + LOG_BOTTOM + PANEL_TOP + PANEL_BOTTOM
local MIN_H_FOR_LIST = HeightForRows(MIN_ROWS)

local MIN_W = WIN_W
local MIN_H = MIN_H_FOR_LIST
if MIN_H_FOR_READER > MIN_H then MIN_H = MIN_H_FOR_READER end
local MAX_W, MAX_H = 1100, 900

-- Row frames are BUILT to this many and then shown or hidden per paint.
-- CreateFrame mid-resize is not viable, so the tallest window the player can
-- ever drag to decides how many exist.
local MAX_ROWS = math.floor(
    ((MAX_H - PANEL_TOP - PANEL_BOTTOM - INBOX_TOP - INBOX_BOTTOM)
        - (LIST_PAD * 2)) / ROW_H)

-- ---- window scale ----------------------------------------------------------
-- Scale and size answer different questions. Extra height shows MORE rows --
-- vanilla frames never reflow, so that is all it can do -- while scale makes
-- the same window physically larger. On a big screen you want both.
--
-- Clamped: below ~0.7 the fonts stop being legible, above ~1.5 a maximum-height
-- window no longer fits a 1024-tall screen.
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.70, 1.50, 0.05

function ui.WindowScale()
    local v = db.GetWindowScale and db.GetWindowScale()
    if not v or v < SCALE_MIN then return 1 end
    if v > SCALE_MAX then return SCALE_MAX end
    return v
end

function ui.ApplyWindowScale()
    if not ui.frame or not ui.frame.SetScale then return end
    ui.frame:SetScale(ui.WindowScale())
end

-- Nudge by `delta`; nil resets to 1.0.
function ui.StepWindowScale(delta)
    local v = 1
    if delta then
        v = ui.WindowScale() + delta
        -- Round to the step so repeated nudges cannot drift off it.
        v = math.floor(v * 100 + 0.5) / 100
        if v < SCALE_MIN then v = SCALE_MIN end
        if v > SCALE_MAX then v = SCALE_MAX end
    end
    db.SaveWindowScale(v)
    ui.ApplyWindowScale()
    if ui.RefreshCourier then ui.RefreshCourier() end
    return v
end

-- Live frame height, falling back to the default before the window exists.
local function FrameH()
    if ui.frame and ui.frame.GetHeight then
        local h = ui.frame:GetHeight()
        if h and h > 0 then return h end
    end
    return WIN_H
end

local function PanelH(frameH)
    return (frameH or FrameH()) - PANEL_TOP - PANEL_BOTTOM
end

-- How many rows a list well of this height can hold. Clamped both ways: a
-- window dragged to its minimum still shows a usable page, and one dragged
-- taller than we built frames for stops at MAX_ROWS rather than indexing nil.
local function RowsForWell(wellH)
    local n = math.floor((wellH - (LIST_PAD * 2)) / ROW_H)
    if n < MIN_ROWS then n = MIN_ROWS end
    if n > MAX_ROWS then n = MAX_ROWS end
    return n
end

-- Rows currently paintable in each list, from the live height.
function ui.InboxRowCount(frameH)
    local h = PanelH(frameH)
    return RowsForWell(h - INBOX_TOP - INBOX_BOTTOM)
end

function ui.LogRowCount(frameH)
    local h = PanelH(frameH)
    return RowsForWell(h - LOG_TOP - LOG_BOTTOM)
end

function ui.LedgerRowCount(frameH)
    local h = PanelH(frameH)
    return RowsForWell(h - LEDGER_TOP - LEDGER_BOTTOM)
end

-- Live geometry. Every value is computed from the CURRENT frame height (or a
-- height you pass in, which is how the harness checks minimum and maximum
-- without actually resizing anything). A list whose `need` exceeds its `have`
-- draws outside its well.
function ui.Geometry(frameH)
    local h = frameH or FrameH()
    local panelH = PanelH(h)
    local rows = ui.InboxRowCount(h)
    return {
        rows   = rows,
        maxRows = MAX_ROWS,
        minRows = MIN_ROWS,
        need   = LIST_PAD + rows * ROW_H + LIST_PAD,
        rowH   = ROW_H,
        winH   = h,
        panelH = panelH,
        panelTop    = PANEL_TOP,
        panelBottom = PANEL_BOTTOM,
        -- Chrome the panels have to start below. Asserted rather than merely
        -- balanced: a panelTop that is self-consistent can still sit on top of
        -- the tab row, and 1.12 draws the overlap rather than clipping it.
        chromeH     = TITLE_INSET + TITLE_H + GAP + TAB_H,
        titleInset  = TITLE_INSET,
        side        = PANEL_SIDE,
        contentSide = CONTENT_SIDE,
        contentBottom = CONTENT_BOTTOM,
        footerInset = FOOTER_INSET,
        footerH     = FOOTER_H,
        footerTop   = FOOTER_INSET + FOOTER_H,
        inbox  = panelH - INBOX_TOP  - INBOX_BOTTOM,
        log    = panelH - LOG_TOP    - LOG_BOTTOM,
        ledger = panelH - LEDGER_TOP - LEDGER_BOTTOM,
        minH   = MIN_H,
        maxH   = MAX_H,
        minW   = MIN_W,
        maxW   = MAX_W,
        defaultH = WIN_H,
    }
end


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

local function WindowBackdrop(frame, bg)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 28,
        insets = { left = 10, right = 10, top = 10, bottom = 10 },
    })
    frame:SetBackdropColor(bg[1], bg[2], bg[3], 1)
    frame:SetBackdropBorderColor(1, 1, 1)
end

-- Wire a list of EditBoxes so Tab walks them in order and wraps at the end.
-- Kept as a helper so the order is declared in one readable line at the call
-- site rather than smeared across four SetScript calls.
function ui.SetTabChain(boxes)
    local n = table.getn(boxes)
    local i = 1
    while i <= n do
        local nextBox = boxes[i + 1] or boxes[1]
        -- Captured per iteration; `nextBox` is a fresh local each pass, so the
        -- closures do not all end up pointing at the last one.
        boxes[i]:SetScript("OnTabPressed", function()
            nextBox:SetFocus()
        end)
        i = i + 1
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

-- ---------------------------------------------------------------------------
-- PORTED VERBATIM FROM AEGIS: EXCHANGE (commit f84f423).
--
-- Colours, states, dimensions and behaviour are Exchange's, copied rather than
-- re-derived, so the two addons' buttons are the SAME buttons rather than two
-- interpretations of one screenshot. Only the field prefix changes
-- (aegis* -> courier*). If Exchange's BTN_KIND is ever retuned, re-port it;
-- do not hand-adjust these numbers here, or the two drift apart silently and
-- nobody notices until they are side by side.
--
-- Note the values below are NOT Courier's own C palette. C.gold/C.border/
-- C.tabOn are different numbers serving the window chrome; substituting them
-- would defeat the entire point of the port.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Buttons
--
-- We draw our own rather than inherit UIPanelButtonTemplate. The template's
-- warm red-brown plate is vanilla's own art and there is nothing wrong with
-- it -- ROADMAP 2l settled that explicitly -- but the design concept asks for
-- flat dark plates with a thin border, and no vanilla template produces that.
-- So the plate is a backdrop and we own all four visual states.
--
-- Two kinds, straight from the concept's stylesheet:
--   * "primary" -- the deep red plate with a gold label (.btn). ONE per area:
--     the thing the area exists to do (Search, Post, Full Scan).
--   * "quiet"   -- the dark neutral plate with a tan label (.btn-quiet).
--     Everything else. This is the common case, so it is the default.
--
-- What the template gave away for free and is hand-written below: the hover
-- and pressed plates, the 1px label nudge on press (a button that does not
-- move when clicked feels dead), and the disabled look. Note that a bare
-- CreateFrame("Button") DOES have working Enable/Disable/IsEnabled -- they
-- just have no appearance attached, which is exactly the trap that would ship
-- a button that stops responding while still looking clickable.
-- ---------------------------------------------------------------------------

-- Borders are DARK, not warm. The concept edges both plates with #14120f --
-- near black -- and the first pass instead used a warm brown on quiet and a
-- bright red on primary, which is what made the unskinned buttons read as
-- outlined-in-brown rather than as flat plates. Under pfUI they already
-- looked right, because pfUI supplies its own dark edge; that difference
-- between the two skins was the tell.
--
-- Not literally #14120f though. The concept's panel behind these is #3c3a36,
-- lighter than the buttons, so a near-black edge makes them pop. Our panel is
-- #211F1A -- DARKER than the plates -- so the same edge would erase the
-- outline entirely. These sit a little above it: dark enough to read as the
-- concept's crisp edge, light enough to still separate a plate from the panel.
-- WHICH REFERENCE WINS, because the two disagree and this has now flipped
-- once. `design/07-buy-tab.png` styles the primary button `#5a1414` -- deep
-- red -- and 1.14.0 took its palette from there. The later "A - Default view"
-- mockup (v1.9.0) draws Search and Buyout as a warm brown-gold plate and adds
-- a PURPLE Advanced. **The mockup is newer and it wins.** Do not re-derive
-- these from the older PNG.
local BTN_KIND = {
    primary = {
        bg     = { 0.42, 0.31, 0.13 },
        over   = { 0.52, 0.39, 0.17 },
        down   = { 0.30, 0.22, 0.09 },
        border = { 0.62, 0.49, 0.22 },
        text   = { 1.00, 0.86, 0.48 },
        font   = "GameFontNormal",
    },
    -- The Advanced button, and nothing else. It is the one control in the
    -- default strip with no counterpart in the stock auction house, and the
    -- mockup gives it its own colour to say so.
    --
    -- 1.14.0 removed a purple VERTEX TINT from this button, which is not the
    -- same thing: a tint sat on top of another plate and read as a smudge.
    -- This is a plate in its own right.
    accent = {
        bg     = { 0.36, 0.26, 0.56 },
        over   = { 0.45, 0.33, 0.68 },
        down   = { 0.26, 0.18, 0.40 },
        border = { 0.58, 0.45, 0.80 },
        text   = { 0.95, 0.92, 1.00 },
        font   = "GameFontNormal",
    },
    quiet = {
        bg     = { 0.17, 0.16, 0.15 },
        over   = { 0.27, 0.25, 0.22 },
        down   = { 0.11, 0.10, 0.09 },
        border = { 0.13, 0.12, 0.10 },
        text   = { 0.80, 0.71, 0.42 },
        font   = "GameFontNormalSmall",
    },
}

-- Disabled is DERIVED, not a fourth hand-picked row: the concept just drops
-- the opacity. Deriving it means a palette edit can never leave the disabled
-- colour behind pointing at the old plate.
local BTN_DIM_BG, BTN_DIM_TEXT = 0.55, 0.45

local function DimRGB(c, f)
    return c[1] * f, c[2] * f, c[3] * f
end

-- Repaint `b` for its current state. Reads the state off the button rather
-- than taking it as an argument so every script can just call Repaint(b).
--
-- The backdrop target is resolved HERE, every time, not cached at creation:
-- under pfUI the visible plate is pfUI's own child frame (b.backdrop), and it
-- does not exist until skin.Apply runs -- which is after the window is built.
-- Same reason TintTab resolves it late for the sub-tabs.
local function RepaintButton(b)
    local k = BTN_KIND[b.courierKind] or BTN_KIND.quiet
    local target = b
    if b.backdrop and b.backdrop.SetBackdropColor then target = b.backdrop end

    -- 1.12 returns 1/nil from IsEnabled(), not a boolean.
    local enabled = true
    if b.IsEnabled then
        local ok, v = pcall(function() return b:IsEnabled() end)
        if ok and not v then enabled = false end
    end

    local bg, br, tx = k.bg, k.border, k.text
    if enabled then
        if b.courierDown then
            bg = k.down
        elseif b.courierOver then
            bg = k.over
        end
    end

    if target.SetBackdropColor then
        if enabled then
            target:SetBackdropColor(bg[1], bg[2], bg[3], 1)
        else
            local r, g, bl = DimRGB(bg, BTN_DIM_BG)
            target:SetBackdropColor(r, g, bl, 1)
        end
    end
    if target.SetBackdropBorderColor then
        if enabled then
            target:SetBackdropBorderColor(br[1], br[2], br[3])
        else
            local r, g, bl = DimRGB(br, BTN_DIM_BG)
            target:SetBackdropBorderColor(r, g, bl)
        end
    end

    if b.label then
        -- courierTextColor overrides the kind's text colour, and it has to be
        -- read HERE rather than set once by the caller: this function runs on
        -- every hover, press and enable, so anything that colours the label
        -- from outside is wiped by the next mouseover. The Min Quality
        -- dropdown uses it to show its selection in that quality's colour.
        local tc = b.courierTextColor or tx
        if enabled then
            b.label:SetTextColor(tc[1], tc[2], tc[3])
        else
            local r, g, bl = DimRGB(tc, BTN_DIM_TEXT)
            b.label:SetTextColor(r, g, bl)
        end
        -- Press nudge. Done by moving the label ourselves rather than via
        -- SetPushedTextOffset, because that only fires for a font string
        -- registered with SetFontString and we deliberately do not depend on
        -- that call existing.
        local dy = 0
        if enabled and b.courierDown then dy = -1 end
        b.label:ClearAllPoints()
        b.label:SetPoint("CENTER", b, "CENTER", 0, dy)
    end
end

-- Change a button's kind after creation and repaint it. This replaces what
-- ui.TintButton did for the accent buttons: there are no template textures to
-- vertex-colour any more, so "make this one stand out" means "make it
-- primary".
function ui.SetButtonKind(b, kind)
    if not b or not b.courierButton then return end
    b.courierKind = BTN_KIND[kind] and kind or "quiet"
    RepaintButton(b)
end

-- Mark exactly one of a row of segmented buttons as the chosen one.
-- `match(b)` answers true for it.
--
-- SIX loops used to do this with b:LockHighlight() / b:UnlockHighlight(), and
-- every one of them was doing NOTHING. LockHighlight drives a TEMPLATE
-- highlight texture; ui.MakeButton draws its own backdrop and has no such
-- texture, so the chosen duration, sell mode, undercut mode, throttle mode,
-- history period and post duration all looked identical to their neighbours.
--
-- This is the same bug that was found and fixed for the Advanced view tabs --
-- see the note in ui.SetBuyView. It was fixed there in one place and left
-- everywhere else, which is why this is now a shared function rather than a
-- seventh copy of the loop.
function ui.MarkChosen(btns, match)
    local i = 1
    while i <= table.getn(btns or {}) do
        local b = btns[i]
        if b then
            -- The kind it had BEFORE we ever touched it. Restoring "quiet"
            -- would be a guess, and a row of accent buttons would come back
            -- wrong the first time one was deselected.
            if not b.courierBaseKind then
                b.courierBaseKind = b.courierKind or "quiet"
            end
            ui.SetButtonKind(b, match(b) and "primary" or b.courierBaseKind)
        end
        i = i + 1
    end
end

-- Build an Aegis button. Drop-in for
--     ui.MakeButton(parent, "quiet", name)
-- -- the returned frame answers SetText/GetText/Enable/Disable/IsEnabled the
-- same way, so existing call sites keep working after the constructor swap.
function ui.MakeButton(parent, kind, name)
    local b = CreateFrame("Button", name, parent)
    b.courierButton = true
    b.courierKind = BTN_KIND[kind] and kind or "quiet"
    b:SetHeight(22)
    b:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })

    -- Recorded so ui/skin.lua can rebuild this font string on pfUI's backdrop
    -- frame with the same font. SetButtonKind only ever changes colours, so
    -- the font a button is born with is the font it keeps.
    b.courierFont = (BTN_KIND[b.courierKind] or BTN_KIND.quiet).font
    local fs = b:CreateFontString(nil, "OVERLAY", b.courierFont)
    fs:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.label = fs

    -- SetText/GetText are defined on the OBJECT, shadowing the widget
    -- metatable for this frame only -- the same containment rule the tooltip
    -- hook follows. Nothing else that draws a Button is affected.
    b.SetText = function(self, t)
        self.courierText = t or ""
        self.label:SetText(self.courierText)
    end
    b.GetText = function(self) return self.courierText or "" end
    -- Real 1.12 returns the font string REGISTERED with SetFontString, which
    -- for a template-less button is nil. Two callers measure a button's label
    -- through this to clip it (both dropdowns), and nil would error there, so
    -- answer it properly rather than leaving a hole for the sweep to fall in.
    b.GetFontString = function(self) return self.label end

    -- Enable/Disable exist and work already; they just have no look. Wrap
    -- them so the plate follows the state.
    local origEnable, origDisable = b.Enable, b.Disable
    b.Enable = function(self)
        if origEnable then origEnable(self) end
        RepaintButton(self)
    end
    b.Disable = function(self)
        if origDisable then origDisable(self) end
        self.courierDown = false
        self.courierOver = false
        RepaintButton(self)
    end

    -- These close over `b` rather than reading the global `this`. `this` is
    -- the right mechanism for a handler SHARED across frames, but each button
    -- already has itself in scope, and depending on the global means the
    -- script only works when the CLIENT is the one invoking it. It is not:
    -- the Filter Builder hides its action buttons from Lua the moment it
    -- builds them, which fires OnHide with no `this` set.
    b:SetScript("OnEnter", function()
        b.courierOver = true
        RepaintButton(b)
    end)
    -- A press that drags off the button never sends it an OnMouseUp, so the
    -- pressed plate would stick until the next hover. OnLeave clears BOTH
    -- flags for that reason, not just the hover one.
    b:SetScript("OnLeave", function()
        b.courierOver = false
        b.courierDown = false
        RepaintButton(b)
    end)
    b:SetScript("OnMouseDown", function()
        b.courierDown = true
        RepaintButton(b)
    end)
    b:SetScript("OnMouseUp", function()
        b.courierDown = false
        RepaintButton(b)
    end)
    -- Hiding mid-press leaves the same stuck plate waiting for the reshow.
    b:SetScript("OnHide", function()
        b.courierDown = false
        b.courierOver = false
        RepaintButton(b)
    end)

    b:SetText("")
    RepaintButton(b)
    return b
end

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
    -- Label, not key. The button still answers to `name` everywhere else.
    fs:SetText(SubTabLabel(name))
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
    WindowBackdrop(f, C.panelBG)
    f:Hide()

    -- Scale FIRST and unconditionally: it is stored independently of the size,
    -- so someone who scaled the window but never dragged it bigger has no saved
    -- width to restore -- and an early return below would lose their scale on
    -- every login.
    ui.ApplyWindowScale()

    -- Restore the saved size, clamped: the stored value predates any change to
    -- MIN/MAX and a window smaller than its own contents is not recoverable
    -- from in-game.
    local sw, sh = db.GetWindowSize()
    if sw and sh then
        if sw < MIN_W then sw = MIN_W end
        if sh < MIN_H then sh = MIN_H end
        if sw > MAX_W then sw = MAX_W end
        if sh > MAX_H then sh = MAX_H end
        f:SetWidth(sw)
        f:SetHeight(sh)
    end

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
    -- TITLE_INSET, not 4: the dialog border is 28px of art with 10px insets,
    -- so a title bar tucked into the corner would sit underneath it.
    title:SetPoint("TOPLEFT", f, "TOPLEFT", TITLE_INSET, -TITLE_INSET)
    title:SetPoint("TOPRIGHT", f, "TOPRIGHT", -TITLE_INSET - 2, -TITLE_INSET)
    Backdrop(title, C.titleBG, false)
    ui.titleBar = title

    local titleText = Label(title, "GameFontNormalLarge", C.gold)
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
    local blizBtn = ui.MakeButton(title, "quiet", "AegisCourierBlizzButton")
    blizBtn:SetWidth(84)
    blizBtn:SetHeight(19)
    blizBtn:SetPoint("RIGHT", close, "LEFT", -4, 0)
    blizBtn:SetText("Blizzard UI")
    blizBtn:SetScript("OnClick", function() ui.ShowBlizzardMail() end)
    ui.blizBtn = blizBtn

    -- ---- resize grip ----------------------------------------------------
    -- Everything inside anchors to its panel's edges, so widening or
    -- heightening the frame carries the panels and their scroll frames along
    -- for free. The one thing that does NOT follow on its own is how many rows
    -- each list draws -- ui.InboxRowCount and friends recompute that from the
    -- live height, so dragging taller genuinely shows more mail rather than
    -- leaving a blank gap.
    f:SetResizable(true)
    if f.SetMinResize then f:SetMinResize(MIN_W, MIN_H) end
    if f.SetMaxResize then f:SetMaxResize(MAX_W, MAX_H) end

    -- On the OUTER border, not inside the content well: a grip tucked into the
    -- recessed area reads as part of the content rather than as a handle.
    local grip = CreateFrame("Button", "AegisCourierResizeGrip", f)
    grip:SetWidth(14)
    grip:SetHeight(14)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel(f:GetFrameLevel() + 12)
    -- The pfUI skin replaces a button's textures with a flat backdrop, which on
    -- an icon button erases the icon -- the same fault that made the recipient
    -- dropdown render as an empty box in v1.1.0.
    grip.courierNoSkin = true
    local gripTex = grip:CreateTexture(nil, "OVERLAY")
    gripTex:SetAllPoints(grip)
    gripTex:SetTexture("Interface\\AddOns\\Aegis_Courier\\media\\ResizeGrip")
    grip.tex = gripTex
    grip:SetScript("OnMouseDown", function()
        ui.sizing = true
        f:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        ui.sizing = false
        f:StopMovingOrSizing()
        db.SaveWindowSize(f:GetWidth(), f:GetHeight())
        ui.Refresh()
    end)
    -- DELIBERATELY NO PER-FRAME REPAINT WHILE DRAGGING. Repainting mid-drag
    -- calls FauxScrollFrame_Update with a row count that changes every frame,
    -- which moves the scrollbar's range, which fires OnVerticalScroll, which
    -- calls the update function again. That is precisely the mutual recursion
    -- that killed the client at 11+ mails in v1.0.4 -- it only terminates
    -- because the range normally holds still, and while resizing it does not.
    -- The lists re-fit once, on release.
    grip:SetScript("OnEnter", function() gripTex:SetVertexColor(1, 0.9, 0.4) end)
    grip:SetScript("OnLeave", function() gripTex:SetVertexColor(1, 1, 1) end)
    ui.resizeGrip = grip

    -- ---- content well ---------------------------------------------------
    -- The recessed plate every panel sits on, matching Exchange's ui.content.
    -- Without it the panels float directly on the window background and the
    -- two addons read differently even with the same outer frame.
    local content = CreateFrame("Frame", "AegisCourierContent", f)
    content:SetPoint("TOPLEFT", f, "TOPLEFT", CONTENT_SIDE, -CONTENT_TOP)
    content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT",
        -CONTENT_SIDE, CONTENT_BOTTOM)
    Backdrop(content, C.well, true)
    ui.content = content

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
            b:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -GAP)
        end
        ui.subTabs[name] = b
        prev = b

        local panel = CreateFrame("Frame", "AegisCourierPanel" .. name, content)
        panel:SetPoint("TOPLEFT", content, "TOPLEFT", PANEL_PAD, -PANEL_PAD)
        panel:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT",
            -PANEL_PAD, PANEL_PAD)
        panel:Hide()
        ui.panels[name] = panel

        i = i + 1
    end

    -- ---- footer ---------------------------------------------------------
    local footer = Label(f, "GameFontNormalSmall", C.dim)
    footer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PANEL_SIDE + 4, FOOTER_INSET)
    ui.footer = footer

    ui.BuildInboxPanel()
    ui.BuildSendPanel()
    ui.BuildSentPanel()
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

    -- `kind` follows Exchange's rule: ONE primary per area -- the thing the
    -- area exists to do -- and quiet for everything else.
    local function ActionButton(name, label, width, onClick, kind)
        local b = ui.MakeButton(panel, kind or "quiet",
            "AegisCourierBtn" .. name)
        b:SetWidth(width)
        b:SetHeight(21)
        b:SetText(label)
        b:SetScript("OnClick", onClick)
        return b
    end

    -- The Inbox's one primary: emptying the mailbox is what the tab is for.
    local openAll = ActionButton("OpenAll", "Open All", 76, function()
        take.Start(take.MODE_OPEN)
    end, "primary")
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
    while i <= MAX_ROWS do
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
        local ret = ui.MakeButton(row, "quiet",
            "AegisCourierInboxReturn" .. i)
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
        "back unopened. COD is only ever paid from the reader, by hand.")
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

    local back = ui.MakeButton(r, "accent", "AegisCourierReaderBack")
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
    -- Quiet, not primary, despite being the panel's obvious verb: Take can be
    -- visible at the same time on a loaded mail, and two primaries side by side
    -- reads as two competing calls to action. Take is the consequential one.
    local reveal = ui.MakeButton(r, "quiet", "AegisCourierReaderReveal")
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

    local takeBtn = ui.MakeButton(r, "primary", "AegisCourierReaderTake")
    takeBtn:SetWidth(70)
    takeBtn:SetHeight(20)
    takeBtn:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 2, 2)
    takeBtn:SetText("Take")
    takeBtn:SetScript("OnClick", function()
        if not ui.readerIndex then return end
        A.take.Single(ui.readerIndex)
    end)
    ui.readerTake = takeBtn

    -- COD mail. Never shown at the same time as Take -- Take is refused for
    -- COD everywhere -- so it occupies the same corner.
    --
    -- Two-step on purpose: paying a COD is unrecoverable, so the first click
    -- only ARMS the button and relabels it, and a second, deliberate click
    -- commits. ui.readerPayArmed holds the index it was armed for, so
    -- navigating anywhere at all disarms it rather than leaving a live
    -- one-click payment sitting under the cursor.
    local payBtn = ui.MakeButton(r, "accent", "AegisCourierReaderPay")
    payBtn:SetWidth(132)
    payBtn:SetHeight(20)
    payBtn:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 2, 2)
    payBtn:SetText("Pay COD")
    payBtn:SetScript("OnClick", function()
        local idx = ui.readerIndex
        if not idx then return end
        if ui.readerPayArmed == idx then
            ui.readerPayArmed = nil
            A.take.PayCOD(idx)
        else
            ui.readerPayArmed = idx
        end
        ui.RefreshInbox()
    end)
    ui.readerPay = payBtn

    local retBtn = ui.MakeButton(r, "quiet", "AegisCourierReaderReturn")
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
    ui.readerPayArmed = nil
    ui.RefreshInbox()
    return true
end

function ui.CloseReader()
    ui.readerIndex = nil
    ui.readerSig = nil
    ui.readerWantBody = nil
    ui.readerPayArmed = nil
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
    -- so the button is not offered rather than offered and rejected. COD mail
    -- gets the Pay button in its place instead -- see below.
    local canTake = (h.money > 0 or h.hasItem) and h.cod == 0 and not h.isGM
        and not A.take.running
    if canTake then ui.readerTake:Show() else ui.readerTake:Hide() end

    -- The COD button. "busy" only means a run is in progress -- the mail is
    -- still a payable COD -- so the button hides for the run rather than
    -- appearing broken.
    local isPayable = h.cod > 0 and not h.isGM and not A.take.running
    -- Asked of the engine rather than derived here: the affordability rule
    -- belongs to take.PayCOD, and a button that re-derives the condition it
    -- gates on is how a button and the thing it triggers drift apart. Only
    -- asked for COD mail -- it costs a header read, and every other mail
    -- already knows the answer.
    local canPay, payWhy = false, nil
    if isPayable then canPay, payWhy = A.take.CanPayCOD(idx) end

    if isPayable then
        ui.readerPay:Show()
        if ui.readerPayArmed == idx and canPay then
            ui.readerPay:SetText("Confirm " .. util.FormatMoney(h.cod, false))
        else
            ui.readerPay:SetText("Pay " .. util.FormatMoney(h.cod, false))
        end
        if canPay then ui.readerPay:Enable() else ui.readerPay:Disable() end
    else
        ui.readerPay:Hide()
        ui.readerPayArmed = nil
    end

    -- Whichever button is actually occupying the bottom-left corner. Pay is
    -- nearly twice Take's width, so anything trailing it has to follow the
    -- live one rather than a fixed anchor -- a hidden frame keeps its last
    -- position, and trailing THAT puts the status text through the button.
    local corner = isPayable and ui.readerPay or ui.readerTake

    if h.canReply and not h.isGM and not A.take.running then
        ui.readerReturn:Show()
        ui.readerReturn:ClearAllPoints()
        ui.readerReturn:SetPoint("LEFT", corner, "RIGHT", 6, 0)
        corner = ui.readerReturn
    else
        ui.readerReturn:Hide()
    end

    ui.readerStatus:ClearAllPoints()
    ui.readerStatus:SetPoint("LEFT", corner, "RIGHT", 10, 0)

    if h.cod > 0 then
        if not canPay and payWhy and payWhy ~= "busy" then
            ui.readerStatus:SetText("|cffd05050" .. payWhy .. ".|r")
        elseif ui.readerPayArmed == idx then
            ui.readerStatus:SetText("|cffd05050Click again to pay. " ..
                "This cannot be undone.|r")
        else
            ui.readerStatus:SetText("COD is never paid automatically \226\128\148 " ..
                "only by this button.")
        end
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
    while i <= MAX_ROWS do
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

    -- How many rows actually fit RIGHT NOW. Frames exist up to MAX_ROWS; the
    -- ones past `rows` are hidden rather than destroyed, because CreateFrame
    -- during a resize is not viable.
    local rows = ui.InboxRowCount()

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

    FauxScrollFrame_Update(ui.inboxScroll, total, rows, ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.inboxScroll) or 0

    local i = 1
    while i <= MAX_ROWS do
        local row = ui.inboxRows[i]
        local h = nil
        if i <= rows then h = mails[offset + i] end
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

-- A gold / silver / copper money input, matching Aegis: Exchange's.
--
-- TWO 1.12 GOTCHAS, both learned the hard way in Exchange and carried over
-- rather than rediscovered:
--
--   1. There are NO per-denomination icon files on this client. There is ONE
--      sprite sheet -- Interface\\MoneyFrame\\UI-MoneyIcons -- holding gold,
--      silver and copper side by side, and you pick one with SetTexCoord.
--      "UI-GoldIcon", which is how later clients do it, resolves to nothing
--      at all, so the coins render INVISIBLE rather than wrong.
--   2. Blank LEADING zeros only. Exchange shipped a version where gold blanked
--      its zero and silver did not, so 11 copper drew as [ ][0][11] -- an empty
--      box beside a zero reads as a missing value rather than "no silver".
--
-- The group exposes GetText/SetText returning and parsing a money STRING, so
-- it drops straight into the places that previously held one edit box.
local function MakeMoneyGSC(name, parent, onChange)
    local grp = {}
    local COIN_U = { gold = 0, silver = 0.25, copper = 0.5 }

    local function mk(suffix, w, coin)
        local e = CreateFrame("EditBox", "AegisCourierEdit" .. name .. suffix,
            parent, "InputBoxTemplate")
        e:SetWidth(w)
        e:SetHeight(18)
        e:SetAutoFocus(false)
        e:SetNumeric(true)
        e:SetJustifyH("RIGHT")
        e:SetFontObject("GameFontHighlightSmall")
        e:SetScript("OnEnterPressed", function() e:ClearFocus() end)
        e:SetScript("OnEscapePressed", function() e:ClearFocus() end)
        e:SetScript("OnTextChanged", function()
            if grp.quiet then return end     -- our own SetText, not the user
            if onChange then onChange() end
        end)
        local tag = parent:CreateTexture(nil, "OVERLAY")
        tag:SetTexture("Interface\\MoneyFrame\\UI-MoneyIcons")
        local u = COIN_U[coin] or 0
        tag:SetTexCoord(u, u + 0.25, 0, 1)
        tag:SetWidth(13)
        tag:SetHeight(13)
        tag:SetPoint("LEFT", e, "RIGHT", 2, 0)
        e.tag = tag
        e.coin = coin
        return e
    end

    grp.g = mk("Gold", 34, "gold")
    grp.s = mk("Silver", 22, "silver")
    grp.c = mk("Copper", 22, "copper")

    grp.GetText = function(self)
        local gg = tonumber(self.g:GetText()) or 0
        local ss = tonumber(self.s:GetText()) or 0
        local cc = tonumber(self.c:GetText()) or 0
        local total = gg * 10000 + ss * 100 + cc
        if total <= 0 then return "" end
        return util.FormatMoney(total, false)
    end

    grp.SetText = function(self, txt)
        local copper = nil
        if txt and txt ~= "" then copper = util.ParseMoney(txt) end
        self.quiet = true
        if not copper or copper <= 0 then
            self.g:SetText(""); self.s:SetText(""); self.c:SetText("")
        else
            local gg, ss, cc = util.MoneyParts(copper)
            -- Leading zeros blank, trailing ones shown -- see gotcha 2.
            self.g:SetText(gg > 0 and tostring(gg) or "")
            self.s:SetText((gg > 0 or ss > 0) and tostring(ss) or "")
            self.c:SetText(tostring(cc))
        end
        self.quiet = false
    end

    return grp
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

    -- Three boxes with coin icons, matching Exchange, rather than one box you
    -- type "12g 30s" into. The group answers GetText/SetText the same way the
    -- single box did, so ui.SendMoneyValue and ClearSendForm are unchanged.
    local money = MakeMoneyGSC("Money", panel, function() ui.RefreshSend() end)
    money.g:SetPoint("LEFT", moneyLbl, "RIGHT", 10, 0)
    money.s:SetPoint("LEFT", money.g, "RIGHT", 18, 0)
    money.c:SetPoint("LEFT", money.s, "RIGHT", 18, 0)
    ui.sendMoney = money

    -- ---- Tab moves to the next field ------------------------------------
    -- The stock mail form chains its own Name/Subject/Body boxes this way and
    -- players expect it. There is no Tab-order property on a 1.12 EditBox --
    -- OnTabPressed plus an explicit SetFocus IS the mechanism.
    --
    -- Order is the form's visual order, top to bottom. The attachment slots
    -- sit between Body and Gold but are icon buttons, not text fields, so they
    -- are not in the chain.
    --
    -- Gold WRAPS back to To rather than dropping focus: the form is short and
    -- cyclable, and a Tab that silently does nothing reads as a broken key.
    -- Note the multiline body is included -- handling OnTabPressed is also
    -- what stops Tab inserting a literal tab character into the message.
    -- The money group is THREE boxes, so the chain threads all of them rather
    -- than treating it as one field.
    ui.SetTabChain({ toBox, subjBox, bodyBox, money.g, money.s, money.c })

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

    local sendBtn = ui.MakeButton(panel, "primary", "AegisCourierBtnSend")
    sendBtn:SetWidth(80)
    sendBtn:SetHeight(22)
    sendBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -6, 4)
    sendBtn:SetText("Send")
    sendBtn:SetScript("OnClick", function() ui.DoSend() end)
    ui.btnSend = sendBtn

    local clearBtn = ui.MakeButton(panel, "quiet", "AegisCourierBtnClearSend")
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
    -- RECEIVED ONLY. Sent mail has its own tab, with a reader -- keeping a
    -- second, poorer view of it here would mean two places to look and two
    -- answers to the same question.
    ui.logDir = "received"

    local heading = Label(panel, "GameFontNormalSmall", C.gold)
    heading:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -6)
    heading:SetText("Mail you collected")

    local findLbl = Label(panel, "GameFontNormalSmall", C.goldDim)
    findLbl:SetPoint("LEFT", heading, "RIGHT", 20, 0)
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
    while i <= MAX_ROWS do
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

    local clear = ui.MakeButton(panel, "quiet", "AegisCourierBtnClearLog")
    clear:SetWidth(90)
    clear:SetHeight(20)
    clear:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 2)
    clear:SetText("Clear view")
    clear:SetScript("OnClick", function()
        -- Received only. The sent box is cleared from its own tab, so neither
        -- Clear button can wipe something the user is not looking at.
        db.ClearLog("received")
        ui.RefreshLog()
    end)
end

-- Entries for the current direction, newest first, after filtering.
-- Flatten a sent-box batch into the same shape the row renderer already
-- expects, so one paint path serves both directions.
--
-- A batch is one row, not one row per mail: mailing 12 items to a bank alt is
-- 12 mails on the server, and listing them individually is what made the old
-- sent log useless for exactly the case people care about.
function ui.SentRow(rec)
    local n = table.getn(rec.items or {})
    -- Name the items outright while they fit; past that, lead with the first
    -- and count the rest. "12 items" alone tells you nothing you wanted.
    local label = ""
    local allNames = ""
    local ai = 1
    while ai <= n do
        allNames = allNames .. " " .. (rec.items[ai].n or "")
        ai = ai + 1
    end
    local i = 1
    while i <= n and i <= 3 do
        if i > 1 then label = label .. ", " end
        label = label .. rec.items[i].n
        if rec.items[i].c and rec.items[i].c > 1 then
            label = label .. " x" .. rec.items[i].c
        end
        i = i + 1
    end
    if n > 3 then label = label .. " +" .. (n - 3) .. " more" end

    return {
        t       = rec.t,
        who     = rec.to,
        subject = rec.s,
        char    = rec.char,
        money   = rec.money,
        cod     = rec.cod,
        -- Carried as `item` because that is the field the row renderer tints
        -- and appends; the sent box's own list stays untouched.
        item    = (label ~= "" and label) or nil,
        mails   = rec.mails,
        -- Every item name, for the find box only. The visible label is
        -- truncated to fit the row, but SEARCH must not be: a bank-alt send is
        -- exactly where the item you are looking for sits ninth in the list,
        -- and "did I mail that?" is the whole reason to open a sent box.
        searchExtra = allNames,
    }
end

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
                .. " " .. (e.char or "") .. " " .. (e.searchExtra or ""))
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

    local visible = ui.LogRowCount()
    local rows = ui.LogRows()
    local total = table.getn(rows)

    FauxScrollFrame_Update(ui.logScroll, total, visible, ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.logScroll) or 0
    local now = time()

    local i = 1
    while i <= MAX_ROWS do
        local row = ui.logRows[i]
        local e = nil
        if i <= visible then e = rows[offset + i] end
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
            -- A batch says how many mails it actually cost, because postage is
            -- per mail and "one send" is not one mail on this client.
            if e.mails and e.mails > 1 then
                subject = subject .. " |cff8c8573(" .. e.mails .. " mails)|r"
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
    local label = "received"
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

-- ---------------------------------------------------------------------------
-- Sent panel
-- ---------------------------------------------------------------------------
-- A record view, NOT a mail view, and the distinction is the whole design.
--
-- Once a mail is sent it is gone from the client. Vanilla has no sent-items
-- store and no API to read a mail you sent -- GetInboxHeaderInfo and
-- GetInboxText only ever see YOUR INBOX. So nothing here queries anything: it
-- replays what Courier wrote down at send time, and whatever was not captured
-- then is gone for good. That is why send.lastSent carries the item texture
-- and db.SentBegin stores the body.
--
-- It follows that there is no Take and no Return. The mail is on its way to
-- someone else; there is nothing to act on. The one useful action is to write
-- to the same person again, which is what the Compose button does.

-- The Sent reader's vertical budget, reported so the harness can assert the
-- blocks actually fit. 1.12 does not clip children -- an overflowing block
-- just draws over whatever is beneath it -- which is the same trap the Inbox
-- list hit in v1.1.0, and the reason this is asserted rather than eyeballed.
-- The message well's height at a given window height: it grows with the
-- window up to SENT_BODY_MAX and then stops, because past that it is empty
-- space rather than more message.
local function SentBodyH(readerH)
    local avail = readerH - SENT_BODY_TOP - SENT_FOOT_H
    if avail > SENT_BODY_MAX then return SENT_BODY_MAX end
    return avail
end

function ui.SentGeometry(frameH)
    local readerH = PanelH(frameH) - LOG_TOP - LOG_BOTTOM - (LIST_PAD * 2)
    return {
        readerH = readerH,
        head    = SENT_HEAD_H,
        items   = SENT_ITEMS_H,
        gap     = SENT_GAP,
        foot    = SENT_FOOT_H,
        bodyTop = SENT_BODY_TOP,
        bodyH   = SentBodyH(readerH),
        bodyMin = SENT_BODY_MIN,
        bodyMax = SENT_BODY_MAX,
        cols    = SENT_ITEM_COLS,
        rows    = SENT_ITEM_ROWS,
        slots   = SENT_ITEM_COLS * SENT_ITEM_ROWS,
    }
end

function ui.BuildSentPanel()
    local panel = ui.panels["Sent"]

    local heading = Label(panel, "GameFontNormalSmall", C.gold)
    heading:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -6)
    heading:SetText("Mail you sent")

    local findLbl = Label(panel, "GameFontNormalSmall", C.goldDim)
    findLbl:SetPoint("LEFT", heading, "RIGHT", 20, 0)
    findLbl:SetText("Find")

    local findBox = MakeEditBox("SentFind", panel, 130)
    findBox:SetPoint("LEFT", findLbl, "RIGHT", 8, 0)
    findBox:SetScript("OnTextChanged", function() ui.RefreshSent() end)
    ui.sentFind = findBox

    local mine = MakeToggle(panel, "SentMine", "this character only")
    mine:SetPoint("LEFT", findBox, "RIGHT", 14, 0)
    mine:SetScript("OnClick", function() ui.RefreshSent() end)
    ui.sentMine = mine

    local well = CreateFrame("Frame", nil, panel)
    well:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -LOG_TOP)
    well:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, LOG_BOTTOM)
    Backdrop(well, C.well, true)
    ui.sentWell = well

    local scroll = CreateFrame("ScrollFrame", "AegisCourierSentScroll", well,
        "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", well, "TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -26, 4)
    -- Two args on 1.12; frame and offset arrive as the `this` / `arg1` globals.
    scroll:SetScript("OnVerticalScroll", function()
        FauxScrollFrame_OnVerticalScroll(ROW_H, ui.RefreshSent)
    end)
    ui.sentScroll = scroll

    ui.sentRows = {}
    local i = 1
    while i <= MAX_ROWS do
        local row = CreateFrame("Button", "AegisCourierSentRow" .. i, well)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", well, "TOPLEFT", 6, -LIST_PAD - (i - 1) * ROW_H)
        row:SetPoint("TOPRIGHT", well, "TOPRIGHT", -26, -LIST_PAD - (i - 1) * ROW_H)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.courierNoSkin = true
        row:SetScript("OnClick", function()
            if row.recIndex then ui.OpenSentRecord(row.recIndex) end
        end)

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
        ui.sentRows[i] = row
        i = i + 1
    end

    local summary = Label(panel, "GameFontNormalSmall", C.dim)
    summary:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 4, 6)
    ui.sentSummary = summary

    local clear = ui.MakeButton(panel, "quiet", "AegisCourierBtnClearSent")
    clear:SetWidth(90)
    clear:SetHeight(20)
    clear:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 2)
    clear:SetText("Clear view")
    clear:SetScript("OnClick", function()
        db.ClearSentBox()
        ui.CloseSentRecord()
    end)
    ui.btnClearSent = clear

    ui.BuildSentReader(well)
end

-- The reader, filling the same well as the list and swapping with it -- the
-- pattern the Inbox reader uses, for the same reason: one panel, one place to
-- look, nothing extra to keep positioned and skinned.
function ui.BuildSentReader(well)
    local r = CreateFrame("Frame", "AegisCourierSentReader", well)
    r:SetPoint("TOPLEFT", well, "TOPLEFT", LIST_PAD, -LIST_PAD)
    r:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -LIST_PAD, LIST_PAD)
    r:Hide()
    ui.sentReader = r

    local back = ui.MakeButton(r, "accent", "AegisCourierSentBack")
    back:SetWidth(60)
    back:SetHeight(19)
    back:SetPoint("TOPLEFT", r, "TOPLEFT", 2, -2)
    back:SetText("Back")
    back:SetScript("OnClick", function() ui.CloseSentRecord() end)
    ui.sentBack = back

    local to = Label(r, "GameFontNormal", C.gold)
    to:SetPoint("LEFT", back, "RIGHT", 8, 0)
    ui.sentTo = to

    local when = Label(r, "GameFontNormalSmall", C.dim)
    when:SetPoint("TOPRIGHT", r, "TOPRIGHT", -4, -6)
    ui.sentWhen = when

    local subject = Label(r, "GameFontNormal", C.text)
    subject:SetPoint("TOPLEFT", r, "TOPLEFT", 4, -26)
    ui.sentSubject = subject

    local meta = Label(r, "GameFontNormalSmall", C.dim)
    meta:SetPoint("TOPLEFT", r, "TOPLEFT", 4, -44)
    ui.sentMeta = meta

    -- Item count rides the meta line now; this label is gone as a separate row.
    ui.sentItemsHead = meta

    -- Filled column-major so reading down a column is reading the batch in
    -- order, the way the attachment grid on the Compose tab is laid out.
    local colW = math.floor((WIN_W - (PANEL_SIDE * 2) - 40) / SENT_ITEM_COLS)
    ui.sentItemRows = {}
    local n = 1
    while n <= SENT_ITEM_ROWS * SENT_ITEM_COLS do
        local col = math.floor((n - 1) / SENT_ITEM_ROWS)
        local rowIdx = n - (col * SENT_ITEM_ROWS)
        local f = CreateFrame("Frame", nil, r)
        f:SetHeight(SENT_ITEM_H)
        f:SetWidth(colW - 6)
        f:SetPoint("TOPLEFT", r, "TOPLEFT", 6 + col * colW,
            -SENT_HEAD_H - (rowIdx - 1) * SENT_ITEM_H)

        local icon = f:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(14)
        icon:SetHeight(14)
        icon:SetPoint("LEFT", f, "LEFT", 0, 0)
        f.icon = icon

        local label = Label(f, "GameFontNormalSmall", C.text)
        label:SetPoint("LEFT", f, "LEFT", 18, 0)
        f.label = label

        f:Hide()
        ui.sentItemRows[n] = f
        n = n + 1
    end

    -- Anchored by its TOP edge with an explicit height, not stretched between
    -- top and bottom: the height is capped (see SENT_BODY_MAX), so it cannot
    -- simply follow the reader's bottom edge. ui.RefitSentReader sets it.
    local bodyWell = CreateFrame("Frame", nil, r)
    bodyWell:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -SENT_BODY_TOP)
    bodyWell:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, -SENT_BODY_TOP)
    bodyWell:SetHeight(SENT_BODY_MAX)
    Backdrop(bodyWell, C.well, true)
    ui.sentBodyWell = bodyWell

    local bodyScroll = CreateFrame("ScrollFrame", "AegisCourierSentBodyScroll",
        bodyWell, "UIPanelScrollFrameTemplate")
    bodyScroll:SetPoint("TOPLEFT", bodyWell, "TOPLEFT", 6, -6)
    bodyScroll:SetPoint("BOTTOMRIGHT", bodyWell, "BOTTOMRIGHT", -26, 6)
    local child = CreateFrame("Frame", nil, bodyScroll)
    child:SetWidth(WIN_W - 90)
    child:SetHeight(1)
    bodyScroll:SetScrollChild(child)

    local body = Label(child, "GameFontHighlightSmall", C.text)
    body:SetPoint("TOPLEFT", child, "TOPLEFT", 0, 0)
    body:SetWidth(WIN_W - 96)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    ui.sentBody = body

    local compose = ui.MakeButton(r, "primary", "AegisCourierSentCompose")
    compose:SetWidth(150)
    compose:SetHeight(20)
    compose:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 2, 2)
    compose:SetText("Compose")
    compose:SetScript("OnClick", function()
        local rec = ui.SentRecord()
        if not rec then return end
        ui.SelectSubTab("Send")
        if ui.sendTo then
            ui.sendTo:SetText(rec.to or "")
            ui.RefreshSend()
        end
    end)
    ui.sentCompose = compose
end

-- The record currently open, or nil. Held by INDEX into the box, so a prune or
-- a new send between paints cannot leave the reader showing a stale table --
-- the index is re-read and re-validated on every refresh.
function ui.SentRecord()
    if not ui.sentIndex then return nil end
    local box = db.SentBox()
    local rec = box[ui.sentIndex]
    if not rec then return nil end
    -- Identity, not position. A prune or a new send can move a record under a
    -- held index, and `t` alone would not catch it -- see db.SentBegin.
    if ui.sentStamp and rec.id ~= ui.sentStamp then return nil end
    return rec
end

function ui.OpenSentRecord(index)
    local box = db.SentBox()
    local rec = box[index]
    if not rec then return false end
    ui.sentIndex = index
    -- Remembered so a record shifting under the index (a prune, or the box
    -- being cleared) is detected rather than silently rendered as a different
    -- send.
    ui.sentStamp = rec.id
    ui.RefreshSent()
    return true
end

function ui.CloseSentRecord()
    ui.sentIndex = nil
    ui.sentStamp = nil
    ui.RefreshSent()
end

function ui.SentReaderOpen()
    return ui.SentRecord() ~= nil
end

-- Rows for the Sent list, newest first, with the same filters the Log offers.
function ui.SentRows()
    local out = {}
    local box = db.SentBox()
    local find = string.lower(util.Trim(ui.sentFind:GetText() or ""))
    local mineOnly = ui.sentMine:GetChecked() and true or false
    local me = UnitName and UnitName("player") or nil

    local i = table.getn(box)
    while i >= 1 do
        local rec = box[i]
        local keep = true
        if mineOnly and me and rec.char and rec.char ~= me then keep = false end
        if keep and find ~= "" then
            local row = ui.SentRow(rec)
            -- searchExtra carries EVERY item name; the visible label is
            -- truncated to fit the row and must not narrow the search.
            local hay = string.lower((rec.to or "") .. " " .. (rec.s or "")
                .. " " .. (rec.char or "") .. " " .. (row.searchExtra or "")
                .. " " .. (rec.body or ""))
            if not util.Contains(hay, find) then keep = false end
        end
        -- The list index is the BOX index, so a click can find the record
        -- again without carrying the table itself around.
        if keep then table.insert(out, { rec = rec, index = i }) end
        i = i - 1
    end
    return out
end

function ui.RefreshSent()
    if not ui.frame or not ui.frame:IsVisible() then return end
    if ui.selectedSubTab ~= "Sent" then return end
    -- Same FrameXML recursion chain the other lists guard against.
    if ui.sentRefreshing then return end
    ui.sentRefreshing = true

    if ui.sentIndex then
        if ui.RefreshSentReader() then
            local h = 1
            while h <= MAX_ROWS do ui.sentRows[h]:Hide() h = h + 1 end
            ui.sentScroll:Hide()
            ui.sentReader:Show()
            ui.sentSummary:SetText("")
            ui.sentRefreshing = false
            return
        end
        -- The record went away under us. Fall through to the list.
        ui.sentIndex = nil
        ui.sentStamp = nil
    end
    ui.sentReader:Hide()
    ui.sentScroll:Show()

    local visible = ui.LogRowCount()   -- Sent shares the Log panel's insets
    local rows = ui.SentRows()
    local total = table.getn(rows)

    FauxScrollFrame_Update(ui.sentScroll, total, visible, ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.sentScroll) or 0
    local now = time()

    local i = 1
    while i <= MAX_ROWS do
        local row = ui.sentRows[i]
        local entry = nil
        if i <= visible then entry = rows[offset + i] end
        if entry then
            local rec = entry.rec
            local flat = ui.SentRow(rec)
            row.when:SetText(util.FormatAgo(now - (rec.t or now)))
            SetClipped(row.who, rec.to or "?", 108)

            local subject = rec.s or ""
            if subject == "" then subject = "|cff8c8573(no subject)|r" end
            if flat.item then
                subject = subject .. "  |cff8fd6a8" .. flat.item .. "|r"
            end
            if rec.mails and rec.mails > 1 then
                subject = subject .. " |cff8c8573(" .. rec.mails .. " mails)|r"
            end
            SetClipped(row.subject, subject, 250)

            if rec.cod and rec.cod > 0 then
                row.amount:SetText("|cffd05050COD " ..
                    util.FormatMoney(rec.cod, false) .. "|r")
            elseif rec.money and rec.money > 0 then
                row.amount:SetText("-" .. util.FormatMoney(rec.money, true))
            else
                row.amount:SetText("")
            end
            row.recIndex = entry.index
            row:Show()
        else
            row.recIndex = nil
            row:Hide()
        end
        i = i + 1
    end

    local stored = table.getn(db.SentBox())
    if stored == 0 then
        ui.sentSummary:SetText("Nothing sent yet. Mail you send is recorded " ..
            "here for " .. db.SENT_DAYS .. " days.")
    elseif total == stored then
        ui.sentSummary:SetText(stored .. (stored == 1 and " send" or " sends"))
    else
        ui.sentSummary:SetText(total .. " of " .. stored .. " sends")
    end

    ui.sentRefreshing = false
end

-- Paint the open record. Returns false when it is no longer there, so the
-- caller drops back to the list instead of showing the wrong send.
-- Re-fit the message well to the current window height. Called from the
-- reader's paint and after a resize; cheap enough to do on both.
function ui.RefitSentReader()
    if not ui.sentBodyWell then return end
    ui.sentBodyWell:SetHeight(ui.SentGeometry().bodyH)
end

function ui.RefreshSentReader()
    local rec = ui.SentRecord()
    if not rec then return false end
    ui.RefitSentReader()

    ui.sentTo:SetText(rec.to or "?")
    ui.sentWhen:SetText(util.FormatAgo(time() - (rec.t or time())))
    local subject = rec.s or ""
    if subject == "" then subject = "|cff8c8573(no subject)|r" end
    ui.sentSubject:SetText(subject)

    -- Postage is per mail on this client, so the mail count is real
    -- information rather than trivia: it is what the send actually cost.
    local meta = (rec.mails or 0) .. ((rec.mails == 1) and " mail" or " mails")
    if rec.char then meta = meta .. "  |  from " .. rec.char end
    if rec.cod and rec.cod > 0 then
        meta = meta .. "  |  |cffd05050COD " ..
            util.FormatMoney(rec.cod, false) .. "|r"
    elseif rec.money and rec.money > 0 then
        meta = meta .. "  |  " .. util.FormatMoney(rec.money, true) .. " sent"
    end
    -- Mail count and item count share ONE line. They used to be two, and the
    -- 18px that bought went to the message well below.
    local items = rec.items or {}
    local n = table.getn(items)
    meta = meta .. "  |  " .. (n == 0 and "no attachments"
        or (n .. (n == 1 and " item" or " items")))
    ui.sentMeta:SetText(meta)

    local i = 1
    while i <= SENT_ITEM_ROWS * 2 do
        local f = ui.sentItemRows[i]
        local it = items[i]
        if it then
            -- `x` is absent on records written before icons were captured. A
            -- sent mail cannot be re-read to fill it in, so fall back rather
            -- than leaving a hole.
            if it.x then
                f.icon:SetTexture(it.x)
                f.icon:Show()
            else
                f.icon:Hide()
            end
            local label = it.n or "?"
            if it.c and it.c > 1 then label = label .. " x" .. it.c end
            SetClipped(f.label, label, 258)
            f:Show()
        else
            f:Hide()
        end
        i = i + 1
    end

    if rec.body and rec.body ~= "" then
        ui.sentBody:SetText(rec.body)
    else
        ui.sentBody:SetText("|cff808080(no message)|r")
    end

    ui.sentCompose:SetText("Compose to " .. (rec.to or "?"))
    return true
end

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
    while i <= MAX_ROWS do
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

    local visible = ui.LedgerRowCount()
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

    FauxScrollFrame_Update(ui.ledgerScroll, total, visible, ROW_H)
    local offset = FauxScrollFrame_GetOffset(ui.ledgerScroll) or 0
    local now = time()

    local i = 1
    while i <= MAX_ROWS do
        local row = ui.ledgerRows[i]
        -- Newest first: walk the array backwards.
        local e = nil
        if i <= visible then e = led[total - (offset + i) + 1] end
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

    -- ---- window scale ----------------------------------------------------
    -- BUTTONS, NOT A SLIDER, deliberately: a slider that rescales the window it
    -- sits on moves itself out from under the cursor mid-drag, and the thumb
    -- then tracks to a value the player did not choose. Discrete steps have no
    -- such feedback loop and are easier to land on a round number.
    local scaleLbl = Label(panel, "GameFontNormalSmall", C.text)
    scaleLbl:SetPoint("TOPLEFT", pfSkin, "BOTTOMLEFT", 2, -14)
    scaleLbl:SetText("Window scale")

    local scaleDown = ui.MakeButton(panel, "quiet", "AegisCourierScaleDown")
    scaleDown:SetWidth(24)
    scaleDown:SetHeight(20)
    scaleDown:SetPoint("LEFT", scaleLbl, "RIGHT", 12, 0)
    scaleDown:SetText("-")
    scaleDown:SetScript("OnClick", function()
        ui.StepWindowScale(-SCALE_STEP)
    end)
    ui.btnScaleDown = scaleDown

    local scaleText = Label(panel, "GameFontHighlightSmall", C.text)
    scaleText:SetPoint("LEFT", scaleDown, "RIGHT", 8, 0)
    scaleText:SetWidth(44)
    scaleText:SetJustifyH("CENTER")
    ui.scaleText = scaleText

    local scaleUp = ui.MakeButton(panel, "quiet", "AegisCourierScaleUp")
    scaleUp:SetWidth(24)
    scaleUp:SetHeight(20)
    scaleUp:SetPoint("LEFT", scaleText, "RIGHT", 8, 0)
    scaleUp:SetText("+")
    scaleUp:SetScript("OnClick", function()
        ui.StepWindowScale(SCALE_STEP)
    end)
    ui.btnScaleUp = scaleUp

    local scaleReset = ui.MakeButton(panel, "quiet", "AegisCourierScaleReset")
    scaleReset:SetWidth(56)
    scaleReset:SetHeight(20)
    scaleReset:SetPoint("LEFT", scaleUp, "RIGHT", 10, 0)
    scaleReset:SetText("Reset")
    scaleReset:SetScript("OnClick", function() ui.StepWindowScale(nil) end)
    ui.btnScaleReset = scaleReset

    local scaleHint = Label(panel, "GameFontNormalSmall", C.dim)
    scaleHint:SetPoint("TOPLEFT", scaleLbl, "BOTTOMLEFT", 0, -6)
    scaleHint:SetText("Scale resizes the whole window; drag the corner to " ..
        "show more mail at once.")

    -- A rule between the two groups. Without it -- and with the Integration
    -- heading previously anchored to `push` rather than to the last checkbox --
    -- the heading was drawn straight on top of the log option.
    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", scaleHint, "BOTTOMLEFT", 0, -14)
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

    if ui.scaleText then
        -- Shown as a percentage: "85%" is easier to reason about than "0.85".
        ui.scaleText:SetText(math.floor(ui.WindowScale() * 100 + 0.5) .. "%")
    end

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
        table.getn(db.SentBox()) .. " sent")
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
    elseif ui.selectedSubTab == "Sent" then
        ui.RefreshSent()
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
        local b = ui.MakeButton(MailFrame, "quiet", "AegisCourierSwapButton")
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
