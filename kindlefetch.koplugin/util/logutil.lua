local logger = require("logger")

-- KOReader writes info, warnings and errors to crash.log on every device, but debug messages only once debug logging
-- is turned on, so whatever is needed to work out what went wrong from someone's crash.log is logged at info or above
local LogUtil = {}

-- the last lines logged at info or above, oldest first, for the diagnostics (see Diagnostics), as crash.log can be
-- hard to get at on a device, and has every other plugin's lines in it too
local RECENT_LINES = 200
local recent = {}

local function remember(level, ...)
    local parts = { os.date("%H:%M:%S", os.time()), level }
    for i = 1, select("#", ...) do
        table.insert(parts, tostring((select(i, ...))))
    end
    table.insert(recent, table.concat(parts, " "))
    if #recent > RECENT_LINES then
        table.remove(recent, 1)
    end
end

function LogUtil.err(...)
    remember("ERROR", ...)
    logger.err("KindleFetch:", ...)
end

function LogUtil.warn(...)
    remember("WARN", ...)
    logger.warn("KindleFetch:", ...)
end

function LogUtil.info(...)
    remember("INFO", ...)
    logger.info("KindleFetch:", ...)
end

-- the last lines logged at info or above this session, oldest first, each with when it was logged
function LogUtil.recent()
    local lines = {}
    for i, line in ipairs(recent) do
        lines[i] = line
    end
    return lines
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

-- the start of a page a site answered with, as text without its tags, to log what it said when it can't be used
function LogUtil.excerpt(html)
    return (html:gsub("<[^>]+>", " "):gsub("%s+", " "):sub(1, 200))
end

return LogUtil
