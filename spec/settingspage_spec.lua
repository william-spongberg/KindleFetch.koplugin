local helper = require("helper")

describe("SettingsPage", function()
    local data_dir, Settings, SettingsPage

    -- the menu on top: the last one shown that hasn't been closed since
    local function lastMenu()
        for i = #helper.state.shown, 1, -1 do
            local widget = helper.state.shown[i]
            if widget.item_table and not helper.wasClosed(widget) then
                return widget
            end
        end
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
            download_dir = helper.abs(data_dir),
        }
        Settings = require("settings.settings")
        SettingsPage = require("settings.settingspage")
    end)

    after_each(helper.cleanup)

    it("shows the current settings", function()
        SettingsPage:showSettings()

        assert.are.same({
            "Show Book Covers: ☑",
            "Download Folder: " .. helper.abs(data_dir),
            "Preferred Languages: en",
            "Preferred File Types: epub, mobi, azw, fb2, prc, cbr, cbz, "
                .. "pdf, txt, rtf, doc, docx, odt, djvu, jpg, tif, pdb, chm, htm, html, htmlz",
            "Preferred Book Types: fiction, nonfiction, comics, magazines, articles, standards",
            "Check for Updates Automatically: ☑",
            "Keep Searches For: 14 days",
            "Keep Mirrors For: 7 days",
            "Clear Cache",
        }, itemTexts(lastMenu()))
        assert.are.equal("Kindle Fetch Settings", lastMenu().title)
    end)

    it("toggles book covers", function()
        SettingsPage:showSettings()
        tap("Show Book Covers")

        assert.is_false(Settings:getShowBookCovers())
        assert.are.equal("Show Book Covers: ☐", lastMenu().item_table[1].text)
        assert.are.equal("Book cover visibility updated", helper.lastNotification())
    end)

    -- closing the menu and opening another for every change flashed the whole screen twice
    it("shows a change in the menu that's open, on the page it's on", function()
        SettingsPage:showSettings()
        local menu = lastMenu()
        tap("Show Book Covers")
        tap("Check for Updates Automatically")

        assert.are.equal(1, #helper.state.shown)
        assert.is_false(helper.wasClosed(menu))
        assert.are.equal(-1, menu.switched_to_item)
        for _, refresh in ipairs(helper.state.refreshes) do
            assert.are_not.equal("full", refresh[1])
        end
    end)

    it("turns automatic update checks off and on", function()
        SettingsPage:showSettings()
        tap("Check for Updates Automatically")

        assert.is_false(Settings:getCheckForUpdates())
        assert.are.equal("Check for Updates Automatically: ☐", lastMenu().item_table[6].text)
        assert.are.equal("Update checks updated", helper.lastNotification())

        tap("Check for Updates Automatically")
        assert.is_true(Settings:getCheckForUpdates())
    end)

    describe("cache expiry", function()
        it("sets how long searches are kept", function()
            SettingsPage:showSettings()
            tap("Keep Searches For")
            assert.are.equal("Keep Searches For", lastMenu().title)
            assert.are.same(
                { "○ 1 day", "○ 3 days", "○ 7 days", "◉ 14 days", "○ 30 days" },
                itemTexts(lastMenu())
            )

            local choices = lastMenu()
            tap("30 days")
            assert.are.equal(30, Settings:getSearchCacheExpiryDays())
            assert.are.equal("Cache expiry updated", helper.lastNotification())
            -- back in the settings, which were open underneath
            assert.is_true(helper.wasClosed(choices))
            assert.are.equal("Keep Searches For: 30 days", lastMenu().item_table[7].text)
            assert.are.equal(2, #helper.state.shown)
        end)

        it("sets how long mirrors are kept", function()
            SettingsPage:showSettings()
            tap("Keep Mirrors For")
            tap("1 day")

            assert.are.equal(1, Settings:getMirrorCacheExpiryDays())
            assert.are.equal("Keep Mirrors For: 1 day", lastMenu().item_table[8].text)
        end)
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
            assert.are.equal("Invalid directory path", helper.lastError())
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

            assert.are.same({ "es", "fr" }, Settings:getPreferredLanguages())
            assert.are.equal("Languages updated", helper.lastNotification())
            assert.are.equal("Preferred Languages: es, fr", lastMenu().item_table[3].text)
        end)

        -- there are eight pages of languages, and each tick used to go back to the first
        it("are ticked in the menu that's open, on the page it's on", function()
            SettingsPage:showSettings()
            tap("Preferred Languages")
            local languages = lastMenu()
            tap("Welsh")
            tap("Welsh")
            tap("Zulu")

            assert.are.equal(languages, lastMenu())
            assert.are.equal(2, #helper.state.shown)
            assert.are.equal(-1, languages.switched_to_item)
            local ticked = {}
            for _, text in ipairs(itemTexts(languages)) do
                if text:find("☑", 1, true) then
                    table.insert(ticked, text)
                end
            end
            assert.are.same({ "☑ English", "☑ Zulu" }, ticked)
        end)

        it("stay as they were, with their menu still open, while none are ticked", function()
            SettingsPage:showSettings()
            tap("Preferred Languages")
            local languages = lastMenu()
            tap("English")
            languages.onClose()

            assert.is_false(helper.wasClosed(languages))
            tap("French")
            languages.onClose()
            assert.is_true(helper.wasClosed(languages))
            assert.are.same({ "fr" }, Settings:getPreferredLanguages())
        end)

        it("cannot all be unticked", function()
            SettingsPage:showSettings()
            tap("Preferred Languages")
            tap("English")
            lastMenu().onClose()

            assert.are.same({ "en" }, Settings:getPreferredLanguages())
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
            -- every one is ticked by default
            assert.are.equal("☑ epub", menu.item_table[2].text)
            assert.are.equal("☑ mobi", menu.item_table[3].text)
        end)

        it("are saved when the menu is closed", function()
            SettingsPage:showSettings()
            tap("Preferred File Types")
            tap("☑ mobi")
            tap("☑ pdf")
            lastMenu().onClose()

            assert.are.same({
                "epub",
                "azw",
                "fb2",
                "prc",
                "cbr",
                "cbz",
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
            assert.are.equal("File types updated", helper.lastNotification())
        end)

        it("cannot all be unticked", function()
            SettingsPage:showSettings()
            tap("Preferred File Types")
            local all = Settings:getPreferredFileTypes()
            for _, ext in ipairs(all) do
                tap("☑ " .. ext)
            end
            lastMenu().onClose()

            assert.are.same(all, Settings:getPreferredFileTypes())
            assert.are.equal("Select at least one file type", helper.lastNotification())
        end)
    end)

    describe("preferred book types", function()
        it("are saved when the menu is closed", function()
            SettingsPage:showSettings()
            tap("Preferred Book Types")
            assert.are.equal("☑ Fiction", lastMenu().item_table[1].text)

            tap("☑ Non-fiction")
            tap("☑ Comics")
            lastMenu().onClose()

            assert.are.same({ "fiction", "magazines", "articles", "standards" }, Settings:getPreferredBookTypes())
            assert.are.equal("Book types updated", helper.lastNotification())
        end)

        it("cannot all be unticked", function()
            SettingsPage:showSettings()
            tap("Preferred Book Types")
            for _, name in ipairs({
                "Fiction",
                "Non-fiction",
                "Comics",
                "Magazines",
                "Scientific articles",
                "Standards",
            }) do
                tap("☑ " .. name)
            end
            lastMenu().onClose()

            assert.are.same(
                { "fiction", "nonfiction", "comics", "magazines", "articles", "standards" },
                Settings:getPreferredBookTypes()
            )
            assert.are.equal("Select at least one book type", helper.lastNotification())
        end)
    end)

    -- they had to be found and deleted by hand when they no longer matched what Library Genesis has
    describe("clearing the cache", function()
        local cleared

        before_each(function()
            cleared = {}
            for _, name in ipairs({ "search", "url", "cover" }) do
                helper.stub("cache." .. name .. "cache", {
                    clear = function()
                        table.insert(cleared, name)
                    end,
                })
            end
            package.loaded["settings.settingspage"] = nil
            SettingsPage = require("settings.settingspage")
        end)

        it("asks first", function()
            SettingsPage:showSettings()
            tap("Clear Cache")

            local confirm = helper.lastShown()
            assert.are.equal("Clear the searches, mirrors and book covers that Kindle Fetch has saved?", confirm.text)
            assert.are.equal("Clear", confirm.ok_text)
            assert.are.same({}, cleared)
        end)

        it("forgets the searches, mirrors and book covers that are saved", function()
            SettingsPage:showSettings()
            tap("Clear Cache")
            helper.lastShown().ok_callback()

            assert.are.same({ "search", "url", "cover" }, cleared)
            assert.are.equal("Cache cleared", helper.lastNotification())
        end)
    end)
end)
