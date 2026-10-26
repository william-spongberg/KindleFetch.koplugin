local helper = require("helper")
local fixtures = require("fixtures")

describe("LibrarySettings", function()
    local web, LibrarySettings, Settings, MultiSearch, added

    local CALIBRE_WEB_FEED = '<feed xmlns="http://www.w3.org/2005/Atom"><title>Will\'s Books</title>'
        .. "<author><name>Will's Books</name><uri>https://github.com/janeczku/calibre-web</uri></author>"
        .. '<link type="application/atom+xml" rel="search" title="Search" href="/opds/search/{searchTerms}"/></feed>'

    -- Calibre's content server's, with each of its libraries
    local function calibreFeed(...)
        local entries = {}
        for _, name in ipairs({ ... }) do
            table.insert(
                entries,
                string.format(
                    '<entry><title>Library: %s</title><id>calibre-library:%s</id><link href="/opds?library_id=%s" '
                        .. 'type="application/atom+xml;type=feed;profile=opds-catalog;kind=navigation"/></entry>',
                    name,
                    name,
                    name
                )
            )
        end
        return '<feed xmlns="http://www.w3.org/2005/Atom"><title>calibre Library</title>'
            .. "<author><name>calibre</name><uri>https://calibre-ebook.com</uri></author>"
            .. '<link rel="search" title="Search" href="/opds/search/{searchTerms}?library_id=Books" '
            .. 'type="application/atom+xml"/>'
            .. table.concat(entries)
            .. "</feed>"
    end

    -- the dialog last shown with boxes to type in
    local function inputDialog()
        for i = #helper.state.shown, 1, -1 do
            if helper.state.shown[i].fields then
                return helper.state.shown[i]
            end
        end
    end

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

    -- type into the boxes of the dialog showing, and tap one of its buttons
    local function typeAndTap(texts, text)
        local dialog = inputDialog()
        for i, typed in pairs(texts) do
            dialog.fields[i].text = typed
        end
        button(dialog, text).callback()
    end

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        helper.state.fs["/mnt/us/documents"] = false
        web = fixtures.fakeWeb(helper)
        added = 0
        Settings = require("settings.settings")
        LibrarySettings = require("ui.librarysettings")
        MultiSearch = require("api.multisearch")
    end)

    after_each(helper.cleanup)

    local function onAdded()
        added = added + 1
    end

    describe("an address typed in", function()
        it("is a web address, http:// where it doesn't say", function()
            assert.are.equal("http://192.168.1.10:8080", LibrarySettings.normalise(" 192.168.1.10:8080 "))
            assert.are.equal(
                "https://books.example/calibre",
                LibrarySettings.normalise("https://books.example/calibre//")
            )
        end)

        -- so it's never logged, nor on curl's command line
        it("gives who it logs in as as the username and password instead", function()
            assert.are.same(
                { "http://nas:8080/opds", "will", "p@ss" },
                { LibrarySettings.normalise("http://will:p%40ss@nas:8080/opds") }
            )
        end)

        it("isn't one where it can't be", function()
            assert.is_nil(LibrarySettings.normalise(""))
            assert.is_nil(LibrarySettings.normalise("not an address"))
        end)
    end)

    describe("adding a library", function()
        it("asks for its address and login, hiding the password", function()
            LibrarySettings.add(onAdded)
            local dialog = inputDialog()
            assert.are.equal("Add a library", dialog.title)
            assert.are.equal("Address, e.g. 192.168.1.10:8080", dialog.fields[1].hint)
            assert.are.equal("password", dialog.fields[3].text_type)
            assert.is_true(dialog.keyboard_shown)
        end)

        it("finds its catalogue at the address, and adds it, to search from then on", function()
            web.pages["http://nas:8083"] = "<html>Calibre-Web</html>"
            web.pages["http://nas:8083/opds"] = CALIBRE_WEB_FEED
            LibrarySettings.add(onAdded)
            typeAndTap({ "nas:8083", "will", "secret" }, "Add")

            assert.are.equal(1, added)
            local library = Settings:getLibraries()[1]
            assert.are.equal("Will's Books", library.name)
            assert.are.equal("calibre-web", library.kind)
            assert.are.equal("http://nas:8083/opds", library.url)
            assert.are.equal("will", library.username)
            assert.are.equal("secret", library.password)
            assert.are.equal("library_" .. library.id, MultiSearch.sources()[1])
            assert.matches("^Added Will's Books", helper.lastNotification())
        end)

        it("doesn't log in without a username", function()
            web.pages["http://nas:8083/opds"] = CALIBRE_WEB_FEED
            LibrarySettings.add(onAdded)
            typeAndTap({ "nas:8083/opds", "", "secret" }, "Add")
            assert.are.equal("", Settings:getLibraries()[1].username)
        end)

        it("asks again, with what was typed, when its catalogue can't be found there", function()
            web.pages["http://nas:8083"] = "<html>Welcome</html>"
            web.pages["http://nas:8083/opds"] = "<html>Not here</html>"
            LibrarySettings.add(onAdded)
            typeAndTap({ "nas:8083", "will", "secret" }, "Add")

            assert.are.equal(0, added)
            assert.are.same({}, Settings:getLibraries())
            assert.are.equal(
                "The library couldn't be added: there's no OPDS catalogue at that address",
                helper.lastError()
            )
            assert.are.same({ "http://nas:8083", "will", "secret" }, inputDialog():getFields())
        end)

        it("asks for the address first", function()
            LibrarySettings.add(onAdded)
            local dialog = inputDialog()
            typeAndTap({ "  " }, "Add")
            assert.are.equal("Enter the library's address, e.g. 192.168.1.10:8080", helper.lastNotification())
            assert.is_false(helper.wasClosed(dialog))
        end)

        -- each of which is a library of its own, with its own search
        it("asks which of Calibre's libraries to add, where it has several", function()
            web.pages["http://nas:8080/opds"] = calibreFeed("Books", "Comics")
            LibrarySettings.add(onAdded)
            typeAndTap({ "nas:8080/opds" }, "Add")

            local chooser = helper.lastShown()
            assert.matches("several libraries", chooser.title)
            assert.are.equal("Books", chooser.buttons[1][1].text)
            assert.are.equal("Comics", chooser.buttons[2][1].text)
            assert.are.equal("All 2", chooser.buttons[3][1].text)

            chooser.buttons[2][1].callback()
            local library = Settings:getLibraries()[1]
            assert.are.equal("Comics", library.name)
            assert.are.equal("http://nas:8080/opds?library_id=Comics", library.url)
            assert.are.equal("http://nas:8080/opds/search/{searchTerms}?library_id=Comics", library.search_url)
            assert.are.equal(1, added)
        end)

        it("adds all of Calibre's libraries at once, when asked to", function()
            web.pages["http://nas:8080/opds"] = calibreFeed("Books", "Comics")
            LibrarySettings.add(onAdded)
            typeAndTap({ "nas:8080/opds" }, "Add")
            helper.lastShown().buttons[3][1].callback()

            local libraries = Settings:getLibraries()
            assert.are.same({ "Books", "Comics" }, { libraries[1].name, libraries[2].name })
            assert.matches("^Added Books, Comics", helper.lastNotification())
        end)

        it("adds Calibre's one library by its name", function()
            web.pages["http://nas:8080/opds"] = calibreFeed("Books")
            LibrarySettings.add(onAdded)
            typeAndTap({ "nas:8080/opds" }, "Add")
            assert.are.equal("Books", Settings:getLibraries()[1].name)
        end)
    end)

    describe("a library added", function()
        local library

        before_each(function()
            library = require("api.libraries").add({
                url = "http://nas:8083/opds",
                name = "Will's Books",
                kind = "calibre-web",
                search_url = "http://nas:8083/opds/search/{searchTerms}",
            }, { username = "will", password = "secret" })
        end)

        it("is listed to edit or remove, after adding another", function()
            local menus = {}
            LibrarySettings.show(function(title, items)
                local menu = { title = title, item_table = items }
                function menu:switchItemTable(_, new_items)
                    self.item_table = new_items
                end
                table.insert(menus, menu)
                return menu
            end)
            local menu = menus[1]
            assert.are.equal("Your Libraries", menu.title)
            assert.are.equal("Add a library…", menu.item_table[1].text)
            assert.are.equal("Will's Books · Calibre-Web", menu.item_table[2].text)

            menu.item_table[2].callback()
            local dialog = helper.lastShown()
            assert.are.equal("Will's Books · nas:8083", dialog.title)
            assert.are.equal("Edit…", dialog.buttons[1][1].text)
            assert.are.equal("Remove", dialog.buttons[1][2].text)
        end)

        it("is renamed without asking its site again", function()
            local changed = 0
            LibrarySettings.edit(library, function()
                changed = changed + 1
            end)
            typeAndTap({ "Home" }, "Save")

            assert.are.equal(1, changed)
            assert.are.equal("Home", Settings:getLibraries()[1].name)
            assert.are.same({}, web.fetched)
        end)

        it("is found again at a new address", function()
            web.pages["http://nas:9000/opds"] = CALIBRE_WEB_FEED
            LibrarySettings.edit(library, function() end)
            typeAndTap({ [2] = "nas:9000/opds" }, "Save")

            local saved = Settings:getLibraries()[1]
            assert.are.equal("http://nas:9000/opds", saved.url)
            assert.are.equal("Will's Books", saved.name)
            assert.are.equal("will", saved.username)
            assert.are.equal(library.id, saved.id)
        end)

        it("is removed once that's confirmed", function()
            local changed = 0
            LibrarySettings.remove(library, function()
                changed = changed + 1
            end)
            local confirm = helper.lastShown()
            assert.matches("^Remove Will's Books from Kindle Fetch%?", confirm.text)
            confirm.ok_callback()

            assert.are.equal(1, changed)
            assert.are.same({}, Settings:getLibraries())
            assert.are.same({ "zlib", "libgen", "archive", "gutenberg" }, MultiSearch.sources())
        end)

        it("is named in the settings", function()
            assert.are.equal("Will's Books", LibrarySettings.describe())
        end)
    end)

    it("names none in the settings, where none have been added", function()
        assert.are.equal("None", LibrarySettings.describe())
    end)
end)
