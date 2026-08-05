-- Aegis: Courier
-- ui/skin.lua
--
-- OPTIONAL pfUI skin. When pfUI is installed, restyle Courier's window with
-- pfUI's own backdrop / button / checkbox / scrollbar helpers so it matches
-- the rest of the interface instead of wearing vanilla tooltip borders.
--
-- Design rules for this file, carried over from Aegis: Exchange's ui/skin.lua
-- so the two stay in step:
--   * It is PURELY cosmetic. Nothing here may change behaviour, and every
--     pfUI call is wrapped in pcall so a pfUI API change can never break the
--     addon -- the worst case is that you keep the default look.
--   * pfUI's helpers come from pfUI:GetEnvironment(), the same entry point the
--     pfUI-addonskinner skins use. Each helper is checked before use.
--   * Skinning is applied ONCE, after the window is built.
--
-- pfUI is never a dependency. It is not in the .toc, and `pfUI == nil` is the
-- ordinary case that must cost nothing.

local A = AegisCourier
A.skin = {}
local skin = A.skin

skin.applied = false

-- pfUI present and exposing its helper environment?
function skin.Available()
    return (pfUI and pfUI.GetEnvironment) and true or false
end

-- Should we skin? pfUI must be present AND the user setting left on.
function skin.Enabled()
    if not skin.Available() then return false end
    if A.db and A.db.Setting and A.db.Setting("pfSkin") == false then
        return false
    end
    return true
end

-- Fetch pfUI's helpers once. Returns a table of the ones we use, each possibly
-- nil -- callers must check.
local function Env()
    if skin.env then return skin.env end
    local ok, env = pcall(function() return pfUI:GetEnvironment() end)
    if not ok or not env then return nil end
    skin.env = {
        CreateBackdrop  = env.CreateBackdrop,
        StripTextures   = env.StripTextures,
        SkinButton      = env.SkinButton,
        SkinCloseButton = env.SkinCloseButton,
        SkinCheckbox    = env.SkinCheckbox,
        SkinScrollbar   = env.SkinScrollbar,
    }
    return skin.env
end

-- ---------------------------------------------------------------------------
-- Wrappers -- every pfUI call goes through pcall, so a missing or changed
-- helper degrades to "unskinned", never to an error.
-- ---------------------------------------------------------------------------

local function Backdrop(frame, alpha)
    local env = Env()
    if not frame or not env or not env.CreateBackdrop then return end
    -- Drop our own vanilla backdrop first, or we end up double-bordered.
    if frame.SetBackdrop then pcall(function() frame:SetBackdrop(nil) end) end
    pcall(function() env.CreateBackdrop(frame, nil, nil, alpha) end)
end

local function Strip(frame)
    local env = Env()
    if not frame or not env or not env.StripTextures then return end
    pcall(function() env.StripTextures(frame, true) end)
end

local function Button(b)
    local env = Env()
    if not b or not env or not env.SkinButton then return end
    pcall(function() env.SkinButton(b) end)
end

local function CloseButton(b)
    local env = Env()
    if not b then return end
    if env and env.SkinCloseButton then
        local ok = pcall(function() env.SkinCloseButton(b) end)
        if ok then return end
    end
    Button(b)
end

local function Checkbox(c)
    local env = Env()
    if not c or not env or not env.SkinCheckbox then return end
    pcall(function() env.SkinCheckbox(c) end)
end

local function Scrollbar(sb)
    local env = Env()
    if not sb or not env or not env.SkinScrollbar then return end
    pcall(function() env.SkinScrollbar(sb) end)
end

-- ---------------------------------------------------------------------------
-- Frame walking
-- ---------------------------------------------------------------------------

-- Children of `frame` as an array. 1.12 returns them as multiple values; the
-- table constructor captures them, which is Lua 5.0 safe.
local function Children(frame)
    if not frame or not frame.GetChildren then return {} end
    local ok, t = pcall(function() return { frame:GetChildren() } end)
    if not ok or not t then return {} end
    return t
end

-- Skin one widget according to what it is.
--
-- Widgets marked `courierNoSkin` opt out: the inbox row buttons (a pfUI border
-- around every row would be noise, and they are click targets rather than
-- buttons visually) and the attachment slots (icon wells, which get a plain
-- backdrop instead).
local function SkinWidget(f)
    if not f or f.courierSkinned then return false end
    local ok, otype = pcall(function() return f:GetObjectType() end)
    if not ok then return false end

    if f.courierNoSkin then
        f.courierSkinned = true
        -- Still worth a pfUI backdrop where we drew a vanilla one.
        if f.courierBackdrop then Backdrop(f) end
        return false
    end

    if otype == "CheckButton" then
        Checkbox(f)
        f.courierSkinned = true
        return true
    elseif otype == "Button" then
        if f.courierCloseButton then
            CloseButton(f)
        else
            Button(f)
        end
        f.courierSkinned = true
        return true
    elseif otype == "EditBox" then
        Strip(f)
        Backdrop(f)
        f.courierSkinned = true
        return true
    elseif otype == "Slider" then
        Scrollbar(f)
        f.courierSkinned = true
        return true
    end
    return false
end

-- Walk `frame` and its descendants. `depth` guards against pathological
-- nesting; our tree is at most four deep.
local function SkinTree(frame, depth)
    if not frame or depth > 6 then return end
    local kids = Children(frame)
    local n = table.getn(kids)
    local i = 1
    while i <= n do
        local child = kids[i]
        if child then
            SkinWidget(child)
            SkinTree(child, depth + 1)
        end
        i = i + 1
    end
end

-- ---------------------------------------------------------------------------
-- Apply
-- ---------------------------------------------------------------------------

-- Restyle the Courier window. Safe to call repeatedly; only the first full
-- pass does the work.
function skin.Apply()
    if not skin.Enabled() then return false end
    if not Env() then return false end
    local ui = A.ui
    if not ui or not ui.frame then return false end

    if skin.applied then
        skin.ApplyExternal()
        return true
    end

    -- Window, title bar and each panel's recessed well.
    Backdrop(ui.frame, 1)
    if ui.titleBar then Backdrop(ui.titleBar, 1) end

    local wells = { ui.inboxWell, ui.logWell, ui.ledgerWell, ui.sendBodyWell,
        ui.sendAuto }
    local i = 1
    while i <= table.getn(wells) do
        if wells[i] then Backdrop(wells[i], 1) end
        i = i + 1
    end

    -- Sub-tab pills keep OUR colouring: pfUI's CreateBackdrop adds a child
    -- `backdrop` frame, and ui.SelectSubTab tints that instead of the button
    -- when it is present, so the selected tab still reads as selected.
    if ui.subTabs then
        for _, b in pairs(ui.subTabs) do
            Backdrop(b, 1)
            b.courierSkinned = true
        end
    end

    -- Everything else by type.
    SkinTree(ui.frame, 0)

    skin.applied = true
    skin.ApplyExternal()

    -- Re-run the tab colouring so the freshly created pfUI backdrops pick up
    -- the selected/unselected tint immediately rather than on the next click.
    if ui.SelectSubTab and ui.selectedSubTab then
        pcall(function() ui.SelectSubTab(ui.selectedSubTab) end)
    end
    return true
end

-- The one button we hang off a Blizzard frame (the "Courier" button on the
-- stock mail window). It is created lazily when MailFrame is first hooked, so
-- it can miss the main pass.
function skin.ApplyExternal()
    if not skin.Enabled() then return end
    local ui = A.ui
    if ui and ui.swapBtn and not ui.swapBtn.courierSkinned then
        Button(ui.swapBtn)
        ui.swapBtn.courierSkinned = true
    end
end

-- Called when the user toggles the setting. Turning it ON applies live;
-- turning it OFF cannot cleanly un-skin (pfUI's backdrops are real frames it
-- created), so that needs a reload. Say so rather than appearing to do nothing.
function skin.OnSettingChanged(on)
    if on then
        if not skin.Available() then
            A.Print("pfUI is not installed, so there is nothing to match.")
            return
        end
        skin.Apply()
        A.Print("matching pfUI's look.")
    else
        A.Print("pfUI styling stays until you /reload.")
    end
end
