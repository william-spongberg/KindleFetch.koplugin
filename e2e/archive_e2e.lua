local H = require("helpers")

describe("Internet Archive", function()
    after_each(H.closeAll)
    -- the book downloaded, removed once read, as other tests find the book they download by looking in the folder
    local downloaded
    after_each(function()
        if downloaded then
            H.removeBook(downloaded)
            downloaded = nil
        end
    end)

    -- Project Gutenberg's Pride and Prejudice, a small epub, not one from a scan, which can be hundreds of megabytes
    local function isGutenbergEpub(book)
        return book.file_type == "epub"
            and book.identifier:find("gut$") ~= nil
            and book.title:lower() == "pride and prejudice"
            and book.authors:lower():find("austen", 1, true) ~= nil
    end

    it("finds books that anyone can download, and shows their covers", function()
        local menu = H.search(H.BOOK_QUERY, "Internet Archive")

        local books = H.books(menu)
        assert(#books >= 10, "only found " .. #books .. " books")
        local preferred = {}
        for _, file_type in ipairs(require("settings.settings"):getPreferredFileTypes()) do
            preferred[file_type] = true
        end
        for _, book in ipairs(books) do
            H.eq("archive", book.source, "source")
            assert(book.id == "archive_" .. book.identifier, "bad id " .. tostring(book.id))
            assert(book.title ~= "", "book without a title")
            assert(preferred[book.file_type], book.title .. " is a " .. book.file_type)
        end
        H.eq(H.BOOK_QUERY .. " · " .. #books .. "+ books", menu.title, "title")

        -- covers download in the background, then the menu is redrawn with them
        H.waitFor("covers to be shown", 90, function()
            return H.find(function(widget)
                return widget.file and widget.file:find("kindlefetch_covers", 1, true)
            end, menu)
        end)
        H.shot("archive-search-results")
    end)

    -- rather than once Library Genesis has answered, which can take a minute or more, as when its mirrors never answer
    it("is searched at once with Library Genesis, its books shown as soon as they're found", function()
        local plugin = H.startSearch(H.BOOK_QUERY, { "Library Genesis", "Internet Archive" })
        local menu = H.waitFor("Internet Archive's books", 60, function()
            assert(not H.errorShown(), H.errorShown())
            return plugin.books_menu and H.isShown(plugin.books_menu) and plugin.books_menu
        end)
        local from_archive = 0
        for _, book in ipairs(H.books(menu)) do
            from_archive = from_archive + (book.source == "archive" and 1 or 0)
        end
        assert(from_archive > 0, "none of the books are from Internet Archive")
        -- each with the site it was found on, as several were searched
        assert(menu.source_name, "the books don't say which site they're from")
        if not plugin.search:isDone() then
            local last = menu.item_table[#menu.item_table]
            H.eq("Still searching Library Genesis…", last.text, "the end of the list")
            H.shot("archive-searched-with-libgen")
        end

        -- then Library Genesis' books are added, or it says why it couldn't be searched, over the books found
        H.waitFor("Library Genesis' search to finish", 240, function()
            return plugin.search:isDone()
        end)
        H.pump()
        local last = menu.item_table[#menu.item_table]
        assert(not last.still_searching, "still says it's searching once it has finished")
    end)

    it("downloads a book and opens it", function()
        local menu = H.search(H.BOOK_QUERY, "Internet Archive")
        local book
        for _, found in ipairs(H.books(menu)) do
            if isGutenbergEpub(found) then
                book = found
                break
            end
        end
        assert(book, "Project Gutenberg's Pride and Prejudice wasn't found")

        H.tapBook(menu, book)
        H.waitFor("the download prompt", 60, function()
            return H.findButton("Download")
        end)
        H.shot("archive-download-prompt")
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
        H.shot("archive-reading")
    end)
end)
