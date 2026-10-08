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
local ButtonTable = require("ui/widget/buttontable")
local TextWidget = require("ui/widget/textwidget")
local ImageWidget = require("ui/widget/imagewidget")
local Notification = require("ui/widget/notification")
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
-- the title and the book's details in black, the rest in greys that are still dark enough to read on e-ink (#3)
local AUTHOR_COLOR = Blitbuffer.COLOR_GRAY_4
local LABEL_COLOR = Blitbuffer.COLOR_GRAY_6
-- the most lines a long title, a long list of authors and the name the book is saved as can take up, so the
-- prompt always fits on the screen
local TITLE_MAX_LINES = 4
local AUTHOR_MAX_LINES = 2
local FILENAME_MAX_LINES = 2
local TITLE_FACE = Font:getFace("cfont", 20)
local AUTHOR_FACE = Font:getFace("cfont", 17)
local DETAIL_FACE = Font:getFace("cfont", 15)
local LABEL_FACE = Font:getFace("cfont", 14)

function DownloadPrompt.new(book, filepath, on_download)
    local self = setmetatable({}, DownloadPrompt)

    LogUtil.debug("params given to DownloadPrompt", book, filepath)

    self.book = book
    self.filepath = filepath
    self.on_download = on_download
    self.fullscreen_cover_shown = false

    -- wrap everything in InputContainer to handle outside taps
    local parent_ref = self
    self.outer_container = InputContainer:new {}
    self.outer_container.dimen = Geom:new {
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.outer_container.ges_events = {
        TapOutside = {
            GestureRange:new {
                ges = "tap",
                range = self.outer_container.dimen,
            },
        },
    }
    function self.outer_container.onTapOutside(_, _, ges)
        if ges.pos:notIntersectWith(parent_ref.frame.dimen) then
            parent_ref:close()
            return true
        end
        return false
    end
    -- show the cover once it has downloaded, or take its placeholder away if it couldn't be, but not for other
    -- books' covers, which can arrive several times a second while search results are open
    function self.outer_container.onKindleFetchCoversDownloaded()
        if parent_ref:coverState() ~= parent_ref.cover_state then
            parent_ref:refreshCover()
        end
    end

    self:buildCover()
    self:buildPathButton()

    -- as in KOReader's own dialogs
    self.button_table = ButtonTable:new {
        width = CONTENT_WIDTH + Size.padding.large * 2,
        zero_sep = true,
        show_parent = self.outer_container,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "cancel",
                    callback = function()
                        self:close()
                    end,
                },
                {
                    text = _("Download"),
                    id = "download",
                    callback = function()
                        self:download()
                    end,
                },
            },
        },
    }

    self.body = FrameContainer:new {
        bordersize = 0,
        padding = Size.padding.large,
        self:buildContent(),
    }

    self.frame = FrameContainer:new {
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = 0,
        VerticalGroup:new {
            align = "left",
            self.body,
            self.button_table,
        },
    }

    self.container = CenterContainer:new {
        dimen = Geom:new {
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        },
        self.frame,
    }
    self.outer_container[1] = self.container

    return self
end

function DownloadPrompt:download()
    self:close()

    if self.on_download then
        self.on_download(self.filepath)
    end
end

-- the full-size cover once it has downloaded (after the cover was first enlarged), otherwise the thumbnail from
-- the search results
function DownloadPrompt:coverFile()
    return CoverCache:getFullSize(self.book) or CoverCache:get(self.book.md5)
end

-- which of its covers the book has, and which are still coming, to tell when that has changed
function DownloadPrompt:coverState()
    return string.format(
        "%s|%s|%s",
        tostring(self:coverFile()),
        tostring(CoverCache:isComing(self.book)),
        tostring(CoverCache:isFullSizeComing(self.book))
    )
end

-- the book's cover (which can be tapped to show it fullscreen), a placeholder while it downloads, or nothing
function DownloadPrompt:buildCover()
    self.cover = nil
    self.cover_container = nil
    self.cover_state = self:coverState()

    local cover_file = self:coverFile()
    if cover_file then
        local cover_image = ImageWidget:new {
            file = cover_file,
            width = COVER_SIZE,
            height = COVER_SIZE,
            scale_factor = 0,
            alpha = true,
        }

        -- make cover tappable for fullscreen
        local parent_ref = self
        self.cover_container = InputContainer:new {}
        self.cover_container.dimen = Geom:new {
            w = COVER_SIZE,
            h = COVER_SIZE,
        }
        self.cover_container.ges_events = {
            TapCover = {
                GestureRange:new {
                    ges = "tap",
                    range = self.cover_container.dimen,
                },
            },
        }
        function self.cover_container:onTapCover()
            parent_ref:toggleFullscreenCover()
            return true
        end
        self.cover_container[1] = CenterContainer:new {
            dimen = Geom:new {
                w = COVER_SIZE,
                h = COVER_SIZE,
            },
            cover_image,
        }
        self.cover = self.cover_container
    elseif CoverCache:isComing(self.book) then
        self.cover = CenterContainer:new {
            dimen = Geom:new {
                w = COVER_SIZE,
                h = COVER_SIZE,
            },
            CoverPlaceholder.new(math.floor(COVER_SIZE * 2 / 3), COVER_SIZE),
        }
    end
end

function DownloadPrompt:refreshCover()
    self:buildCover()
    self.body[1] = self:buildContent()
    UIManager:setDirty(self.outer_container, "ui")

    -- stop saying the full-size cover is loading once it's arrived, or couldn't be downloaded
    if not CoverCache:isFullSizeComing(self.book) then
        self:closeLoadingNotice()
    end

    -- show the full-size cover fullscreen too, if it arrived while the thumbnail was showing
    if self.fullscreen_cover_shown and self.fullscreen_file ~= self:coverFile() then
        self:closeFullscreenCover()
        self:showFullscreenCover()
    end
end

-- the book's details that it has, as label and value pairs
function DownloadPrompt:details()
    local book = self.book
    local details = {}
    local function add(label, value)
        if value and value ~= "" then
            table.insert(details, { label, value })
        end
    end

    local format = {}
    if book.file_type and book.file_type ~= "" then
        table.insert(format, book.file_type:upper())
    end
    if book.file_size and book.file_size ~= "" then
        table.insert(format, book.file_size)
    end
    add(_("Format"), table.concat(format, " · "))
    add(_("Language"), book.language)
    add(_("Year"), book.year)
    add(_("Type"), book.book_type)
    return details
end

-- the book's details in two columns, their labels in grey
function DownloadPrompt:buildDetails(width)
    local details = self:details()

    local label_width = 0
    for _, detail in ipairs(details) do
        local label = TextWidget:new {
            text = detail[1],
            face = LABEL_FACE,
        }
        label_width = math.max(label_width, label:getSize().w)
        label:free()
    end
    local gap = Size.padding.large

    local rows = VerticalGroup:new {
        align = "left",
    }
    for i, detail in ipairs(details) do
        if i > 1 then
            table.insert(
                rows,
                VerticalSpan:new {
                    width = Size.padding.small,
                }
            )
        end
        table.insert(
            rows,
            HorizontalGroup:new {
                align = "center",
                TextBoxWidget:new {
                    width = label_width + Size.padding.small,
                    face = LABEL_FACE,
                    text = detail[1],
                    fgcolor = LABEL_COLOR,
                },
                HorizontalSpan:new {
                    width = gap,
                },
                TextBoxWidget:new {
                    width = width - label_width - Size.padding.small - gap,
                    face = DETAIL_FACE,
                    text = detail[2],
                    fgcolor = Blitbuffer.COLOR_BLACK,
                },
            }
        )
    end
    return rows
end

-- text over as many lines as it needs, up to max_lines, ending in an ellipsis if there's more of it than that
local function wrappedText(max_lines, options)
    local function build(height)
        return TextBoxWidget:new {
            width = options.width,
            face = options.face,
            text = options.text,
            bold = options.bold,
            fgcolor = options.fgcolor,
            height = height,
            height_adjust = height and true or nil,
            height_overflow_show_ellipsis = height and true or nil,
        }
    end

    local widget = build()
    if widget:getVisLineCount() > max_lines then
        local height = widget:getLineHeight() * max_lines
        widget:free()
        widget = build(height)
    end
    return widget
end

function DownloadPrompt:buildContent()
    -- the book's details take the whole width when there's no cover
    local text_width = self.cover and CONTENT_WIDTH - COVER_SIZE - Size.padding.large or CONTENT_WIDTH

    self.title = wrappedText(TITLE_MAX_LINES, {
        width = text_width,
        face = TITLE_FACE,
        text = self.book.display_title or "",
        bold = true,
    })

    self.author = wrappedText(AUTHOR_MAX_LINES, {
        width = text_width,
        face = AUTHOR_FACE,
        text = self.book.authors or "",
        fgcolor = AUTHOR_COLOR,
    })

    self.details_group = self:buildDetails(text_width)

    local about = VerticalGroup:new {
        align = "left",
        self.title,
        VerticalSpan:new {
            width = Size.padding.small,
        },
        self.author,
        VerticalSpan:new {
            width = Size.padding.large,
        },
        self.details_group,
    }

    self.header = about
    if self.cover then
        self.header = HorizontalGroup:new {
            align = "top",
            self.cover,
            HorizontalSpan:new {
                width = Size.padding.large,
            },
            about,
        }
    end

    -- the name it's saved as, on its own, as a long folder would leave no room for it beside it
    self.filename_widget = wrappedText(FILENAME_MAX_LINES, {
        width = CONTENT_WIDTH,
        face = DETAIL_FACE,
        text = self:filename(),
        fgcolor = Blitbuffer.COLOR_BLACK,
    })

    return VerticalGroup:new {
        align = "left",
        self.header,
        VerticalSpan:new {
            width = Size.padding.large * 2,
        },
        TextBoxWidget:new {
            width = CONTENT_WIDTH,
            face = LABEL_FACE,
            text = _("Download to"),
            fgcolor = LABEL_COLOR,
        },
        VerticalSpan:new {
            width = Size.padding.small,
        },
        self.path_widget,
        VerticalSpan:new {
            width = Size.padding.small,
        },
        self.filename_widget,
    }
end

-- the folder the book is saved in, and the name it's saved as
function DownloadPrompt:folder()
    local folder = self.filepath:match("^(.*)/[^/]*$")
    return folder ~= "" and folder or "/"
end
function DownloadPrompt:filename()
    return self.filepath:match("([^/]+)$") or ""
end

-- the folder the book is downloaded to, which can be tapped to choose another
function DownloadPrompt:buildPathButton()
    self.path_widget = Button:new {
        text = self:folder(),
        callback = function()
            self:choosePath()
        end,
        text_font_size = 16,
        text_font_bold = false,
        bordersize = Size.border.thin,
        radius = Size.radius.button,
        padding = Size.padding.default,
        width = CONTENT_WIDTH,
        max_width = CONTENT_WIDTH,
    }
end

function DownloadPrompt:choosePath()
    DownloadMgr:new {
        title = _("Choose download directory"),
        onConfirm = function(dir)
            self.filepath = dir .. "/" .. self:filename()

            -- recreate the button rather than setting its text, which keeps the old text's size
            self:buildPathButton()
            self.body[1]:free()
            self.body[1] = self:buildContent()

            UIManager:forceRePaint()
        end,
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
    local loading_full_size = CoverCache:downloadFullSize(self.book)

    local fullscreen_image = ImageWidget:new {
        file = cover_file,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        scale_factor = 0,
        alpha = true,
    }

    self.fullscreen_frame = FrameContainer:new {
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        CenterContainer:new {
            dimen = Geom:new {
                w = Screen:getWidth(),
                h = Screen:getHeight(),
            },
            fullscreen_image,
        },
    }

    local parent_ref = self
    self.fullscreen_container = InputContainer:new {}
    self.fullscreen_container.dimen = Geom:new {
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.fullscreen_container.ges_events = {
        TapClose = {
            GestureRange:new {
                ges = "tap",
                range = self.fullscreen_container.dimen,
            },
        },
    }
    function self.fullscreen_container:onTapClose()
        parent_ref:closeFullscreenCover()
        return true
    end
    self.fullscreen_container[1] = self.fullscreen_frame

    UIManager:show(self.fullscreen_container)
    UIManager:setDirty(self.fullscreen_container, "full")
    -- over the thumbnail until the full-size cover arrives, so it's clear something is happening (rather than closing
    -- after a couple of seconds like other notifications)
    if loading_full_size then
        self.loading_notice = Notification:new {
            text = _("Loading full-size cover..."),
            timeout = false,
        }
        UIManager:show(self.loading_notice)
    end
end

function DownloadPrompt:closeLoadingNotice()
    if self.loading_notice then
        UIManager:close(self.loading_notice)
        self.loading_notice = nil
    end
end

function DownloadPrompt:closeFullscreenCover()
    if not self.fullscreen_cover_shown then
        return
    end

    self.fullscreen_cover_shown = false
    self:closeLoadingNotice()
    UIManager:close(self.fullscreen_container)
    UIManager:setDirty(self.fullscreen_container, "full")
end

-- only the part of the screen the prompt takes up is refreshed, as KOReader's own dialogs do
function DownloadPrompt:show()
    UIManager:show(self.outer_container)
    UIManager:setDirty(self.outer_container, function()
        return "ui", self.frame.dimen
    end)
end

function DownloadPrompt:close()
    if self.fullscreen_cover_shown then
        self:closeFullscreenCover()
    end
    UIManager:close(self.outer_container)
    UIManager:setDirty(nil, function()
        return "ui", self.frame.dimen
    end)
end

return DownloadPrompt
