-- Aegis: Courier
-- core/init.lua
--
-- Namespace table and event dispatcher for Turtle WoW 1.18.1, which runs the
-- ORIGINAL WoW 1.12 (vanilla) client on Lua 5.0.
--
-- See CLAUDE.md for the hard rules. In short, everywhere in this addon:
--   * Lua 5.0 only  (no string.match/gmatch, no ":match()")
--   * no "#" length operator      -> table.getn(t)
--   * no "%" modulo operator      -> math.mod(a, b)
--   * events use the GLOBALS event, arg1, arg2, ...  (NOT self/event/...)
--
-- This file is deliberately near-identical to Aegis: Exchange's core/init.lua.
-- The client constraints are the same, so the dispatcher is the same; keeping
-- them in step means a fix to one is a mechanical port to the other.

-- ---------------------------------------------------------------------------
-- Namespace
-- ---------------------------------------------------------------------------
-- Single global table. Everything the addon exposes hangs off this.
AegisCourier = {}
local A = AegisCourier

A.name = "Aegis_Courier"   -- must match the folder / .toc / ADDON_LOADED

-- Shown in the window title bar and printed at load. It is the only reliable
-- way to know which build produced an in-game bug report, so it must never
-- disagree with the .toc.
--
-- It did disagree: this was a hand-maintained literal, and two releases went
-- out that bumped `## Version` in the .toc and left this behind, so the title
-- bar kept claiming 1.0.4. Read the real thing instead. The literal below is
-- only a fallback for a client without GetAddOnMetadata, and the test harness
-- parses the .toc and asserts the two agree so it cannot drift again.
A.version = "1.9.4"
if GetAddOnMetadata then
    local v = GetAddOnMetadata("Aegis_Courier", "Version")
    if type(v) == "string" and v ~= "" then A.version = v end
end

-- Detect Turtle WoW. Turtle exposes a global TURTLE_WOW_VERSION.
A.isTurtle = (TURTLE_WOW_VERSION ~= nil)

-- ---------------------------------------------------------------------------
-- Event dispatch
-- ---------------------------------------------------------------------------
-- Vanilla 1.12 delivers events to a frame's OnEvent script with the GLOBALS
-- `event`, `arg1`, `arg2`, ... already set. There is no function(self, event,
-- ...) signature on this client. We register one hidden driver frame and fan
-- each event out to any number of registered handlers.

-- eventName -> array of handler functions.
A.eventHandlers = {}

-- The driver frame. Named so FrameXML / other files can find it via getglobal.
A.frame = CreateFrame("Frame", "AegisCourierEventFrame")

-- Register `fn` to run whenever `evt` fires. The underlying event is only
-- registered with the driver frame the first time it is seen.
function A.RegisterEvent(evt, fn)
    local list = A.eventHandlers[evt]
    if not list then
        list = {}
        A.eventHandlers[evt] = list
        A.frame:RegisterEvent(evt)
    end
    table.insert(list, fn)
end

-- OnEvent target. Reads the vanilla event globals and forwards them to each
-- handler as explicit args (handlers may also read the globals directly).
function A.Dispatch()
    local list = A.eventHandlers[event]
    if not list then return end
    local n = table.getn(list)
    local i = 1
    while i <= n do
        list[i](event, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
        i = i + 1
    end
end

A.frame:SetScript("OnEvent", A.Dispatch)

-- ---------------------------------------------------------------------------
-- Load bootstrap
-- ---------------------------------------------------------------------------
-- SavedVariables (CourierDB / CourierCharDB) are nil until ADDON_LOADED fires
-- for "Aegis_Courier". Modules queue their init routine via A.OnLoad and we run
-- them all once -- and only once -- at that point.
A.initCallbacks = {}
A.loaded = false

-- Queue `fn` to run right after ADDON_LOADED for this addon (or immediately if
-- we have already loaded).
function A.OnLoad(fn)
    if A.loaded then
        fn()
    else
        table.insert(A.initCallbacks, fn)
    end
end

-- ---------------------------------------------------------------------------
-- Chat output
-- ---------------------------------------------------------------------------

-- Courier's chat colour: a slightly greener blue than Exchange's, so a user
-- running both can tell at a glance which addon is talking.
function A.Print(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff8fd6a8Courier|r: " .. text,
            0.56, 0.84, 0.66)
    end
end

A.RegisterEvent("ADDON_LOADED", function(evt, loadedName)
    if loadedName ~= A.name then return end
    A.loaded = true
    local cbs = A.initCallbacks
    local n = table.getn(cbs)
    local i = 1
    while i <= n do
        cbs[i]()
        i = i + 1
    end
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(
            "Aegis: Courier v" .. A.version .. " loaded \226\128\148 /courier",
            0.56, 0.84, 0.66)
    end
end)
