local helper = require("helper")
local fixtures = require("fixtures")

describe("DownloadPrompt", function()
    local data_dir, book, downloads, DownloadPrompt

    local function newPrompt()
        return DownloadPrompt.new(book, "/mnt/us/documents/Dune.epub", function(filepath)
            table.insert(downloads, filepath)
        end)
    end

    local function cacheCover()
        fixtures.cacheCover(helper, book.md5)
    end

    -- the group with the book's title, authors and details, beside the cover if there is one
    local function detailsGroup(prompt)
        local header = prompt.frame[1][1]
        return prompt.cover and header[3] or header
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        book = {
            md5 = fixtures.DUNE.md5,
            display_title = "Dune",
            authors = "Frank Herbert",
            year = "1990",
            language = "English [en]",
            book_type = "Book (fiction)",
            file_type = "epub",
            file_size = "1.2MB"
        }
        downloads = {}
        DownloadPrompt = require("ui.downloadprompt")
    end)

    after_each(helper.cleanup)

    it("shows the book's details and where it will be saved", function()
        local prompt = newPrompt()

        assert.are.equal("Dune", prompt.title.text)
        assert.are.equal("Frank Herbert", prompt.author.text)
        assert.are.equal("/mnt/us/documents/Dune.epub", prompt.path_widget.text)

        local details = {}
        for _, widget in ipairs(detailsGroup(prompt)) do
            if widget.text then
                table.insert(details, widget.text)
            end
        end
        assert.are.same({"Dune", "Frank Herbert", "Year: 1990", "Language: English [en]", "Type: Book (fiction)",
                         "Format: epub", "Size: 1.2MB"}, details)
    end)

    it("shows the author and details in black", function()
        local prompt = newPrompt()
        assert.are.equal("black", prompt.author.fgcolor)
        assert.are.equal("black", detailsGroup(prompt)[5].fgcolor)
    end)

    it("shows a dash for missing details", function()
        book.year = nil
        local prompt = newPrompt()
        assert.are.equal("Year: -", detailsGroup(prompt)[5].text)
    end)

    it("shows and closes", function()
        local prompt = newPrompt()
        prompt:show()
        assert.are.equal(prompt.outer_container, helper.lastShown())

        prompt:close()
        assert.is_true(helper.wasClosed(prompt.outer_container))
    end)

    it("downloads to the chosen path when confirmed", function()
        local prompt = newPrompt()
        prompt:show()
        prompt.download_button.callback()

        assert.are.same({"/mnt/us/documents/Dune.epub"}, downloads)
        assert.is_true(helper.wasClosed(prompt.outer_container))
    end)

    it("lets the download folder be changed", function()
        local prompt = newPrompt()
        prompt.path_widget.callback()
        helper.state.dir_choosers[1].onConfirm("/mnt/us/books")

        assert.are.equal("/mnt/us/books/Dune.epub", prompt.filepath)
        assert.are.equal("/mnt/us/books/Dune.epub", prompt.path_widget.text)

        prompt.download_button.callback()
        assert.are.same({"/mnt/us/books/Dune.epub"}, downloads)
    end)

    it("lets the download folder be changed more than once", function()
        local prompt = newPrompt()
        prompt.path_widget.callback()
        helper.state.dir_choosers[1].onConfirm("/mnt/us/books")
        prompt.path_widget.callback()
        helper.state.dir_choosers[2].onConfirm("/mnt/us/comics")

        assert.are.equal("/mnt/us/comics/Dune.epub", prompt.filepath)
    end)

    it("closes when tapping outside of it", function()
        local prompt = newPrompt()
        prompt:show()

        local inside = helper.stubs.geometry:new{outside = false}
        assert.is_false(prompt.outer_container:onTapOutside(nil, {pos = inside}))
        assert.is_false(helper.wasClosed(prompt.outer_container))

        local outside = helper.stubs.geometry:new{outside = true}
        assert.is_true(prompt.outer_container:onTapOutside(nil, {pos = outside}))
        assert.is_true(helper.wasClosed(prompt.outer_container))
    end)

    describe("cover", function()
        it("is left out when the book doesn't have one, giving its details the whole width", function()
            local prompt = newPrompt()
            assert.is_nil(prompt.cover)
            assert.are.equal(380, prompt.title.width)

            prompt:showFullscreenCover()
            assert.is_false(prompt.fullscreen_cover_shown)
        end)

        it("is a placeholder while it downloads", function()
            book.image_url = "https://covers.example/dune.jpg"
            local prompt = newPrompt()

            assert.is_true(prompt.cover[1].is_cover_placeholder)
            assert.is_nil(prompt.cover_container)
            assert.are.equal(380 - 192 - 10, prompt.title.width)
        end)

        it("is shown once it has downloaded", function()
            book.image_url = "https://covers.example/dune.jpg"
            local prompt = newPrompt()
            prompt:show()

            cacheCover()
            prompt.outer_container:onKindleFetchCoversDownloaded()
            assert.are.equal(prompt.cover_container, prompt.cover)
            assert.are.equal(prompt.cover, prompt.frame[1][1][1])
        end)

        it("is taken away when it couldn't be downloaded", function()
            book.image_url = "https://covers.example/dune.jpg"
            local prompt = newPrompt()
            require("util.curlutil").downloadMultiple = function()
                return nil, nil, nil, "unable to launch curl"
            end
            require("cache.covercache"):downloadMultiple({book}, 1)

            prompt.outer_container:onKindleFetchCoversDownloaded()
            assert.is_nil(prompt.cover)
            assert.are.equal(380, prompt.title.width)
        end)

        it("is shown when it has been downloaded", function()
            cacheCover()
            local prompt = newPrompt()
            assert.are.equal(prompt.cover_container, prompt.cover)
        end)

        it("opens fullscreen when tapped, and closes when tapped again", function()
            cacheCover()
            local prompt = newPrompt()

            prompt.cover_container:onTapCover()
            assert.is_true(prompt.fullscreen_cover_shown)
            assert.are.equal(prompt.fullscreen_container, helper.lastShown())

            prompt.cover_container:onTapCover()
            assert.is_false(prompt.fullscreen_cover_shown)
            prompt:toggleFullscreenCover()
            assert.is_true(prompt.fullscreen_cover_shown)

            prompt.fullscreen_container:onTapClose()
            assert.is_false(prompt.fullscreen_cover_shown)
            assert.is_true(helper.wasClosed(prompt.fullscreen_container))

            local closed = #helper.state.closed
            prompt:closeFullscreenCover()
            assert.are.equal(closed, #helper.state.closed)
        end)

        it("closes along with the prompt", function()
            cacheCover()
            local prompt = newPrompt()
            prompt:toggleFullscreenCover()

            prompt:close()
            assert.is_true(helper.wasClosed(prompt.fullscreen_container))
            assert.is_true(helper.wasClosed(prompt.outer_container))
        end)
    end)
end)
