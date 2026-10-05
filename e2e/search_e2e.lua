local H = require("helpers")

describe("Searching", function()
    after_each(H.closeAll)

    it("falls back to other mirrors when some fail, and forgets the ones that failed", function()
        local broken = H.breakMirrors()

        local menu = H.search(H.SEARCH_QUERY)
        assert(#H.books(menu) > 0, "no books found")
        for _, mirror in ipairs(require("api.urlapi"):getLibgenUrls()) do
            for _, url in ipairs(broken) do
                assert(mirror ~= url, url .. " is still one of the mirrors")
            end
        end
    end)

    it("finds books on Library Genesis", function()
        local menu = H.search(H.SEARCH_QUERY)
        H.shot("search-results")

        -- enough to fill the page, even though most of Library Genesis' first results are in other languages
        local books = H.books(menu)
        assert(#books >= 10, "only found " .. #books .. " books")
        local preferred = {}
        for _, file_type in ipairs(require("settings.settings"):getPreferredFileTypes()) do
            preferred[file_type] = true
        end
        for _, book in ipairs(books) do
            assert(book.md5:match("^%x+$") and #book.md5 == 32, "bad md5 " .. tostring(book.md5))
            assert(book.title ~= "", "book without a title")
            assert(preferred[book.file_type], book.title .. " is a " .. book.file_type)
        end
        H.eq("Load more", menu.item_table[#menu.item_table].text, "last entry")
    end)

    -- KOReader carries on while Library Genesis answers, rather than being held up until it has
    it("can be called off while waiting for Library Genesis", function()
        H.openMainMenu({ "Kindle Fetch", "Search Library Genesis" })
        local plugin = H.plugin()
        local dialog = H.waitFor("the search dialog", 10, function()
            return plugin.search_box and H.isShown(plugin.search_box) and plugin.search_box
        end)
        dialog:setInputText(H.SEARCH_QUERY)
        local since = #H.notifications
        H.tapButton("Search", dialog)

        local message = H.waitFor("the message saying it's searching", 10, function()
            for _, window in ipairs(H.windows()) do
                if type(window.text) == "string" and window.text:find("Searching Library Genesis", 1, true) then
                    return window
                end
            end
        end)
        assert(message.text:find("Tap to cancel", 1, true), "the message doesn't say how to call the search off")
        H.shot("searching")

        H.tap(message.movable)
        H.waitFor("the message to go", 10, function()
            return not H.isShown(message)
        end)
        -- long enough for Library Genesis to have answered
        H.sleep(1)
        H.poll(15, function()
            return plugin.books_menu and H.isShown(plugin.books_menu)
        end)
        assert(not (plugin.books_menu and H.isShown(plugin.books_menu)), "the books were shown all the same")
        assert(H.isShown(dialog), "the search dialog has gone")
        -- calling it off isn't an error
        assert(not H.errorShown(), "said " .. tostring(H.errorShown()))
        for i = since + 1, #H.notifications do
            assert(not H.notifications[i]:find("No books", 1, true), "said " .. H.notifications[i])
        end
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
        local last_page = menu.page
        H.waitFor("more books", 120, function()
            return #H.books(menu) > count
        end)
        -- added to the list that's open, which stays where it was rather than going back to its first page
        H.eq(menu, plugin.books_menu, "the menu of books")
        assert(H.isShown(menu), "the books are no longer showing")
        H.eq(last_page, menu.page, "page showing")
        local first_new = H.books(menu)[count + 1]
        assert(
            H.find(function(widget)
                return widget.entry and widget.entry.book == first_new
            end, menu),
            "the first of the new books isn't on the page showing"
        )
        H.shot("search-more")
    end)
end)
