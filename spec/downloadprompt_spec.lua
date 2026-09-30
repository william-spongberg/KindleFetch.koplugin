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
    -- the book's details, as label and value pairs
    local function details(prompt)
        local rows = {}
        for _, row in ipairs(prompt.details_group) do
            if row[1] and row[3] then
                table.insert(rows, {row[1].text, row[3].text})
            end
        end
        return rows
    end

    -- tap one of the buttons along the bottom
    local function tapButton(prompt, id)
        for _, button in ipairs(prompt.button_table.buttons[1]) do
            if button.id == id then
                return button.callback()
            end
        end
        error("no button " .. id)
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
        assert.are.same({{"Format", "EPUB · 1.2MB"}, {"Language", "English [en]"}, {"Year", "1990"},
                         {"Type", "Book (fiction)"}}, details(prompt))
    end)

    -- in greys dark enough to read on e-ink (#3)
    it("shows the title and details in black, and the author and labels in grey", function()
        local prompt = newPrompt()
        assert.are.equal("gray 4", prompt.author.fgcolor)
        assert.are.equal("gray 6", prompt.details_group[1][1].fgcolor)
        assert.are.equal("black", prompt.details_group[1][3].fgcolor)
        assert.is_true(prompt.title.bold)
    end)

    it("leaves out missing details", function()
        book.year = nil
        book.file_size = nil
        local prompt = newPrompt()
        assert.are.same({{"Format", "EPUB"}, {"Language", "English [en]"}, {"Type", "Book (fiction)"}},
            details(prompt))
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
        tapButton(prompt, "download")

        assert.are.same({"/mnt/us/documents/Dune.epub"}, downloads)
        assert.is_true(helper.wasClosed(prompt.outer_container))
    end)

    it("closes without downloading when cancelled", function()
        local prompt = newPrompt()
        prompt:show()
        tapButton(prompt, "cancel")

        assert.are.same({}, downloads)
        assert.is_true(helper.wasClosed(prompt.outer_container))
    end)

    it("lets the download folder be changed", function()
        local prompt = newPrompt()
        prompt.path_widget.callback()
        helper.state.dir_choosers[1].onConfirm("/mnt/us/books")

        assert.are.equal("/mnt/us/books/Dune.epub", prompt.filepath)
        assert.are.equal("/mnt/us/books/Dune.epub", prompt.path_widget.text)

        tapButton(prompt, "download")
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
            assert.are.equal(prompt.cover, prompt.header[1])
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

        describe("full-size", function()
            local CoverCache, runs

            before_each(function()
                CoverCache = require("cache.covercache")
                runs = {}
                local CurlUtil = require("util.curlutil")
                CurlUtil.downloadMultiple = function(urls, paths)
                    table.insert(runs, {
                        urls = urls,
                        paths = paths
                    })
                    return 4000, CurlUtil.createExitFile(), data_dir .. "/curl_config.txt"
                end
                CurlUtil.isPidRunning = function()
                    return true
                end
                book.image_url = "https://libgen.example/fictioncovers/1000/dune_small.jpg"
                cacheCover()
            end)

            it("is only downloaded once the cover is enlarged, showing the thumbnail until then", function()
                local prompt = newPrompt()
                assert.are.equal(0, #runs)

                prompt.cover_container:onTapCover()
                assert.are.same({"https://libgen.example/fictioncovers/1000/dune.jpg"}, runs[1].urls)
                assert.are.equal(CoverCache:get(book.md5), prompt.fullscreen_file)
            end)

            it("replaces the thumbnail once it arrives", function()
                local prompt = newPrompt()
                prompt.cover_container:onTapCover()
                local thumbnail = prompt.fullscreen_container

                fixtures.cacheCover(helper, book.md5 .. "_full")
                prompt.outer_container:onKindleFetchCoversDownloaded()
                assert.is_true(helper.wasClosed(thumbnail))
                assert.is_true(prompt.fullscreen_cover_shown)
                assert.are.equal(prompt.fullscreen_container, helper.lastShown())
                assert.are.equal(CoverCache:getFullSize(book), prompt.fullscreen_file)
                assert.are.equal(CoverCache:getFullSize(book), prompt.cover_container[1][1].file)
                assert.are.equal(1, #runs)
            end)

            it("leaves the thumbnail showing when it couldn't be downloaded", function()
                local prompt = newPrompt()
                prompt.cover_container:onTapCover()
                local thumbnail = prompt.fullscreen_container

                prompt.outer_container:onKindleFetchCoversDownloaded()
                assert.is_false(helper.wasClosed(thumbnail))
                assert.are.equal(CoverCache:get(book.md5), prompt.fullscreen_file)
            end)
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
