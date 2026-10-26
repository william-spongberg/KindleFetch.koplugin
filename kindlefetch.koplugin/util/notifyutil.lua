local Notification = require("ui/widget/notification")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local NotifyUtil = {}

function NotifyUtil.info(...)
    Notification:notify(..., Notification.SOURCE_ALWAYS_SHOW, true)
    UIManager:forceRePaint()
end

-- say something in a message that stays until it's dismissed, for what mustn't be missed
function NotifyUtil.message(text)
    UIManager:show(InfoMessage:new {
        text = text,
    })
end

-- say what went wrong in a message that stays until dismissed, as a notification is gone in seconds, read or not
function NotifyUtil.error(text)
    UIManager:show(InfoMessage:new {
        text = text,
        icon = "notice-warning",
    })
end

return NotifyUtil
