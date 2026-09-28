local H = require("helpers")

describe("Searching", function()
    after_each(H.closeAll)

    it("finds books on Library Genesis", function()
        local menu = H.search(H.SEARCH_QUERY)
        H.shot("search-results")

        -- enough to fill the page, even though most of Library Genesis' first results are in other languages
        local books = H.books(menu)
        assert(#books >= 10, "only found " .. #books .. " books")
        local preferred = {
            epub = true,
            pdf = true,
            cbr = true,
            cbz = true
        }
        for _, book in ipairs(books) do
            assert(book.md5:match("^%x+$") and #book.md5 == 32, "bad md5 " .. tostring(book.md5))
            assert(book.title ~= "", "book without a title")
            assert(preferred[book.file_type], book.title .. " is a " .. book.file_type)
        end
        H.eq("Load more", menu.item_table[#menu.item_table].text, "last entry")
    end)

    it("shows book covers once they have downloaded", function()
        local CoverCache = require("cache.covercache")
        local menu = H.search(H.SEARCH_QUERY)

        local on_first_page = {}
        for _, index in ipairs(menu.page_items[1]) do
            local book = menu.item_table[index].book
            if book and book.image_url then
                table.insert(on_first_page, book)
            end
        end
        assert(#on_first_page > 0, "no covers to download on the first page")

        -- covers download in the background, then the menu is redrawn with them
        local cover = H.waitFor("covers to be shown", 90, function()
            return H.find(function(widget)
                return widget.file and widget.file:find("kindlefetch_covers", 1, true)
            end, menu)
        end)
        assert(CoverCache:cacheExists(on_first_page[1].md5) or cover, "covers weren't cached")
        H.shot("search-covers")
    end)

    it("loads more books", function()
        local plugin = H.plugin()
        local menu = H.search(H.SEARCH_QUERY)
        local count = #H.books(menu)

        H.tapMenuEntry(menu, function(item)
            return item.text == "Load more"
        end)
        local more = H.waitFor("more books", 120, function()
            return plugin.books_menu ~= menu and H.isShown(plugin.books_menu) and plugin.books_menu
        end)
        assert(#H.books(more) > count, "no more books were added")
        H.shot("search-more")
    end)
end)
