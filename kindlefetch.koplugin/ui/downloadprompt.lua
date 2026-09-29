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
local CoverPlaceholder = require("ui.coverplaceholder")
local _ = require("gettext")

local DownloadPrompt = {}
DownloadPrompt.__index = DownloadPrompt

local CONTENT_WIDTH = Screen:scaleBySize(380)
local COVER_SIZE = Screen:scaleBySize(192)

local function infoLine(label, value, width)
    return TextBoxWidget:new{
        width = width,
        face = Font:getFace("cfont", 16),
        text = string.format("%s: %s", label, value or "-"),
        fgcolor = Blitbuffer.COLOR_BLACK
    }
end

function DownloadPrompt.new(book, filepath, on_download)
    local self = setmetatable({}, DownloadPrompt)

    LogUtil.debug("params given to DownloadPrompt", book, filepath)

    self.book = book
    self.filepath = filepath
    self.on_download = on_download
    self.fullscreen_cover_shown = false

    self:buildCover()

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
    -- show the cover once it has downloaded, or take its placeholder away if it couldn't be
    function self.outer_container:onKindleFetchCoversDownloaded()
        parent_ref:refreshCover()
    end
    self.outer_container[1] = self.container

    return self
end

-- the full-size cover once it has downloaded (after the cover was first enlarged), otherwise the thumbnail from
-- the search results
function DownloadPrompt:coverFile()
    return CoverCache:getFullSize(self.book) or CoverCache:get(self.book.md5)
end

-- the book's cover (which can be tapped to show it fullscreen), a placeholder while it downloads, or nothing
function DownloadPrompt:buildCover()
    self.cover = nil
    self.cover_container = nil

    local cover_file = self:coverFile()
    if cover_file then
        local cover_image = ImageWidget:new{
            file = cover_file,
            width = COVER_SIZE,
            height = COVER_SIZE,
            scale_factor = 0,
            alpha = true
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
        self.cover_container[1] = CenterContainer:new{
            dimen = Geom:new{
                w = COVER_SIZE,
                h = COVER_SIZE
            },
            cover_image
        }
        self.cover = self.cover_container
    elseif CoverCache:isComing(self.book) then
        self.cover = CenterContainer:new{
            dimen = Geom:new{
                w = COVER_SIZE,
                h = COVER_SIZE
            },
            CoverPlaceholder.new(math.floor(COVER_SIZE * 2 / 3), COVER_SIZE)
        }
    end
end

function DownloadPrompt:refreshCover()
    self:buildCover()
    self.frame[1] = self:buildContent()
    UIManager:setDirty(self.outer_container, "ui")

    -- show the full-size cover fullscreen too, if it arrived while the thumbnail was showing
    if self.fullscreen_cover_shown and self.fullscreen_file ~= self:coverFile() then
        self:closeFullscreenCover()
        self:showFullscreenCover()
    end
end

function DownloadPrompt:buildContent()
    -- the book's details take the whole width when there's no cover
    local text_width = self.cover and CONTENT_WIDTH - COVER_SIZE - Size.padding.large or CONTENT_WIDTH

    self.title = TextBoxWidget:new{
        width = text_width,
        face = Font:getFace("cfont", 20),
        text = self.book.display_title or "",
        bold = true
    }

    self.author = TextBoxWidget:new{
        width = text_width,
        face = Font:getFace("cfont", 17),
        text = self.book.authors or "",
        fgcolor = Blitbuffer.COLOR_BLACK
    }

    local details = VerticalGroup:new{self.title, VerticalSpan:new{
        width = Size.padding.small
    }, self.author, VerticalSpan:new{
        width = Size.padding.default
    }, infoLine(_("Year"), self.book.year, text_width), infoLine(_("Language"), self.book.language, text_width),
                                      infoLine(_("Type"), self.book.book_type, text_width),
                                      infoLine(_("Format"), self.book.file_type, text_width),
                                      infoLine(_("Size"), self.book.file_size, text_width)}

    local header = details
    if self.cover then
        header = HorizontalGroup:new{self.cover, HorizontalSpan:new{
            width = Size.padding.large
        }, details}
    end

    return VerticalGroup:new{header, VerticalSpan:new{
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
    local cover_file = self:coverFile()
    if not cover_file then
        return
    end

    self.fullscreen_cover_shown = true
    self.fullscreen_file = cover_file
    -- only get the full-size cover once it's wanted, showing the thumbnail until it arrives
    CoverCache:downloadFullSize(self.book)

    local fullscreen_image = ImageWidget:new{
        file = cover_file,
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
