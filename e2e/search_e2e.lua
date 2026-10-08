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
        -- what was searched for and how many books there are so far, above them
        H.eq(H.SEARCH_QUERY .. " · " .. #books .. "+ books", menu.title, "title")
    end)

    -- KOReader carries on while Library Genesis answers, rather than being held up until it has
    it("can be called off while waiting for Library Genesis", function()
        local since = #H.notifications
        local plugin, dialog = H.startSearch(H.SEARCH_QUERY)

        local message = H.waitFor("the message saying it's searching", 10, function()
            for _, window in ipairs(H.windows()) do
                if type(window.title) == "string" and window.title:find("Searching Library Genesis", 1, true) then
                    return window
                end
            end
        end)
        H.shot("searching")

        -- a tap elsewhere, which may have been meant for something else, leaves it searching
        H.tapAt(5, 5)
        assert(H.isShown(message), "a tap away from the message called the search off")

        H.tapButton("Cancel", message)
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
        local failure = H.errorShown()
        assert(not failure, "said " .. tostring(failure))
        for i = since + 1, #H.notifications do
            assert(not H.notifications[i]:find("No books", 1, true), "said " .. H.notifications[i])
        end
    end)

    -- rather than only that no books were found, which is what it looks like when there are plenty of other kinds
    it("says when the results are all in other file types or languages", function()
        local Settings = require("settings.settings")
        local file_types = Settings:getPreferredFileTypes()
        -- a file type that books about Harry Potter aren't in
        Settings:setPreferredFileTypes({ "tif" })

        local ok, err = pcall(function()
            local plugin = H.startSearch(H.SEARCH_QUERY)
            local explanation = H.waitFor("the explanation", 180, function()
                assert(not H.errorShown(), H.errorShown())
                assert(not (plugin.books_menu and H.isShown(plugin.books_menu)), "found books as tif files")
                return H.messageSaying("but none in the languages and file types chosen")
            end)
            assert(explanation:find("Library Genesis listed %d+ results"), explanation)
            H.shot("search-other-file-types")

            -- which is where to change what's shown
            H.tapButton("Settings")
            H.waitFor("the settings", 10, function()
                return H.find(function(widget)
                    return type(widget.text) == "string" and widget.text:find("Preferred File Types", 1, true)
                end)
            end)
        end)
        Settings:setPreferredFileTypes(file_types)
        if not ok then
            error(err, 0)
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
