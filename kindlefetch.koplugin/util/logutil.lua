local logger = require("logger")

-- KOReader writes info, warnings and errors to crash.log on every device, but debug messages only once debug logging
-- is turned on, so whatever is needed to work out what went wrong from someone's crash.log is logged at info or above
local LogUtil = {}

-- the last lines logged at info or above, oldest first, for the diagnostics (see Diagnostics), as crash.log can be
-- hard to get at on a device, and has every other plugin's lines in it too
local RECENT_LINES = 200
local recent = {}

-- what's never logged, e.g. the passwords of the libraries added (see LibrarySites), each as the pattern that finds it,
-- with *** logged in its place. (each at least a few characters long, as one or two would be found in the words of
-- nearly everything logged)
local hidden = {}
local MIN_HIDDEN_LENGTH = 4

-- never log secret, e.g. a password, logging *** in its place
function LogUtil.hide(secret)
    if type(secret) == "string" and #secret >= MIN_HIDDEN_LENGTH then
        hidden[secret] = secret:gsub("%W", "%%%0")
    end
end

-- what's to be logged, with what's hidden (see hide) replaced: in its text, rather than the tables (e.g. a book's)
-- that KOReader's logger writes out itself
local function masked(...)
    if next(hidden) == nil then
        return ...
    end
    local values = { n = select("#", ...), ... }
    for i = 1, values.n do
        if type(values[i]) == "string" then
            for __, pattern in pairs(hidden) do
                values[i] = values[i]:gsub(pattern, "***")
            end
        end
    end
    return unpack(values, 1, values.n)
end

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
    remember("ERROR", masked(...))
    logger.err("KindleFetch:", masked(...))
end

function LogUtil.warn(...)
    remember("WARN", masked(...))
    logger.warn("KindleFetch:", masked(...))
end

function LogUtil.info(...)
    remember("INFO", masked(...))
    logger.info("KindleFetch:", masked(...))
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
    logger.dbg("KindleFetch:", masked(...))
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
