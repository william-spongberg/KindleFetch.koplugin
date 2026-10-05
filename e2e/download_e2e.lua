local H = require("helpers")

describe("Downloading", function()
    after_each(H.closeAll)

    -- epubs of the public domain book, smallest first
    local function epubs(menu)
        local books = {}
        for _, book in ipairs(H.books(menu)) do
            if book.file_type == "epub" and H.isPublicDomain(book) then
                table.insert(books, book)
            end
        end
        assert(#books > 0, "no epubs of Jane Austen's Pride and Prejudice found")
        table.sort(books, function(a, b)
            return H.sizeInBytes(a.file_size) < H.sizeInBytes(b.file_size)
        end)
        return books
    end

    local function isDownloadShowing()
        return H.findButton("Hide") and H.findButton("Cancel")
    end

    -- wait for something a download leads to, failing straight away if it says it has failed instead
    local function waitForDownload(what, timeout, check)
        return H.waitFor(what, timeout, function()
            local failure = H.errorShown()
            if failure then
                error(failure, 0)
            end
            return check()
        end)
    end

    local function isEpubToDownload(book)
        return book.file_type == "epub" and H.isPublicDomain(book)
    end

    -- tap Download in the prompt, and download over the book if an earlier test has left it there. returns
    -- whether it was asked to
    local function confirmDownload()
        H.tapButton("Download")
        if H.poll(2, function()
            return H.findButton("Overwrite")
        end) then
            H.tapButton("Overwrite")
            return true
        end
        return false
    end

    it("falls back to another mirror when one fails", function()
        local menu = H.searchUntil(H.BOOK_QUERY, isEpubToDownload)
        local book = epubs(menu)[1]
        local broken = H.breakMirrors()

        H.tapBook(menu, book)
        H.waitFor("the download prompt", 60, function()
            return H.findButton("Download")
        end)
        confirmDownload()
        waitForDownload("the download to finish", 300, function()
            return H.findButton("Read now")
        end)

        -- the one that doesn't exist is forgotten, and the one that answered is kept, as it may just not have the book
        local mirrors = require("api.urlapi"):getLibgenUrls()
        for _, mirror in ipairs(mirrors) do
            assert(mirror ~= broken[1], broken[1] .. " is still one of the mirrors")
        end
        H.eq(broken[2], mirrors[1], "first mirror")
    end)

    it("downloads a book and opens it", function()
        local menu = H.searchUntil(H.BOOK_QUERY, isEpubToDownload)
        local book = epubs(menu)[1]

        H.tapBook(menu, book)
        H.waitFor("the download prompt", 60, function()
            return H.findButton("Download")
        end)
        H.shot("download-prompt")
        confirmDownload()

        waitForDownload("the download to finish", 300, function()
            return H.findButton("Read now")
        end)
        H.shot("downloaded")

        local ls = io.popen("find " .. H.books_dir .. " -name '*.epub' -size +0")
        local downloaded = ls:read("*l")
        ls:close()
        assert(downloaded, "no book in " .. H.books_dir)

        local plugin = H.plugin()
        H.tapButton("Read now")
        local ReaderUI = require("apps/reader/readerui")
        local reader = H.waitFor("the book to open", 120, function()
            return ReaderUI.instance and ReaderUI.instance.document and ReaderUI.instance
        end)
        H.eq(downloaded, reader.document.file, "book opened")
        assert(reader.document:getPageCount() > 0, "the book has no pages")
        -- which would otherwise show again once the book is closed
        assert(not H.isShown(plugin.search_box), "the search box is still open behind the book")
        assert(not H.isShown(plugin.books_menu), "the search results are still open behind the book")
        H.shot("reading")
    end)

    it("shows a hidden download again when its book is chosen, and cancels it", function()
        local menu = H.searchUntil(H.BOOK_QUERY, isEpubToDownload)
        -- the biggest book, so it's still downloading when cancelled
        local books = epubs(menu)
        local book = books[#books]

        H.tapBook(menu, book)
        H.waitFor("the download prompt", 60, function()
            return H.findButton("Download")
        end)
        confirmDownload()
        waitForDownload("the download progress", 60, isDownloadShowing)
        H.shot("download-progress")

        H.tapButton("Hide")
        assert(not isDownloadShowing(), "the download progress is still showing")

        H.tapBook(menu, book)
        H.waitFor("the download progress to show again", 10, isDownloadShowing)

        local since = #H.notifications
        H.tapButton("Cancel")
        H.waitForNotification("Download cancelled", 30, since)
        H.eq(0, #require("api.lgliapi"):getActiveDownloads(), "downloads in progress")
    end)
end)
