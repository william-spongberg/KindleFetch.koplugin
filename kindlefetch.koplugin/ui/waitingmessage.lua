local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local HttpUtil = require("util.httputil")
local _ = require("gettext")

local WaitingMessage = {}

-- say on the message what's being waited for now (see HttpUtil.sayStatus), e.g. which of a site's mirrors is being
-- tried, beneath what it said, so a wait that takes a while doesn't look stuck. rebuild has the message laid out again
-- with its new text. nil keeps the last said, as the message is about to say something else or close, and laying it
-- out again in between would only flash on an e-reader's screen
local function addStatus(message, text, field, rebuild)
    function message:setStatus(status)
        if not status or self.closed or self.cancelled then
            return
        end
        self[field] = text .. "\n\n" .. status
        rebuild(self)
        -- (as it may have grown, the whole screen)
        UIManager:setDirty("all", "ui")
        UIManager:forceRePaint()
    end
    return message
end

-- a message saying what's being waited for, with a Cancel button where the wait can be called off (see
-- HttpUtil.setTrapWidget), rather than any tap calling it off, as a tap may have been meant for something else. once
-- Cancel has been tapped, the message's cancelled is set
function WaitingMessage.new(text)
    if not HttpUtil.canCancel() then
        return addStatus(
            InfoMessage:new {
                text = text,
            },
            text,
            "text",
            function(self)
                self:free()
                self:init()
            end
        )
    end

    local message
    -- (set by Trapper:dismissablePopen while it waits)
    local function cancel()
        if message.cancelled then
            return
        end
        message.cancelled = true
        if message.dismiss_callback then
            message.dismiss_callback()
        end
    end
    message = ButtonDialog:new {
        title = text,
        title_align = "center",
        dismissable = false,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(message)
                        cancel()
                    end,
                },
            },
        },
        -- as KOReader's Home key closes it, which left the wait going, and what it was waiting for shown once over
        tap_close_callback = cancel,
    }
    return addStatus(message, text, "title", function(self)
        self:reinit()
    end)
end

return WaitingMessage
