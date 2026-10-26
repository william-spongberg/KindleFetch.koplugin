local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local HttpUtil = require("util.httputil")
local _ = require("gettext")

local WaitingMessage = {}

-- say what's waited for under the text (see HttpUtil.sayStatus); nil keeps the last, as redrawing would flash
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

-- a message saying what's waited for, with Cancel where it can be called off, as taps may be meant for something else
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
