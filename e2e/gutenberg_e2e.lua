local H = require("helpers")

describe("Project Gutenberg", function()
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

    -- its own Pride and Prejudice, its most downloaded book, rather than the audiobook of it, or another edition
    local function isPride(book)
        return book.gutenberg_id == 1342
    end

    it("finds books, with their covers", function()
        local menu = H.search(H.BOOK_QUERY, "Project Gutenberg")

        local books = H.books(menu)
        assert(#books > 0, "no books found")
        for _, book in ipairs(books) do
            H.eq("gutenberg", book.source, "source")
            assert(book.title ~= "", "book without a title")
        end
        local found = false
        for _, book in ipairs(books) do
            found = found or isPride(book)
        end
        assert(found, "Pride and Prejudice wasn't found")

        H.waitFor("covers to be shown", 90, function()
            return H.find(function(widget)
                return widget.file and widget.file:find("kindlefetch_covers", 1, true)
            end, menu)
        end)
        H.shot("gutenberg-search-results")
    end)

    it("downloads a book and opens it", function()
        local menu = H.search(H.BOOK_QUERY, "Project Gutenberg")
        local book
        for _, found in ipairs(H.books(menu)) do
            if isPride(found) then
                book = found
                break
            end
        end
        assert(book, "Pride and Prejudice wasn't found")

        H.tapBook(menu, book)
        H.waitFor("the download prompt", 60, function()
            return H.findButton("Download")
        end)
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

        local path = H.books_dir .. "/" .. book.title .. "." .. book.file_type
        downloaded = path
        local file = io.open(path, "rb")
        assert(file, "no book at " .. path)
        if book.file_type == "epub" then
            -- an epub is a zip file
            H.eq("PK", file:read(2), "start of the book")
        end
        file:close()

        H.tapButton("Read now")
        local ReaderUI = require("apps/reader/readerui")
        local reader = H.waitFor("the book to open", 120, function()
            return ReaderUI.instance and ReaderUI.instance.document and ReaderUI.instance
        end)
        H.eq(path, reader.document.file, "book opened")
        assert(reader.document:getPageCount() > 0, "the book has no pages")
        H.shot("gutenberg-reading")
    end)
end)
