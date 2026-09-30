local helper = require("helper")

describe("SettingsPage", function()
    local data_dir, Settings, SettingsPage

    local function lastMenu()
        return helper.lastShown()
    end

    local function itemTexts(menu)
        local texts = {}
        for _, item in ipairs(menu.item_table) do
            table.insert(texts, item.text)
        end
        return texts
    end

    -- tap the menu item whose text contains text
    local function tap(text)
        for _, item in ipairs(lastMenu().item_table) do
            if item.text:find(text, 1, true) then
                return item.callback()
            end
        end
        error("no menu item containing " .. text)
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.state.settings_files[data_dir .. "/settings/kindlefetch_settings.lua"] = {
            download_dir = helper.abs(data_dir)
        }
        Settings = require("settings.settings")
        SettingsPage = require("settings.settingspage")
    end)

    after_each(helper.cleanup)

    it("shows the current settings", function()
        SettingsPage:showSettings()

        assert.are.same({"Show Book Covers: ☑", "Download Folder: " .. helper.abs(data_dir),
                         "Preferred Languages: en", "Preferred File Types: epub, pdf, cbr, cbz",
                         "Preferred Book Types: book_fiction, book_comic"}, itemTexts(lastMenu()))
    end)

    it("toggles book covers", function()
        SettingsPage:showSettings()
        tap("Show Book Covers")

        assert.is_false(Settings:getShowBookCovers())
        assert.are.equal("Show Book Covers: ☐", lastMenu().item_table[1].text)
        assert.are.equal("Book cover visibility updated", helper.lastNotification())
    end)

    describe("download folder", function()
        it("can be changed", function()
            local books = helper.tmpdir("books")
            SettingsPage:showSettings()
            tap("Download Folder")
            helper.state.dir_choosers[1].onConfirm(books)

            assert.are.equal(books, Settings:getDownloadDir())
            assert.are.equal("Download folder updated", helper.lastNotification())
            assert.are.equal("Download Folder: " .. books, lastMenu().item_table[2].text)
        end)

        it("must exist", function()
            SettingsPage:showSettings()
            tap("Download Folder")
            helper.state.dir_choosers[1].onConfirm(data_dir .. "/missing")

            assert.are.equal(helper.abs(data_dir), Settings:getDownloadDir())
            assert.are.equal("Error: Invalid directory path", helper.lastNotification())
        end)
    end)

    describe("preferred languages", function()
        it("lists every language, with the preferred ones ticked", function()
            SettingsPage:showSettings()
            tap("Preferred Languages")

            local texts = itemTexts(lastMenu())
            assert.are.equal(#Settings:getAvailableLanguages(), #texts)
            assert.are.equal("☑ English", texts[1])
            assert.are.equal("☐ Spanish", texts[2])
        end)

        it("are saved when the menu is closed", function()
            SettingsPage:showSettings()
            tap("Preferred Languages")
            tap("Spanish")
            tap("English")
            tap("French")
            lastMenu().onClose()

            assert.are.same({"es", "fr"}, Settings:getPreferredLanguages())
            assert.are.equal("Languages updated", helper.lastNotification())
            assert.are.equal("Preferred Languages: es, fr", lastMenu().item_table[3].text)
        end)

        it("cannot all be unticked", function()
            SettingsPage:showSettings()
            tap("Preferred Languages")
            tap("English")
            lastMenu().onClose()

            assert.are.same({"en"}, Settings:getPreferredLanguages())
            assert.are.equal("Select at least one language", helper.lastNotification())
        end)
    end)

    describe("preferred file types", function()
        it("are grouped by category", function()
            SettingsPage:showSettings()
            tap("Preferred File Types")

            local menu = lastMenu()
            assert.are.equal("── Ebooks ──", menu.item_table[1].text)
            assert.is_false(menu.item_table[1].enabled)
            assert.are.equal("☑ epub", menu.item_table[2].text)
            assert.are.equal("☐ mobi", menu.item_table[3].text)
        end)

        it("are saved when the menu is closed", function()
            SettingsPage:showSettings()
            tap("Preferred File Types")
            tap("mobi")
            tap("☑ pdf")
            lastMenu().onClose()

            assert.are.same({"epub", "mobi", "cbr", "cbz"}, Settings:getPreferredFileTypes())
            assert.are.equal("File types updated", helper.lastNotification())
        end)

        it("cannot all be unticked", function()
            SettingsPage:showSettings()
            tap("Preferred File Types")
            for _, ext in ipairs({"epub", "pdf", "cbr", "cbz"}) do
                tap("☑ " .. ext)
            end
            lastMenu().onClose()

            assert.are.same({"epub", "pdf", "cbr", "cbz"}, Settings:getPreferredFileTypes())
            assert.are.equal("Select at least one file type", helper.lastNotification())
        end)
    end)

    describe("preferred book types", function()
        it("are saved when the menu is closed", function()
            SettingsPage:showSettings()
            tap("Preferred Book Types")
            assert.are.equal("☑ Book (fiction)", lastMenu().item_table[1].text)

            tap("Book (non-fiction)")
            tap("Comic book")
            lastMenu().onClose()

            assert.are.same({"book_fiction", "book_nonfiction"}, Settings:getPreferredBookTypes())
            assert.are.equal("Book types updated", helper.lastNotification())
        end)

        it("cannot all be unticked", function()
            SettingsPage:showSettings()
            tap("Preferred Book Types")
            tap("Book (fiction)")
            tap("Comic book")
            lastMenu().onClose()

            assert.are.same({"book_fiction", "book_comic"}, Settings:getPreferredBookTypes())
            assert.are.equal("Select at least one book type", helper.lastNotification())
        end)
    end)
end)
