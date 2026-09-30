local helper = require("helper")
local fixtures = require("fixtures")

describe("BookMenu", function()
    local data_dir, selected, BookMenu, CoverCache

    local function book(n, overrides)
        local b = {
            md5 = "md5-" .. n,
            display_title = "Book " .. n,
            authors = "Author " .. n,
            year = "1990",
            language = "English [en]",
            book_type = "Book (fiction)",
            file_type = "epub",
            file_size = "1.2MB",
            image_url = "https://covers.example/" .. n .. ".jpg",
        }
        for k, v in pairs(overrides or {}) do
            b[k] = v
        end
        return b
    end

    -- the parts of a laid out Menu that BookMenu relies on
    local function newMenu(count)
        local Widget = helper.widgetClass()
        local items = {}
        for n = 1, count do
            table.insert(items, {
                book = book(n),
                callback = function()
                    table.insert(selected, n)
                end,
            })
        end
        table.insert(items, {
            text = "Load more",
            callback = function()
                table.insert(selected, "more")
            end,
        })

        local menu = BookMenu:new {
            item_table = items,
            available_height = 500, -- room for 4 books of 125px
            page = 1,
            dimen = helper.stubs.geometry:new { w = 600, h = 800 },
            inner_dimen = helper.stubs.geometry:new { w = 580, h = 780 },
            item_group = Widget:new {},
            page_info = Widget:new {},
            return_button = Widget:new {},
            content_group = Widget:new {},
            _recalculateDimen = function() end,
            mergeTitleBarIntoLayout = function() end,
            updatePageInfo = function(self, select_number)
                self.select_number = select_number
            end,
        }
        menu:setupItemHeights()
        return menu
    end

    local function cacheCover(md5)
        fixtures.cacheCover(helper, md5)
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        selected = {}
        CoverCache = require("cache.covercache")
        BookMenu = require("ui.bookmenu")
    end)

    after_each(helper.cleanup)

    describe("pages", function()
        it("fit as many books as the screen allows, plus one", function()
            local menu = newMenu(11)
            assert.are.equal(4, menu:getNumberBooksPerPage())
            assert.are.same({ { 1, 2, 3, 4, 5 }, { 6, 7, 8, 9, 10 }, { 11, 12 } }, menu.page_items)
        end)

        it("give every item the height of a cover", function()
            local menu = newMenu(2)
            for _, item in ipairs(menu.item_table) do
                assert.are.equal(100, item.height)
            end
        end)

        it("are empty without any items", function()
            local menu = newMenu(0)
            menu.item_table = {}
            menu:setupItemHeights()
            assert.are.same({ {} }, menu.page_items)
        end)

        it("load covers when turned to", function()
            local menu = newMenu(2)
            local pages = {}
            menu.onPageChange = function(page)
                table.insert(pages, page)
            end

            assert.is_true(menu:onGotoPage(2))
            assert.are.equal(2, menu.page)
            assert.are.same({ 2 }, pages)
        end)

        it("can be turned without a page change callback", function()
            local menu = newMenu(2)
            assert.is_true(menu:onGotoPage(2))
        end)
    end)

    describe("updateItems", function()
        it("shows the books on the current page", function()
            local menu = newMenu(11)
            menu.page = 3
            menu:updateItems()

            assert.are.equal(2, #menu.item_group)
            assert.are.equal("md5-11", menu.item_group[1].entry.book.md5)
            assert.are.equal("Load more", menu.item_group[2].entry.text)
            assert.are.equal(2, #menu.layout)
            assert.are.equal("ui", helper.state.refresh[1])
            assert.are.same({ 600, 800 }, { helper.state.refresh[2].w, helper.state.refresh[2].h })
        end)

        it("selects the current item", function()
            local menu = newMenu(11)
            menu.page = 2
            menu.itemnumber = 7
            menu:updateItems()
            assert.are.equal(2, menu.select_number)
        end)

        it("does nothing for pages that do not exist", function()
            local menu = newMenu(2)
            menu.page = 5
            menu:updateItems()
            assert.are.equal(0, #menu.item_group)
        end)
    end)

    describe("book items", function()
        local function details(widget)
            local content = widget[1][#widget[1]]
            return content[1].text, content[3].text, content[5].text
        end

        it("show the title, authors and details", function()
            local menu = newMenu(1)
            local title, authors, info = details(menu:createBookItemWidget(book(1)))

            assert.are.equal("Book 1", title)
            assert.are.equal("Author 1", authors)
            assert.are.equal("1990 · English [en] · Book (fiction) · epub · 1.2MB", info)
        end)

        -- gray text is hard to read on e-ink screens (#3)
        it("show authors and details in black", function()
            local menu = newMenu(1)
            local content = menu:createBookItemWidget(book(1))[1]
            content = content[#content]

            assert.are.equal("black", content[3].fgcolor)
            assert.are.equal("black", content[5].fgcolor)
        end)

        it("leave out missing details", function()
            local menu = newMenu(1)
            local b = book(1, { year = "" })
            b.file_size = nil
            local _, _, info = details(menu:createBookItemWidget(b))
            assert.are.equal("English [en] · Book (fiction) · epub", info)
        end)

        it("show a placeholder while the cover downloads", function()
            local menu = newMenu(1)
            local item = menu:createBookItemWidget(book(1))[1]

            assert.are.equal(3, #item)
            assert.is_true(item[1][1].is_cover_placeholder)
        end)

        it("show the cover once it has been downloaded", function()
            local menu = newMenu(1)
            cacheCover("md5-1")
            local item = menu:createBookItemWidget(book(1))[1]

            assert.are.equal(3, #item)
            assert.are.equal(CoverCache:getPath("md5-1"), item[1][1].file)
        end)

        it("leave the cover out when the book doesn't have one", function()
            local menu = newMenu(1)
            local b = book(1)
            b.image_url = nil

            assert.are.equal(2, #menu:createBookItemWidget(b)[1])
        end)

        it("leave the cover out when it couldn't be downloaded", function()
            local menu = newMenu(1)
            require("util.curlutil").downloadMultiple = function()
                return nil, nil, nil, "unable to launch curl"
            end
            CoverCache:downloadMultiple({ book(1) }, 6)

            assert.are.equal(2, #menu:createBookItemWidget(book(1))[1])
        end)

        it("leave out placeholders when covers are turned off", function()
            local menu = newMenu(1)
            require("settings.settings"):setShowBookCovers(false)

            assert.are.equal(2, #menu:createBookItemWidget(book(1))[1])
        end)

        it("leave out covers already downloaded when covers are turned off", function()
            local menu = newMenu(1)
            cacheCover("md5-1")
            require("settings.settings"):setShowBookCovers(false)

            assert.are.equal(2, #menu:createBookItemWidget(book(1))[1])
        end)
    end)

    describe("selecting", function()
        it("runs the item's callback", function()
            local menu = newMenu(2)
            menu:onMenuSelect(menu.item_table[2])
            menu:onMenuSelect(menu.item_table[3])
            assert.are.same({ 2, "more" }, selected)
        end)

        it("ignores items without a callback", function()
            assert.is_true(newMenu(0):onMenuSelect({ text = "nothing" }))
        end)

        it("happens when an item is tapped", function()
            local menu = newMenu(1)
            menu:updateItems()
            local item = menu.item_group[1]
            item[1].dimen = helper.stubs.geometry:new { x = 0, y = 0, w = 580, h = 100 }

            assert.is_true(item:onTapSelect())
            assert.are.same({ 1 }, selected)

            helper.state.reader_settings.flash_ui = false
            item:onTapSelect()
            assert.are.same({ 1, 1 }, selected)
        end)

        it("ignores taps before the item has been drawn", function()
            local menu = newMenu(1)
            menu:updateItems()
            assert.is_nil(menu.item_group[1]:onTapSelect())
            assert.are.same({}, selected)
        end)
    end)

    describe("loadCoversForPage", function()
        local requested

        before_each(function()
            requested = nil
            CoverCache.downloadMultiple = function(_, books, parallel_jobs, on_done)
                requested = {
                    parallel_jobs = parallel_jobs,
                    on_done = on_done,
                }
                for _, b in ipairs(books) do
                    table.insert(requested, b.md5)
                end
                return true
            end
        end)

        it("downloads the covers missing from that page in the background", function()
            local menu = newMenu(11)
            cacheCover("md5-7")
            menu.item_table[8].book.image_url = nil

            menu.page = 2
            menu:loadCoversForPage(2)
            assert.are.same({ "md5-6", "md5-9", "md5-10" }, { requested[1], requested[2], requested[3] })
            assert.are.equal(3, #requested)
            assert.are.equal(5, requested.parallel_jobs)
            -- the menu isn't redrawn until they have downloaded
            assert.are.equal(0, #menu.item_group)
        end)

        -- covers another search started downloading still show up once they download
        it("redraws the page showing once covers have downloaded", function()
            local menu = newMenu(11)
            menu.page = 3
            menu:onKindleFetchCoversDownloaded()

            assert.are.equal(2, #menu.item_group)
            assert.are.equal("md5-11", menu.item_group[1].entry.book.md5)
        end)

        it("does nothing when every cover is there", function()
            local menu = newMenu(1)
            cacheCover("md5-1")
            CoverCache.downloadMultiple = function()
                error("should not download")
            end

            menu:loadCoversForPage(1)
            assert.are.equal(0, #menu.item_group)
        end)
    end)
end)
