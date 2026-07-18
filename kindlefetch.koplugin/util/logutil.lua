local logger = require("logger")

local LogUtil = {}

function LogUtil.warn(...)
    logger.warn("KindleFetch:", ...)
end

function LogUtil.debug(...)
    logger.dbg("KindleFetch:", ...)
end

return LogUtil