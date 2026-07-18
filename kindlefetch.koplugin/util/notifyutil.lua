local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")

local NotifyUtil = {}

function NotifyUtil.info(...)
    Notification:notify(..., Notification.SOURCE_ALWAYS_SHOW, true)
    UIManager:forceRePaint()
end

return NotifyUtil