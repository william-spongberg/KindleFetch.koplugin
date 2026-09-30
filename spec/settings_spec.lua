local helper = require("helper")

describe("KindleFetchSettings", function()
    local data_dir, Settings

    local function pluginSettings()
        return helper.state.settings_files[data_dir .. "/settings/kindlefetch_settings.lua"]
    end

    local function setReaderHomeDir(path)
        helper.state.settings_files[data_dir .. "/settings/../settings.reader.lua"] = {
            home_dir = path
        }
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
                download_dir = "/mnt/us/books"
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
            Settings:setPreferredLanguages({"fr", "de"})
            Settings:setPreferredFileTypes({"mobi"})
            Settings:setPreferredBookTypes({"book_nonfiction"})

            assert.is_false(Settings:getShowBookCovers())
            assert.are.same({"fr", "de"}, Settings:getPreferredLanguages())
            assert.are.same({"mobi"}, Settings:getPreferredFileTypes())
            assert.are.same({"book_nonfiction"}, Settings:getPreferredBookTypes())
        end)

        it("offer every choice Anna's Archive supports", function()
            assert.are.same({text = "English", code = "en"}, Settings:getAvailableLanguages()[1])
            assert.are.equal(100, #Settings:getAvailableLanguages())
            assert.are.same({"cbr", "cbz"}, Settings:getComicFileTypes())
            assert.are.same({"epub", "mobi", "azw", "azw3", "kfx", "fb2", "lit", "prc", "lrf", "snb", "updb"},
                Settings:getEbookFileTypes())
            assert.are.same({"pdf", "txt", "rtf", "doc", "docx", "odt", "djvu"}, Settings:getDocumentFileTypes())
            assert.are.same({"jpg", "tif", "pdb"}, Settings:getImageFileTypes())
            assert.are.same({"chm", "htm", "html", "htmlz", "mht"}, Settings:getWebFileTypes())
            assert.are.same({"book_fiction", "book_nonfiction", "book_unknown", "book_comic", "standards_document"},
                (function()
                    local codes = {}
                    for _, book_type in ipairs(Settings:getAvailableBookTypes()) do
                        table.insert(codes, book_type.code)
                    end
                    return codes
                end)())
        end)
    end)

    describe("load", function()
        it("saves a usable download folder on devices without a home dir", function()
            helper.stubs.device.home_dir = nil
            Settings:load()
            assert.are.equal(helper.ROOT, pluginSettings().download_dir)
        end)

        it("fills in default preferences", function()
            Settings:load()
            assert.are.same({"en"}, pluginSettings().preferred_languages)
            assert.are.same({"epub", "pdf", "cbr", "cbz"}, pluginSettings().preferred_file_types)
            assert.are.same({"book_fiction", "book_comic"}, pluginSettings().preferred_book_types)
            assert.is_true(pluginSettings().show_book_covers)
        end)
    end)
end)
