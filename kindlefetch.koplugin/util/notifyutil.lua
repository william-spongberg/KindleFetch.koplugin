local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local NotifyUtil = {}

function NotifyUtil.info(...)
    Notification:notify(..., Notification.SOURCE_ALWAYS_SHOW, true)
    UIManager:forceRePaint()
end

-- say that something went wrong, in a message that stays until it's dismissed. a notification is gone after a
-- couple of seconds, whether or not it was read, and what went wrong may only be known after a wait
function NotifyUtil.error(text)
    UIManager:show(InfoMessage:new {
        text = text,
        icon = "notice-warning",
    })
end

return NotifyUtil
