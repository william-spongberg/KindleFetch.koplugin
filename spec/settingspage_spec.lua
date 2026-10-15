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

    -- the button in a dialog with the given text
    local function button(dialog, text)
        for _, row in ipairs(dialog.buttons) do
            for _, b in ipairs(row) do
                if b.text == text then
                    return b
                end
            end
        end
        error("no button " .. text)
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
            "Download Folder: " .. SettingsPage.shortenFolder(helper.abs(data_dir)),
            "Z-Library Account: Not logged in",
            -- by name, rather than the codes they're saved as
            "Preferred Languages: English",
            "Preferred File Types: All",
            "Preferred Book Types: All",
            "Check for Updates Automatically: ☑",
            "Keep Searches For: 14 days",
            "Keep Mirrors For: 7 days",
            "HTTP Proxy: Off",
            "Clear Cache",
        }, itemTexts(lastMenu()))
        assert.are.equal("Kindle Fetch Settings", lastMenu().title)
    end)

    -- rather than a list too long to fit, or codes
    it("names the file types and book types chosen, when they aren't all", function()
        Settings:setPreferredFileTypes({ "pdf", "epub" })
        Settings:setPreferredBookTypes({ "nonfiction", "fiction" })
        SettingsPage:showSettings()

        -- in the order they're listed in
        assert.are.equal("Preferred File Types: epub, pdf", lastMenu().item_table[5].text)
        assert.are.equal("Preferred Book Types: Fiction, Non-fiction", lastMenu().item_table[6].text)
    end)

    describe("Z-Library account", function()
        local logins

        before_each(function()
            logins = {}
            helper.stub("ui.zliblogin", {
                show = function(on_logged_in)
                    table.insert(logins, on_logged_in)
                end,
            })
            SettingsPage = dofile("kindlefetch.koplugin/settings/settingspage.lua")
        end)

        it("logs in, showing the account's email once it has", function()
            SettingsPage:showSettings()
            tap("Z-Library Account: Not logged in")
            assert.are.equal(1, #logins)

            Settings:setZlibAccount({ email = "reader@example.com", user_id = 42, user_key = "key" })
            logins[1]()
            assert.are.equal("Z-Library Account: reader@example.com", lastMenu().item_table[3].text)
        end)

        it("logs out once asked if it should", function()
            Settings:setZlibAccount({ email = "reader@example.com", user_id = 42, user_key = "key" })
            SettingsPage:showSettings()
            tap("Z-Library Account: reader@example.com")

            local confirm = helper.lastShown()
            assert.are.equal("Log out of Z-Library (reader@example.com)?", confirm.text)
            assert.are.equal("Log out", confirm.ok_text)
            assert.is_not_nil(Settings:getZlibAccount())

            confirm.ok_callback()
            assert.is_nil(Settings:getZlibAccount())
            assert.are.equal("Z-Library Account: Not logged in", lastMenu().item_table[3].text)
            assert.are.equal(0, #logins)
        end)
    end)

    -- whose end says the most about it, where the menu would cut it off
    it("shows the end of a long download folder", function()
        assert.are.equal("/mnt/us/documents/books", SettingsPage.shortenFolder("/mnt/us/documents/books"))
        assert.are.equal(
            "…/e2e/kindle-paperwhite/books",
            SettingsPage.shortenFolder("/home/someone/Documents/dev/projects/KindleFetch/e2e/kindle-paperwhite/books")
        )
        local long_name = "/" .. string.rep("a very long folder name ", 3)
        assert.are.equal("…" .. long_name, SettingsPage.shortenFolder("/mnt/us/documents" .. long_name))
    end)

    -- rounded corners aren't painted, so the top edge of KOReader's menu showed in the corners of the settings
    it("fills the screen to its corners, as do the menus it opens", function()
        SettingsPage:showSettings()
        local settings = lastMenu()
        tap("Preferred Languages")
        local languages = lastMenu()

        assert.are_not.equal(settings, languages)
        for _, menu in ipairs({ settings, languages }) do
            assert.is_true(menu.covers_fullscreen)
            assert.is_false(menu.is_popout)
        end
    end)

    it("toggles book covers", function()
        SettingsPage:showSettings()
        tap("Show Book Covers")

        assert.is_false(Settings:getShowBookCovers())
        assert.are.equal("Show Book Covers: ☐", lastMenu().item_table[1].text)
        -- which isn't said as well, as each notification refreshes the screen twice
        assert.are.equal(0, #helper.state.notifications)
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
        assert.are.equal("Check for Updates Automatically: ☐", lastMenu().item_table[7].text)
        assert.are.equal(0, #helper.state.notifications)

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
            assert.are.equal(0, #helper.state.notifications)
            -- back in the settings, which were open underneath
            assert.is_true(helper.wasClosed(choices))
            assert.are.equal("Keep Searches For: 30 days", lastMenu().item_table[8].text)
            assert.are.equal(2, #helper.state.shown)
        end)

        it("sets how long mirrors are kept", function()
            SettingsPage:showSettings()
            tap("Keep Mirrors For")
            tap("1 day")

            assert.are.equal(1, Settings:getMirrorCacheExpiryDays())
            assert.are.equal("Keep Mirrors For: 1 day", lastMenu().item_table[9].text)
        end)
    end)

    -- KOReader's, which Kindle Fetch goes through for everything
    describe("HTTP proxy", function()
        it("turns KOReader's on, saying which it is, without who it's logged into as", function()
            SettingsPage:showSettings()
            tap("HTTP Proxy")
            local dialog = helper.lastShown()
            assert.are.equal("http://", dialog.input)
            assert.is_true(dialog.keyboard_shown)
            assert.is_false(button(dialog, "Turn off").enabled)

            dialog.input_text = " http://reader:secret@proxy.example:8080 "
            button(dialog, "Turn on").callback()
            assert.is_true(helper.wasClosed(dialog))
            assert.are.equal("http://reader:secret@proxy.example:8080", require("socket.http").PROXY)
            assert.is_true(helper.state.reader_settings.http_proxy_enabled)
            assert.are.equal("HTTP Proxy: http://proxy.example:8080", lastMenu().item_table[10].text)
            for _, log in ipairs(helper.state.logs) do
                for i = 3, #log do
                    assert.is_nil(tostring(log[i]):find("secret", 1, true))
                end
            end
        end)

        it("turns it off, keeping its address for next time", function()
            require("ui/network/manager"):setHTTPProxy("http://proxy.example:8080")
            SettingsPage:showSettings()
            assert.are.equal("HTTP Proxy: http://proxy.example:8080", lastMenu().item_table[10].text)
            tap("HTTP Proxy")
            local dialog = helper.lastShown()
            assert.are.equal("http://proxy.example:8080", dialog.input)

            button(dialog, "Turn off").callback()
            assert.is_nil(require("socket.http").PROXY)
            assert.is_false(helper.state.reader_settings.http_proxy_enabled)
            assert.are.equal("http://proxy.example:8080", helper.state.reader_settings.http_proxy)
            assert.are.equal("HTTP Proxy: Off", lastMenu().item_table[10].text)
        end)

        it("only turns on what's an address", function()
            SettingsPage:showSettings()
            tap("HTTP Proxy")
            local dialog = helper.lastShown()
            dialog.input_text = "proxy.example:8080"
            button(dialog, "Turn on").callback()

            assert.is_false(helper.wasClosed(dialog))
            assert.is_nil(require("socket.http").PROXY)
            assert.are.equal("Enter the proxy's address, e.g. http://proxy.example:8080", helper.lastNotification())
        end)
    end)

    -- which would go back to what it was
    it("says when a change couldn't be saved", function()
        SettingsPage:showSettings()
        helper.state.settings_unwritable = true
        tap("Show Book Covers")
        assert.are.equal("Kindle Fetch's settings couldn't be saved", helper.lastError())
    end)

    describe("download folder", function()
        it("can be changed", function()
            local books = helper.tmpdir("books")
            SettingsPage:showSettings()
            tap("Download Folder")
            helper.state.dir_choosers[1].onConfirm(books)

            assert.are.equal(books, Settings:getDownloadDir())
            assert.are.equal(0, #helper.state.notifications)
            assert.are.equal("Download Folder: " .. books, lastMenu().item_table[2].text)
        end)

        it("must exist", function()
            SettingsPage:showSettings()
            tap("Download Folder")
            helper.state.dir_choosers[1].onConfirm(data_dir .. "/missing")

            assert.are.equal(helper.abs(data_dir), Settings:getDownloadDir())
            assert.are.equal(
                "Books can't be downloaded to " .. data_dir .. "/missing: it doesn't exist",
                helper.lastError()
            )
        end)

        it("must be one books can be saved in", function()
            SettingsPage:showSettings()
            tap("Download Folder")
            helper.state.dir_choosers[1].onConfirm("/proc")

            assert.matches("^Books can't be downloaded to /proc: it can't be written to", helper.lastError())
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
            assert.are.equal(0, #helper.state.notifications)
            assert.are.equal("Preferred Languages: Spanish, French", lastMenu().item_table[4].text)
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

        -- from the results, rather than the settings (see KindleFetch:changeChoices)
        it("can be chosen on their own, saying once chosen whether they've changed", function()
            local changes = {}
            local function onClosed(changed)
                table.insert(changes, changed)
            end
            SettingsPage:changeLanguages(onClosed)
            local languages = lastMenu()
            -- filling the screen
            assert.are.equal(600, languages.width)
            assert.are.equal(800, languages.height)
            languages.onClose()
            assert.are.same({ false }, changes)

            SettingsPage:changeLanguages(onClosed)
            tap("English")
            tap("French")
            lastMenu().onClose()
            assert.are.same({ false, true }, changes)
            assert.are.same({ "fr" }, Settings:getPreferredLanguages())

            -- once there are some ticked
            SettingsPage:changeLanguages(onClosed)
            tap("French")
            lastMenu().onClose()
            assert.are.same({ false, true }, changes)
        end)

        -- e.g. from the results, after the settings were opened and closed
        it("leave the settings alone once they've been closed", function()
            SettingsPage:showSettings()
            local settings = lastMenu()
            helper.stubs.uimanager:close(settings)
            SettingsPage:changeLanguages()
            tap("French")
            lastMenu().onClose()

            assert.is_nil(settings.switched_to_item)
        end)

        -- as the settings show what's chosen
        it("are saved without saying anything", function()
            SettingsPage:showSettings()
            tap("Preferred Languages")
            tap("English")
            tap("French")
            lastMenu().onClose()

            assert.are.same({ "fr" }, Settings:getPreferredLanguages())
            for _, widget in ipairs(helper.state.shown) do
                assert.are_not.equal("notice-warning", widget.icon)
            end
        end)

        -- which KOReader's Home key closes, then sends Home on again until what's on top has changed, which it
        -- never did while the menu stayed open with nothing ticked
        it("are left as they were when KOReader's Home key closes their menu with none ticked", function()
            local Menu = require("ui/widget/menu")
            Menu.onHome = function(self)
                self:onClose()
                return true
            end
            SettingsPage:showSettings()
            tap("Preferred Languages")
            local languages = lastMenu()
            tap("English")
            languages:onHome()

            assert.is_true(helper.wasClosed(languages))
            assert.are.same({ "en" }, Settings:getPreferredLanguages())
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
            assert.are.equal(0, #helper.state.notifications)
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
            assert.are.equal(0, #helper.state.notifications)
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
            Settings:addRecentSearch("dune")
            SettingsPage:showSettings()
            tap("Clear Cache")
            helper.lastShown().ok_callback()

            assert.are.same({ "search", "url", "cover" }, cleared)
            -- and the searches made recently
            assert.are.same({}, Settings:getRecentSearches())
            assert.are.equal("Cache cleared", helper.lastNotification())
        end)
    end)
end)
