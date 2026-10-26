local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local WaitingMessage = require("ui.waitingmessage")
local HttpUtil = require("util.httputil")
local Guard = require("util.guard")

-- runs what waits on the sites without holding KOReader up (see Trapper), letting what's shown call its requests off
local BackgroundTask = {}

local function pack(...)
    return { n = select("#", ...), ... }
end

-- run work, whose requests trap calls off (see HttpUtil.setTrapWidget), then on_done with what it returned; on_error
-- (or Guard.say) with Errors.UNEXPECTED once either goes wrong (see Guard.call)
function BackgroundTask.run(what, trap, work, on_done, on_error)
    Trapper:wrap(Guard.wrap(what, function()
        HttpUtil.setTrapWidget(trap)
        local results = pack(work())
        HttpUtil.setTrapWidget(nil)
        if on_done then
            on_done(unpack(results, 1, results.n))
        end
    end, function(err)
        HttpUtil.setTrapWidget(nil)
        local handle = on_error or Guard.say
        handle(err)
    end))
end

-- run work as run does, saying text with a Cancel that calls it off; finally, where given, once the message closes
function BackgroundTask.withMessage(what, text, work, on_done, finally)
    local message
    local function close()
        HttpUtil.setTrapWidget(nil)
        if message and not message.cancelled and not message.closed then
            message.closed = true
            UIManager:close(message)
        end
        if finally then
            finally()
        end
    end
    BackgroundTask.run(what, nil, function()
        message = WaitingMessage.new(text)
        UIManager:show(message)
        UIManager:forceRePaint()
        HttpUtil.setTrapWidget(message)
        return work()
    end, function(...)
        close()
        if on_done then
            on_done(...)
        end
    end, function(err)
        close()
        Guard.say(err)
    end)
end

return BackgroundTask
