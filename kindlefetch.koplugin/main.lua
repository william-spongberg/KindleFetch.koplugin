local logger = require("logger")
local SafeMode = require("safemode")

-- load Kindle Fetch, or SafeMode's menu where it fails, so a broken update can be fixed without copying over USB
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
