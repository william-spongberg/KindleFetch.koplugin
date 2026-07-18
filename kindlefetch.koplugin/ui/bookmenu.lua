local Menu = require("ui/widget/menu")
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local CenterContainer = require("ui/widget/container/centercontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local ImageWidget = require("ui/widget/imagewidget")
local Blitbuffer = require("ffi/blitbuffer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local UIManager = require("ui/uimanager")
local StringUtil = require("util.stringutil")
local Screen = require("device").screen
local TextWidget = require("ui/widget/textwidget")
local CoverCache = require("cache.covercache")

-- constants
local COVER_SIZE = Screen:scaleBySize(100)

local function formatBookDetails(book)
    local details = {}

    local function addBookDetail(detail)
        if StringUtil.assertValidString(detail) then
            table.insert(details, detail)
        end
    end

    addBookDetail(book.year)
    addBookDetail(book.language)
    addBookDetail(book.book_type)
    addBookDetail(book.file_type)
    addBookDetail(book.file_size)

    return table.concat(details, " · ")
end

local BookMenuItem = InputContainer:extend{}

function BookMenuItem:init()
    self.ges_events = {
        TapSelect = {GestureRange:new{
            ges = "tap",
            range = self.dimen
        }}
    }
end

function BookMenuItem:onTapSelect(arg, ges)
    if not self[1].dimen then
        return
    end

    if G_reader_settings:isFalse("flash_ui") then
        self.menu:onMenuSelect(self.entry)
    else
        self[1].invert = true
        UIManager:widgetInvert(self[1], self[1].dimen.x, self[1].dimen.y)
        UIManager:setDirty(nil, "fast", self[1].dimen)
        UIManager:forceRePaint()
        UIManager:yieldToEPDC()

        self[1].invert = false
        UIManager:widgetInvert(self[1], self[1].dimen.x, self[1].dimen.y)
        UIManager:setDirty(nil, "ui", self[1].dimen)

        self.menu:onMenuSelect(self.entry)
        UIManager:forceRePaint()
    end
    return true
end

local BookMenu = Menu:extend{}

function BookMenu:onMenuSelect(entry)
    if entry and entry.callback then
        return entry.callback()
    end
    return true
end

function BookMenu:createBookItemWidget(book)
    -- cover image (if exists)
    local cover_widget
    if CoverCache:cacheExists(book.md5) then
        cover_widget = ImageWidget:new{
            file = CoverCache:get(book.md5),
            width = COVER_SIZE,
            height = COVER_SIZE,
            scale_factor = 0,
            alpha = true
        }
    end

    -- title
    local title_widget = TextBoxWidget:new{
        width = self.dimen.w,
        face = Font:getFace("cfont", 18),
        text = book.display_title or "",
        bold = true
    }

    -- authors
    local author_widget = TextBoxWidget:new{
        width = self.dimen.w,
        face = Font:getFace("cfont", 15),
        text = book.authors or "",
        fgcolor = Blitbuffer.COLOR_GRAY
    }

    -- book details (year, language, type, format, size)
    local details_widget = TextBoxWidget:new{
        width = self.dimen.w,
        face = Font:getFace("cfont", 14),
        text = formatBookDetails(book),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY
    }

    -- main content group
    local content_group = VerticalGroup:new{title_widget, VerticalSpan:new{
        width = Size.padding.small
    }, author_widget, VerticalSpan:new{
        width = Size.padding.small
    }, details_widget}

    -- combine cover and content horizontally
    local book_item
    if cover_widget then
        book_item = HorizontalGroup:new{CenterContainer:new{
            dimen = Geom:new{
                w = COVER_SIZE * 2 / 3,
                h = COVER_SIZE
            },
            cover_widget
        }, HorizontalSpan:new{
            width = Size.padding.large
        }, content_group}
    else
        book_item = HorizontalGroup:new{HorizontalSpan:new{
            width = Size.padding.large
        }, content_group}
    end

    -- wrap in frame
    local framed_item = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = Size.padding.default,
        book_item
    }

    return framed_item
end

function BookMenu:onGotoPage(page)
    -- Call parent implementation
    local result = Menu.onGotoPage(self, page)

    -- Trigger page change callback
    if self.onPageChange then
        self.onPageChange(page)
    end

    return result
end

function BookMenu:getNumberBooksPerPage()
    return math.floor(self.available_height / (COVER_SIZE * 5 / 4))
end

function BookMenu:setupItemHeights()
    if #self.item_table == 0 then
        self.page_items = {{}}
        return
    end

    self.page_items = {}
    local items = {}
    local items_per_page = self:getNumberBooksPerPage()

    for i = 1, #self.item_table do
        local item = self.item_table[i]
        item.height = COVER_SIZE

        table.insert(items, i)

        if #items > items_per_page then
            table.insert(self.page_items, items)
            items = {}
            current_y = 0
        end
    end

    -- Add remaining items as final page
    if #items > 0 then
        table.insert(self.page_items, items)
    end
end

function BookMenu:updateItems(select_number, no_recalculate_dimen)
    local old_dimen = self.dimen and self.dimen:copy()
    self.layout = {}
    self.item_group:clear()
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    self:_recalculateDimen(no_recalculate_dimen)

    if not self.page_items or not self.page_items[self.page] then
        return
    end

    local items_nb = #self.page_items[self.page]

    for idx = 1, items_nb do
        local index = self.page_items[self.page][idx]
        local item = self.item_table[index]
        if item == nil then
            break
        end

        item.idx = index

        if index == self.itemnumber then
            select_number = idx
        end

        local item_widget
        if item.book then
            item_widget = self:createBookItemWidget(item.book)
        elseif item.text then
            local text_widget = TextWidget:new{
                text = item.text,
                face = Font:getFace("cfont", 20),
                bold = true
            }

            item_widget = FrameContainer:new{
                background = Blitbuffer.COLOR_WHITE,
                bordersize = 0,
                CenterContainer:new{
                    dimen = Geom:new{
                        w = self.dimen.w,
                        h = item.height - 2 * Size.padding.default
                    },
                    text_widget
                }
            }
        end

        if item_widget then
            local menu_item = BookMenuItem:new{
                menu = self,
                entry = item,
                dimen = Geom:new{
                    w = self.inner_dimen.w,
                    h = item.height
                },
                item_widget
            }
            table.insert(self.item_group, menu_item)
            table.insert(self.layout, {menu_item})
        end
    end

    self:updatePageInfo(select_number)
    self:mergeTitleBarIntoLayout()

    UIManager:setDirty(self.show_parent, function()
        local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
        return "ui", refresh_dimen
    end)
end

return BookMenu
