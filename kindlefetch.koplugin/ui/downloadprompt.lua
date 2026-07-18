local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")
local Button = require("ui/widget/button")
local ImageWidget = require("ui/widget/imagewidget")
local DownloadMgr = require("ui/downloadmgr")
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local LogUtil = require("util.logutil")
local CoverCache = require("cache.covercache")
local _ = require("gettext")

local DownloadPrompt = {}
DownloadPrompt.__index = DownloadPrompt

local CONTENT_WIDTH = Screen:scaleBySize(380)
local COVER_SIZE = Screen:scaleBySize(192)

local function infoLine(label, value)
    return TextBoxWidget:new{
        width = CONTENT_WIDTH - COVER_SIZE - Size.padding.large,
        face = Font:getFace("cfont", 16),
        text = string.format("%s: %s", label, value or "-"),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY
    }
end

function DownloadPrompt.new(book, filepath, on_download)
    local self = setmetatable({}, DownloadPrompt)

    LogUtil.debug("params given to DownloadPrompt", book, filepath)

    self.book = book
    self.filepath = filepath
    self.on_download = on_download
    self.fullscreen_cover_shown = false

    if CoverCache:cacheExists(self.book.md5) then
        local cover_image = ImageWidget:new{
            file = CoverCache:get(self.book.md5),
            width = COVER_SIZE,
            height = COVER_SIZE,
            scale_factor = 0,
            alpha = true
        }

        self.cover = CenterContainer:new{
            dimen = Geom:new{
                w = COVER_SIZE,
                h = COVER_SIZE
            },
            cover_image
        }

        -- make cover tappable for fullscreen
        local parent_ref = self
        self.cover_container = InputContainer:new{}
        self.cover_container.dimen = Geom:new{
            w = COVER_SIZE,
            h = COVER_SIZE
        }
        self.cover_container.ges_events = {
            TapCover = {GestureRange:new{
                ges = "tap",
                range = self.cover_container.dimen
            }}
        }
        function self.cover_container:onTapCover()
            parent_ref:toggleFullscreenCover()
            return true
        end
        self.cover_container[1] = self.cover
        self.cover = self.cover_container
    else
        self.cover = HorizontalSpan:new{
            width = COVER_SIZE
        }
    end

    self.path_widget = Button:new{
        text = self.filepath,
        callback = function()
            self:choosePath()
        end,
        bordersize = Size.border.default,
        padding = Size.padding.default,
        width = CONTENT_WIDTH
    }

    self.download_button = Button:new{
        text = _("Download"),
        callback = function()
            self:close()

            if self.on_download then
                self.on_download(self.filepath)
            end
        end,
        padding = Size.padding.default
    }

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        width = CONTENT_WIDTH + Size.padding.large * 2,
        self:buildContent()
    }

    self.container = CenterContainer:new{
        dimen = Geom:new{
            w = Screen:getWidth(),
            h = Screen:getHeight()
        },
        self.frame
    }

    -- wrap everything in InputContainer to handle outside taps
    local parent_ref = self
    self.outer_container = InputContainer:new{}
    self.outer_container.dimen = Geom:new{
        w = Screen:getWidth(),
        h = Screen:getHeight()
    }
    self.outer_container.ges_events = {
        TapOutside = {GestureRange:new{
            ges = "tap",
            range = self.outer_container.dimen
        }}
    }
    function self.outer_container:onTapOutside(arg, ges)
        if ges.pos:notIntersectWith(parent_ref.frame.dimen) then
            parent_ref:close()
            return true
        end
        return false
    end
    self.outer_container[1] = self.container

    return self
end

function DownloadPrompt:buildContent()
    self.title = TextBoxWidget:new{
        width = CONTENT_WIDTH - COVER_SIZE - Size.padding.large,
        face = Font:getFace("cfont", 20),
        text = self.book.display_title or "",
        bold = true
    }

    self.author = TextBoxWidget:new{
        width = CONTENT_WIDTH - COVER_SIZE - Size.padding.large,
        face = Font:getFace("cfont", 17),
        text = self.book.authors or "",
        fgcolor = Blitbuffer.COLOR_GRAY
    }

    return VerticalGroup:new{HorizontalGroup:new{self.cover, HorizontalSpan:new{
        width = Size.padding.large
    }, VerticalGroup:new{self.title, VerticalSpan:new{
        width = Size.padding.small
    }, self.author, VerticalSpan:new{
        width = Size.padding.default
    }, infoLine(_("Year"), self.book.year), infoLine(_("Language"), self.book.language),
                         infoLine(_("Type"), self.book.book_type), infoLine(_("Format"), self.book.file_type),
                         infoLine(_("Size"), self.book.file_size)}}, VerticalSpan:new{
        width = Size.padding.large
    }, TextBoxWidget:new{
        width = CONTENT_WIDTH,
        face = Font:getFace("cfont", 14),
        text = _("Download to:"),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY
    }, VerticalSpan:new{
        width = Size.padding.small
    }, self.path_widget, VerticalSpan:new{
        width = Size.padding.large
    }, HorizontalGroup:new{
        align = "center",
        self.download_button
    }}
end

function DownloadPrompt:choosePath()
    DownloadMgr:new{
        title = _("Choose download directory"),
        onConfirm = function(dir)
            local filename = self.filepath:match("([^/]+)$") or ""
            self.filepath = dir .. "/" .. filename

            -- recreate button to avoid font issues with new text being set
            self.path_widget = Button:new{
                text = self.filepath,
                callback = function()
                    self:choosePath()
                end,
                bordersize = Size.border.default,
                padding = Size.padding.default,
                width = CONTENT_WIDTH,
                max_width = CONTENT_WIDTH
            }

            -- replace old widget in the layout
            self.frame[1]:free()
            self.frame[1] = self:buildContent()

            UIManager:forceRePaint()
        end
    }:chooseDir()
end

function DownloadPrompt:toggleFullscreenCover()
    if self.fullscreen_cover_shown then
        self:closeFullscreenCover()
    else
        self:showFullscreenCover()
    end
end

function DownloadPrompt:showFullscreenCover()
    if not CoverCache:cacheExists(self.book.md5) then
        return
    end

    self.fullscreen_cover_shown = true

    local fullscreen_image = ImageWidget:new{
        file = CoverCache:get(self.book.md5),
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        scale_factor = 0,
        alpha = true
    }

    self.fullscreen_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{
                w = Screen:getWidth(),
                h = Screen:getHeight()
            },
            fullscreen_image
        }
    }

    local parent_ref = self
    self.fullscreen_container = InputContainer:new{}
    self.fullscreen_container.dimen = Geom:new{
        w = Screen:getWidth(),
        h = Screen:getHeight()
    }
    self.fullscreen_container.ges_events = {
        TapClose = {GestureRange:new{
            ges = "tap",
            range = self.fullscreen_container.dimen
        }}
    }
    function self.fullscreen_container:onTapClose()
        parent_ref:closeFullscreenCover()
        return true
    end
    self.fullscreen_container[1] = self.fullscreen_frame

    UIManager:show(self.fullscreen_container)
    UIManager:setDirty(self.fullscreen_container, "full")
end

function DownloadPrompt:closeFullscreenCover()
    if not self.fullscreen_cover_shown then
        return
    end

    self.fullscreen_cover_shown = false
    UIManager:close(self.fullscreen_container)
    UIManager:setDirty(self.fullscreen_container, "full")
end

function DownloadPrompt:show()
    UIManager:show(self.outer_container)
    UIManager:setDirty(self.outer_container, "full")
end

function DownloadPrompt:close()
    if self.fullscreen_cover_shown then
        self:closeFullscreenCover()
    end
    UIManager:close(self.outer_container)
    UIManager:setDirty(self.outer_container, "full")
end

return DownloadPrompt
