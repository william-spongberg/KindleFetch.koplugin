local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local HttpUtil = require("util.httputil")
local _ = require("gettext")

local WaitingMessage = {}

-- a message saying what's being waited for, with a Cancel button where the wait can be called off (see
-- HttpUtil.setTrapWidget), rather than any tap calling it off, as a tap may have been meant for something else. once
-- Cancel has been tapped, the message's cancelled is set
function WaitingMessage.new(text)
    if not HttpUtil.canCancel() then
        return InfoMessage:new {
            text = text,
        }
    end

    local message
    message = ButtonDialog:new {
        title = text,
        title_align = "center",
        dismissable = false,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        message.cancelled = true
                        UIManager:close(message)
                        -- set by Trapper:dismissablePopen while it waits
                        if message.dismiss_callback then
                            message.dismiss_callback()
                        end
                    end,
                },
            },
        },
    }
    return message
end

return WaitingMessage
