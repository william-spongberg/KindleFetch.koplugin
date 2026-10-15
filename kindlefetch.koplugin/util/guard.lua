local UIManager = require("ui/uimanager")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local Errors = require("util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

-- KOReader doesn't catch errors in what it runs later: tasks it's asked to run in a while or on the next tick, the
-- functions Trapper wraps, and the event handlers of widgets other than the plugin's own (which PluginLoader's
-- HandlerSandbox catches), so a mistake in one of Kindle Fetch's exited KOReader, or was lost without a trace. these
-- run them catching any, logging it with where it happened, then cleaning up after what was going on
local Guard = {}

local function pack(...)
    return { n = select("#", ...), ... }
end

-- say that something went wrong, when what was going on has nothing of its own to clean up and say
function Guard.say(err)
    NotifyUtil.error(T(_("Kindle Fetch: %1"), err))
end

-- like pcall, logging what went wrong with where it happened, as what was being done (e.g. "searching")
function Guard.pcall(what, fn, ...)
    local results = pack(xpcall(fn, debug.traceback, ...))
    if not results[1] then
        LogUtil.err(what, "went wrong:", tostring(results[2]))
    end
    return unpack(results, 1, results.n)
end

-- call fn, returning what it returns. once it fails (see pcall), on_error is called with Errors.UNEXPECTED to clean up
-- after it and say so (Guard.say when not given), and nothing is returned
function Guard.call(what, fn, on_error, ...)
    local results = pack(Guard.pcall(what, fn, ...))
    if results[1] then
        return unpack(results, 2, results.n)
    end
    Guard.pcall("cleaning up after " .. what, on_error or Guard.say, Errors.UNEXPECTED)
end

-- fn as a function that's called as Guard.call calls it, for KOReader to call later
function Guard.wrap(what, fn, on_error)
    return function(...)
        return Guard.call(what, fn, on_error, ...)
    end
end

-- UIManager:scheduleIn and nextTick, for a function that's called as Guard.call calls it
function Guard.scheduleIn(seconds, what, fn, on_error)
    UIManager:scheduleIn(seconds, Guard.wrap(what, fn, on_error))
end
function Guard.nextTick(what, fn, on_error)
    UIManager:nextTick(Guard.wrap(what, fn, on_error))
end

-- for what goes wrong when nothing needs saying, e.g. an update check that wasn't asked for
function Guard.quiet() end

return Guard
