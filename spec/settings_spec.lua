local helper = require("helper")

describe("KindleFetchSettings", function()
    local data_dir, Settings

    local function pluginSettings()
        return helper.state.settings_files[data_dir .. "/settings/kindlefetch_settings.lua"]
    end

    local function setReaderHomeDir(path)
        helper.state.reader_settings.home_dir = path
    end

    -- count how often the settings file is read from and written to storage
    local function countFileAccess()
        local count = {
            opens = 0,
            flushes = 0,
        }
        local open = helper.stubs.luasettings.open
        helper.stubs.luasettings.open = function(...)
            count.opens = count.opens + 1
            local file = open(...)
            local flush = file.flush
            function file:flush()
                count.flushes = count.flushes + 1
                return flush(self)
            end
            return file
        end
        return count
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        -- don't let the host machine decide whether the kindle documents folder exists
        helper.state.fs["/mnt/us/documents"] = false
        Settings = require("settings.settings")
    end)

    after_each(helper.cleanup)

    describe("getDownloadDir", function()
        it("uses the saved download folder", function()
            helper.state.settings_files[data_dir .. "/settings/kindlefetch_settings.lua"] = {
                download_dir = "/mnt/us/books",
            }
            assert.are.equal("/mnt/us/books", Settings:getDownloadDir())
        end)

        it("defaults to koreader's home folder", function()
            local home = helper.tmpdir("home")
            setReaderHomeDir(home)
            assert.are.equal(home, Settings:getDownloadDir())
        end)

        it("uses the kindle documents folder when no home folder is set", function()
            helper.state.fs["/mnt/us/documents"] = "directory"
            assert.are.equal("/mnt/us/documents", Settings:getDownloadDir())
        end)

        it("falls back to the device home dir when the home folder is missing", function()
            setReaderHomeDir("/storage/emulated/0/Books")
            helper.stubs.device.home_dir = "/storage/emulated/0"
            assert.are.equal("/storage/emulated/0", Settings:getDownloadDir())
        end)

        it("falls back to the koreader dir on devices without a home dir", function()
            helper.stubs.device.home_dir = nil
            assert.are.equal(helper.ROOT, Settings:getDownloadDir())
        end)
    end)

    describe("setDownloadDir", function()
        it("saves folders that exist", function()
            local books = helper.tmpdir("books")
            assert.is_true(Settings:setDownloadDir(books))
            assert.are.equal(books, Settings:getDownloadDir())
        end)

        it("refuses folders that do not exist", function()
            local ok, err = Settings:setDownloadDir(data_dir .. "/missing")
            assert.is_false(ok)
            assert.are.equal("Invalid directory path", err)
        end)
    end)

    describe("preferences", function()
        it("are saved", function()
            Settings:setShowBookCovers(false)
            Settings:setCheckForUpdates(false)
            Settings:setPreferredLanguages({ "fr", "de" })
            Settings:setPreferredFileTypes({ "mobi" })
            Settings:setPreferredBookTypes({ "nonfiction" })

            assert.is_false(Settings:getShowBookCovers())
            assert.is_false(Settings:getCheckForUpdates())
            assert.are.same({ "fr", "de" }, Settings:getPreferredLanguages())
            assert.are.same({ "mobi" }, Settings:getPreferredFileTypes())
            assert.are.same({ "nonfiction" }, Settings:getPreferredBookTypes())
        end)

        -- and only file types KOReader can open
        it("offer every choice Library Genesis supports", function()
            assert.are.same({ text = "English", code = "en" }, Settings:getAvailableLanguages()[1])
            assert.are.equal(100, #Settings:getAvailableLanguages())
            assert.are.same({ "cbr", "cbz" }, Settings:getComicFileTypes())
            assert.are.same({ "epub", "mobi", "azw", "fb2", "prc" }, Settings:getEbookFileTypes())
            assert.are.same({ "pdf", "txt", "rtf", "doc", "docx", "odt", "djvu" }, Settings:getDocumentFileTypes())
            assert.are.same({ "jpg", "tif", "pdb" }, Settings:getImageFileTypes())
            assert.are.same({ "chm", "htm", "html", "htmlz" }, Settings:getWebFileTypes())
            assert.are.same(
                { "fiction", "nonfiction", "comics", "magazines", "articles", "standards" },
                (function()
                    local codes = {}
                    for _, book_type in ipairs(Settings:getAvailableBookTypes()) do
                        table.insert(codes, book_type.code)
                    end
                    return codes
                end)()
            )
        end)
    end)

    describe("cache expiry", function()
        it("keeps searches for two weeks and mirrors for a week by default", function()
            assert.are.equal(14, Settings:getSearchCacheExpiryDays())
            assert.are.equal(7, Settings:getMirrorCacheExpiryDays())
        end)

        it("can be changed", function()
            assert.are.same({ 1, 3, 7, 14, 30 }, Settings:getAvailableCacheExpiryDays())
            Settings:setSearchCacheExpiryDays(30)
            Settings:setMirrorCacheExpiryDays(1)

            assert.are.equal(30, Settings:getSearchCacheExpiryDays())
            assert.are.equal(1, Settings:getMirrorCacheExpiryDays())
        end)
    end)

    it("remembers the plugin version it last ran", function()
        assert.is_nil(Settings:getLastVersion())
        Settings:setLastVersion("0.4")
        assert.are.equal("0.4", Settings:getLastVersion())
    end)

    describe("preferred book types", function()
        it("are converted from the ones used for Anna's Archive", function()
            helper.state.settings_files[data_dir .. "/settings/kindlefetch_settings.lua"] = {
                preferred_book_types = {
                    "book_fiction",
                    "book_nonfiction",
                    "book_unknown",
                    "book_comic",
                    "standards_document",
                },
            }
            assert.are.same({ "fiction", "nonfiction", "comics", "standards" }, Settings:getPreferredBookTypes())

            Settings:load()
            assert.are.same({ "fiction", "nonfiction", "comics", "standards" }, pluginSettings().preferred_book_types)
        end)

        it("leave out Russian fiction, which can no longer be chosen", function()
            helper.state.settings_files[data_dir .. "/settings/kindlefetch_settings.lua"] = {
                preferred_book_types = { "fiction", "fiction_rus", "magazines" },
            }
            assert.are.same({ "fiction", "magazines" }, Settings:getPreferredBookTypes())
        end)

        it("fall back to the defaults when none of those chosen are left", function()
            helper.state.settings_files[data_dir .. "/settings/kindlefetch_settings.lua"] = {
                preferred_book_types = { "book_unknown" },
            }
            assert.are.same(
                { "fiction", "nonfiction", "comics", "magazines", "articles", "standards" },
                Settings:getPreferredBookTypes()
            )
        end)

        it("can all be turned off", function()
            Settings:setPreferredBookTypes({})
            assert.are.same({}, Settings:getPreferredBookTypes())
        end)
    end)

    describe("preferred file types", function()
        it("leave out ones KOReader can't open, which can no longer be chosen", function()
            helper.state.settings_files[data_dir .. "/settings/kindlefetch_settings.lua"] = {
                preferred_file_types = { "epub", "azw3", "kfx", "pdf" },
            }
            assert.are.same({ "epub", "pdf" }, Settings:getPreferredFileTypes())
        end)

        it("fall back to the defaults when none of those chosen are left", function()
            helper.state.settings_files[data_dir .. "/settings/kindlefetch_settings.lua"] = {
                preferred_file_types = { "azw3", "lit" },
            }
            assert.are.same({
                "epub",
                "mobi",
                "azw",
                "fb2",
                "prc",
                "cbr",
                "cbz",
                "pdf",
                "txt",
                "rtf",
                "doc",
                "docx",
                "odt",
                "djvu",
                "jpg",
                "tif",
                "pdb",
                "chm",
                "htm",
                "html",
                "htmlz",
            }, Settings:getPreferredFileTypes())
        end)

        it("can all be turned off", function()
            Settings:setPreferredFileTypes({})
            assert.are.same({}, Settings:getPreferredFileTypes())
        end)
    end)

    describe("load", function()
        it("saves a usable download folder on devices without a home dir", function()
            helper.stubs.device.home_dir = nil
            Settings:load()
            assert.are.equal(helper.ROOT, pluginSettings().download_dir)
        end)

        -- every kind of book in every file type KOReader can open, in English
        it("fills in default preferences", function()
            Settings:load()
            assert.are.same({ "en" }, pluginSettings().preferred_languages)
            assert.are.same({
                "epub",
                "mobi",
                "azw",
                "fb2",
                "prc",
                "cbr",
                "cbz",
                "pdf",
                "txt",
                "rtf",
                "doc",
                "docx",
                "odt",
                "djvu",
                "jpg",
                "tif",
                "pdb",
                "chm",
                "htm",
                "html",
                "htmlz",
            }, pluginSettings().preferred_file_types)
            assert.are.same(
                { "fiction", "nonfiction", "comics", "magazines", "articles", "standards" },
                pluginSettings().preferred_book_types
            )
            assert.is_true(pluginSettings().show_book_covers)
            assert.is_true(pluginSettings().check_for_updates)
        end)

        -- it runs every time the file manager or a book is opened
        it("only writes the settings file when something changed", function()
            local count = countFileAccess()

            Settings:load()
            assert.are.equal(1, count.flushes)

            Settings:load()
            Settings:load()
            assert.are.equal(1, count.flushes)
        end)

        it("writes the settings file again once a saved setting is out of date", function()
            helper.state.settings_files[data_dir .. "/settings/kindlefetch_settings.lua"] = {
                preferred_file_types = { "epub", "azw3" },
            }
            local count = countFileAccess()

            Settings:load()
            assert.are.equal(1, count.flushes)
            assert.are.same({ "epub" }, pluginSettings().preferred_file_types)
        end)

        it("leaves a download folder that has gone missing as it was saved", function()
            helper.state.settings_files[data_dir .. "/settings/kindlefetch_settings.lua"] = {
                download_dir = data_dir .. "/missing",
            }
            Settings:load()
            assert.are.equal(data_dir .. "/missing", pluginSettings().download_dir)
        end)
    end)

    it("reads the settings file from storage once", function()
        local count = countFileAccess()

        Settings:getShowBookCovers()
        Settings:getPreferredLanguages()
        Settings:getDownloadDir()
        Settings:setShowBookCovers(false)
        Settings:getShowBookCovers()

        assert.are.equal(1, count.opens)
        assert.are.equal(1, count.flushes)
    end)
end)
