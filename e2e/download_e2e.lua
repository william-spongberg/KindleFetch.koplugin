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

    local function isEpubToDownload(book)
        return book.file_type == "epub" and H.isPublicDomain(book)
    end

    it("downloads a book and opens it", function()
        local menu = H.searchUntil(H.BOOK_QUERY, isEpubToDownload)
        local book = epubs(menu)[1]

        H.tapBook(menu, book)
        H.waitFor("the download prompt", 60, function()
            return H.findButton("Download")
        end)
        H.shot("download-prompt")
        H.tapButton("Download")

        H.waitFor("the download to finish", 300, function()
            return H.findButton("Read now")
        end)
        H.shot("downloaded")

        local ls = io.popen("find " .. H.books_dir .. " -name '*.epub' -size +0")
        local downloaded = ls:read("*l")
        ls:close()
        assert(downloaded, "no book in " .. H.books_dir)

        H.tapButton("Read now")
        local ReaderUI = require("apps/reader/readerui")
        local reader = H.waitFor("the book to open", 120, function()
            return ReaderUI.instance and ReaderUI.instance.document and ReaderUI.instance
        end)
        H.eq(downloaded, reader.document.file, "book opened")
        assert(reader.document:getPageCount() > 0, "the book has no pages")
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
        H.tapButton("Download")
        H.waitFor("the download progress", 60, isDownloadShowing)
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
