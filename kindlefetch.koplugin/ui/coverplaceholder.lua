local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local IconWidget = require("ui/widget/iconwidget")
local Geom = require("ui/geometry")

-- A grey, book shaped box shown in place of a book's cover while it downloads.
local CoverPlaceholder = {}

function CoverPlaceholder.new(width, height)
    local icon_size = math.floor(width / 2)

    return FrameContainer:new{
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        bordersize = 0,
        padding = 0,
        is_cover_placeholder = true,
        CenterContainer:new{
            dimen = Geom:new{
                w = width,
                h = height
            },
            IconWidget:new{
                icon = "book.opened",
                width = icon_size,
                height = icon_size,
                alpha = true
            }
        }
    }
end

return CoverPlaceholder
