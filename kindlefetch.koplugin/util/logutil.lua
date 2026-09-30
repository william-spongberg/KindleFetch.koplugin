local logger = require("logger")

-- KOReader writes info, warnings and errors to crash.log on every device, but debug messages only once debug logging
-- is turned on, so whatever is needed to work out what went wrong from someone's crash.log is logged at info or above
local LogUtil = {}

function LogUtil.err(...)
    logger.err("KindleFetch:", ...)
end

function LogUtil.warn(...)
    logger.warn("KindleFetch:", ...)
end

function LogUtil.info(...)
    logger.info("KindleFetch:", ...)
end

function LogUtil.debug(...)
    logger.dbg("KindleFetch:", ...)
end

-- the site a url is on, to log which mirror was used without the rest of it (download links carry a temporary key)
function LogUtil.site(url)
    if type(url) ~= "string" then
        return tostring(url)
    end
    return url:match("^%a+://([^/?#]+)") or url
end

return LogUtil
