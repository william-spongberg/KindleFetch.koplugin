local H = require("helpers")

-- Z-Library can only be searched once logged into, so these need an account, given by KINDLEFETCH_ZLIB_EMAIL and
-- KINDLEFETCH_ZLIB_PASSWORD
local email, password = os.getenv("KINDLEFETCH_ZLIB_EMAIL"), os.getenv("KINDLEFETCH_ZLIB_PASSWORD")
-- each download counts towards the few books a day Z-Library lets an account download, so only one device downloads
local DOWNLOADS_ON = "kindle-paperwhite"

describe("Z-Library", function()
    after_each(H.closeAll)
    -- the book downloaded, which is removed once it has been read, as other tests find the book they download by
    -- looking for one in the folder
    local downloaded
    after_each(function()
        if downloaded then
            H.removeBook(downloaded)
            downloaded = nil
        end
    end)

    if not (email and password) then
        pending("needs KINDLEFETCH_ZLIB_EMAIL and KINDLEFETCH_ZLIB_PASSWORD")
        return
    end

    -- starting logged out, and logging out once done, rather than leaving the key that logs in among the test's files
    local ZlibAccount = require("api.zlibaccount")
    before_each(function()
        ZlibAccount:logout()
    end)
    after_each(function()
        ZlibAccount:logout()
    end)

    -- Jane Austen's own Pride and Prejudice, rather than one of the newer books based on it
    local function isPublicDomainEpub(book)
        return book.file_type == "epub"
            and book.title:lower() == "pride and prejudice"
            and book.authors:lower():find("austen", 1, true) ~= nil
    end

    it("logs in from its search menu entry, then finds books", function()
        H.openMainMenu({ "Kindle Fetch", "Search Z-Library" })
        local dialog = H.waitFor("the login dialog", 10, function()
            return H.find(function(widget)
                return widget.title == "Log in to Z-Library" and widget.input_fields
            end)
        end)
        dialog.input_fields[1]:setText(email)
        dialog.input_fields[2]:setText(password)
        H.shot("zlib-login")
        H.tapButton("Log in", dialog)

        local plugin = H.plugin()
        local search_box = H.waitFor("the search dialog", 60, function()
            local failure = H.errorShown()
            if failure then
                error(failure, 0)
            end
            return plugin.search_box and H.isShown(plugin.search_box) and plugin.search_box
        end)
        assert(ZlibAccount:isLoggedIn(), "not logged in")
        H.eq("Search Z-Library", search_box.title, "search box")

        search_box:setInputText(H.BOOK_QUERY)
        H.tapButton("Search", search_box)
        local menu = H.waitFor("search results", 120, function()
            local failure = H.errorShown() or H.messageSaying("No books found")
            if failure then
                error("search failed: " .. failure, 0)
            end
            return plugin.books_menu and H.isShown(plugin.books_menu) and plugin.books_menu
        end)

        local books = H.books(menu)
        assert(#books >= 10, "only found " .. #books .. " books")
        local preferred = {}
        for _, file_type in ipairs(require("settings.settings"):getPreferredFileTypes()) do
            preferred[file_type] = true
        end
        for _, book in ipairs(books) do
            H.eq("zlib", book.source, "source")
            assert(book.id:match("^zlib_%d+$"), "bad id " .. tostring(book.id))
            assert(book.title ~= "", "book without a title")
            assert(preferred[book.file_type], book.title .. " is a " .. book.file_type)
        end
        H.waitFor("covers to be shown", 90, function()
            return H.find(function(widget)
                return widget.file and widget.file:find("kindlefetch_covers", 1, true)
            end, menu)
        end)
        H.shot("zlib-search-results")
    end)

    if H.profile_name ~= DOWNLOADS_ON then
        pending("downloads a book and opens it (only on " .. DOWNLOADS_ON .. ")")
        return
    end

    it("downloads a book and opens it", function()
        assert(ZlibAccount:login(email, password), "couldn't log in")
        local menu = H.search(H.BOOK_QUERY, "Z-Library")
        local book
        for _, found in ipairs(H.books(menu)) do
            if
                isPublicDomainEpub(found)
                and (not book or H.sizeInBytes(found.file_size) < H.sizeInBytes(book.file_size))
            then
                book = found
            end
        end
        assert(book, "Jane Austen's Pride and Prejudice wasn't found as an epub")

        H.tapBook(menu, book)
        H.waitFor("the download prompt", 60, function()
            return H.findButton("Download")
        end)
        H.shot("zlib-download-prompt")
        H.tapButton("Download")
        if H.poll(2, function()
            return H.findButton("Overwrite")
        end) then
            H.tapButton("Overwrite")
        end

        H.waitFor("the download to finish", 300, function()
            local failure = H.errorShown()
            if failure then
                error(failure, 0)
            end
            return H.findButton("Read now")
        end)

        local path = H.books_dir .. "/" .. book.title .. ".epub"
        downloaded = path
        local file = io.open(path, "rb")
        assert(file, "no book at " .. path)
        -- an epub is a zip file
        H.eq("PK", file:read(2), "start of the book")
        file:close()

        H.tapButton("Read now")
        local ReaderUI = require("apps/reader/readerui")
        local reader = H.waitFor("the book to open", 120, function()
            return ReaderUI.instance and ReaderUI.instance.document and ReaderUI.instance
        end)
        H.eq(path, reader.document.file, "book opened")
        assert(reader.document:getPageCount() > 0, "the book has no pages")
        H.shot("zlib-reading")
    end)
end)
