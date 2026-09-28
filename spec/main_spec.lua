local helper = require("helper")
local fixtures = require("fixtures")

describe("KindleFetch", function()
    local KindleFetch, checks, settings, searches, search_results, downloads, menus, settings_shown

    -- KOReader creates a new plugin instance for the file manager and for every book that is opened
    local function openUI()
        return KindleFetch:new{
            ui = {
                menu = {
                    registerToMainMenu = function() end
                }
            }
        }
    end

    local function book(title, file_type)
        return {
            md5 = title:lower(),
            title = title,
            display_title = title,
            file_type = file_type or "epub"
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
            plugin = 0
        }
        settings = {
            show_covers = true,
            download_dir = "/mnt/us/documents"
        }
        searches, search_results, downloads, menus, settings_shown = {}, {}, {}, {}, 0

        helper.stub("settings.settings", {
            load = function() end,
            getShowBookCovers = function()
                return settings.show_covers
            end,
            getDownloadDir = function()
                return settings.download_dir
            end
        })
        helper.stub("settings.settingspage", {
            showSettings = function()
                settings_shown = settings_shown + 1
            end
        })
        helper.stub("api.annasapi", {
            search = function(_, query, page)
                table.insert(searches, {query, page})
                local result = search_results[page] or {{}}
                return result[1], result[2]
            end
        })
        helper.stub("api.lgliapi", {
            downloadBook = function(_, download_book, filepath, callback)
                table.insert(downloads, {
                    book = download_book,
                    filepath = filepath,
                    callback = callback
                })
            end
        })
        helper.stub("ui.bookmenu", {
            new = function(_, menu)
                menu.covers_loaded = {}
                function menu:loadCoversForPage(page)
                    table.insert(self.covers_loaded, page)
                end
                table.insert(menus, menu)
                return menu
            end
        })
        helper.stub("cache.covercache", {})
        helper.stub("updater.curlupdater", {
            checkVersion = function()
                checks.curl = checks.curl + 1
            end
        })
        helper.stub("updater.pluginupdater", {
            checkForUpdates = function()
                checks.plugin = checks.plugin + 1
            end
        })

        -- KOReader loads main.lua once per session
        KindleFetch = dofile("kindlefetch.koplugin/main.lua")
    end)

    describe("init", function()
        it("registers a dispatcher action", function()
            openUI()
            assert.are.equal("KindleFetch", helper.state.actions.kindlefetch_action.event)
        end)

        it("checks for updates once the UI is ready", function()
            openUI()
            assert.are.same({curl = 0, plugin = 0}, checks)

            helper.runScheduled()
            assert.are.same({curl = 1, plugin = 1}, checks)
        end)

        it("only checks for updates once per session", function()
            openUI()
            helper.runScheduled()
            openUI()
            openUI()
            helper.runScheduled()

            assert.are.same({curl = 1, plugin = 1}, checks)
        end)

        it("waits for a network connection before checking for updates", function()
            helper.stubs.network.connected = false
            openUI()
            helper.runScheduled()
            assert.are.same({curl = 0, plugin = 0}, checks)

            helper.stubs.network.connected = true
            openUI()
            helper.runScheduled()
            assert.are.same({curl = 1, plugin = 1}, checks)
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
            menuItem(plugin, "Search Anna's Archive").callback()

            assert.are.equal("Search Anna's Archive", plugin.search_box.title)
            assert.are.equal(plugin.search_box, helper.lastShown())
        end)

        it("opens the settings", function()
            menuItem(openUI(), "Settings").callback()
            assert.are.equal(1, settings_shown)
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

        it("offers to turn on wifi when it is off", function()
            helper.stubs.network.connected = false
            helper.stubs.network.wifi_on = false
            search(openUI(), "dune")

            assert.are.equal("turn wifi on", helper.stubs.network.prompted)
            assert.are.equal(0, #searches)
        end)

        it("offers to connect when wifi is on but not connected", function()
            helper.stubs.network.connected = false
            search(openUI(), "dune")

            assert.are.equal("connect to wifi", helper.stubs.network.prompted)
            assert.are.equal(0, #searches)
        end)

        it("shows the books found, with a way to load more", function()
            search_results[1] = {{book("Dune"), book("Dune Messiah")}}
            search(openUI(), "  dune  ")

            assert.are.same({{"dune", 1}}, searches)
            assert.are.equal("Searching...", helper.state.notifications[1])
            assert.are.same({"Dune", "Dune Messiah", "Load more"}, itemTexts(menus[1]))
            assert.are.equal(menus[1], helper.lastShown())
        end)

        it("loads covers for each page shown", function()
            search_results[1] = {{book("Dune")}}
            search(openUI(), "dune")
            menus[1].onPageChange(2)

            assert.are.same({1, 2}, menus[1].covers_loaded)
        end)

        it("does not load covers when they are turned off", function()
            settings.show_covers = false
            search_results[1] = {{book("Dune")}}
            search(openUI(), "dune")
            menus[1].onPageChange(2)

            assert.are.same({}, menus[1].covers_loaded)
        end)

        it("reports search errors", function()
            search_results[1] = {nil, "no Anna's Archive URLs available"}
            search(openUI(), "dune")

            assert.are.equal("Error: no Anna's Archive URLs available", helper.lastNotification())
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
            search_results[1] = {{book("Dune"), book("Dune Messiah")}}
            search(plugin, "dune")
        end)

        it("adds the next page of books to the list", function()
            search_results[2] = {{book("Children of Dune")}}
            loadMore()

            assert.are.same({{"dune", 1}, {"dune", 2}}, searches)
            assert.is_true(helper.wasClosed(menus[1]))
            assert.are.same({"Dune", "Dune Messiah", "Children of Dune", "Load more"}, itemTexts(menus[2]))
        end)

        it("stays on the same page after an error", function()
            search_results[2] = {nil, "request timed out"}
            loadMore()
            assert.are.equal("Error: request timed out", helper.lastNotification())

            search_results[2] = {{book("Children of Dune")}}
            loadMore()
            assert.are.same({"dune", 2}, searches[3])
        end)

        it("says when there are no more books", function()
            search_results[2] = {{}}
            loadMore()

            assert.are.equal("No more books found", helper.lastNotification())
            assert.are.equal(1, #menus)

            loadMore()
            assert.are.same({"dune", 2}, searches[3])
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

        before_each(function()
            search_results[1] = {{book("Dune"), book("AC/DC", "pdf")}}
            search(openUI(), "dune")
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

        it("says when the download has finished", function()
            selectBook("Dune")
            downloads[1].callback(true)
            assert.are.equal("Downloaded Dune", helper.lastNotification())
        end)

        it("says why a download failed", function()
            selectBook("Dune")
            downloads[1].callback(false, "cancelled")
            assert.are.equal("Download failed: cancelled", helper.lastNotification())

            downloads[1].callback(false)
            assert.are.equal("Download failed", helper.lastNotification())
        end)
    end)
end)
