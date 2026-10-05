local helper = require("helper")

describe("KindleFetch", function()
    local KindleFetch, checks, settings, searches, search_results, downloads, menus, settings_shown, cleared, plugin_dir
    local cancelled_downloads, curl_check_user_requested, leftovers_removed
    -- pages of results saved from earlier searches, as "query page"
    local saved

    -- KOReader creates a new plugin instance for the file manager and for every book that is opened
    local opened
    -- KOReader's file manager and reader, of which one is open at a time (the file manager here, until a spec
    -- opens a book with readBook)
    local FileManager, ReaderUI

    local function openUI()
        opened = nil
        return KindleFetch:new {
            ui = {
                menu = {
                    registerToMainMenu = function() end,
                },
            },
        }
    end

    -- close the file manager and open a book, as KOReader does
    local function readBook()
        FileManager.instance = nil
        ReaderUI.instance = {
            document = {},
            switchDocument = function(_, file)
                opened = { "switchDocument", file }
            end,
        }
    end

    local function book(title, file_type)
        return {
            md5 = title:lower(),
            title = title,
            display_title = title,
            file_type = file_type or "epub",
        }
    end

    -- open the search dialog and search for query
    local function search(plugin, query)
        plugin:setupUI()
        plugin.search_box.input_text = query
        plugin.search_box.buttons[1][2].callback()
    end

    local function itemTexts(menu)
        local texts = {}
        for _, item in ipairs(menu.item_table) do
            table.insert(texts, item.book and item.book.title or item.text)
        end
        return texts
    end

    before_each(function()
        helper.reset()
        checks = {
            curl = 0,
            plugin = 0,
        }
        settings = {
            show_covers = true,
            download_dir = "/mnt/us/documents",
            last_version = "0.4",
            check_for_updates = true,
            languages = { "en" },
            file_types = { "epub" },
            book_types = { "fiction" },
        }
        searches, search_results, downloads, menus, settings_shown = {}, {}, {}, {}, 0
        saved = {}

        helper.stub("settings.settings", {
            load = function() end,
            getShowBookCovers = function()
                return settings.show_covers
            end,
            getDownloadDir = function()
                return settings.download_dir
            end,
            getCheckForUpdates = function()
                return settings.check_for_updates
            end,
            getLastUpdateCheck = function()
                return settings.last_update_check
            end,
            getLastVersion = function()
                return settings.last_version
            end,
            setLastVersion = function(_, version)
                settings.last_version = version
            end,
            getPreferredLanguages = function()
                return settings.languages
            end,
            getPreferredFileTypes = function()
                return settings.file_types
            end,
            getPreferredBookTypes = function()
                return settings.book_types
            end,
        })

        cleared = {
            search = 0,
            mirrors = 0,
        }
        helper.stub("cache.searchcache", {
            clear = function()
                cleared.search = cleared.search + 1
            end,
        })
        helper.stub("cache.urlcache", {
            clear = function()
                cleared.mirrors = cleared.mirrors + 1
            end,
        })
        plugin_dir = helper.tmpdir("plugin")
        helper.writeFile(plugin_dir .. "/version.txt", "0.4\n")
        helper.stub("util.pathutil", {
            getPluginPath = function()
                return plugin_dir
            end,
        })
        helper.stub("settings.settingspage", {
            showSettings = function()
                settings_shown = settings_shown + 1
            end,
        })
        helper.stub("api.lglisearch", {
            search = function(_, query, page)
                table.insert(searches, { query, page })
                -- books, error, and the page to carry on from
                local result = search_results[page] or { {} }
                return result[1], result[2], result[3]
            end,
            isCached = function(_, query, page)
                return saved[query .. " " .. page] == true
            end,
        })
        cancelled_downloads = 0
        curl_check_user_requested = nil

        FileManager = {
            instance = {
                openFile = function(_, file)
                    opened = { "openFile", file }
                end,
            },
        }
        ReaderUI = {
            showReader = function(_, file)
                opened = { "showReader", file }
            end,
        }
        helper.stub("apps/filemanager/filemanager", FileManager)
        helper.stub("apps/reader/readerui", ReaderUI)
        helper.stub("api.lgliapi", {
            cancelAllDownloads = function()
                cancelled_downloads = cancelled_downloads + 1
            end,
            downloadBook = function(_, download_book, filepath, callback, open_existing)
                table.insert(downloads, {
                    book = download_book,
                    filepath = filepath,
                    callback = callback,
                    open_existing = open_existing,
                })
            end,
        })
        helper.stub("ui.bookmenu", {
            new = function(_, menu)
                menu.covers_loaded = {}
                function menu:loadCoversForPage(page)
                    table.insert(self.covers_loaded, page)
                end
                table.insert(menus, menu)
                return menu
            end,
        })
        helper.stub("cache.covercache", {})
        leftovers_removed = 0
        helper.stub("util.curlutil", {
            getVersion = function()
                return "8.17.0"
            end,
            removeLeftovers = function()
                leftovers_removed = leftovers_removed + 1
            end,
        })
        helper.stub("updater.curlupdater", {
            checkVersion = function(user_requested)
                checks.curl = checks.curl + 1
                curl_check_user_requested = user_requested
            end,
        })
        helper.stub("updater.pluginupdater", {
            checkForUpdates = function(user_requested)
                checks.plugin = checks.plugin + 1
                checks.user_requested = user_requested
            end,
        })

        -- KOReader loads main.lua once per session
        KindleFetch = dofile("kindlefetch.koplugin/main.lua")
    end)

    after_each(helper.cleanup)

    describe("exiting", function()
        it("cancels downloads when KOReader exits", function()
            -- returning nothing lets the exit event carry on to the rest of KOReader
            assert.is_nil(openUI():onExit())
            assert.are.equal(1, cancelled_downloads)
        end)

        it("cancels downloads when KOReader restarts", function()
            assert.is_nil(openUI():onRestart())
            assert.are.equal(1, cancelled_downloads)
        end)
    end)

    -- to make sense of a crash.log from someone's device
    it("logs the versions and settings in use, once per session", function()
        openUI()
        openUI()

        local summaries = {}
        for _, log in ipairs(helper.state.logs) do
            if log[1] == "info" and tostring(log[3]):find("^KindleFetch %S+ on KOReader") then
                table.insert(summaries, log[3])
            end
        end
        assert.are.equal(1, #summaries)
        assert.matches("KindleFetch 0.4 on KOReader .*, curl 8.17.0", summaries[1])
    end)

    -- KOReader may have closed while they were running
    it("removes the files left by earlier downloads, once per session", function()
        openUI()
        openUI()
        assert.are.equal(1, leftovers_removed)
    end)

    describe("after an update", function()
        it("clears cached searches and mirrors", function()
            settings.last_version = "0.3"
            openUI()

            assert.are.same({ search = 1, mirrors = 1 }, cleared)
            assert.are.equal("0.4", settings.last_version)
        end)

        it("clears them the first time the plugin runs", function()
            settings.last_version = nil
            openUI()

            assert.are.same({ search = 1, mirrors = 1 }, cleared)
            assert.are.equal("0.4", settings.last_version)
        end)

        it("keeps them while the version stays the same", function()
            openUI()
            assert.are.same({ search = 0, mirrors = 0 }, cleared)
        end)

        it("only checks once per session", function()
            settings.last_version = "0.3"
            openUI()
            settings.last_version = "0.2"
            openUI()

            assert.are.same({ search = 1, mirrors = 1 }, cleared)
        end)

        it("does nothing when the installed version is unknown", function()
            settings.last_version = "0.3"
            os.remove(plugin_dir .. "/version.txt")
            openUI()

            assert.are.same({ search = 0, mirrors = 0 }, cleared)
            assert.are.equal("0.3", settings.last_version)
        end)
    end)

    describe("init", function()
        it("registers a dispatcher action", function()
            openUI()
            assert.are.equal("KindleFetch", helper.state.actions.kindlefetch_action.event)
        end)

        it("opens the search dialog when the dispatcher action is used", function()
            local plugin = openUI()
            local event = helper.state.actions.kindlefetch_action.event

            -- KOReader calls the on<Event> handler for the action's event
            assert.is_true(plugin["on" .. event](plugin))
            assert.are.equal(plugin.search_box, helper.lastShown())
        end)

        it("checks for updates once the UI is ready", function()
            openUI()
            assert.are.same({ curl = 0, plugin = 0 }, checks)

            helper.runScheduled()
            assert.are.same({ curl = 1, plugin = 1, user_requested = false }, checks)
        end)

        it("does not check for updates when automatic checks are turned off", function()
            settings.check_for_updates = false
            openUI()
            helper.runScheduled()

            assert.are.same({ curl = 0, plugin = 0 }, checks)
        end)

        it("only checks for updates once per session", function()
            openUI()
            helper.runScheduled()
            openUI()
            openUI()
            helper.runScheduled()

            assert.are.same({ curl = 1, plugin = 1, user_requested = false }, checks)
        end)

        it("checks for updates automatically at most once a day", function()
            helper.state.time = 2000000
            settings.last_update_check = 2000000 - 24 * 60 * 60 + 1
            openUI()
            helper.runScheduled()
            assert.are.same({ curl = 0, plugin = 0 }, checks)

            -- KOReader has been restarted a second later
            KindleFetch = dofile("kindlefetch.koplugin/main.lua")
            helper.state.time = 2000001
            openUI()
            helper.runScheduled()
            assert.are.same({ curl = 1, plugin = 1, user_requested = false }, checks)
        end)

        -- an e-reader's clock can be wrong, or be put right, between checks
        it("checks for updates when the last check appears to be in the future", function()
            helper.state.time = 2000000
            settings.last_update_check = 2000000 + 7 * 24 * 60 * 60
            openUI()
            helper.runScheduled()

            assert.are.same({ curl = 1, plugin = 1, user_requested = false }, checks)
        end)

        it("waits for a network connection before checking for updates", function()
            helper.stubs.network.connected = false
            openUI()
            helper.runScheduled()
            assert.are.same({ curl = 0, plugin = 0 }, checks)

            helper.stubs.network.connected = true
            openUI()
            helper.runScheduled()
            assert.are.same({ curl = 1, plugin = 1, user_requested = false }, checks)
        end)
    end)

    describe("main menu", function()
        local function menuItem(plugin, text)
            local menu_items = {}
            plugin:addToMainMenu(menu_items)
            assert.are.equal("Kindle Fetch", menu_items.kindlefetch.text)
            for _, item in ipairs(menu_items.kindlefetch.sub_item_table) do
                if item.text == text then
                    return item
                end
            end
        end

        it("opens the search dialog", function()
            local plugin = openUI()
            menuItem(plugin, "Search Library Genesis").callback()

            assert.are.equal("Search Library Genesis", plugin.search_box.title)
            assert.are.equal(plugin.search_box, helper.lastShown())
        end)

        it("opens the settings", function()
            menuItem(openUI(), "Settings").callback()
            assert.are.equal(1, settings_shown)
        end)

        it("checks for updates when asked, even if automatic checks are off", function()
            settings.check_for_updates = false
            menuItem(openUI(), "Check for updates").callback()

            assert.are.same({ curl = 1, plugin = 1, user_requested = true }, checks)
            -- so updating curl is offered again, even if it was turned down before
            assert.is_true(curl_check_user_requested)
            assert.are.equal("Checking for updates...", helper.lastNotification())
        end)

        it("connects to wifi before checking for updates", function()
            helper.stubs.network.connected = false
            menuItem(openUI(), "Check for updates").callback()
            assert.are.same({ curl = 0, plugin = 0 }, checks)
            assert.are.equal("turn wifi on", helper.stubs.network.prompted)

            helper.stubs.network.connected = true
            helper.stubs.network.when_connected()
            assert.are.same({ curl = 1, plugin = 1, user_requested = true }, checks)
        end)
    end)

    describe("searching", function()
        it("can be cancelled", function()
            local plugin = openUI()
            plugin:setupUI()
            plugin.search_box.buttons[1][1].callback()

            assert.is_true(helper.wasClosed(plugin.search_box))
            assert.are.equal(0, #searches)
        end)

        it("needs a search term", function()
            local plugin = openUI()
            search(plugin, "   ")

            assert.is_true(plugin.search_box.keyboard_closed)
            assert.are.equal("Enter a search term first", helper.lastNotification())
            assert.are.equal(0, #searches)
        end)

        -- as nothing could be found
        for _, preference in ipairs({
            { "languages", "language" },
            { "file_types", "file type" },
            { "book_types", "book type" },
        }) do
            it("says when every " .. preference[2] .. " is turned off, rather than searching", function()
                settings[preference[1]] = {}
                search(openUI(), "dune")

                assert.are.equal(0, #searches)
                assert.are.equal(
                    "Error: turn on at least one " .. preference[2] .. " in Kindle Fetch's settings",
                    helper.lastNotification()
                )
            end)
        end

        it("shows results saved from an earlier search without turning on wifi", function()
            helper.stubs.network.connected = false
            saved["dune 1"] = true
            search_results[1] = { { book("Dune") } }
            search(openUI(), "dune")

            assert.is_nil(helper.stubs.network.prompted)
            assert.are.same({ { "dune", 1 } }, searches)
            assert.are.same({ "Dune" }, itemTexts(menus[1]))
        end)

        it("turns on wifi when offline, then searches once connected", function()
            helper.stubs.network.connected = false
            search_results[1] = { { book("Dune") }, nil, 2 }
            search(openUI(), "dune")
            assert.are.equal("turn wifi on", helper.stubs.network.prompted)
            assert.are.equal(0, #searches)

            helper.stubs.network.connected = true
            helper.stubs.network.when_connected()
            assert.are.same({ { "dune", 1 } }, searches)
            assert.are.same({ "Dune", "Load more" }, itemTexts(menus[1]))
        end)

        it("shows the books found, with a way to load more", function()
            search_results[1] = { { book("Dune"), book("Dune Messiah") }, nil, 2 }
            search(openUI(), "  dune  ")

            assert.are.same({ { "dune", 1 } }, searches)
            assert.are.equal("Searching...", helper.state.notifications[1])
            assert.are.same({ "Dune", "Dune Messiah", "Load more" }, itemTexts(menus[1]))
            assert.are.equal(menus[1], helper.lastShown())
        end)

        it("doesn't offer more books at the end of the results", function()
            search_results[1] = { { book("Dune") } }
            search(openUI(), "dune")

            assert.are.same({ "Dune" }, itemTexts(menus[1]))
        end)

        it("loads covers for each page shown", function()
            search_results[1] = { { book("Dune") } }
            search(openUI(), "dune")
            menus[1].onPageChange(2)

            assert.are.same({ 1, 2 }, menus[1].covers_loaded)
        end)

        it("does not load covers when they are turned off", function()
            settings.show_covers = false
            search_results[1] = { { book("Dune") } }
            search(openUI(), "dune")
            menus[1].onPageChange(2)

            assert.are.same({}, menus[1].covers_loaded)
        end)

        it("reports search errors", function()
            search_results[1] = { nil, "no Library Genesis urls available" }
            search(openUI(), "dune")

            assert.are.equal("Error: no Library Genesis urls available", helper.lastNotification())
            assert.are.equal(0, #menus)
        end)

        it("says when nothing was found", function()
            search(openUI(), "dune")

            assert.are.equal("No books found", helper.lastNotification())
            assert.are.equal(0, #menus)
        end)
    end)

    describe("load more", function()
        local plugin

        local function loadMore()
            local items = menus[#menus].item_table
            items[#items].callback()
        end

        before_each(function()
            plugin = openUI()
            search_results[1] = { { book("Dune"), book("Dune Messiah") }, nil, 2 }
            search(plugin, "dune")
        end)

        it("adds the next books to the list", function()
            search_results[2] = { { book("Children of Dune") }, nil, 4 }
            loadMore()

            assert.are.same({ { "dune", 1 }, { "dune", 2 } }, searches)
            assert.is_true(helper.wasClosed(menus[1]))
            assert.are.same({ "Dune", "Dune Messiah", "Children of Dune", "Load more" }, itemTexts(menus[2]))
        end)

        it("carries on from where the last search stopped", function()
            search_results[2] = { { book("Children of Dune") }, nil, 4 }
            loadMore()
            search_results[4] = { { book("God Emperor of Dune") } }
            loadMore()

            assert.are.same({ "dune", 4 }, searches[3])
            -- the end of the results
            assert.are.same({ "Dune", "Dune Messiah", "Children of Dune", "God Emperor of Dune" }, itemTexts(menus[3]))
        end)

        it("turns on wifi first when offline, then loads them once connected", function()
            helper.stubs.network.connected = false
            search_results[2] = { { book("Children of Dune") } }
            loadMore()
            assert.are.equal("turn wifi on", helper.stubs.network.prompted)
            assert.are.equal(1, #searches)

            helper.stubs.network.connected = true
            helper.stubs.network.when_connected()
            assert.are.same({ "dune", 2 }, searches[2])
        end)

        it("loads the next books without wifi when they're saved from an earlier search", function()
            helper.stubs.network.connected = false
            saved["dune 2"] = true
            search_results[2] = { { book("Children of Dune") } }
            loadMore()

            assert.is_nil(helper.stubs.network.prompted)
            assert.are.same({ "dune", 2 }, searches[2])
        end)

        it("stays on the same page after an error", function()
            search_results[2] = { nil, "request timed out" }
            loadMore()
            assert.are.equal("Error: request timed out", helper.lastNotification())

            search_results[2] = { { book("Children of Dune") } }
            loadMore()
            assert.are.same({ "dune", 2 }, searches[3])
        end)

        it("says when there are no more books", function()
            search_results[2] = { {} }
            loadMore()

            assert.are.equal("No more books found", helper.lastNotification())
            assert.are.equal(1, #menus)

            -- and doesn't search again
            loadMore()
            assert.are.equal(2, #searches)
            assert.are.equal("No more books found", helper.lastNotification())
        end)
    end)

    describe("downloading", function()
        local function selectBook(title)
            for _, item in ipairs(menus[#menus].item_table) do
                if item.book and item.book.title == title then
                    return item.callback()
                end
            end
        end

        local plugin

        before_each(function()
            search_results[1] = { { book("Dune"), book("AC/DC", "pdf") } }
            plugin = openUI()
            search(plugin, "dune")
        end)

        it("downloads the selected book into the download folder", function()
            selectBook("Dune")
            assert.are.equal("Dune", downloads[1].book.title)
            assert.are.equal("/mnt/us/documents/Dune.epub", downloads[1].filepath)
        end)

        it("uses a safe file name", function()
            selectBook("AC/DC")
            assert.are.equal("/mnt/us/documents/AC_DC.pdf", downloads[1].filepath)
        end)

        it("offers to read the book once it has downloaded", function()
            selectBook("Dune")
            downloads[1].callback(true, nil, "/mnt/us/books/Dune.epub")
            helper.tick()

            local dialog = helper.lastShown()
            -- centred, with the title in bold on a line of its own
            assert.are.equal("\u{FFF1}Downloaded\n\u{FFF2}Dune\u{FFF3}\n\nWould you like to read it now?", dialog.title)
            assert.are.equal("center", dialog.title_align)
            local read_now = dialog.buttons[1][2]
            assert.are.equal("Read now", read_now.text)

            read_now.callback()
            assert.is_true(helper.wasClosed(dialog))
            assert.are.same({ "openFile", "/mnt/us/books/Dune.epub" }, opened)
            -- closing the search box too, which would otherwise show again once the book is closed
            assert.is_true(helper.wasClosed(menus[1]))
            assert.is_true(helper.wasClosed(plugin.search_box))
        end)

        -- chosen when asked whether to download over it
        it("opens a book that's already there, in place of downloading it again", function()
            selectBook("Dune")
            downloads[1].open_existing("/mnt/us/documents/Dune.epub")

            assert.are.same({ "openFile", "/mnt/us/documents/Dune.epub" }, opened)
            assert.is_true(helper.wasClosed(menus[1]))
            assert.is_true(helper.wasClosed(plugin.search_box))
        end)

        it("closes the offer to read the book when cancelled", function()
            selectBook("Dune")
            downloads[1].callback(true, nil, "/mnt/us/books/Dune.epub")
            helper.tick()

            local dialog = helper.lastShown()
            dialog.buttons[1][1].callback()
            assert.is_true(helper.wasClosed(dialog))
            assert.is_nil(opened)
        end)

        it("switches to the downloaded book when already reading one", function()
            readBook()
            selectBook("Dune")
            downloads[1].callback(true, nil, "/mnt/us/books/Dune.epub")
            helper.tick()
            helper.lastShown().buttons[1][2].callback()

            assert.are.same({ "switchDocument", "/mnt/us/books/Dune.epub" }, opened)
        end)

        -- the download may have been hidden, and finish after what it was started from has closed. opening the
        -- book from there crashed KOReader when that was a book, as only the file manager can open files
        it("opens the book from what's open by then, rather than what the download was started from", function()
            selectBook("Dune")
            readBook()
            downloads[1].callback(true, nil, "/mnt/us/books/Dune.epub")
            helper.tick()
            helper.lastShown().buttons[1][2].callback()
            assert.are.same({ "switchDocument", "/mnt/us/books/Dune.epub" }, opened)

            -- and the other way round: started while reading a book that has been closed since
            ReaderUI.instance = nil
            FileManager.instance = {
                openFile = function(_, file)
                    opened = { "openFile", file }
                end,
            }
            downloads[1].callback(true, nil, "/mnt/us/books/Dune.epub")
            helper.tick()
            helper.lastShown().buttons[1][2].callback()
            assert.are.same({ "openFile", "/mnt/us/books/Dune.epub" }, opened)
        end)

        it("opens the book when neither a book nor the file manager is open", function()
            FileManager.instance = nil
            selectBook("Dune")
            downloads[1].callback(true, nil, "/mnt/us/books/Dune.epub")
            helper.tick()
            helper.lastShown().buttons[1][2].callback()

            assert.are.same({ "showReader", "/mnt/us/books/Dune.epub" }, opened)
        end)

        it("says why a download failed", function()
            selectBook("Dune")
            downloads[1].callback(false, "download produced empty file")
            assert.are.equal("Download failed: download produced empty file", helper.lastNotification())

            downloads[1].callback(false)
            assert.are.equal("Download failed", helper.lastNotification())
        end)

        it("says a download was cancelled, rather than that it failed", function()
            selectBook("Dune")
            downloads[1].callback(false, "cancelled")
            assert.are.equal("Download cancelled", helper.lastNotification())
        end)
    end)
end)
