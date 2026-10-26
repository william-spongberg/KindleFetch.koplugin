local helper = require("helper")

describe("KindleFetch", function()
    local KindleFetch, checks, settings, searches, search_results, downloads, menus, settings_shown, cleared, plugin_dir
    -- what was searched for on Internet Archive and Z-Library, rather than Library Genesis
    local archive_searches, zlib_searches, gutenberg_searches
    -- what Internet Archive and Z-Library find, by page, where it isn't what Library Genesis does (search_results)
    local site_results
    -- whether Z-Library is logged into, and what to do once the login dialog shown since has logged in
    local zlib_logged_in, zlib_logins
    local cancelled_downloads, curl_check_user_requested, leftovers_removed
    -- how many times the libraries in the settings were opened (see SettingsPage:changeLibraries)
    local libraries_shown
    -- the downloads the downloader says are in progress, and those it was asked to show the progress of
    local active_downloads, downloads_shown
    -- whether searches can be called off, and the widget that calls each one off when tapped (false without one)
    local can_cancel, trap_widgets
    -- pages of results saved from earlier searches, as "query page"
    local saved
    -- the settings' menus for choosing languages, file types and book types that were opened, and what each calls once
    -- closed, and the lists of what the books found have to tick (see SettingsPage:tickSeveral)
    local choosers, tick_lists
    -- whether curl can look names up with encrypted DNS
    local can_use_encrypted_dns

    -- KOReader creates a new plugin instance for the file manager and for every book that is opened
    local opened
    -- KOReader's file manager and reader, of which one is open at a time (the file manager here, until a spec
    -- opens a book with readBook)
    local FileManager, ReaderUI
    -- how many times the file manager was refreshed, and the files the buttons from KOReader's file browser were
    -- tapped for: to show their folders, add to collections and show the information of
    local refreshes, folders_shown, collections_chosen, info_shown

    -- KOReader's collections for the file manager or a book, noting the files added to them in chosen
    local function collections(chosen)
        return {
            genAddToCollectionButton = function(_, file, caller_pre_callback)
                return {
                    text = "Collections…",
                    callback = function()
                        caller_pre_callback()
                        table.insert(chosen, file)
                    end,
                }
            end,
        }
    end

    local function fileManager()
        return {
            openFile = function(_, file)
                opened = { "openFile", file }
            end,
            onRefresh = function()
                refreshes = refreshes + 1
            end,
            collections = collections(collections_chosen),
            bookinfo = {},
        }
    end

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
            id = title:lower(),
            title = title,
            display_title = title,
            file_type = file_type or "epub",
        }
    end

    -- the button in a row of buttons with the given text
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

    -- the button in a dialog with the given id, e.g. the search box's Sites button
    local function buttonWithId(dialog, id)
        for _, row in ipairs(dialog.buttons) do
            for _, b in ipairs(row) do
                if b.id == id then
                    return b
                end
            end
        end
        error("no button " .. id)
    end

    -- do what starts a search (e.g. tapping Search or Load more), then let it run: each site's search starts once
    -- KOReader has shown what's on screen (see MultiSearch), leaving what was waiting from before (e.g. checking for
    -- updates) to wait
    local function andSearch(fn, ...)
        local from = #helper.state.scheduled
        fn(...)
        while #helper.state.scheduled > from do
            local due = {}
            for i = from + 1, #helper.state.scheduled do
                table.insert(due, helper.state.scheduled[i])
            end
            for i = #helper.state.scheduled, from + 1, -1 do
                table.remove(helper.state.scheduled, i)
            end
            for _, task in ipairs(due) do
                task()
            end
        end
    end

    -- open the search dialog for the site (Library Genesis unless given) and search for query
    local function search(plugin, query, source)
        plugin:setupUI(nil, nil, { source or "libgen" })
        plugin.search_box.input_text = query
        andSearch(button(plugin.search_box, "Search").callback)
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
            recent_searches = {},
            search_sources = { "libgen" },
        }
        searches, search_results, downloads, menus, settings_shown = {}, {}, {}, {}, 0
        archive_searches, zlib_searches, gutenberg_searches, site_results = {}, {}, {}, {}
        zlib_logged_in, zlib_logins = true, {}
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
            setLastUpdateCheck = function(_, time)
                settings.last_update_check = time
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
            getRecentSearches = function()
                return settings.recent_searches
            end,
            getSearchSources = function()
                return { unpack(settings.search_sources) }
            end,
            setSearchSources = function(_, sources)
                settings.search_sources = sources
                return true
            end,
            addRecentSearch = function(_, query)
                table.insert(settings.recent_searches, 1, query)
            end,
            setSkippedVersion = function(_, version)
                settings.skipped_version = version
            end,
            getEncryptedDns = function()
                return settings.encrypted_dns
            end,
            setEncryptedDns = function(_, on)
                settings.encrypted_dns = on
                return true
            end,
            getLibraries = function()
                return settings.libraries or {}
            end,
            setLibraries = function(_, libraries)
                settings.libraries = libraries
                return true
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
        choosers, tick_lists = {}, {}
        local function chooser(name)
            return function(_, on_closed)
                table.insert(choosers, { name = name, on_closed = on_closed })
            end
        end
        helper.stub("settings.settingspage", {
            showSettings = function()
                settings_shown = settings_shown + 1
            end,
            changeLibraries = function()
                libraries_shown = libraries_shown + 1
            end,
            changeLanguages = chooser("languages"),
            changeFileTypes = chooser("file types"),
            changeBookTypes = chooser("book types"),
            tickSeveral = function(_, title, choices, ticked, save, none_text, on_closed)
                table.insert(tick_lists, {
                    title = title,
                    choices = choices,
                    ticked = ticked,
                    save = save,
                    none_text = none_text,
                    on_closed = on_closed,
                })
            end,
        })
        can_cancel, trap_widgets = true, {}
        local trap_widget
        helper.stub("util.httputil", {
            CANCELLED = "request cancelled",
            canCancel = function()
                return can_cancel
            end,
            setTrapWidget = function(widget)
                trap_widget = widget
            end,
            getTrapWidget = function()
                return trap_widget
            end,
        })
        helper.stub("api.lglisearch", {
            NAME = "Library Genesis",
            HAS_BOOK_TYPES = true,
            SCOPES = { "title", "author", "isbn" },
            search = function(_, query, page, scope)
                table.insert(searches, { query, page, scope })
                table.insert(trap_widgets, require("util.httputil").getTrapWidget() or false)
                -- books, error, the page to carry on from and how many results were read (or a function to run in
                -- place of the search)
                local result = search_results[page] or { {} }
                if type(result) == "function" then
                    return result()
                end
                return result[1], result[2], result[3], result[4]
            end,
            isCached = function(_, query, page)
                return saved[query .. " " .. page] == true
            end,
        })
        -- which finds the same books, but has no book types
        helper.stub("api.iasearch", {
            NAME = "Internet Archive",
            SCOPES = { "title", "author", "isbn" },
            search = function(_, query, page, scope)
                table.insert(archive_searches, { query, page, scope })
                local result = (site_results.archive or search_results)[page] or { {} }
                if type(result) == "function" then
                    return result()
                end
                return result[1], result[2], result[3], result[4]
            end,
            isCached = function()
                return false
            end,
        })
        helper.stub("api.zlibsearch", {
            NAME = "Z-Library",
            NEEDS_LOGIN = true,
            search = function(_, query, page, scope)
                table.insert(zlib_searches, { query, page, scope })
                local result = (site_results.zlib or search_results)[page] or { {} }
                if type(result) == "function" then
                    return result()
                end
                return result[1], result[2], result[3], result[4]
            end,
            isCached = function()
                return false
            end,
        })
        -- which has neither book types nor ways to narrow a search down, like Z-Library, but needs no account
        helper.stub("api.gutenbergsearch", {
            NAME = "Project Gutenberg",
            search = function(_, query, page, scope)
                table.insert(gutenberg_searches, { query, page, scope })
                local result = (site_results.gutenberg or search_results)[page] or { {} }
                if type(result) == "function" then
                    return result()
                end
                return result[1], result[2], result[3], result[4]
            end,
            isCached = function()
                return false
            end,
        })
        helper.stub("api.zlibaccount", {
            isLoggedIn = function()
                return zlib_logged_in
            end,
        })
        helper.stub("ui.zliblogin", {
            show = function(on_logged_in)
                table.insert(zlib_logins, on_logged_in)
            end,
        })
        cancelled_downloads = 0
        libraries_shown = 0
        curl_check_user_requested = nil
        active_downloads, downloads_shown = {}, {}

        refreshes, folders_shown, collections_chosen, info_shown = 0, {}, {}, {}
        FileManager = { instance = fileManager() }
        -- each closing the dialog it's in first, with what it's given to
        helper.stub("apps/filemanager/filemanagerutil", {
            genShowFolderButton = function(file, caller_callback, button_disabled)
                return {
                    text = "Show folder",
                    enabled = not button_disabled,
                    callback = function()
                        caller_callback()
                        table.insert(folders_shown, file)
                    end,
                }
            end,
            genBookInformationButton = function(doc_settings_or_file, book_props, caller_callback, button_disabled)
                return {
                    text = "Book information",
                    enabled = not button_disabled,
                    callback = function()
                        caller_callback()
                        table.insert(info_shown, { doc_settings_or_file, book_props })
                    end,
                }
            end,
        })
        ReaderUI = {
            showReader = function(_, file)
                opened = { "showReader", file }
            end,
        }
        helper.stub("apps/filemanager/filemanager", FileManager)
        helper.stub("apps/reader/readerui", ReaderUI)
        helper.stub("api.downloader", {
            cancelAllDownloads = function()
                cancelled_downloads = cancelled_downloads + 1
            end,
            getActiveDownloads = function()
                return active_downloads
            end,
            showDownload = function(_, id)
                table.insert(downloads_shown, id)
                return true
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
            isSupported = function()
                return true
            end,
            new = function(_, menu)
                menu.covers_loaded = {}
                menu.page = 1
                function menu:loadCoversForPage(page)
                    table.insert(self.covers_loaded, page)
                end
                function menu:updateItems()
                    self.redrawn = (self.redrawn or 0) + 1
                end
                -- as KOReader's menu does once its X is tapped
                function menu:onCloseAllMenus()
                    require("ui/uimanager"):close(self)
                    if self.close_callback then
                        self.close_callback()
                    end
                end
                -- like KOReader's menu, show other entries, turning to the page with the given one (2 to a page here)
                -- (or staying on the page that's showing for a negative one)
                function menu:switchItemTable(title, item_table, item_number)
                    self.title = title or self.title
                    self.item_table = item_table
                    if item_number >= 0 then
                        self.page = math.ceil(item_number / 2)
                    end
                end
                table.insert(menus, menu)
                return menu
            end,
        })
        helper.stub("cache.covercache", {})
        leftovers_removed = 0
        can_use_encrypted_dns = true
        helper.stub("util.curlutil", {
            getVersion = function()
                return "8.17.0"
            end,
            canUseEncryptedDns = function()
                return can_use_encrypted_dns
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

        -- so downloads wait for the device to wake up and Wi-Fi to come back, rather than failing
        it("tells the downloader when the device sleeps and wakes, and Wi-Fi goes off and comes back", function()
            local told = {}
            local Downloader = require("api.downloader")
            for _, event in ipairs({ "onSuspend", "onResume", "onNetworkDisconnected", "onNetworkConnected" }) do
                Downloader[event] = function()
                    table.insert(told, event)
                end
            end
            local plugin = openUI()
            for _, event in ipairs({ "onSuspend", "onResume", "onNetworkDisconnected", "onNetworkConnected" }) do
                -- letting the event carry on to the rest of KOReader
                assert.is_nil(plugin[event](plugin))
            end
            assert.are.same({ "onSuspend", "onResume", "onNetworkDisconnected", "onNetworkConnected" }, told)
        end)

        -- as when the device is powered off or restarted, or its storage is shared over USB, which curl carried on
        -- writing to
        it("cancels downloads when KOReader closes without exiting", function()
            active_downloads = { { id = "dune", title = "Dune" } }
            assert.is_nil(openUI():onClose())
            assert.are.equal(1, cancelled_downloads)
            assert.is_truthy(helper.logged("info", "^cancelling downloads, as KOReader is closing"))
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

    -- which KOReader left it out of its menu for, along with checking for updates
    it("shows what's left of its menu when it can't start", function()
        settings.download_dir = nil
        require("settings.settings").load = function()
            error("attempt to index a nil value")
        end
        local registered = {}
        local plugin = KindleFetch:new {
            ui = {
                menu = {
                    registerToMainMenu = function(_, widget)
                        table.insert(registered, widget)
                    end,
                },
            },
        }
        assert.are.same({ plugin }, registered)
        local menu_items = {}
        plugin:addToMainMenu(menu_items)
        assert.are.equal("Kindle Fetch couldn't start", menu_items.kindlefetch.sub_item_table[1].text)
        assert.is_truthy(helper.logged("err", "^could not start Kindle Fetch:.*attempt to index a nil value"))
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
            assert.are.equal("Search for books", plugin.search_box.title)
            -- for the sites ticked in it last
            assert.are.equal("Sites: Library Genesis", buttonWithId(plugin.search_box, "sites").text)
        end)

        it("registers a dispatcher action for searching Z-Library", function()
            local plugin = openUI()
            local action = helper.state.actions.kindlefetch_zlib_action
            assert.are.equal("Kindle Fetch: search Z-Library", action.title)

            assert.is_true(plugin["on" .. action.event](plugin))
            assert.are.equal("Sites: Z-Library", buttonWithId(plugin.search_box, "sites").text)
        end)

        it("registers a dispatcher action for searching Internet Archive", function()
            local plugin = openUI()
            local action = helper.state.actions.kindlefetch_archive_action
            assert.are.equal("Kindle Fetch: search Internet Archive", action.title)

            assert.is_true(plugin["on" .. action.event](plugin))
            assert.are.equal(plugin.search_box, helper.lastShown())
            assert.are.equal("Sites: Internet Archive", buttonWithId(plugin.search_box, "sites").text)
        end)

        it("checks for updates once the UI is ready", function()
            openUI()
            assert.are.same({ curl = 0, plugin = 0 }, checks)

            helper.runScheduled()
            assert.are.same({ curl = 1, plugin = 1, user_requested = false }, checks)
        end)

        -- which wasn't asked for, so isn't said
        it("only logs what goes wrong checking for updates", function()
            helper.stub("updater.curlupdater", {
                checkVersion = function()
                    error("unexpected")
                end,
            })
            package.loaded["kindlefetch"] = nil
            KindleFetch = dofile("kindlefetch.koplugin/main.lua")
            openUI()
            helper.tick()

            assert.is_truthy(helper.logged("err", "^checking for updates went wrong:.*unexpected"))
            assert.is_nil(helper.lastError())
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

        -- even when the latest release couldn't be looked up, as on a Kindle whose curl is too old to, which offered to
        -- update curl every time KOReader started (#57)
        it("waits a day after checking for updates, whether or not they could be looked up", function()
            helper.state.time = 2000000
            openUI()
            helper.runScheduled()
            assert.are.equal(2000000, settings.last_update_check)

            -- KOReader has been restarted an hour later
            KindleFetch = dofile("kindlefetch.koplugin/main.lua")
            helper.state.time = 2000000 + 60 * 60
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
                if (item.text or item.text_func()) == text then
                    return item
                end
            end
        end

        -- which is in the settings (see SettingsPage:goBack)
        it("doesn't offer to go back to the version before", function()
            helper.writeFile(plugin_dir .. ".previous/main.lua", "-- v0.3")
            helper.writeFile(plugin_dir .. ".previous/version.txt", "0.3\n")
            assert.is_nil(menuItem(openUI(), "Go back to v0.3"))
        end)

        -- where a download that was hidden can be shown again, without finding its book again
        describe("downloads", function()
            local function downloading(title, percentage, status_text)
                table.insert(active_downloads, {
                    id = title:lower(),
                    title = title,
                    widget = {
                        percentage = percentage,
                        status_text = status_text,
                    },
                })
            end

            it("can't be chosen while nothing is downloading", function()
                local item = menuItem(openUI(), "Downloads")
                assert.is_false(item.enabled_func())

                -- but says so if it is all the same, e.g. as the last download finishes
                item.callback()
                assert.are.equal("No downloads in progress", helper.lastNotification())
            end)

            it("says how many books are downloading", function()
                downloading("Dune", 0.5)
                downloading("Emma", 0.25)

                local item = menuItem(openUI(), "Downloads (2)")
                assert.is_true(item.enabled_func())
            end)

            it("shows the progress of the book that is downloading", function()
                downloading("Dune", 0.5)
                menuItem(openUI(), "Downloads (1)").callback()

                assert.are.same({ "dune" }, downloads_shown)
                assert.are.equal(0, #helper.state.shown)
            end)

            it("lists the books that are downloading when there are several, to choose which to show", function()
                downloading("Dune", 0.456, "45% · 0.5 / 1.1 MB")
                downloading("Emma", 0, "Waiting for Library Genesis...")
                downloading("Persuasion", 0, "2.0 MB")
                menuItem(openUI(), "Downloads (3)").callback()

                local dialog = helper.lastShown()
                assert.are.equal("Downloads", dialog.title)
                assert.are.same(
                    { "Dune · 45%", "Emma · Waiting for Library Genesis...", "Persuasion · 2.0 MB" },
                    { dialog.buttons[1][1].text, dialog.buttons[2][1].text, dialog.buttons[3][1].text }
                )

                dialog.buttons[2][1].callback()
                assert.is_true(helper.wasClosed(dialog))
                assert.are.same({ "emma" }, downloads_shown)
            end)
        end)

        it("opens the search box, for the sites ticked in it last", function()
            settings.search_sources = { "libgen", "archive" }
            local plugin = openUI()
            menuItem(plugin, "Search").callback()

            assert.are.equal("Search for books", plugin.search_box.title)
            assert.are.equal(plugin.search_box, helper.lastShown())
            assert.are.equal(
                "Sites: Library Genesis and Internet Archive",
                buttonWithId(plugin.search_box, "sites").text
            )
        end)

        -- where the sites are chosen (see chooseSites)
        it("has the one Search, rather than one for each site", function()
            local plugin = openUI()
            assert.is_nil(menuItem(plugin, "Search Library Genesis"))
            assert.is_nil(menuItem(plugin, "Search Z-Library"))
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
            plugin:setupUI("libgen")
            button(plugin.search_box, "Cancel").callback()

            assert.is_true(helper.wasClosed(plugin.search_box))
            assert.are.equal(0, #searches)
        end)

        it("starts from the keyboard's enter key as well as the Search button", function()
            local plugin = openUI()
            plugin:setupUI("libgen")

            local search_button = button(plugin.search_box, "Search")
            assert.is_true(search_button.is_enter_default)
            assert.is_nil(button(plugin.search_box, "Cancel").is_enter_default)
            assert.is_nil(button(plugin.search_box, "Recent").is_enter_default)
        end)

        describe("recent searches", function()
            it("are remembered once they've found books", function()
                search_results[1] = { { book("Dune") } }
                search(openUI(), "  dune  ")
                assert.are.same({ "dune" }, settings.recent_searches)

                -- but not when there's nothing to search for
                search(openUI(), "  ")
                settings.languages = {}
                search(openUI(), "emma")
                assert.are.same({ "dune" }, settings.recent_searches)
            end)

            -- which were remembered as they started
            it("aren't remembered when they fail, or find nothing, as with a typo", function()
                search_results[1] = { nil, "request timed out" }
                search(openUI(), "dune")
                search_results[1] = { {} }
                search(openUI(), "dnue")
                assert.are.same({}, settings.recent_searches)
            end)

            it("are offered from the search box, to search for again", function()
                settings.recent_searches = { "emma", "dune" }
                search_results[1] = { { book("Emma") } }
                local plugin = openUI()
                plugin:setupUI(nil, nil, { "libgen" })
                assert.is_true(button(plugin.search_box, "Recent").enabled)
                button(plugin.search_box, "Recent").callback()

                local list = helper.lastShown()
                assert.are.equal("Recent searches", list.title)
                assert.are.same({ "emma", "dune" }, { list.buttons[1][1].text, list.buttons[2][1].text })
                andSearch(list.buttons[1][1].callback)
                assert.is_true(helper.wasClosed(list))
                -- in the search box too, to change it from there once the books are closed
                assert.are.equal("emma", plugin.search_box.input_text)
                assert.are.same({ { "emma", 1 } }, searches)
                assert.are.same({ "Emma" }, itemTexts(menus[1]))
            end)

            it("can't be chosen before there are any", function()
                local plugin = openUI()
                plugin:setupUI(nil, nil, { "libgen" })
                assert.is_false(button(plugin.search_box, "Recent").enabled)

                -- until something has been found from the search box that's open
                search_results[1] = { { book("Dune") } }
                local enabled = false
                plugin.search_box.button_table = {
                    getButtonById = function(_, id)
                        assert.are.equal("recent", id)
                        return {
                            enable = function()
                                enabled = true
                            end,
                        }
                    end,
                }
                plugin.search_box.input_text = "dune"
                andSearch(button(plugin.search_box, "Search").callback)
                assert.is_true(enabled)
            end)
        end)

        it("needs a search term", function()
            local plugin = openUI()
            search(plugin, "   ")

            assert.is_true(plugin.search_box.keyboard_closed)
            assert.are.equal("Enter a search term first", helper.lastNotification())
            assert.are.equal(0, #searches)
        end)

        it("searches the site the search box is for", function()
            search_results[1] = { { book("Emma") } }
            search(openUI(), "emma", "archive")

            assert.are.same({ { "emma", 1 } }, archive_searches)
            assert.are.same({}, searches)
            assert.are.same({ "Emma" }, itemTexts(menus[1]))
        end)

        it("searches Z-Library as the site the search box is for", function()
            search(openUI(), "1984", "zlib")
            assert.are.same({ { "1984", 1 } }, zlib_searches)
        end)

        -- e.g. once Z-Library has logged Kindle Fetch out, which can be since the search box was opened
        it("logs in to Z-Library again before searching it", function()
            local plugin = openUI()
            plugin:setupUI(nil, nil, { "zlib" })
            zlib_logged_in = false
            plugin.search_box.input_text = "1984"
            andSearch(button(plugin.search_box, "Search").callback)
            assert.are.same({}, zlib_searches)

            zlib_logged_in = true
            andSearch(zlib_logins[1])
            assert.are.same({ { "1984", 1 } }, zlib_searches)
        end)

        -- which it doesn't have
        it("searches Internet Archive with every book type turned off", function()
            settings.book_types = {}
            search(openUI(), "emma", "archive")

            assert.are.same({ { "emma", 1 } }, archive_searches)
            assert.is_nil(helper.lastError())
        end)

        it("loads more books from the site the search was on", function()
            search_results[1] = { { book("Emma") }, nil, 2 }
            search_results[2] = { { book("Emma, volume 2") } }
            search(openUI(), "emma", "archive")
            andSearch(menus[1].item_table[2].callback)

            assert.are.same({ { "emma", 1 }, { "emma", 2 } }, archive_searches)
            assert.are.same({}, searches)
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
                -- as the search box says when there's no search term
                assert.are.equal(
                    "Turn on at least one " .. preference[2] .. " in Kindle Fetch's settings first",
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
            andSearch(helper.stubs.network.when_connected)
            assert.are.same({ { "dune", 1 } }, searches)
            assert.are.same({ "Dune", "Load more" }, itemTexts(menus[1]))
        end)

        it("shows the books found, with a way to load more", function()
            search_results[1] = { { book("Dune"), book("Dune Messiah") }, nil, 2 }
            search(openUI(), "  dune  ")

            assert.are.same({ { "dune", 1 } }, searches)
            assert.are.same({ "Dune", "Dune Messiah", "Load more" }, itemTexts(menus[1]))
            assert.are.equal(menus[1], helper.lastShown())
        end)

        -- KOReader carries on meanwhile, rather than being held up until Library Genesis has answered
        describe("while waiting for Library Genesis", function()
            local function message()
                return helper.state.shown[2]
            end

            it("says which site it's searching", function()
                search(openUI(), "emma", "archive")
                assert.are.equal("Searching Internet Archive for\n“emma”...", message().title)
            end)

            it("says it's searching until the books are found, with a button to call it off", function()
                search_results[1] = { { book("Dune") } }
                search(openUI(), "dune")

                assert.are.equal("Searching Library Genesis for\n“dune”...", message().title)
                assert.are.equal("Cancel", message().buttons[1][1].text)
                -- rather than any tap calling it off, which may have been meant for something else
                assert.is_false(message().dismissable)
                -- or a second tap on what started the search landing on it
                assert.is_true(helper.state.input_inhibited)
                assert.is_true(helper.wasClosed(message()))
                assert.are.equal(0, #helper.state.notifications)
                -- its Cancel calls the search off, which waits with a stand-in of its own (see MultiSearch)
                assert.are.equal(1, #trap_widgets)
                assert.are_not.equal(message(), trap_widgets[1])
                assert.is_nil(require("util.httputil").getTrapWidget())
            end)

            it("is called off with the message's Cancel button", function()
                local dismissed = 0
                local stand_in
                search_results[1] = function()
                    -- as Trapper:dismissablePopen does with what the page is waited for with
                    stand_in = require("util.httputil").getTrapWidget()
                    stand_in.dismiss_callback = function()
                        dismissed = dismissed + 1
                    end
                    message().buttons[1][1].callback()
                    return nil, "request cancelled"
                end
                search(openUI(), "dune")

                assert.are.equal(1, dismissed)
                assert.is_true(stand_in.cancelled)
                assert.is_true(helper.wasClosed(message()))
                -- once
                local closes = 0
                for _, closed in ipairs(helper.state.closed) do
                    closes = closes + (closed == message() and 1 or 0)
                end
                assert.are.equal(1, closes)
                assert.are.equal(0, #menus)
            end)

            -- which left the search going, and what it found shown once it was over
            it("is called off when KOReader closes the message, as its Home key does", function()
                local dismissed = 0
                search_results[1] = function()
                    require("util.httputil").getTrapWidget().dismiss_callback = function()
                        dismissed = dismissed + 1
                    end
                    -- as ButtonDialog's onClose does, before closing it
                    message().tap_close_callback()
                    return nil, "request cancelled"
                end
                search(openUI(), "dune")

                assert.are.equal(1, dismissed)
                assert.is_true(message().cancelled)
                assert.are.equal(0, #menus)
            end)

            it("doesn't offer to call it off when it can't be", function()
                can_cancel = false
                search_results[1] = { { book("Dune") } }
                search(openUI(), "dune")

                assert.are.equal("Searching Library Genesis for\n“dune”...", message().text)
                assert.is_nil(message().buttons)
            end)

            it("shows nothing more once it's called off", function()
                search_results[1] = { nil, "request cancelled" }
                local plugin = openUI()
                search(plugin, "dune")

                assert.is_true(helper.wasClosed(message()))
                assert.are.equal(0, #menus)
                assert.are.equal(0, #helper.state.notifications)
                assert.are.equal(2, #helper.state.shown)
                -- the search box is still there to search again from
                assert.is_false(helper.wasClosed(plugin.search_box))
            end)

            it("says nothing for results saved from an earlier search, which are there straight away", function()
                saved["dune 1"] = true
                search_results[1] = { { book("Dune") } }
                search(openUI(), "dune")

                assert.are.equal(menus[1], helper.state.shown[2])
            end)

            -- which was lost, as Trapper drops what goes wrong once its function has waited on something
            it("says so when showing the books found goes wrong", function()
                search_results[1] = { { book("Dune") } }
                require("ui.bookmenu").new = function()
                    error("attempt to call a nil value")
                end
                search(openUI(), "dune")

                assert.is_true(helper.wasClosed(message()))
                assert.are.equal("Search failed: something went wrong, see crash.log", helper.lastError())
                assert.matches(
                    "attempt to call a nil value",
                    helper.logged("err", '^showing what was found for "dune" went wrong')
                )
            end)

            it("says so when the search goes wrong, rather than leaving its message up", function()
                search_results[1] = function()
                    error("attempt to index a nil value")
                end
                search(openUI(), "dune")

                assert.is_true(helper.wasClosed(message()))
                assert.is_nil(require("util.httputil").getTrapWidget())
                assert.are.equal("Search failed: something went wrong, see crash.log", helper.lastError())
                assert.matches(
                    "attempt to index a nil value",
                    helper.logged("err", '^search of Library Genesis for "dune" went wrong')
                )
            end)
        end)

        it("doesn't offer more books at the end of the results", function()
            search_results[1] = { { book("Dune") } }
            search(openUI(), "dune")

            assert.are.same({ "Dune" }, itemTexts(menus[1]))
        end)

        it("says above the books what was searched for, and how many were found", function()
            search_results[1] = { { book("Dune"), book("Dune Messiah") } }
            search(openUI(), " dune ")
            assert.are.equal("dune · 2 books", menus[1].title)
            assert.is_true(menus[1].title_shrink_font_to_fit)

            search_results[1] = { { book("Dune") } }
            search(openUI(), "dune")
            assert.are.equal("dune · 1 book", menus[2].title)

            -- with more to load
            search_results[1] = { { book("Dune") }, nil, 2 }
            search(openUI(), "dune")
            assert.are.equal("dune · 1+ books", menus[3].title)
        end)

        -- whose results were blank, and whose covers failed to load, as its menu lacks what laying them out builds on
        it(
            "lists the books as KOReader's own menu does, without covers, on a KOReader that can't lay them out",
            function()
                require("ui.bookmenu").isSupported = function()
                    return false
                end
                search_results[1] = { { book("Dune") }, nil, 2 }
                local plugin = openUI()
                search(plugin, "dune")

                assert.are.equal(0, #menus)
                local list = plugin.books_menu
                assert.are.equal(list, helper.lastShown())
                assert.are.same({ "Dune · EPUB", "Load more" }, { list.item_table[1].text, list.item_table[2].text })
                assert.is_nil(list.loadCoversForPage)
                -- saying which are downloaded already, where KOReader's menu says such things
                assert.is_nil(list.item_table[1].mandatory_func())
                assert.is_truthy(helper.logged("warn", "^showing results as a list without covers"))
            end
        )

        -- rounded corners aren't painted, and show what was on screen before
        it("fills the screen with the books, to its corners", function()
            search_results[1] = { { book("Dune") } }
            search(openUI(), "dune")

            assert.is_true(menus[1].covers_fullscreen)
            assert.is_false(menus[1].is_popout)
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

            assert.are.equal("Search failed: no Library Genesis urls available", helper.lastError())
            assert.are.equal(0, #menus)
        end)

        -- in a message that stays, as it may come a while after the search was started
        it("says when nothing was found", function()
            search(openUI(), "dune")

            local explanation = helper.lastShown()
            assert.are.equal("Library Genesis found no books for “dune”.", explanation.text)
            assert.is_true(explanation.no_ok_button)
            assert.are.equal("Close", explanation.cancel_text)
            assert.are.equal(0, #menus)
            assert.are.equal(0, #helper.state.notifications)
        end)

        describe("offering what fixes a search that failed", function()
            it("tries again, once the device is connected", function()
                search_results[1] = { nil, "no internet connection" }
                search(openUI(), "dune")
                search_results[1] = { { book("Dune") } }

                local again = helper.lastShown().other_buttons[1][1]
                assert.are.equal("Try again", again.text)
                andSearch(again.callback)
                assert.are.same({ { "dune", 1 }, { "dune", 1 } }, searches)
                assert.are.same({ "Dune" }, itemTexts(menus[1]))
            end)

            it("opens the libraries in the settings, where a library turned its login down", function()
                search_results[1] = { nil, require("util.errors").LIBRARY_LOGIN }
                search(openUI(), "dune")

                local libraries = helper.lastShown().other_buttons[1][1]
                assert.are.equal("Your Libraries…", libraries.text)
                libraries.callback()
                assert.are.equal(1, libraries_shown)
            end)

            it("tries a library that can't be reached again", function()
                search_results[1] = { nil, require("util.errors").LIBRARY_UNREACHABLE }
                search(openUI(), "dune")
                local again = helper.lastShown().other_buttons[1][1]
                assert.are.equal("Try again", again.text)
                andSearch(again.callback)
                assert.are.equal(2, #searches)
            end)

            -- where the network's own DNS may be what's blocking them (#55)
            it(
                "looks the sites up with encrypted DNS, then searches again, where the network can't find them",
                function()
                    search_results[1] = { nil, require("util.errors").UNFOUND }
                    search(openUI(), "dune")

                    local encrypted_dns = helper.lastShown().other_buttons[1][1]
                    assert.are.equal("Use encrypted DNS", encrypted_dns.text)
                    andSearch(encrypted_dns.callback)
                    assert.is_true(settings.encrypted_dns)
                    assert.are.equal(2, #searches)
                end
            )

            it("only offers encrypted DNS where curl can look names up with it, and it's off", function()
                search_results[1] = { nil, require("util.errors").UNFOUND }
                can_use_encrypted_dns = false
                search(openUI(), "dune")
                -- just the other sites
                assert.are.equal("Search Z-Library", helper.lastShown().other_buttons[1][1].text)

                can_use_encrypted_dns = true
                settings.encrypted_dns = true
                search(openUI(), "dune")
                assert.are.equal("Search Z-Library", helper.lastShown().other_buttons[1][1].text)
            end)

            it("logs in again, then searches again, once Z-Library has logged Kindle Fetch out", function()
                search_results[1] = { nil, "Z-Library has logged Kindle Fetch out, so log in again" }
                search(openUI(), "1984", "zlib")

                local log_in = helper.lastShown().other_buttons[1][1]
                assert.are.equal("Log in", log_in.text)
                log_in.callback()
                andSearch(zlib_logins[1])
                assert.are.equal(2, #zlib_searches)
            end)
        end)

        describe("offering the other sites", function()
            local function texts(row)
                local result = {}
                for _, b in ipairs(row) do
                    table.insert(result, b.text)
                end
                return result
            end

            it("searches another site for the same thing when nothing was found", function()
                local plugin = openUI()
                search(plugin, "dune")
                local first_box = plugin.search_box
                local explanation = helper.lastShown()
                assert.are.same(
                    { "Search Z-Library", "Search Internet Archive", "Search Project Gutenberg" },
                    texts(explanation.other_buttons[1])
                )

                explanation.other_buttons[1][2].callback()
                -- once the message has closed
                assert.are.same({}, archive_searches)
                helper.tick()
                helper.tick()
                assert.is_true(helper.wasClosed(first_box))
                assert.are.equal("Sites: Internet Archive", buttonWithId(plugin.search_box, "sites").text)
                assert.are.equal("dune", plugin.search_box.input)
                assert.are.same({ { "dune", 1 } }, archive_searches)
            end)

            -- as it can only be searched with an account
            it("only offers Z-Library once logged in", function()
                zlib_logged_in = false
                search(openUI(), "dune")
                assert.are.same(
                    { "Search Internet Archive", "Search Project Gutenberg" },
                    texts(helper.lastShown().other_buttons[1])
                )
            end)

            it("offers them when a search fails", function()
                search_results[1] = { nil, "all Library Genesis mirrors failed" }
                search(openUI(), "dune")

                local failure = helper.lastShown()
                assert.are.equal("Search failed: all Library Genesis mirrors failed", failure.text)
                assert.are.equal("notice-warning", failure.icon)
                assert.are.same(
                    { "Search Z-Library", "Search Internet Archive", "Search Project Gutenberg" },
                    texts(failure.other_buttons[1])
                )
            end)

            -- which they'd fail for too
            it("doesn't offer them when the device isn't connected", function()
                search_results[1] = { nil, "no internet connection" }
                search(openUI(), "dune")

                assert.are.equal("Search failed: no internet connection", helper.lastError())
                -- just trying again (see the fixes errors offer)
                assert.are.same({ "Try again" }, texts(helper.lastShown().other_buttons[1]))
                assert.are.equal(1, #helper.lastShown().other_buttons)
            end)

            it("offers them when the site listed results, but none in the languages and file types chosen", function()
                search_results[1] = { {}, nil, 2, 37 }
                search(openUI(), "emma", "archive")

                local other_buttons = helper.lastShown().other_buttons
                assert.are.same({ "Keep searching" }, texts(other_buttons[1]))
                assert.are.same(
                    { "Search Z-Library", "Search Library Genesis", "Search Project Gutenberg" },
                    texts(other_buttons[2])
                )
            end)
        end)

        -- which was said to have failed, rather than offering the settings
        it("offers the settings when the site has none of the file types chosen", function()
            search_results[1] = { nil, "none of the file types chosen in the settings" }
            search(openUI(), "emma", "archive")

            local explanation = helper.lastShown()
            assert.are.equal(
                "Internet Archive doesn't have books in any of the file types chosen in Kindle Fetch's settings.",
                explanation.text
            )
            assert.are.equal("Settings", explanation.ok_text)
            assert.is_nil(helper.lastError())
            explanation.ok_callback()
            assert.are.equal(1, settings_shown)
        end)

        -- which is why most searches that find nothing do
        describe("when Library Genesis lists results, but none in the languages and file types chosen", function()
            it("says so, and offers the settings", function()
                search_results[1] = { {}, nil, nil, 37 }
                search(openUI(), "dune")

                local explanation = helper.lastShown()
                assert.are.equal(
                    "Library Genesis listed 37 results, but none in the languages and file types chosen in Kindle "
                        .. "Fetch's settings.",
                    explanation.text
                )
                assert.are.equal("Settings", explanation.ok_text)
                assert.are.equal("Close", explanation.cancel_text)
                -- there are no more results to look through, just the other sites
                assert.are.equal(1, #explanation.other_buttons)
                assert.are.equal("Search Z-Library", explanation.other_buttons[1][1].text)
                assert.are.equal(0, #menus)

                explanation.ok_callback()
                assert.are.equal(1, settings_shown)
            end)

            it("says which site listed them", function()
                search_results[1] = { {}, nil, nil, 37 }
                search(openUI(), "emma", "archive")

                assert.are.equal(
                    "Internet Archive listed 37 results, but none in the languages and file types chosen in Kindle "
                        .. "Fetch's settings.",
                    helper.lastShown().text
                )
            end)

            it("offers to keep searching while there are more results to look through", function()
                search_results[1] = { {}, nil, 6, 500 }
                search_results[6] = { { book("Dune") }, nil, 7, 100 }
                search(openUI(), "dune")

                local keep_searching = helper.lastShown().other_buttons[1][1]
                assert.are.equal("Keep searching", keep_searching.text)

                andSearch(keep_searching.callback)
                assert.are.same({ { "dune", 1 }, { "dune", 6 } }, searches)
                assert.are.same({ "Dune", "Load more" }, itemTexts(menus[1]))
            end)

            -- which searched straight away, as Wi-Fi may have gone off since
            it("turns on Wi-Fi before searching on, when it's off", function()
                search_results[1] = { {}, nil, 6, 500 }
                search_results[6] = { { book("Dune") } }
                search(openUI(), "dune")
                helper.stubs.network.connected = false

                helper.lastShown().other_buttons[1][1].callback()
                assert.are.equal("turn wifi on", helper.stubs.network.prompted)
                assert.are.same({ { "dune", 1 } }, searches)

                helper.stubs.network.connected = true
                andSearch(helper.stubs.network.when_connected)
                assert.are.same({ { "dune", 1 }, { "dune", 6 } }, searches)
            end)
        end)
    end)

    -- ticked in the search box, each searched at once, their books shown as soon as any are found (see MultiSearch)
    describe("searching several sites", function()
        local plugin

        before_each(function()
            settings.search_sources = { "libgen", "archive" }
            plugin = openUI()
        end)

        local function searchSites(query)
            plugin:setupUI()
            plugin.search_box.input_text = query
            andSearch(button(plugin.search_box, "Search").callback)
        end

        local function texts(row)
            local result = {}
            for _, b in ipairs(row) do
                table.insert(result, b.text)
            end
            return result
        end

        it("searches every site ticked, saying which it's searching", function()
            searchSites("emma")
            assert.are.same({ { "emma", 1 } }, searches)
            assert.are.same({ { "emma", 1 } }, archive_searches)
            assert.are.same({}, zlib_searches)
            assert.are.equal(
                "Searching Library Genesis and Internet Archive for\n“emma”...",
                helper.state.shown[2].title
            )
        end)

        -- rather than once the slowest site has answered
        it("shows each site's books as soon as it has found them, saying which are still being searched", function()
            search_results[1] = { { book("Dune") } }
            local shown_meanwhile
            site_results.archive = {
                function()
                    shown_meanwhile = { title = menus[1].title, items = itemTexts(menus[1]) }
                    return { book("Emma") }
                end,
            }
            searchSites("x")

            assert.are.same({ "Dune", "Still searching Internet Archive…" }, shown_meanwhile.items)
            assert.are.equal("x · 1+ books", shown_meanwhile.title)
            -- once the first books were showing, rather than over them
            assert.is_true(helper.wasClosed(helper.state.shown[2]))
            assert.are.same({ "Dune", "Emma" }, itemTexts(menus[1]))
            assert.are.equal("x · 2 books", menus[1].title)
            assert.are.equal(1, #menus)
        end)

        it("says which site each book was found on", function()
            local dune, emma = book("Dune"), book("Emma")
            dune.source, emma.source = "libgen", "archive"
            search_results[1] = { { dune } }
            site_results.archive = { { { emma } } }
            searchSites("x")

            assert.are.equal("Dune · EPUB · Library Genesis", menus[1].item_table[1].text)
            assert.are.equal("Internet Archive", menus[1].source_name(emma))
        end)

        it("says over the books found when a site fails", function()
            search_results[1] = { { book("Dune") } }
            site_results.archive = { { nil, "request timed out" } }
            searchSites("x")

            assert.are.same({ "Dune" }, itemTexts(menus[1]))
            assert.are.equal("Searching Internet Archive failed: request timed out", helper.lastError())
        end)

        -- as it can be one that's only there at home, say
        it("says a site that can't be reached, as a library away from it, only once a session", function()
            local unreachable = require("util.errors").LIBRARY_UNREACHABLE
            search_results[1] = { { book("Dune") } }
            site_results.archive = { { nil, unreachable }, { nil, unreachable } }
            searchSites("x")
            assert.are.equal("Searching Internet Archive failed: " .. unreachable, helper.lastError())

            local shown = #helper.state.shown
            searchSites("y")
            for i = shown + 1, #helper.state.shown do
                assert.are_not.equal("notice-warning", helper.state.shown[i].icon)
            end
        end)

        -- once there are books to say so over
        it("says a site that failed before any books were found did, once they are", function()
            search_results[1] = { nil, "request timed out" }
            site_results.archive = { { { book("Emma") } } }
            searchSites("x")

            assert.are.same({ "Emma" }, itemTexts(menus[1]))
            assert.are.equal("Searching Library Genesis failed: request timed out", helper.lastError())
        end)

        it("says why each site failed, when none found books, offering the sites that weren't searched", function()
            search_results[1] = { nil, "request timed out" }
            site_results.archive = { { nil, "no response" } }
            searchSites("x")

            local failure = helper.lastShown()
            assert.are.equal(
                "Search failed:\nLibrary Genesis: request timed out\nInternet Archive: no response",
                failure.text
            )
            assert.are.same({ "Search Z-Library", "Search Project Gutenberg" }, texts(failure.other_buttons[1]))
            assert.are.equal(0, #menus)
        end)

        it("says none of them found any books", function()
            searchSites("x")
            local explanation = helper.lastShown()
            assert.are.equal("Library Genesis and Internet Archive found no books for “x”.", explanation.text)
            assert.are.same({ "Search Z-Library", "Search Project Gutenberg" }, texts(explanation.other_buttons[1]))
        end)

        it(
            "adds up the results they listed in other languages and file types, keeping searching those with more",
            function()
                search_results[1] = { {}, nil, 2, 25 }
                site_results.archive = { { {}, nil, nil, 50 } }
                searchSites("x")

                local explanation = helper.lastShown()
                assert.are.equal(
                    "Library Genesis and Internet Archive listed 75 results, but none in the languages and file types "
                        .. "chosen in Kindle Fetch's settings.",
                    explanation.text
                )
                search_results[2] = { { book("Dune") } }
                andSearch(explanation.other_buttons[1][1].callback)
                assert.are.same({ { "x", 1 }, { "x", 2 } }, searches)
                assert.are.equal(1, #archive_searches)
                assert.are.same({ "Dune" }, itemTexts(menus[1]))
            end
        )

        it("calls every site's search off with the message's Cancel", function()
            search_results[1] = function()
                helper.state.shown[2].buttons[1][1].callback()
                return nil, "request cancelled"
            end
            searchSites("x")

            assert.are.same({}, archive_searches)
            assert.are.equal(0, #menus)
            assert.are.equal(0, #helper.state.notifications)
        end)

        -- whose books would have nowhere to go
        it("calls off the sites still being searched once the books found are closed", function()
            settings.search_sources = { "libgen", "archive", "gutenberg" }
            search_results[1] = { { book("Dune") } }
            local called_off
            site_results.archive = {
                function()
                    menus[1]:onCloseAllMenus()
                    called_off = require("util.httputil").getTrapWidget().cancelled
                    return nil, "request cancelled"
                end,
            }
            searchSites("x")

            assert.is_true(called_off)
            assert.is_true(helper.wasClosed(menus[1]))
            -- nor started, where it hadn't been
            assert.are.same({}, gutenberg_searches)
            assert.is_nil(helper.lastError())
            assert.are.equal(1, #menus)
        end)

        it("loads more from each site that has more", function()
            search_results[1] = { { book("Dune") }, nil, 2 }
            search_results[2] = { { book("Dune Messiah") } }
            site_results.archive = { { { book("Emma") }, nil, 2 }, { { book("Persuasion") } } }
            searchSites("x")
            assert.are.same({ "Dune", "Emma", "Load more" }, itemTexts(menus[1]))

            local items = menus[1].item_table
            andSearch(items[#items].callback)
            assert.are.same({ { "x", 1 }, { "x", 2 } }, searches)
            assert.are.same({ { "x", 1 }, { "x", 2 } }, archive_searches)
            assert.are.same({ "Dune", "Emma", "Dune Messiah", "Persuasion" }, itemTexts(menus[1]))
        end)

        it("only loads more from the sites that have more", function()
            search_results[1] = { { book("Dune") }, nil, 2 }
            search_results[2] = { { book("Dune Messiah") } }
            site_results.archive = { { { book("Emma") } } }
            searchSites("x")

            local items = menus[1].item_table
            andSearch(items[#items].callback)
            assert.are.equal(2, #searches)
            assert.are.equal(1, #archive_searches)
        end)

        -- as it can only be searched with an account, which every search would ask for
        it("leaves Z-Library out while it isn't logged into, rather than asking to log in", function()
            settings.search_sources = { "zlib", "libgen" }
            zlib_logged_in = false
            searchSites("x")
            assert.are.same({ { "x", 1 } }, searches)
            assert.are.same({}, zlib_searches)
            assert.are.same({}, zlib_logins)
        end)

        it("logs in to Z-Library first, where it's the only site ticked", function()
            settings.search_sources = { "zlib" }
            zlib_logged_in = false
            searchSites("x")
            assert.are.same({}, zlib_searches)
            assert.are.equal(1, #zlib_logins)

            zlib_logged_in = true
            andSearch(zlib_logins[1])
            assert.are.equal(1, #zlib_searches)
        end)
    end)

    -- in the search box, ticked in a menu of their own, and searched from then on
    describe("choosing the sites to search", function()
        local function sitesMenu(plugin)
            buttonWithId(plugin.search_box, "sites").callback()
            return helper.lastShown()
        end

        local function rowTexts(dialog)
            local texts = {}
            for _, row in ipairs(dialog.buttons) do
                table.insert(texts, row[1].text)
            end
            return texts
        end

        it("ticks and unticks them, searching those ticked from then on", function()
            local plugin = openUI()
            plugin:setupUI()
            local menu = sitesMenu(plugin)
            assert.are.equal("Search on", menu.title)
            assert.are.same(
                { "Z-Library", "✓ Library Genesis", "Internet Archive", "Project Gutenberg" },
                rowTexts(menu)
            )

            menu.buttons[3][1].callback()
            assert.are.same(
                { "Z-Library", "✓ Library Genesis", "✓ Internet Archive", "Project Gutenberg" },
                rowTexts(menu)
            )
            assert.are.equal(
                "Sites: Library Genesis and Internet Archive",
                buttonWithId(plugin.search_box, "sites").text
            )
            assert.are.same({ "libgen", "archive" }, settings.search_sources)

            menu.buttons[2][1].callback()
            assert.are.same({ "archive" }, settings.search_sources)
            plugin.search_box.input_text = "emma"
            andSearch(button(plugin.search_box, "Search").callback)
            assert.are.same({}, searches)
            assert.are.same({ { "emma", 1 } }, archive_searches)
        end)

        it("keeps at least one ticked", function()
            local plugin = openUI()
            plugin:setupUI()
            sitesMenu(plugin).buttons[2][1].callback()

            assert.are.equal("Choose at least one site to search", helper.lastNotification())
            assert.are.same({ "libgen" }, settings.search_sources)
        end)

        it("says when they're all ticked", function()
            settings.search_sources = { "zlib", "gutenberg", "libgen", "archive" }
            local plugin = openUI()
            plugin:setupUI()
            assert.are.equal("Sites: All", buttonWithId(plugin.search_box, "sites").text)
        end)

        -- e.g. a library the user has added (see MultiSearch.addSite), returning what it's asked to search for
        local function addLibrary()
            local library_searches = {}
            require("api.multisearch").addSite("library_1", {
                NAME = "Home library",
                search = function(_, query, page, scope)
                    table.insert(library_searches, { query, page, scope })
                    return {}, nil, nil, 0
                end,
                isCached = function()
                    return false
                end,
            })
            return library_searches
        end

        it("offers the sites added while KOReader runs first, searching them once ticked", function()
            local plugin = openUI()
            local library_searches = addLibrary()
            plugin:setupUI()
            local menu = sitesMenu(plugin)
            assert.are.same(
                { "Home library", "Z-Library", "✓ Library Genesis", "Internet Archive", "Project Gutenberg" },
                rowTexts(menu)
            )

            menu.buttons[1][1].callback()
            assert.are.same({ "library_1", "libgen" }, settings.search_sources)
            assert.are.equal("Sites: Home library and Library Genesis", buttonWithId(plugin.search_box, "sites").text)
            plugin.search_box.input_text = "emma"
            andSearch(button(plugin.search_box, "Search").callback)
            assert.are.same({ { "emma", 1 } }, library_searches)
            assert.are.same({ { "emma", 1 } }, searches)
        end)

        it("offers the libraries in the settings once KOReader has started", function()
            settings.libraries = {
                {
                    id = "a1",
                    name = "Books",
                    url = "http://nas:8080/opds?library_id=Books",
                    kind = "calibre",
                    search_url = "http://nas:8080/opds/search/{searchTerms}?library_id=Books",
                    username = "",
                    password = "",
                },
            }
            local plugin = openUI()
            plugin:setupUI()
            assert.are.equal("Books", rowTexts(sitesMenu(plugin))[1])
        end)

        it("says when they're all ticked, with the sites added", function()
            settings.search_sources = { "zlib", "gutenberg", "libgen", "archive", "library_1" }
            local plugin = openUI()
            addLibrary()
            plugin:setupUI()
            assert.are.equal("Sites: All", buttonWithId(plugin.search_box, "sites").text)
        end)

        it("stops offering or searching a site that has been removed, though it was ticked", function()
            settings.search_sources = { "library_1", "libgen" }
            local plugin = openUI()
            local library_searches = addLibrary()
            require("api.multisearch").removeSite("library_1")
            plugin:setupUI()
            assert.are.equal("Sites: Library Genesis", buttonWithId(plugin.search_box, "sites").text)
            assert.are.same(
                { "Z-Library", "✓ Library Genesis", "Internet Archive", "Project Gutenberg" },
                rowTexts(sitesMenu(plugin))
            )

            plugin.search_box.input_text = "emma"
            andSearch(button(plugin.search_box, "Search").callback)
            assert.are.same({}, library_searches)
            assert.are.same({ { "emma", 1 } }, searches)
        end)

        -- as it can only be searched with an account
        it("logs in to Z-Library before ticking it", function()
            zlib_logged_in = false
            local plugin = openUI()
            plugin:setupUI()
            local menu = sitesMenu(plugin)
            assert.are.equal("Z-Library (log in)", menu.buttons[1][1].text)

            menu.buttons[1][1].callback()
            assert.is_true(helper.wasClosed(menu))
            assert.are.same({ "libgen" }, settings.search_sources)
            zlib_logged_in = true
            zlib_logins[1]()
            assert.are.same({ "zlib", "libgen" }, settings.search_sources)
            assert.are.equal("Sites: Z-Library and Library Genesis", buttonWithId(plugin.search_box, "sites").text)
        end)

        -- which it is to begin with, as every site is
        it("shows Z-Library unticked while it isn't logged into, though it's ticked to be searched", function()
            settings.search_sources = { "zlib", "libgen", "archive", "gutenberg" }
            zlib_logged_in = false
            local plugin = openUI()
            plugin:setupUI()
            assert.are.equal("Sites: All but Z-Library", buttonWithId(plugin.search_box, "sites").text)
            assert.are.equal("Z-Library (log in)", sitesMenu(plugin).buttons[1][1].text)

            zlib_logged_in = true
            plugin:setupUI()
            assert.are.equal("Sites: All", buttonWithId(plugin.search_box, "sites").text)
        end)
    end)

    -- e.g. only the books' authors, on the sites that can be
    describe("narrowing a search down", function()
        it("searches what's chosen in the search box", function()
            local plugin = openUI()
            plugin:setupUI(nil, nil, { "libgen" })
            local scope = button(plugin.search_box, "Search in: All")
            assert.are.equal("scope", scope.id)

            scope.callback()
            local chooser = helper.lastShown()
            assert.are.equal("✓ All", chooser.buttons[1][1].text)
            assert.are.equal("Author", chooser.buttons[1][3].text)
            chooser.buttons[1][3].callback()
            assert.is_true(helper.wasClosed(chooser))
            assert.are.equal("Search in: Author", scope.text)

            plugin.search_box.input_text = "herbert"
            andSearch(button(plugin.search_box, "Search").callback)
            assert.are.same({ { "herbert", 1, "author" } }, searches)
        end)

        -- which can't be
        it("searches everything on Z-Library", function()
            andSearch(openUI().setupUI, openUI(), "1984", "author", { "zlib" }, true)
            assert.are.same({ { "1984", 1 } }, zlib_searches)
        end)

        it("searches the other sites narrowed down as this one was, where they can be", function()
            local plugin = openUI()
            andSearch(plugin.setupUI, plugin, "herbert", "author", { "libgen" }, true)
            local explanation = helper.lastShown()
            -- Internet Archive, after Z-Library
            explanation.other_buttons[1][2].callback()
            helper.tick()
            helper.tick()
            assert.are.same({ { "herbert", 1, "author" } }, archive_searches)
            assert.are.equal("Search in: Author", button(plugin.search_box, "Search in: Author").text)
        end)

        it("searches the authors' names for more by an author", function()
            local plugin = openUI()
            plugin:searchFor("Frank Herbert", "author")
            assert.are.equal("Search in: Author", buttonWithId(plugin.search_box, "scope").text)
            andSearch(button(plugin.search_box, "Search").callback)
            assert.are.same({ { "Frank Herbert", 1, "author" } }, searches)
        end)
    end)

    describe("searching from books", function()
        local function texts(row)
            local result = {}
            for _, b in ipairs(row) do
                table.insert(result, b.text)
            end
            return result
        end

        -- to choose the sites to search, as for any other search
        it("opens the search box with what's given in it, on one line", function()
            local plugin = openUI()
            plugin:searchFor("  Frank\n  Herbert ")

            assert.are.equal(plugin.search_box, helper.lastShown())
            assert.are.equal("Frank Herbert", plugin.search_box.input)
            assert.are.equal("Sites: Library Genesis", buttonWithId(plugin.search_box, "sites").text)
            assert.are.same({}, searches)
            andSearch(button(plugin.search_box, "Search").callback)
            assert.are.same({ { "Frank Herbert", 1 } }, searches)
        end)

        -- as a whole paragraph can't be searched for
        it("searches for the start of what's long, up to a space", function()
            local plugin = openUI()
            plugin:searchFor(string.rep("word ", 30))
            assert.are.equal(string.rep("word ", 19) .. "word", plugin.search_box.input)

            -- or between characters, rather than partway through one
            plugin:searchFor(string.rep("é", 60))
            assert.are.equal(string.rep("é", 50), plugin.search_box.input)
            plugin:searchFor("a" .. string.rep("é", 60))
            assert.are.equal("a" .. string.rep("é", 49), plugin.search_box.input)
        end)

        it("doesn't search for nothing", function()
            openUI():searchFor(" \n ")
            assert.are.equal(0, #helper.state.shown)
        end)

        describe("from KOReader's dialog for a book", function()
            local added, widgets

            before_each(function()
                added, widgets = {}, {}
                FileManager.addFileDialogButtons = function(widget, row_id, row_func)
                    table.insert(added, { widget = widget, row_id = row_id, row_func = row_func })
                end
                for _, name in ipairs({ "filemanagerhistory", "filemanagercollection", "filemanagerfilesearcher" }) do
                    local menu = { file_dialog = { name = name } }
                    widgets[name] = {
                        getMenuInstance = function()
                            return menu
                        end,
                    }
                    helper.stub("apps/filemanager/" .. name, widgets[name])
                end
            end)

            it("offers more by the book's author, in the file browser, history, collections and file search", function()
                openUI()
                openUI()

                -- once a session
                assert.are.equal(4, #added)
                assert.are.equal(FileManager, added[1].widget)
                assert.are.equal(widgets.filemanagerhistory, added[2].widget)
                assert.are.equal("kindlefetch", added[1].row_id)

                local row = added[2].row_func("/books/Dune.epub", true, { authors = "Frank Herbert\nBrian Herbert" })
                assert.are.same({ "More by this author" }, texts(row))
                row[1].callback()
                assert.are.equal("Frank Herbert", helper.lastShown().input)
                assert.are.equal("Search in: Author", buttonWithId(helper.lastShown(), "scope").text)
            end)

            it("closes the dialog it's in", function()
                openUI()
                local history_dialog = widgets.filemanagerhistory.getMenuInstance().file_dialog
                local row = added[2].row_func("/books/Dune.epub", true, { authors = "Frank Herbert" })
                row[1].callback()
                assert.is_true(helper.wasClosed(history_dialog))
            end)

            it("offers nothing for folders, or books whose author isn't known", function()
                openUI()
                assert.is_nil(added[1].row_func("/books", false, nil))
                assert.is_nil(added[1].row_func("/books/Dune.epub", true, nil))
                assert.is_nil(added[1].row_func("/books/Dune.epub", true, { authors = "" }))
            end)

            -- rather than one for a book that has been closed since
            it("searches from what's open by then", function()
                openUI()
                local latest = openUI()
                added[1].row_func("/books/Dune.epub", true, { authors = "Frank Herbert" })[1].callback()
                assert.are.equal(latest.search_box, helper.lastShown())
            end)
        end)

        it("searches for what's highlighted in a book", function()
            local added = {}
            KindleFetch:new {
                ui = {
                    menu = { registerToMainMenu = function() end },
                    highlight = {
                        addToHighlightDialog = function(_, idx, fn_button)
                            added[idx] = fn_button
                        end,
                    },
                },
            }
            local closed = false
            local search_button = added["12_kindlefetch_search"]({
                selected_text = { text = "the spice\nmust flow" },
                onClose = function()
                    closed = true
                end,
            })

            assert.are.equal("Search Kindle Fetch", search_button.text)
            search_button.callback()
            assert.is_true(closed)
            assert.are.equal("the spice must flow", helper.lastShown().input)
        end)

        it("offers more by the author of the book being read, in Kindle Fetch's menu", function()
            local function menuTexts(plugin)
                local menu_items = {}
                plugin:addToMainMenu(menu_items)
                local result = {}
                for _, item in ipairs(menu_items.kindlefetch.sub_item_table) do
                    table.insert(result, item.text or item.text_func())
                end
                return result, menu_items.kindlefetch.sub_item_table
            end

            local reading = KindleFetch:new {
                ui = {
                    menu = { registerToMainMenu = function() end },
                    document = {},
                    doc_props = { authors = "Frank Herbert" },
                },
            }
            local menu_texts, items = menuTexts(reading)
            -- after Search
            assert.are.equal("More by Frank Herbert", menu_texts[2])
            items[2].callback()
            assert.are.equal("Frank Herbert", helper.lastShown().input)

            -- which there's nothing to search for without
            reading.ui.doc_props = {}
            menu_texts, items = menuTexts(reading)
            assert.are.equal("More by this author", menu_texts[2])
            assert.is_false(items[2].enabled_func())
            -- or a book
            menu_texts = menuTexts(openUI())
            assert.are.equal("Downloads", menu_texts[2])
        end)
    end)

    describe("changing what the books found can be in, from the results", function()
        local plugin

        -- the results' menu's Search again, offering what can be changed, from the menu that's open
        local function searchAgain(menu)
            menu:onLeftButtonTap()
            local results_menu = helper.lastShown()
            button(results_menu, "Search again…").callback()
            assert.is_true(helper.wasClosed(results_menu))
            return helper.lastShown()
        end

        before_each(function()
            search_results[1] = { { book("1984"), book("Animal Farm") } }
            plugin = openUI()
            search(plugin, "orwell")
        end)

        it("offers the languages, file types and book types", function()
            local dialog = searchAgain(menus[1])
            assert.are.equal("Change the settings, and search again:", dialog.title)
            button(dialog, "Languages…").callback()
            assert.is_true(helper.wasClosed(dialog))
            assert.are.equal("languages", choosers[1].name)

            button(searchAgain(menus[1]), "File types…").callback()
            button(searchAgain(menus[1]), "Book types…").callback()
            assert.are.equal("file types", choosers[2].name)
            assert.are.equal("book types", choosers[3].name)
        end)

        it("searches again once they've changed, in place of the results", function()
            button(searchAgain(menus[1]), "Languages…").callback()
            search_results[1] = { { book("Nineteen Eighty-Four") } }
            andSearch(choosers[1].on_closed, true)

            assert.is_true(helper.wasClosed(menus[1]))
            assert.are.same({ { "orwell", 1 }, { "orwell", 1 } }, searches)
            assert.are.same({ "Nineteen Eighty-Four" }, itemTexts(menus[2]))
        end)

        it("leaves the results as they are when nothing has changed", function()
            button(searchAgain(menus[1]), "File types…").callback()
            choosers[1].on_closed(false)

            assert.is_false(helper.wasClosed(menus[1]))
            assert.are.equal(1, #searches)
        end)

        -- which only Library Genesis sorts its books into
        it("leaves book types out for the other sites", function()
            search_results[1] = { { book("Emma") } }
            search(plugin, "emma", "archive")
            local dialog = searchAgain(menus[2])
            assert.is_false(pcall(button, dialog, "Book types…"))
            assert.is_true(pcall(button, dialog, "Languages…"))
        end)
    end)

    describe("looking through the books found", function()
        local plugin

        before_each(function()
            local orwell = book("1984")
            orwell.authors = "George Orwell"
            local huxley = book("Brave New World", "pdf")
            huxley.authors = "Aldous Huxley"
            local farm = book("Animal Farm")
            farm.authors = "George Orwell"
            search_results[1] = { { orwell, huxley, farm }, nil, 2 }
            plugin = openUI()
            search(plugin, "dystopia")
        end)

        -- KOReader's Go to letter, on tapping the page number, exited KOReader on a book without
        it("lists each book with its title, authors and file type", function()
            local items = menus[1].item_table
            assert.are.equal("1984 · George Orwell · EPUB", items[1].text)
            assert.are.equal("Brave New World · Aldous Huxley · PDF", items[2].text)
            assert.are.equal("Load more", items[4].text)
            for _, item in ipairs(items) do
                assert.are.equal("string", type(item.text))
            end
        end)

        it("shows only the books with the text in their title, authors or file type, from the page number", function()
            -- KOReader's Search, on tapping the page number
            menus[1].search_callback("orwell")
            -- with Load more, whose books are looked through as these are
            assert.are.same({ "1984", "Animal Farm", "Load more" }, itemTexts(menus[1]))
            assert.are.equal("dystopia · 2 of 3 books", menus[1].title)
            assert.are.equal(1, menus[1].page)
            assert.are.same({ 1, 1 }, menus[1].covers_loaded)
            -- without searching again
            assert.are.same({ { "dystopia", 1 } }, searches)

            menus[1].search_callback(" PDF ")
            assert.are.same({ "Brave New World", "Load more" }, itemTexts(menus[1]))
        end)

        it("shows every book again, with Load more, once there's no text to look for", function()
            menus[1].search_callback("orwell")
            menus[1].search_callback("")
            assert.are.same({ "1984", "Brave New World", "Animal Farm", "Load more" }, itemTexts(menus[1]))
            assert.are.equal("dystopia · 3+ books", menus[1].title)
        end)

        it("says when none of the books have the text, leaving them as they were", function()
            menus[1].search_callback("orwell")
            menus[1].search_callback("tolkien")
            assert.are.equal("None of the books found have “tolkien” in them.", helper.lastShown().text)
            assert.are.same({ "1984", "Animal Farm", "Load more" }, itemTexts(menus[1]))
        end)

        it("is offered from the menu at the top of the results, along with showing every book again", function()
            assert.are.equal("appbar.menu", menus[1].title_bar_left_icon)
            menus[1]:onLeftButtonTap()
            local results_menu = helper.lastShown()
            -- there's nothing to show again yet
            assert.is_false(pcall(button, results_menu, "Show all 3 books"))

            button(results_menu, "Look through the books found…").callback()
            assert.is_true(helper.wasClosed(results_menu))
            local dialog = helper.lastShown()
            assert.is_true(dialog.keyboard_shown)
            dialog.input_text = "huxley"
            button(dialog, "Look through").callback()
            assert.is_true(helper.wasClosed(dialog))
            assert.are.same({ "Brave New World", "Load more" }, itemTexts(menus[1]))

            menus[1]:onLeftButtonTap()
            -- with what's being looked for, to change it
            button(helper.lastShown(), "Look through the books found…").callback()
            assert.are.equal("huxley", helper.lastShown().input)
            menus[1]:onLeftButtonTap()
            button(helper.lastShown(), "Show all 3 books").callback()
            assert.are.same({ "1984", "Brave New World", "Animal Farm", "Load more" }, itemTexts(menus[1]))
        end)

        it("starts afresh for the next search", function()
            menus[1].search_callback("orwell")
            search_results[1] = { { book("Dune") } }
            search(plugin, "dune")
            assert.are.same({ "Dune" }, itemTexts(menus[2]))
            assert.are.equal("dune · 1 book", menus[2].title)
        end)
    end)

    describe("showing only some of the books found", function()
        local plugin

        -- a book found on the site, in the language, and the file type where given
        local function siteBook(title, source, language, file_type)
            local found = book(title, file_type)
            found.source = source
            found.language = language
            return found
        end

        local function searchDune()
            plugin:setupUI()
            plugin.search_box.input_text = "dune"
            andSearch(button(plugin.search_box, "Search").callback)
        end

        -- the texts of the buttons in the menu at the top of the results that are showing, and the menu
        local function resultsMenu()
            menus[#menus]:onLeftButtonTap()
            local results_menu = helper.lastShown()
            local texts = {}
            for _, row in ipairs(results_menu.buttons) do
                for _, b in ipairs(row) do
                    table.insert(texts, b.text)
                end
            end
            return texts, results_menu
        end

        -- the button in the menu at the top of the results whose text starts with start
        local function filterButton(start)
            local _, results_menu = resultsMenu()
            for _, row in ipairs(results_menu.buttons) do
                for _, b in ipairs(row) do
                    if b.text:sub(1, #start) == start then
                        return b
                    end
                end
            end
            error("no button " .. start)
        end

        local function choiceTexts(list)
            local texts = {}
            for _, choice in ipairs(list.choices) do
                table.insert(texts, choice.text)
            end
            return texts
        end

        -- show only the books with the codes of what the button's list has, as if they were all that was ticked once
        -- it was closed, returning what saving it did: it's closed, with what's ticked changed, unless that's false
        local function show(start, codes)
            filterButton(start).callback()
            local list = tick_lists[#tick_lists]
            local taken = list.save(codes)
            if taken ~= false then
                list.on_closed(true)
            end
            return taken
        end

        local function loadMore()
            local items = menus[#menus].item_table
            andSearch(items[#items].callback)
        end

        before_each(function()
            settings.search_sources = { "zlib", "libgen", "archive" }
            zlib_logged_in = true
            site_results.zlib = {
                { { siteBook("Dune", "zlib", "english"), siteBook("Dune Messiah", "zlib", "French") }, nil, 2 },
            }
            search_results[1] = { { siteBook("Children of Dune", "libgen", "English", "pdf") }, nil, 2 }
            site_results.archive = { { { siteBook("Emma", "archive") } } }
            plugin = openUI()
            searchDune()
        end)

        it("offers to show only the books from some of the sites, languages and file types found", function()
            assert.are.same({
                "Look through the books found…",
                "Sites: All",
                "Languages: All",
                "File types: All",
                "Downloaded: All",
                "Search again…",
            }, (resultsMenu()))

            filterButton("Sites:").callback()
            assert.is_true(helper.wasClosed(helper.state.shown[#helper.state.shown]))
            local list = tick_lists[1]
            assert.are.equal("Sites", list.title)
            -- each with how many of the books have it, in the order the sites are offered
            assert.are.same({ "Z-Library (2)", "Library Genesis (1)", "Internet Archive (1)" }, choiceTexts(list))
            assert.are.same({ "zlib", "libgen", "archive" }, list.ticked)
            assert.are.equal("That would hide every book found.", list.none_text)

            -- the most common first, each site's spelling of a language as the same, and books that don't say last
            filterButton("Languages:").callback()
            assert.are.same({ "English (2)", "French (1)", "Unknown (1)" }, choiceTexts(tick_lists[2]))
            filterButton("File types:").callback()
            assert.are.same({ "EPUB (3)", "PDF (1)" }, choiceTexts(tick_lists[3]))
        end)

        it("shows only the books with what's ticked, without searching again", function()
            local covers_loaded = #menus[1].covers_loaded
            show("Sites:", { "zlib", "archive" })
            assert.are.same({ "Dune", "Dune Messiah", "Emma", "Load more" }, itemTexts(menus[1]))
            assert.are.equal("dune · 3 of 4 books", menus[1].title)
            -- from the first page, with its covers
            assert.are.equal(1, menus[1].page)
            assert.are.equal(covers_loaded + 1, #menus[1].covers_loaded)
            assert.are.equal(1, menus[1].covers_loaded[covers_loaded + 1])
            assert.are.same({ { "dune", 1 } }, searches)
            -- which the menu says, offering to show them all again
            assert.are.equal("Sites: Z-Library, Internet Archive", filterButton("Sites:").text)

            show("Languages:", { "english", "" })
            assert.are.same({ "Dune", "Emma", "Load more" }, itemTexts(menus[1]))
            filterButton("Show all 4 books").callback()
            assert.are.same({ "Dune", "Dune Messiah", "Children of Dune", "Emma", "Load more" }, itemTexts(menus[1]))
            assert.are.equal("dune · 4+ books", menus[1].title)
            assert.are.equal("Sites: All", filterButton("Sites:").text)
        end)

        it("leaves the list on the page it's on where nothing has changed", function()
            menus[1].page = 2
            filterButton("Sites:").callback()
            local list = tick_lists[1]
            list.save(list.ticked)
            list.on_closed(false)
            assert.are.equal(2, menus[1].page)
            assert.are.equal("dune · 4+ books", menus[1].title)
        end)

        it("doesn't hide every book, leaving the list open to tick something else", function()
            show("Languages:", { "french" })
            assert.is_false(show("Sites:", { "libgen", "archive" }))
            assert.are.equal("That would hide every book found.", helper.lastNotification())
            assert.are.same({ "Dune Messiah", "Load more" }, itemTexts(menus[1]))
            assert.are.equal("Sites: All", filterButton("Sites:").text)
        end)

        it("looks through the books shown for text", function()
            show("Sites:", { "libgen" })
            menus[1].search_callback("messiah")
            assert.are.equal("None of the books shown have “messiah” in them.", helper.lastShown().text)
            menus[1].search_callback("children")
            assert.are.same({ "Children of Dune", "Load more" }, itemTexts(menus[1]))
            -- and shows all of them again, whatever was hidden
            filterButton("Show all 4 books").callback()
            assert.are.equal(5, #menus[1].item_table)
        end)

        -- as there's nothing to choose between
        it("doesn't offer what all the books found have the same of", function()
            search_results[1] =
                { { siteBook("Dune", "libgen", "English"), siteBook("Dune Messiah", "libgen", "English") } }
            search(plugin, "dune")
            assert.are.same({
                "Look through the books found…",
                -- which takes looking in the download folder to know
                "Downloaded: All",
                "Search again…",
            }, (resultsMenu()))
        end)

        it("offers the decades the books found are from, and how big they are, where they differ", function()
            local dune = siteBook("Dune", "libgen", "English")
            dune.year, dune.file_size = "1965", "2 MB"
            local messiah = siteBook("Dune Messiah", "libgen", "English")
            messiah.year, messiah.file_size = "2008", "250 MB"
            search_results[1] = { { dune, messiah } }
            search(plugin, "dune")
            assert.are.same({
                "Look through the books found…",
                "Years: All",
                "Sizes: All",
                "Downloaded: All",
                "Search again…",
            }, (resultsMenu()))

            show("Years:", { "2000" })
            assert.are.same({ "Dune Messiah" }, itemTexts(menus[2]))
            show("Sizes:", { "2" })
            assert.are.equal("That would hide every book found.", helper.lastNotification())
            assert.are.equal("Years: 2000s", filterButton("Years:").text)
        end)

        it("shows which books have been downloaded already, or haven't", function()
            helper.state.fs["/mnt/us/documents/Dune.epub"] = "file"
            filterButton("Downloaded:").callback()
            assert.are.same({ "Yes (1)", "No (3)" }, choiceTexts(tick_lists[1]))
            tick_lists[1].save({ "no" })
            tick_lists[1].on_closed(true)
            assert.are.same({ "Dune Messiah", "Children of Dune", "Emma", "Load more" }, itemTexts(menus[1]))
            assert.are.equal("Downloaded: No", filterButton("Downloaded:").text)
        end)

        -- as nothing was said about what they have, which wasn't there to untick
        it("shows the books of the sites that finish later, but for what's hidden", function()
            site_results.archive = {
                function()
                    -- once Z-Library's and Library Genesis' books are showing
                    show("Languages:", { "english" })
                    return { siteBook("Emma", "archive", "German"), siteBook("Madame Bovary", "archive", "French") }
                end,
            }
            searchDune()
            assert.are.same({ "Dune", "Children of Dune", "Emma", "Load more" }, itemTexts(menus[2]))
            assert.are.equal("dune · 3 of 5 books", menus[2].title)
        end)

        it("loads more only from the sites shown", function()
            show("Sites:", { "libgen", "archive" })
            site_results.zlib[2] = { { siteBook("God Emperor of Dune", "zlib", "English") } }
            search_results[2] = { { siteBook("Heretics of Dune", "libgen", "English") } }
            loadMore()
            assert.are.same({ { "dune", 1 } }, zlib_searches)
            assert.are.same({ { "dune", 1 }, { "dune", 2 } }, searches)
            -- and has no more to load, though the sites hidden do
            assert.are.same({ "Children of Dune", "Emma", "Heretics of Dune" }, itemTexts(menus[1]))
        end)

        it("turns to the first of the books loaded that's shown", function()
            show("Sites:", { "zlib", "libgen" })
            site_results.zlib[2] = { { siteBook("God Emperor of Dune", "zlib", "English") } }
            search_results[2] = { { siteBook("Heretics of Dune", "libgen", "English") } }
            loadMore()
            -- the fourth shown, on the second page, rather than the fifth found
            assert.are.equal(2, menus[1].page)
        end)

        it("says when the books loaded are all hidden", function()
            show("Languages:", { "french" })
            site_results.zlib[2] = { { siteBook("God Emperor of Dune", "zlib", "English") } }
            search_results[2] = { {} }
            loadMore()
            assert.are.equal("1 more book was found, but it isn't among those shown.", helper.lastShown().text)
            assert.are.same({ "Dune Messiah" }, itemTexts(menus[1]))
        end)

        it("starts afresh for the next search", function()
            show("Sites:", { "zlib" })
            searchDune()
            assert.are.same({ "Dune", "Dune Messiah", "Children of Dune", "Emma", "Load more" }, itemTexts(menus[2]))
            assert.are.equal("Sites: All", filterButton("Sites:").text)
        end)
    end)

    describe("load more", function()
        local plugin

        local function loadMore()
            local items = menus[#menus].item_table
            andSearch(items[#items].callback)
        end

        before_each(function()
            plugin = openUI()
            search_results[1] = { { book("Dune"), book("Dune Messiah") }, nil, 2 }
            search(plugin, "dune")
        end)

        it("offers to try again when loading more fails as the device isn't connected", function()
            search_results[2] = { nil, "no internet connection" }
            loadMore()
            local again = helper.lastShown().other_buttons[1][1]
            assert.are.equal("Loading more books failed: no internet connection", helper.lastShown().text)

            search_results[2] = { { book("Children of Dune") }, nil, 4 }
            andSearch(again.callback)
            assert.are.same({ "Dune", "Dune Messiah", "Children of Dune", "Load more" }, itemTexts(menus[1]))
        end)

        it("says it's loading more until they're found, with a button to call it off", function()
            search_results[2] = { { book("Children of Dune") }, nil, 4 }
            local shown = #helper.state.shown
            loadMore()

            local message = helper.state.shown[shown + 1]
            assert.are.equal("Loading more books...", message.title)
            assert.are.equal("Cancel", message.buttons[1][1].text)
            assert.is_true(helper.wasClosed(message))
            -- which calls it off through the stand-in it waits with (see MultiSearch)
            assert.are.equal(message.dismiss_callback ~= nil, true)
            assert.are_not.equal(message, trap_widgets[2])
        end)

        it("leaves the books as they were once loading more is called off", function()
            search_results[2] = { nil, "request cancelled" }
            loadMore()

            assert.are.equal(1, #menus)
            assert.is_false(helper.wasClosed(menus[1]))
            assert.are.equal(0, #helper.state.notifications)

            -- and can be asked for again
            search_results[2] = { { book("Children of Dune") } }
            loadMore()
            assert.are.same({ "Dune", "Dune Messiah", "Children of Dune" }, itemTexts(menus[1]))
        end)

        it("adds the next books to the list", function()
            search_results[2] = { { book("Children of Dune") }, nil, 4 }
            loadMore()

            assert.are.same({ { "dune", 1 }, { "dune", 2 } }, searches)
            assert.are.same({ "Dune", "Dune Messiah", "Children of Dune", "Load more" }, itemTexts(menus[1]))
            assert.are.equal("dune · 3+ books", menus[1].title)
        end)

        -- it used to show them in a new list, back at its first page
        it("adds them to the list that's open, turning to the first of them and loading their covers", function()
            search_results[2] = { { book("Children of Dune"), book("God Emperor of Dune") }, nil, 4 }
            loadMore()

            assert.are.equal(1, #menus)
            assert.is_false(helper.wasClosed(menus[1]))
            -- the third book is the first on the second page
            assert.are.equal(2, menus[1].page)
            assert.are.same({ 1, 2 }, menus[1].covers_loaded)
            -- and the new books can be chosen, like the first ones
            menus[1].item_table[3].callback()
            assert.are.equal("Children of Dune", downloads[1].book.title)
        end)

        it("doesn't load the new books' covers when covers are turned off", function()
            settings.show_covers = false
            search_results[2] = { { book("Children of Dune") } }
            loadMore()

            -- only the first page's, from before they were turned off
            assert.are.same({ 1 }, menus[1].covers_loaded)
        end)

        it("carries on from where the last search stopped", function()
            search_results[2] = { { book("Children of Dune") }, nil, 4 }
            loadMore()
            search_results[4] = { { book("God Emperor of Dune") } }
            loadMore()

            assert.are.same({ "dune", 4 }, searches[3])
            -- the end of the results
            assert.are.same({ "Dune", "Dune Messiah", "Children of Dune", "God Emperor of Dune" }, itemTexts(menus[1]))
        end)

        it("turns on wifi first when offline, then loads them once connected", function()
            helper.stubs.network.connected = false
            search_results[2] = { { book("Children of Dune") } }
            loadMore()
            assert.are.equal("turn wifi on", helper.stubs.network.prompted)
            assert.are.equal(1, #searches)

            helper.stubs.network.connected = true
            andSearch(helper.stubs.network.when_connected)
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

        -- which was said to be the end of the results, and Load more taken away
        it("says loading more failed when the search doesn't say why", function()
            search_results[2] = { nil }
            loadMore()
            assert.are.equal("Loading more books failed: search failed", helper.lastError())
            assert.are.same({ "Dune", "Dune Messiah", "Load more" }, itemTexts(menus[1]))
        end)

        it("stays on the same page after an error", function()
            search_results[2] = { nil, "request timed out" }
            loadMore()
            assert.are.equal("Loading more books failed: request timed out", helper.lastError())

            search_results[2] = { { book("Children of Dune") } }
            loadMore()
            assert.are.same({ "dune", 2 }, searches[3])
        end)

        it("says when there are no more books, and takes Load more off the end of the list", function()
            search_results[2] = { {} }
            loadMore()

            assert.are.equal("No more books found", helper.lastShown().text)
            assert.are.equal(1, #menus)
            assert.are.same({ "Dune", "Dune Messiah" }, itemTexts(menus[1]))
            assert.are.equal("dune · 2 books", menus[1].title)
            -- staying on the page that was showing
            assert.are.equal(1, menus[1].page)
        end)

        it("doesn't search again once there are no more books", function()
            search_results[2] = { {} }
            loadMore()
            plugin:loadMoreBooks()

            assert.are.equal(2, #searches)
            assert.are.equal("No more books found", helper.lastShown().text)
        end)

        it("says when none of the next results could be shown, with more to look through", function()
            search_results[2] = { {}, nil, 7, 500 }
            loadMore()

            assert.are.equal(
                "None of the next 500 results are in the languages and file types chosen. Load more to keep looking.",
                helper.lastShown().text
            )
            assert.are.same({ "Dune", "Dune Messiah", "Load more" }, itemTexts(menus[1]))

            search_results[7] = { { book("Children of Dune") } }
            loadMore()
            assert.are.same({ "dune", 7 }, searches[3])
            assert.are.same({ "Dune", "Dune Messiah", "Children of Dune" }, itemTexts(menus[1]))
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

        it("marks the books that are in the download folder already", function()
            helper.state.fs["/mnt/us/documents/Dune.epub"] = "file"
            assert.is_true(menus[1].is_downloaded(book("Dune")))
            assert.is_false(menus[1].is_downloaded(book("AC/DC", "pdf")))
        end)

        it("marks a book as downloaded once it has", function()
            assert.is_false(menus[1].is_downloaded(book("Dune")))
            selectBook("Dune")
            helper.state.fs["/mnt/us/documents/Dune.epub"] = "file"
            downloads[1].callback(true, nil, "/mnt/us/documents/Dune.epub")

            assert.are.equal(1, menus[1].redrawn)
            assert.is_true(menus[1].is_downloaded(book("Dune")))
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

        it("closes the offer to read the book when it isn't wanted now", function()
            selectBook("Dune")
            downloads[1].callback(true, nil, "/mnt/us/books/Dune.epub")
            helper.tick()

            local dialog = helper.lastShown()
            -- rather than Cancel, as the book has downloaded
            assert.are.equal("Not now", dialog.buttons[1][1].text)
            dialog.buttons[1][1].callback()
            assert.is_true(helper.wasClosed(dialog))
            assert.is_nil(opened)
        end)

        -- which didn't show it until it was left and gone back to
        it("lists the downloaded book in the file browser", function()
            selectBook("Dune")
            downloads[1].callback(true, nil, "/mnt/us/books/Dune.epub")
            assert.are.equal(1, refreshes)
        end)

        it("offers what KOReader's file browser has for the book, beneath the question's answers", function()
            selectBook("Dune")
            downloads[1].callback(true, nil, "/mnt/us/books/Dune.epub")
            helper.tick()

            local dialog = helper.lastShown()
            local texts = {}
            for i, row in ipairs(dialog.buttons) do
                texts[i] = {}
                for __, b in ipairs(row) do
                    table.insert(texts[i], b.text)
                end
            end
            assert.are.same(
                { { "Not now", "Read now" }, { "Show folder", "Collections…", "Book information" } },
                texts
            )

            -- each closing the dialog first
            button(dialog, "Collections…").callback()
            assert.is_true(helper.wasClosed(dialog))
            assert.are.same({ "/mnt/us/books/Dune.epub" }, collections_chosen)

            downloads[1].callback(true, nil, "/mnt/us/books/Dune.epub")
            helper.tick()
            dialog = helper.lastShown()
            assert.is_true(button(dialog, "Book information").enabled)
            button(dialog, "Book information").callback()
            assert.is_true(helper.wasClosed(dialog))
            -- what's known of the book is found out from the file, as the site's details may not be the book's own
            assert.are.same({ { "/mnt/us/books/Dune.epub" } }, info_shown)
        end)

        it("shows the downloaded book's folder from behind the search", function()
            selectBook("Dune")
            downloads[1].callback(true, nil, "/mnt/us/books/Dune.epub")
            helper.tick()

            local dialog = helper.lastShown()
            button(dialog, "Show folder").callback()
            assert.are.same({ "/mnt/us/books/Dune.epub" }, folders_shown)
            assert.is_true(helper.wasClosed(dialog))
            -- which would otherwise hide it
            assert.is_true(helper.wasClosed(menus[1]))
            assert.is_true(helper.wasClosed(plugin.search_box))
        end)

        it("adds the downloaded book to collections from what's open by then", function()
            selectBook("Dune")
            readBook()
            local chosen = {}
            ReaderUI.instance.collections = collections(chosen)
            downloads[1].callback(true, nil, "/mnt/us/books/Dune.epub")
            helper.tick()

            button(helper.lastShown(), "Collections…").callback()
            assert.are.same({ "/mnt/us/books/Dune.epub" }, chosen)
            assert.are.same({}, collections_chosen)
        end)

        it("shows the downloaded book's information as KOReader before v2024.04 does", function()
            -- which was given what closes the dialog where it's given what's known of the book now
            helper.stub("apps/filemanager/filemanagerutil", {
                genBookInformationButton = function(file, caller_callback, button_disabled)
                    return {
                        text = "Book information",
                        enabled = not button_disabled,
                        callback = function()
                            caller_callback()
                            table.insert(info_shown, file)
                        end,
                    }
                end,
            })
            selectBook("Dune")
            downloads[1].callback(true, nil, "/mnt/us/books/Dune.epub")
            helper.tick()

            local dialog = helper.lastShown()
            assert.is_true(button(dialog, "Book information").enabled)
            button(dialog, "Book information").callback()
            assert.is_true(helper.wasClosed(dialog))
            assert.are.same({ "/mnt/us/books/Dune.epub" }, info_shown)
        end)

        it("leaves out what KOReader's file browser doesn't have", function()
            helper.stub("apps/filemanager/filemanagerutil", {})
            FileManager.instance.collections = nil
            selectBook("Dune")
            downloads[1].callback(true, nil, "/mnt/us/books/Dune.epub")
            helper.tick()

            -- rather than an empty row
            assert.are.equal(1, #helper.lastShown().buttons)
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
            FileManager.instance = fileManager()
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
            assert.are.equal("Download failed: download produced empty file", helper.lastError())

            downloads[1].callback(false)
            assert.are.equal("Download failed", helper.lastError())
            assert.are.equal(0, refreshes)
        end)

        -- rather than its link being looked up, only for Z-Library to say so
        it("logs in to Z-Library first, to download a book found there once logged out", function()
            local zlib_book = book("1984")
            zlib_book.source = "zlib"
            zlib_logged_in = false
            plugin:downloadBook(zlib_book)
            assert.are.equal(0, #downloads)
            assert.are.equal(1, #zlib_logins)

            zlib_logged_in = true
            zlib_logins[1]()
            assert.are.equal(zlib_book, downloads[1].book)
        end)

        describe("offering what fixes it when it fails", function()
            it("logs in again, then downloads the book again, once Z-Library has logged Kindle Fetch out", function()
                selectBook("Dune")
                downloads[1].callback(false, "Z-Library has logged Kindle Fetch out, so log in again")

                local failure = helper.lastShown()
                assert.are.equal(
                    "Download failed: Z-Library has logged Kindle Fetch out, so log in again",
                    failure.text
                )
                assert.are.equal("notice-warning", failure.icon)
                assert.are.equal("Log in", failure.other_buttons[1][1].text)
                failure.other_buttons[1][1].callback()
                zlib_logins[1]()
                assert.are.equal(2, #downloads)
                assert.are.equal("Dune", downloads[2].book.title)
            end)

            it("offers to update a Kindle's curl, where it's too old", function()
                selectBook("Dune")
                downloads[1].callback(false, require("util.errors").OUTDATED_CURL)

                local update = helper.lastShown().other_buttons[1][1]
                assert.are.equal("Update curl", update.text)
                update.callback()
                assert.are.equal(1, checks.curl)
                assert.is_true(curl_check_user_requested)
            end)

            it("turns Wi-Fi on, then downloads the book again, where the device isn't connected", function()
                selectBook("Dune")
                helper.stubs.network.wifi_on = false
                helper.stubs.network.connected = false
                downloads[1].callback(false, "no internet connection")

                local wifi = helper.lastShown().other_buttons[1][1]
                assert.are.equal("Turn on Wi-Fi", wifi.text)
                wifi.callback()
                assert.are.equal(1, #downloads)
                helper.stubs.network.when_connected()
                assert.are.equal(2, #downloads)
            end)
        end)

        it("says a download was cancelled, rather than that it failed", function()
            selectBook("Dune")
            downloads[1].callback(false, "request cancelled")
            assert.are.equal("Download cancelled", helper.lastNotification())
            assert.is_nil(helper.lastError())
        end)
    end)
end)
