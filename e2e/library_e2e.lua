local H = require("helpers")

-- Calibre's content server, started by e2e/run.sh where Calibre is installed, with a Digest login, as it has no HTTPS
local address = os.getenv("E2E_CALIBRE_URL")
local username, password = os.getenv("E2E_CALIBRE_USER"), os.getenv("E2E_CALIBRE_PASSWORD")

describe("Your libraries", function()
    after_each(H.closeAll)
    -- the book downloaded, removed once read, as other tests find the book they download by looking in the folder
    local downloaded
    after_each(function()
        if downloaded then
            H.removeBook(downloaded)
            downloaded = nil
        end
    end)

    if not (address and username and password) then
        pending("needs Calibre installed, for e2e/run.sh to start its content server")
        return
    end

    local Settings = require("settings.settings")
    local Libraries = require("api.libraries")
    local CurlUtil = require("util.curlutil")
    -- starting with no libraries, and leaving none behind
    local function removeLibraries()
        for _, library in ipairs(Settings:getLibraries()) do
            Libraries.remove(library.id)
        end
    end
    before_each(removeLibraries)
    after_each(removeLibraries)

    -- type into the boxes of the dialog showing with them, and tap one of its buttons
    local function typeAndTap(texts, button)
        local dialog = H.waitFor("a dialog to type in", 10, function()
            return H.find(function(widget)
                return widget.input_fields and widget.getFields
            end)
        end)
        for i, text in pairs(texts) do
            dialog.input_fields[i]:setText(text)
        end
        H.tapButton(button, dialog)
    end

    -- open Your Libraries in the settings, then Add a library…
    local function openAdding()
        H.openMainMenu({ "Kindle Fetch", "Settings" })
        local settings = H.waitFor("the settings", 10, function()
            return H.find(function(widget)
                return widget.title == "Kindle Fetch Settings" and widget.item_table
            end)
        end)
        H.tapMenuEntry(settings, function(item)
            return item.text and item.text:find("^Your Libraries:")
        end)
        local libraries = H.waitFor("the libraries", 10, function()
            return H.find(function(widget)
                return widget.title == "Your Libraries" and widget.item_table
            end)
        end)
        H.tapMenuEntry(libraries, function(item)
            return item.text == "Add a library…"
        end)
    end

    -- add the library, logging in to it
    local function addLibrary()
        openAdding()
        local since = #H.notifications
        typeAndTap({ address, username, password }, "Add")
        H.waitForNotification("Added ", 60, since)
        return assert(Settings:getLibraries()[1], "the library wasn't added")
    end

    -- search the library for Pride and Prejudice, download it and open it
    local function downloadAndRead(library, shot)
        local menu = H.search("pride prejudice", { library.name })
        local book = H.books(menu)[1]
        assert(book, "no books found")
        H.eq("Pride and Prejudice", book.display_title, "book found")
        H.eq("epub", book.file_type, "its file type")
        if shot then
            H.waitFor("covers to be shown", 60, function()
                return H.find(function(widget)
                    return widget.file and widget.file:find("kindlefetch_covers", 1, true)
                end, menu)
            end)
            H.shot(shot)
        end

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
        H.waitFor("the download to finish", 120, function()
            local failure = H.errorShown()
            if failure then
                error(failure, 0)
            end
            return H.findButton("Read now")
        end)

        local path = H.books_dir .. "/" .. book.title .. "." .. book.file_type
        downloaded = path
        local file = assert(io.open(path, "rb"), "no book at " .. path)
        H.eq("PK", file:read(2), "start of the book")
        file:close()

        H.tapButton("Read now")
        local ReaderUI = require("apps/reader/readerui")
        local reader = H.waitFor("the book to open", 120, function()
            return ReaderUI.instance and ReaderUI.instance.document and ReaderUI.instance
        end)
        H.eq(path, reader.document.file, "book opened")
        assert(reader.document:getPageCount() > 0, "the book has no pages")
    end

    it("asks for the login of a Calibre library that needs one, then adds it", function()
        openAdding()
        typeAndTap({ address }, "Add")
        H.waitFor("being told it needs logging in to", 60, function()
            return H.errorShown()
        end)
        assert(H.errorShown():find("didn't accept the username and password", 1, true), H.errorShown())
        H.dismissError()

        -- asked again, with what was typed
        local since = #H.notifications
        typeAndTap({ [2] = username, [3] = password }, "Add")
        H.waitForNotification("Added ", 60, since)
        local library = Settings:getLibraries()[1]
        assert(library, "the library wasn't added")
        H.eq("calibre", library.kind, "its kind")
        H.eq(username, library.username, "its username")
    end)

    it("searches the library, with its covers, and downloads and opens a book from it", function()
        downloadAndRead(addLibrary(), "library-search-results")
    end)

    -- logging in the Digest way itself, as luasocket can't
    it("does so with KOReader's own HTTP too, where curl can't", function()
        local library = addLibrary()
        local canFetch = CurlUtil.canFetch
        CurlUtil.canFetch = function()
            return false
        end
        local ok, err = pcall(downloadAndRead, library)
        CurlUtil.canFetch = canFetch
        assert(ok, err)
    end)
end)
