local logger = require("logger")

local LogUtil = {}

function LogUtil.warn(log)
    logger.warn("KindleFetch:", log)
end

function LogUtil.debug(log)
    logger.dbg("KindleFetch:", log)
end

return LogUtil