local logger = require("logger")
local SafeMode = require("safemode")

-- KOReader loads plugins from their main.lua, which loads Kindle Fetch (see kindlefetch.lua), or when it can't be
-- loaded or started, e.g. once updated to a version that doesn't work with this KOReader, a menu with what's left (see
-- SafeMode). without it, Kindle Fetch was gone from KOReader's menu, along with checking for updates, until it was
-- copied over USB
local loaded, KindleFetch = xpcall(require, debug.traceback, "kindlefetch")
if not loaded then
    logger.err("KindleFetch:", "could not load Kindle Fetch:", KindleFetch)
    return SafeMode.new(KindleFetch)
end

-- and when starting it goes wrong, which KOReader would leave it out of its menu for
local init = KindleFetch.init
function KindleFetch:init()
    local started, err = xpcall(init, debug.traceback, self)
    if not started then
        logger.err("KindleFetch:", "could not start Kindle Fetch:", err)
        SafeMode.takeOver(self, err)
    end
end

return KindleFetch
