local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

-- the version of Kindle Fetch that was installed before it was last updated, which is kept next to it (KOReader only
-- loads plugins from folders whose names end in .koplugin, so it's left alone), to go back to if the new version
-- doesn't work on this device. it only needs KOReader itself, as it's what's left when Kindle Fetch can't start (see
-- SafeMode)
local Rollback = {}

-- where the version before is kept
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

-- the version kept from before, e.g. "0.7", or nil when none is
function Rollback.previousVersion(plugin_path)
    local previous = Rollback.previousPath(plugin_path)
    if lfs.attributes(previous .. "/main.lua", "mode") ~= "file" then
        return nil
    end
    return readVersion(previous) or "?"
end

-- swap the version installed now with the one kept from before, keeping the one installed now in its place, to go
-- forward to again. returns true, or nil and what went wrong, leaving them as they were
function Rollback.goBack(plugin_path)
    local previous = Rollback.previousPath(plugin_path)
    local swap = plugin_path .. ".swap"
    logger.info("KindleFetch:", "going back from", readVersion(plugin_path), "to", readVersion(previous))

    local ok, err = os.rename(plugin_path, swap)
    if not ok then
        logger.warn("KindleFetch:", "could not move", plugin_path, "aside to", swap .. ":", err)
        return nil, err
    end
    ok, err = os.rename(previous, plugin_path)
    if not ok then
        logger.warn("KindleFetch:", "could not move", previous, "into place:", err)
        local restored, restore_err = os.rename(swap, plugin_path)
        if not restored then
            logger.err("KindleFetch:", "could not put", swap, "back:", restore_err)
        end
        return nil, err
    end
    ok, err = os.rename(swap, previous)
    if not ok then
        -- which leaves it gone back all the same, only without a version to go forward to
        logger.warn("KindleFetch:", "could not keep", swap, "as", previous .. ":", err)
    end
    return true
end

return Rollback
