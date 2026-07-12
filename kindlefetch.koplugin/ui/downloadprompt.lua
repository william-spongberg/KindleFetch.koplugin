local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Button = require("ui/widget/button")
local ImageWidget = require("ui/widget/imagewidget")
local DownloadMgr = require("ui/downloadmgr")
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local DownloadPrompt = {}
DownloadPrompt.__index = DownloadPrompt

local CONTENT_WIDTH = Screen:scaleBySize(380)
local COVER_SIZE = Screen:scaleBySize(192)

local function infoLine(label, value)
    return TextBoxWidget:new{
        width = CONTENT_WIDTH - COVER_SIZE - Size.padding.large,
        face = Font:getFace("cfont", 16),
        text = string.format("%s: %s", label, value or "-")
    }
end

function DownloadPrompt.new(book, filepath, on_download)
    local self = setmetatable({}, DownloadPrompt)

    logger.dbg("KindleFetch: params given to DownloadPrompt", book, filepath)

    self.book = book
    self.filepath = filepath
    self.on_download = on_download

    if book.image_path then
        self.cover = CenterContainer:new{
            dimen = Geom:new{
                w = COVER_SIZE,
                h = COVER_SIZE
            },
            ImageWidget:new{
                file = self.book.image_path,
                width = COVER_SIZE,
                height = COVER_SIZE,
                scale_factor = 0,
                alpha = true -- use this to avoid dark images
            }
        }
    else
        self.cover = HorizontalSpan:new{
            width = COVER_SIZE
        }
    end

    self.title = TextBoxWidget:new{
        width = CONTENT_WIDTH - COVER_SIZE - Size.padding.large,
        face = Font:getFace("cfont", 20),
        text = self.book.title or ""
    }

    self.author = TextBoxWidget:new{
        width = CONTENT_WIDTH - COVER_SIZE - Size.padding.large,
        face = Font:getFace("cfont", 17),
        text = self.book.author or ""
    }

    self.path_widget = TextBoxWidget:new{
        width = CONTENT_WIDTH,
        face = Font:getFace("cfont", 16),
        text = self.filepath
    }

    self.choose_button = Button:new{
        text = _("Choose Folder"),
        callback = function()
            DownloadMgr:new{
                title = _("Choose download directory"),
                onConfirm = function(dir)
                    local filename = self.filepath:match("([^/]+)$") or ""

                    self.filepath = dir .. "/" .. filename
                    self.path_widget:setText(self.filepath)

                    UIManager:forceRePaint()
                end
            }:chooseDir()
        end
    }

    self.download_button = Button:new{
        text = _("Download"),
        callback = function()
            self:close()

            if self.on_download then
                self.on_download(self.filepath)
            end
        end
    }

    self.cancel_button = Button:new{
        text = _("Cancel"),
        callback = function()
            self:close()
        end
    }

    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        padding = Size.padding.large,
        width = CONTENT_WIDTH + Size.padding.large * 2,

        VerticalGroup:new{HorizontalGroup:new{self.cover, HorizontalSpan:new{
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
            face = Font:getFace("cfont", 16),
            text = _("Save to:")
        }, self.path_widget, VerticalSpan:new{
            width = Size.padding.small
        }, self.choose_button, VerticalSpan:new{
            width = Size.padding.large
        }, HorizontalGroup:new{
            align = "center",
            self.cancel_button,
            HorizontalSpan:new{
                width = Size.padding.default
            },
            self.download_button
        }}
    }

    self.container = CenterContainer:new{
        dimen = Geom:new{
            w = Screen:getWidth(),
            h = Screen:getHeight()
        },
        self.frame
    }

    return self
end

function DownloadPrompt:show()
    UIManager:show(self.container)
    UIManager:setDirty(self.container, "full")
end

function DownloadPrompt:close()
    UIManager:close(self.container)
    UIManager:setDirty(self.container, "full")
end

return DownloadPrompt
