local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local ProgressWidget = require("ui/widget/progresswidget")
local Button = require("ui/widget/button")
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local DownloadProgress = {}
DownloadProgress.__index = DownloadProgress

-- fixed width for the whole widget's contents to prevent overdrawing
local CONTENT_WIDTH = Screen:scaleBySize(280)

-- on_cancel: function called when the user taps Cancel.
function DownloadProgress.new(title, on_cancel)
    local self = setmetatable({}, DownloadProgress)

    self.title = title
    self.cancelled = false
    self.on_cancel = on_cancel
    self.is_visible = true
    self.percentage = 0
    self.status_text = ""
    self:build()

    return self
end

-- create the widgets, again whenever shown after being hidden, as KOReader frees widgets once they're closed
function DownloadProgress:build()
    -- title
    self.text_widget = TextBoxWidget:new {
        text = self.title,
        face = Font:getFace("cfont", 18),
        width = CONTENT_WIDTH,
        alignment = "center",
    }

    -- download percentage
    self.status_widget = TextWidget:new {
        text = self.status_text,
        face = Font:getFace("cfont", 16),
        width = CONTENT_WIDTH,
        alignment = "center",
    }

    self.status_container = CenterContainer:new {
        dimen = Geom:new {
            w = CONTENT_WIDTH,
            h = 25,
        },
        self.status_widget,
    }

    self.bar_widget = ProgressWidget:new {
        width = CONTENT_WIDTH,
        height = Screen:scaleBySize(16),
        percentage = self.percentage,
    }

    -- cancel button
    self.cancel_button = Button:new {
        text = _("Cancel"),
        callback = function()
            self:cancel()
        end,
        padding = Size.padding.default,
    }

    -- hide button
    self.hide_button = Button:new {
        text = _("Hide"),
        callback = function()
            self:toggleVisibility()
        end,
        padding = Size.padding.default,
    }

    -- button group
    self.button_group = HorizontalGroup:new {
        align = "center",
        self.cancel_button,
        HorizontalSpan:new {
            width = Size.padding.default,
        },
        self.hide_button,
    }

    self.frame = FrameContainer:new {
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        width = CONTENT_WIDTH + Size.padding.large * 2,

        VerticalGroup:new {
            align = "center",
            self.text_widget,
            VerticalSpan:new {
                width = Size.padding.default,
            },
            self.bar_widget,
            VerticalSpan:new {
                width = Size.padding.small,
            },
            self.status_container,
            VerticalSpan:new {
                width = Size.padding.large,
            },
            self.button_group,
        },
    }

    self.container = CenterContainer:new {
        dimen = Geom:new {
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        },
        self.frame,
    }
end

-- show the widget, refreshing only the part of the screen it takes up, as a download refreshes it twice a second
-- and an e-ink screen is slow to
function DownloadProgress:_show()
    UIManager:show(self.container)
    UIManager:setDirty(self.container, function()
        return "ui", self.frame.dimen
    end)
end

-- take the widget off the screen, refreshing only where it was
function DownloadProgress:_close()
    local frame = self.frame
    UIManager:close(self.container)
    UIManager:setDirty(nil, function()
        return "ui", frame.dimen
    end)
end

function DownloadProgress:show()
    if not self.is_visible then
        return
    end
    self:_show()
end

-- toggle visibility of the progress widget
function DownloadProgress:toggleVisibility()
    self.is_visible = not self.is_visible
    if self.is_visible then
        self:build()
        self:_show()
    else
        self:_close()
    end
end

-- update percentage text and force repaint
function DownloadProgress:update(percentage, status_text)
    if self.cancelled then
        return
    end

    -- keep track of progress while hidden, for when it's shown again
    local changed = percentage ~= self.percentage or (status_text ~= nil and status_text ~= self.status_text)
    self.percentage = percentage
    if status_text then
        self.status_text = status_text
    end
    -- nothing to redraw when it's off screen, or says the same as it did
    if not self.is_visible or not changed then
        return
    end

    self.bar_widget.percentage = percentage
    if status_text then
        self.status_widget:setText(status_text)
    end
    UIManager:setDirty(self.container, function()
        return "ui", self.frame.dimen
    end)
end

function DownloadProgress:cancel()
    -- prevent double cancel
    if self.cancelled then
        return
    end
    self.cancelled = true

    -- trigger cancel function if exists
    if self.on_cancel then
        self.on_cancel()
    end

    self:close()
end

function DownloadProgress:close()
    if not self.is_visible then
        return
    end
    self:_close()
end

return DownloadProgress
