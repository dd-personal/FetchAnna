local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

-- The version of FetchAnna installed before the last update, kept next to it to go back to if the new one doesn't work
-- on this device. KOReader only loads plugins from folders named *.koplugin, so it leaves this one alone. Needs only
-- KOReader itself, as it's what's left when FetchAnna can't start (see SafeMode).
local Rollback = {}

-- Returns where the previous version is kept.
function Rollback.previousPath(plugin_path)
    return plugin_path .. ".previous"
end

local function readVersion(folder)
    local f = io.open(folder .. "/version.txt", "r")
    if not f then
        return nil
    end
    local version = (f:read("*a") or ""):match("^%s*(.-)%s*$")
    f:close()
    return version ~= "" and version or nil
end

-- Returns the version kept from before, e.g. "0.7", or nil when none is.
function Rollback.previousVersion(plugin_path)
    local previous = Rollback.previousPath(plugin_path)
    if lfs.attributes(previous .. "/main.lua", "mode") ~= "file" then
        return nil
    end
    return readVersion(previous) or "?"
end

-- Swaps the installed version with the one kept from before, which can then be gone forward to again. Returns true, or
-- nil and what went wrong, leaving both as they were.
function Rollback.goBack(plugin_path)
    local previous = Rollback.previousPath(plugin_path)
    local swap = plugin_path .. ".swap"
    logger.info("FetchAnna:", "going back from", readVersion(plugin_path), "to", readVersion(previous))

    local ok, err = os.rename(plugin_path, swap)
    if not ok then
        logger.warn("FetchAnna:", "could not move", plugin_path, "aside to", swap .. ":", err)
        return nil, err
    end
    ok, err = os.rename(previous, plugin_path)
    if not ok then
        logger.warn("FetchAnna:", "could not move", previous, "into place:", err)
        local restored, restore_err = os.rename(swap, plugin_path)
        if not restored then
            logger.err("FetchAnna:", "could not put", swap, "back:", restore_err)
        end
        return nil, err
    end
    ok, err = os.rename(swap, previous)
    if not ok then
        -- It has still gone back, only with no version to go forward to.
        logger.warn("FetchAnna:", "could not keep", swap, "as", previous .. ":", err)
    end
    return true
end

return Rollback
