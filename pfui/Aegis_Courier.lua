-- Aegis: Courier -- skin for pfUI-addonskinner
--
-- OPTIONAL, and NOT part of the addon. Courier skins itself when pfUI is
-- present, so you do not need this file. It exists for people who manage every
-- skin through pfUI-addonskinner
-- (https://github.com/mrrosh/pfUI-addonskinner) and want Courier to appear in
-- that addon's list with the rest.
--
-- To use it:
--   1. Copy this file to
--        Interface/AddOns/pfUI-addonskinner/skins/Aegis_Courier.lua
--   2. Add this line to pfUI-addonskinner.toc, under "# skins":
--        skins\Aegis_Courier.lua
--   3. Restart the client.
--
-- It is deliberately NOT listed in Aegis_Courier.toc -- it belongs to the other
-- addon, and loading it here would call into a pfUI table that need not exist.
--
-- All it does is call Courier's own skinning routine, so the look stays in one
-- place and cannot drift between the two paths.

pfUI.addonskinner:RegisterSkin("Aegis_Courier", function()
    if AegisCourier and AegisCourier.skin then
        -- The window is built lazily (the first time you open a mailbox or
        -- type /courier), so Apply() is also re-run from Courier itself after
        -- the build. Calling it here covers the case where it already exists.
        AegisCourier.skin.Apply()
    end

    -- Remove from the pending list now that it has been applied.
    pfUI.addonskinner:UnregisterSkin("Aegis_Courier")
end)
