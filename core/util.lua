-- Aegis: Courier
-- core/util.lua
--
-- Lua 5.0 / vanilla 1.12 safe helpers.
--   * money formatting and the auction consignment split
--   * string helpers via string.find / string.gfind  (NOT string.match/gmatch)
--   * time formatting
--
-- Reminder of the constraints exercised here:
--   * no "%" operator          -> math.mod(a, b)
--   * no "#" length operator   -> table.getn(t)
--   * no string.match/gmatch   -> string.find (with captures) / string.gfind

local A = AegisCourier
A.util = {}
local util = A.util

local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD   = 10000   -- 100 * 100

-- Turtle's faction consignment cut on a completed auction sale: 5%. The money
-- attached to an "Auction successful" mail is already NET of this, so the
-- gross is net / (1 - CUT_RATE). See util.SaleSplit.
util.CUT_RATE = 0.05

-- ---------------------------------------------------------------------------
-- Money
-- ---------------------------------------------------------------------------

-- Split a copper amount into (gold, silver, copper). Uses math.mod and
-- math.floor because Lua 5.0 has neither the "%" operator nor integer div.
function util.MoneyParts(copper)
    copper = copper or 0
    if copper < 0 then copper = -copper end
    copper = math.floor(copper)
    local gold   = math.floor(copper / COPPER_PER_GOLD)
    local silver = math.floor(math.mod(copper, COPPER_PER_GOLD) / COPPER_PER_SILVER)
    local cop    = math.mod(copper, COPPER_PER_SILVER)
    return gold, silver, cop
end

-- Format a copper amount as a compact string like "12g 34s 56c". Leading zero
-- denominations are dropped, but copper is always shown when the total is
-- under one silver. Pass `colored` = true for WoW colour escape codes.
function util.FormatMoney(copper, colored)
    local g, s, c = util.MoneyParts(copper)
    local parts = {}
    if colored then
        if g > 0 then table.insert(parts, "|cffffd700" .. g .. "g|r") end
        if s > 0 then table.insert(parts, "|cffc7c7cf" .. s .. "s|r") end
        if c > 0 or table.getn(parts) == 0 then
            table.insert(parts, "|cffeda55f" .. c .. "c|r")
        end
    else
        if g > 0 then table.insert(parts, g .. "g") end
        if s > 0 then table.insert(parts, s .. "s") end
        if c > 0 or table.getn(parts) == 0 then
            table.insert(parts, c .. "c")
        end
    end
    return table.concat(parts, " ")
end

-- Parse a money string like "12g 34s 56c" (units case-insensitive, spaces
-- optional) into total copper. A bare number is read as GOLD, which is what
-- someone typing "50" into a mail money box means. Returns nil when nothing
-- parseable is found. Uses string.gfind (Lua 5.0), NOT string.gmatch.
function util.ParseMoney(str)
    if type(str) ~= "string" then return nil end
    local trimmed = util.Trim(str)
    if trimmed == "" then return nil end

    -- Bare number -> gold.
    local s, e = string.find(trimmed, "^%d+$")
    if s then return tonumber(trimmed) * COPPER_PER_GOLD end

    local total, found = 0, false
    for amount, unit in string.gfind(trimmed, "(%d+)%s*([gscGSC])") do
        local n = tonumber(amount)
        if n then
            unit = string.lower(unit)
            if unit == "g" then
                total = total + n * COPPER_PER_GOLD
            elseif unit == "s" then
                total = total + n * COPPER_PER_SILVER
            else
                total = total + n
            end
            found = true
        end
    end
    if not found then return nil end
    return total
end

-- Given the money actually attached to a sale mail (the NET proceeds), return
-- (gross, cut, net) in copper.
--
-- The auction house takes its consignment cut before mailing you the balance,
-- so what arrives is net. Gross is therefore net / 0.95, not net * 1.05 --
-- those differ, and using the wrong one under-reports the cut on every sale.
-- Rounding: gross is rounded to the nearest copper and the cut is derived as
-- (gross - net) so the three numbers always reconcile exactly.
function util.SaleSplit(netCopper)
    netCopper = math.floor(netCopper or 0)
    if netCopper <= 0 then return 0, 0, 0 end
    local gross = math.floor((netCopper / (1 - util.CUT_RATE)) + 0.5)
    return gross, gross - netCopper, netCopper
end

-- ---------------------------------------------------------------------------
-- Strings
-- ---------------------------------------------------------------------------

-- Trim leading/trailing whitespace. Uses string.gsub (fine in 5.0) with an
-- anchored capture; NOT string.match.
function util.Trim(str)
    if type(str) ~= "string" then return str end
    local result = string.gsub(str, "^%s*(.-)%s*$", "%1")
    return result   -- discard gsub's 2nd return (substitution count)
end

-- Collapse runs of whitespace to a single space and trim. Used to normalize
-- sender names before comparing them: the auction-house sender set in the wild
-- contains a double space ("Thunder Bluff  Auction House"), and matching on a
-- normalized string is more robust than reproducing the typo.
function util.Normalize(str)
    if type(str) ~= "string" then return str end
    local result = string.gsub(str, "%s+", " ")
    return util.Trim(result)
end

-- True when `haystack` contains `needle` as a PLAIN substring (no pattern
-- magic). string.find's 4th argument is the plain flag.
function util.Contains(haystack, needle)
    if type(haystack) ~= "string" or type(needle) ~= "string" then
        return false
    end
    if needle == "" then return false end
    return string.find(haystack, needle, 1, true) ~= nil
end

-- Turn a client format string such as AUCTION_SOLD_MAIL_SUBJECT
-- ("Auction successful: %s") into a plain prefix by stripping the "%s"
-- placeholder -- the technique TurtleMail uses, and the reason its matching is
-- localization-proof where a hardcoded English literal is not.
--
-- Returns nil when `fmt` is not a usable string, so callers can fall back.
function util.SubjectStem(fmt)
    if type(fmt) ~= "string" or fmt == "" then return nil end
    -- "%%s" is the pattern for a literal "%s".
    local stem = string.gsub(fmt, "%%s", "")
    stem = util.Trim(stem)
    if stem == "" then return nil end
    return stem
end

-- Pull the item name out of a subject given the format string it was built
-- from. "Auction successful: %s" + "Auction successful: Silk Cloth" ->
-- "Silk Cloth". Returns nil when the subject does not match the format.
--
-- Works by locating the format's literal fragments around the placeholder, so
-- it holds for locales where "%s" is not at the end (e.g. "Outbid on %s" has a
-- prefix only, but other locales may wrap it).
function util.SubjectItem(subject, fmt)
    if type(subject) ~= "string" or type(fmt) ~= "string" then return nil end
    local ps, pe = string.find(fmt, "%%s")
    if not ps then return nil end
    local prefix = string.sub(fmt, 1, ps - 1)
    local suffix = string.sub(fmt, pe + 1)

    local start = 1
    if prefix ~= "" then
        local s, e = string.find(subject, prefix, 1, true)
        if s ~= 1 then return nil end
        start = e + 1
    end

    local finish = string.len(subject)
    if suffix ~= "" then
        -- Find the LAST occurrence of the suffix so an item name containing it
        -- does not truncate the match early.
        local from, s, e = 1, nil, nil
        while true do
            local fs, fe = string.find(subject, suffix, from, true)
            if not fs then break end
            s, e = fs, fe
            from = fs + 1
        end
        if not s or e ~= string.len(subject) then return nil end
        finish = s - 1
    end

    if finish < start then return nil end
    return util.Trim(string.sub(subject, start, finish))
end

-- Pull the display name out of an item link. Bag slots DO have links on 1.12
-- (unlike the mail inbox -- see CLAUDE.md rule 10), and the name sits between
-- the square brackets:
--   |cff1eff00|Hitem:2589:0:0:0|h[Linen Cloth]|h|r  ->  "Linen Cloth"
-- string.find with a capture; NOT string.match.
-- Seconds to one decimal place, e.g. 4.2s. Hand-rolled rather than via
-- string.format to match the rest of this file, and built from math.floor
-- only -- Lua 5.0 has no integer division and no % operator.
function util.FormatSeconds(secs)
    if type(secs) ~= "number" or secs < 0 then return "?" end
    local tenths = math.floor(secs * 10 + 0.5)
    local whole = math.floor(tenths / 10)
    local frac = tenths - (whole * 10)
    return whole .. "." .. frac .. "s"
end

function util.ItemNameFromLink(link)
    if type(link) ~= "string" then return nil end
    local _, _, name = string.find(link, "%[(.+)%]")
    return name
end

-- Pull the "item:id:enchant:suffix:unique" string out of a full item link.
--
-- This is what GameTooltip:SetHyperlink wants, and the SUFFIX field is why the
-- whole string is kept rather than just the id: a random-suffix item is
-- "Training Sword" plus suffix 1234, and an id alone would render it as the
-- plain base item with none of the stats the player actually has.
function util.ItemStringFromLink(link)
    if type(link) ~= "string" then return nil end
    local _, _, s = string.find(link, "|H(item:[^|]+)|h")
    if s then return s end
    -- Already an item string rather than a decorated link.
    if string.find(link, "^item:%d+") then return link end
    return nil
end

-- Pull the numeric itemID out of an item link or item string.
function util.ItemIdFromLink(link)
    if type(link) ~= "string" then return nil end
    local _, _, id = string.find(link, "item:(%d+)")
    return tonumber(id)
end

-- ---------------------------------------------------------------------------
-- Time
-- ---------------------------------------------------------------------------

-- Format "how long ago": "just now", "5m ago", "2h 14m ago", "3d ago".
function util.FormatAgo(sec)
    sec = math.floor(sec or 0)
    if sec < 60 then
        return "just now"
    elseif sec < 3600 then
        return math.floor(sec / 60) .. "m ago"
    elseif sec < 86400 then
        local h = math.floor(sec / 3600)
        local m = math.floor(math.mod(sec, 3600) / 60)
        return h .. "h " .. m .. "m ago"
    end
    return math.floor(sec / 86400) .. "d ago"
end

-- Format a mail's remaining life. GetInboxHeaderInfo returns `daysLeft` as a
-- FRACTIONAL number of DAYS (see CLAUDE.md rule 8), which is why this takes
-- days rather than seconds and why sub-day values fall through to hours.
function util.FormatDaysLeft(days)
    if type(days) ~= "number" then return "" end
    if days >= 1 then
        return math.floor(days) .. "d"
    end
    local hours = math.floor(days * 24)
    if hours >= 1 then
        return hours .. "h"
    end
    local mins = math.floor(days * 24 * 60)
    if mins < 1 then mins = 1 end
    return mins .. "m"
end

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- Count entries in a hash table via pairs, since table.getn only measures the
-- contiguous array part.
function util.CountKeys(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end
