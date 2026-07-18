local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")

local NotifyUtil = {}

function NotifyUtil.info(message)
    Notification:notify(message, Notification.SOURCE_ALWAYS_SHOW, true)
    UIManager:forceRePaint()
end

return NotifyUtil