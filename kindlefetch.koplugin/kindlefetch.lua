local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Trapper = require("ui/trapper")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local KindleFetchSettings = require("settings.settings")
local SettingsPage = require("settings.settingspage")
local util = require("util")
local NetworkMgr = require("ui/network/manager")
local StringUtil = require("util.stringutil")
local Sources = require("api.sources")
local Downloader = require("api.downloader")
local HttpUtil = require("util.httputil")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local BookMenu = require("ui.bookmenu")
local Menu = require("ui/widget/menu")
local WaitingMessage = require("ui.waitingmessage")
local ZlibLogin = require("ui.zliblogin")
local ZlibAccount = require("api.zlibaccount")
local SearchCache = require("cache.searchcache")
local UrlCache = require("cache.urlcache")
local CurlUpdater = require("updater.curlupdater")
local PluginUpdater = require("updater.pluginupdater")
local FileUtil = require("util.fileutil")
local PathUtil = require("util.pathutil")
local Rollback = require("updater.rollback")
local Errors = require("util.errors")
local Guard = require("util.guard")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext

-- a new plugin instance is created every time the file manager or a book is opened,
-- so only check for updates and clear old caches once per session
local update_check_scheduled = false
local version_checked = false
-- and only check for updates automatically once a day, in seconds
local UPDATE_CHECK_INTERVAL = 24 * 60 * 60

local function updateCheckDue()
    local last_check = KindleFetchSettings:getLastUpdateCheck()
    -- (or the clock has been put back since, as an e-reader's can be)
    return not last_check or math.abs(os.time() - last_check) >= UPDATE_CHECK_INTERVAL
end

local function installedVersion()
    return FileUtil.readFile(PathUtil.getPluginPath() .. "/version.txt")
end

-- what's needed to make sense of a crash.log from someone else's device
local function logEnvironment()
    local CurlUtil = require("util.curlutil")
    local ok, koreader_version = pcall(function()
        return require("version"):getCurrentRevision()
    end)
    local device = Device:isKindle() and "Kindle"
        or (Device.isKobo and Device:isKobo()) and "Kobo"
        or Device:isAndroid() and "Android"
        or Device:isSDL() and "computer"
        or "device"
    local proxy_url = os.getenv("PROXY_URL")
    LogUtil.info(
        string.format(
            "KindleFetch %s on KOReader %s, %s %s, curl %s%s",
            installedVersion() or "unknown",
            ok and koreader_version or "unknown",
            device,
            tostring(Device.model),
            CurlUtil.getVersion() or "not found",
            proxy_url and proxy_url ~= "" and ", with PROXY_URL set" or ""
        )
    )
    LogUtil.info(
        "downloading to",
        KindleFetchSettings:getDownloadDir(),
        "with covers",
        KindleFetchSettings:getShowBookCovers() and "on" or "off",
        "and update checks",
        KindleFetchSettings:getCheckForUpdates() and "on" or "off"
    )
    if not BookMenu.isSupported() then
        LogUtil.warn("showing results as a list without covers, as this KOReader's menu can't lay them out")
    end
end

-- clear caches left by other versions of the plugin, as their contents may not work with this one
local function clearCachesAfterUpdate()
    local version = installedVersion()
    if not version or version == KindleFetchSettings:getLastVersion() then
        return
    end

    LogUtil.info(
        "KindleFetch was",
        KindleFetchSettings:getLastVersion() or "not installed",
        "before, so clearing its caches"
    )
    SearchCache:clear()
    UrlCache:clear()
    KindleFetchSettings:setLastVersion(version)
end

local KindleFetch = WidgetContainer:new {
    name = "kindlefetch",
    is_doc_only = false,
}

function KindleFetch:onDispatcherRegisterActions()
    Dispatcher:registerAction("kindlefetch_action", {
        category = "none",
        event = "KindleFetch",
        title = _("Kindle Fetch"),
        general = true,
    })
    Dispatcher:registerAction("kindlefetch_archive_action", {
        category = "none",
        event = "KindleFetchArchive",
        title = T(_("Kindle Fetch: search %1"), Sources.archive.NAME),
        general = true,
    })
    Dispatcher:registerAction("kindlefetch_zlib_action", {
        category = "none",
        event = "KindleFetchZlib",
        title = T(_("Kindle Fetch: search %1"), Sources.zlib.NAME),
        general = true,
    })
end

-- cancel downloads when KOReader exits or restarts, so curl isn't left running and partial books are removed
-- (without returning true, so the event still reaches the rest of KOReader). KOReader closes without exiting too:
-- when the device is powered off or restarted, its storage is shared over USB (which curl would carry on writing
-- to), or it's quit from the file manager, each of which only sends Close (as closing a book doesn't)
function KindleFetch:onExit()
    if #Downloader:getActiveDownloads() > 0 then
        LogUtil.info("cancelling downloads, as KOReader is closing")
    end
    Downloader:cancelAllDownloads()
end
KindleFetch.onRestart = KindleFetch.onExit
KindleFetch.onClose = KindleFetch.onExit

-- downloads wait while the device sleeps or Wi-Fi is off, carrying on once it's back (again without returning true)
function KindleFetch:onSuspend()
    Downloader:onSuspend()
end
function KindleFetch:onResume()
    Downloader:onResume()
end
function KindleFetch:onNetworkDisconnected()
    Downloader:onNetworkDisconnected()
end
function KindleFetch:onNetworkConnected()
    Downloader:onNetworkConnected()
end

-- sent by the dispatcher actions, e.g. when a gesture is assigned to one
function KindleFetch:onKindleFetch()
    self:setupUI("libgen")
    return true
end
function KindleFetch:onKindleFetchArchive()
    self:setupUI("archive")
    return true
end
function KindleFetch:onKindleFetchZlib()
    self:setupUI("zlib")
    return true
end

function KindleFetch:init()
    -- load settings
    KindleFetchSettings:load()

    if not version_checked then
        version_checked = true
        logEnvironment()
        clearCachesAfterUpdate()
        -- tidy up after the last session, which may have closed with downloads still running
        require("util.curlutil").removeLeftovers()
    end

    -- get screen size
    if self.dimen == nil then
        self.dimen = Screen:getSize()
    end

    -- register to main menu
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    -- if network is connected, schedule update checks after UI is ready
    if
        not update_check_scheduled
        and KindleFetchSettings:getCheckForUpdates()
        and NetworkMgr:isConnected()
        and updateCheckDue()
    then
        update_check_scheduled = true
        -- (saying nothing if it goes wrong, as it wasn't asked for)
        Guard.scheduleIn(0.1, "checking for updates", function()
            -- the next check waits a day from here, whether or not the latest release can be looked up: on a Kindle
            -- whose curl is too old to look it up, updating curl was offered every time KOReader started (#57)
            KindleFetchSettings:setLastUpdateCheck(os.time())
            -- check curl is at min version
            CurlUpdater.checkVersion()
            -- check for updates
            PluginUpdater.checkForUpdates(false)
        end, Guard.quiet)
    end
end

function KindleFetch:checkForUpdates()
    NetworkMgr:runWhenConnected(function()
        NotifyUtil.info(_("Checking for updates..."))
        CurlUpdater.checkVersion(true)
        PluginUpdater.checkForUpdates(true)
    end)
end

function KindleFetch:addToMainMenu(menu_items)
    menu_items.kindlefetch = {
        text = _("Kindle Fetch"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = T(_("Search %1"), Sources.libgen.NAME),
                callback = function()
                    self:setupUI("libgen")
                end,
            },
            {
                text = T(_("Search %1"), Sources.archive.NAME),
                callback = function()
                    self:setupUI("archive")
                end,
            },
            {
                text = T(_("Search %1"), Sources.zlib.NAME),
                callback = function()
                    self:setupUI("zlib")
                end,
            },
            {
                -- where a download that was hidden can be shown again, without finding its book again
                text_func = function()
                    local count = #Downloader:getActiveDownloads()
                    return count > 0 and T(_("Downloads (%1)"), count) or _("Downloads")
                end,
                enabled_func = function()
                    return #Downloader:getActiveDownloads() > 0
                end,
                callback = function()
                    self:showDownloads()
                end,
            },
            {
                text = _("Settings"),
                callback = function()
                    SettingsPage:showSettings()
                end,
            },
            {
                text = _("Check for updates"),
                callback = function()
                    self:checkForUpdates()
                end,
            },
        },
    }

    -- the version installed before the last update, while it's kept, in case this one doesn't work on this device
    local previous_version = Rollback.previousVersion(PathUtil.getPluginPath())
    if previous_version then
        table.insert(menu_items.kindlefetch.sub_item_table, {
            text = T(_("Go back to v%1"), previous_version),
            callback = function()
                self:goBack(previous_version)
            end,
        })
    end
end

-- go back to the version installed before the last update (see Rollback), once KOReader has restarted
function KindleFetch:goBack(previous_version)
    local current_version = installedVersion() or "?"
    UIManager:show(ConfirmBox:new {
        text = T(
            _("Go back to Kindle Fetch v%1? v%2, the version installed now, is kept to go forward to again."),
            previous_version,
            current_version
        ),
        ok_text = _("Go back"),
        ok_callback = function()
            local ok, err = Rollback.goBack(PathUtil.getPluginPath())
            if not ok then
                NotifyUtil.error(T(_("Going back failed: %1"), err))
                return
            end
            -- so it isn't offered again every day, only when asked to check for updates
            KindleFetchSettings:setSkippedVersion(current_version)
            UIManager:askForRestart(
                T(_("Kindle Fetch has gone back to v%1, which KOReader will use once it restarts."), previous_version)
            )
        end,
    })
end

-- show the progress of the download in progress, or list them to choose from when there are several
function KindleFetch:showDownloads()
    local downloads = Downloader:getActiveDownloads()
    if #downloads == 0 then
        NotifyUtil.info(_("No downloads in progress"))
        return
    end
    if #downloads == 1 then
        Downloader:showDownload(downloads[1].id)
        return
    end

    local dialog
    local buttons = {}
    for __, download in ipairs(downloads) do
        -- how far along it is, or what it's doing when that isn't known
        local percentage = download.widget.percentage or 0
        local progress = percentage > 0 and string.format("%d%%", math.floor(percentage * 100))
            or download.widget.status_text
        table.insert(buttons, {
            {
                text = download.title .. " · " .. progress,
                callback = function()
                    UIManager:close(dialog)
                    Downloader:showDownload(download.id)
                end,
            },
        })
    end
    dialog = ButtonDialog:new {
        title = _("Downloads"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- the searches made recently, to choose one to search for again
function KindleFetch:showRecentSearches()
    local dialog
    local buttons = {}
    for __, query in ipairs(KindleFetchSettings:getRecentSearches()) do
        table.insert(buttons, {
            {
                text = query,
                callback = function()
                    UIManager:close(dialog)
                    self.search_box:setInputText(query)
                    self:performSearch()
                end,
            },
        })
    end
    dialog = ButtonDialog:new {
        title = _("Recent searches"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- whether the site can only be searched once logged into, and isn't. then logs in, calling on_logged_in once it has
local function needsLogin(source, on_logged_in)
    if not Sources[source].NEEDS_LOGIN or ZlibAccount:isLoggedIn() then
        return false
    end
    LogUtil.info("logging in to", Sources[source].NAME, "before searching it")
    ZlibLogin.show(on_logged_in)
    return true
end

-- open the search box, for searching the site source names (see Sources), once logged into it where it needs that
function KindleFetch:setupUI(source)
    -- grab self reference for callbacks
    local this = self
    local function openOnceLoggedIn()
        this:setupUI(source)
    end
    if needsLogin(source, openOnceLoggedIn) then
        return
    end
    self.source = source

    self.search_box = InputDialog:new {
        title = T(_("Search %1"), Sources[source].NAME),
        input_type = "text",
        buttons = {
            {
                {
                    text = "Cancel",
                    callback = function()
                        UIManager:close(this.search_box)
                    end,
                },
                {
                    text = _("Recent"),
                    id = "recent",
                    enabled = #KindleFetchSettings:getRecentSearches() > 0,
                    callback = function()
                        this:showRecentSearches()
                    end,
                },
                {
                    text = "Search",
                    -- so the keyboard's enter key searches too
                    is_enter_default = true,
                    callback = function()
                        this:performSearch()
                    end,
                },
            },
        },
    }
    UIManager:show(self.search_box)
end

function KindleFetch:performSearch()
    local query = StringUtil.trim(self.search_box:getInputText())

    -- close keyboard after search
    self.search_box:onCloseKeyboard()

    -- check query is not empty
    if query == "" then
        NotifyUtil.info(_("Enter a search term first"))
        return
    end

    -- nothing can be found with every language, file type or book type (where the site has them) turned off. said
    -- like the other things the search box needs first, each in a sentence of its own, to be translated whole
    local turned_off = #KindleFetchSettings:getPreferredLanguages() == 0 and "language"
        or #KindleFetchSettings:getPreferredFileTypes() == 0 and "file type"
        or Sources[self.source].HAS_BOOK_TYPES and #KindleFetchSettings:getPreferredBookTypes() == 0 and "book type"
    if turned_off then
        LogUtil.warn("every", turned_off, "is turned off, so there's nothing to search for")
        NotifyUtil.info(({
            ["language"] = _("Turn on at least one language in Kindle Fetch's settings first"),
            ["file type"] = _("Turn on at least one file type in Kindle Fetch's settings first"),
            ["book type"] = _("Turn on at least one book type in Kindle Fetch's settings first"),
        })[turned_off])
        return
    end

    -- e.g. once Z-Library has logged Kindle Fetch out (see ZlibAccount:request)
    local function searchOnceLoggedIn()
        self:performSearch()
    end
    if needsLogin(self.source, searchOnceLoggedIn) then
        return
    end

    -- check device is online, otherwise turn on wifi (as set up in KOReader's network settings) and search once
    -- connected,
    -- unless the results are saved from an earlier search
    if not NetworkMgr:isConnected() and not Sources[self.source]:isCached(query, 1) then
        NetworkMgr:runWhenConnected(function()
            self:performSearch()
        end)
        return
    end

    LogUtil.debug("starting search for", query)
    self:searchFrom(query, 1)
end

-- search from a page of the site's results, and show the books found
function KindleFetch:searchFrom(query, page)
    self.current_search_query = query
    -- saying what's being searched for, as the search box is behind it, on a line of its own, so the message covers
    -- the search box's own buttons however short the search
    local waiting_text = T(_("Searching %1 for\n“%2”..."), Sources[self.source].NAME, query)
    self:searchInBackground(query, page, waiting_text, function(books, err, next_page, results_read)
        self.books = books
        self.next_page = next_page

        -- which can't be searched for on this site, as when no results are in them, so the settings are offered
        if err == Errors.NO_FILE_TYPES then
            LogUtil.warn(Sources[self.source].NAME, "has none of the file types chosen")
            self:explainNoBooks(query, nil, nil)
            return
        end

        -- check for errors
        if err or not books then
            err = err or "search failed"
            LogUtil.warn(string.format("search for %q failed: %s", query, err))
            NotifyUtil.error(T(_("Search failed: %1"), err))
            return
        end
        if #books == 0 then
            LogUtil.info(
                string.format("no books found for %q with the preferred languages, file types and book types", query)
            )
            self:explainNoBooks(query, results_read or 0, next_page)
            return
        end

        -- show books
        self:rememberSearch(query)
        self:showBooks(books)
    end)
end

-- remember a search that found books, to search for again from Recent, rather than typos and searches that failed,
-- which it was remembered before, and enable Recent in the search box, which there may not have been any of when it
-- was opened
function KindleFetch:rememberSearch(query)
    KindleFetchSettings:addRecentSearch(query)
    local recent = self.search_box
        and self.search_box.button_table
        and self.search_box.button_table:getButtonById("recent")
    if recent then
        recent:enable()
    end
end

-- say that no books were found, and why when it's known: the site may have listed plenty, all in other languages or
-- file types than those chosen in the settings
function KindleFetch:explainNoBooks(query, results_read, next_page)
    if results_read == 0 then
        NotifyUtil.message(_("No books found"))
        return
    end

    -- (none at all for a site that has none of the file types chosen)
    local name = Sources[self.source].NAME
    local text = results_read
            and T(
                _("%1 listed %2 results, but none in the languages and file types chosen in Kindle Fetch's settings."),
                name,
                results_read
            )
        or T(_("%1 doesn't have books in any of the file types chosen in Kindle Fetch's settings."), name)
    UIManager:show(ConfirmBox:new {
        text = text,
        ok_text = _("Settings"),
        ok_callback = function()
            SettingsPage:showSettings()
        end,
        cancel_text = _("Close"),
        -- there are more results to look through
        other_buttons = next_page and {
            {
                {
                    text = _("Keep searching"),
                    callback = function()
                        self:searchOnline(query, next_page)
                    end,
                },
            },
        },
    })
end

-- search from a page of results (see searchFrom), turning on Wi-Fi first if need be, as KOReader is set up to, unless
-- the page is saved from an earlier search
function KindleFetch:searchOnline(query, page)
    if not NetworkMgr:isConnected() and not Sources[self.source]:isCached(query, page) then
        NetworkMgr:runWhenConnected(function()
            self:searchFrom(query, page)
        end)
        return
    end
    self:searchFrom(query, page)
end

function KindleFetch:search(query, page)
    local books, err, next_page, results_read = Sources[self.source]:search(query, page)

    if not books or type(books) ~= "table" then
        return nil, err
    end

    return books, nil, next_page, results_read
end

-- search without holding up the rest of KOReader while the site answers, where that's possible (see
-- HttpUtil), showing waiting_text until it has. calls on_done with what search returned, unless the search was
-- called off before finding anything, with the message's Cancel button
function KindleFetch:searchInBackground(query, page, waiting_text, on_done)
    -- results saved from an earlier search are there straight away
    local message
    local function closeMessage()
        if message and not message.cancelled and not message.closed then
            message.closed = true
            UIManager:close(message)
        end
    end

    -- an error is passed on rather than left to Trapper, which would lose it and leave the message up, including one
    -- in showing what was found
    Trapper:wrap(Guard.wrap(string.format("searching for %q", query), function()
        if not Sources[self.source]:isCached(query, page) then
            message = WaitingMessage.new(waiting_text)
            UIManager:show(message)
            -- so that a second tap on what started the search doesn't land on the message
            Device.input:inhibitInputUntil(true)
            UIManager:forceRePaint()
        end

        HttpUtil.setTrapWidget(message)
        local ok, books, err, next_page, results_read =
            Guard.pcall(string.format("search for %q", query), self.search, self, query, page)
        HttpUtil.setTrapWidget(nil)
        closeMessage()
        if not ok then
            books, err, next_page = nil, Errors.UNEXPECTED, nil
        end

        if err == HttpUtil.CANCELLED then
            LogUtil.info(string.format("search for %q was called off", query))
            return
        end
        on_done(books, err, next_page, results_read)
    end, function(err)
        HttpUtil.setTrapWidget(nil)
        closeMessage()
        -- which says it failed, as it does for any other error
        on_done(nil, err)
    end))
end

-- whether the results show the books' covers: when they're turned on, and KOReader's menu can lay them out (see
-- BookMenu.isSupported)
local function coversShown()
    return BookMenu.isSupported() and KindleFetchSettings:getShowBookCovers()
end

-- a book's title, authors and file type, which the results are looked through for (see filterBooks), as is each
-- entry's text by KOReader's own Go to letter, which KOReader exited on for an entry without text
local function bookText(book)
    local parts = {}
    local function add(part)
        if part and part ~= "" then
            table.insert(parts, part)
        end
    end
    add(book.display_title or book.title)
    add(book.authors)
    add(book.file_type and book.file_type:upper())
    return table.concat(parts, " · ")
end

-- the books as entries for the menu of results, followed by a way to load more when there are more to load. only
-- those with the text looked for in them, when the results are being looked through (see filterBooks)
function KindleFetch:bookMenuItems(books)
    local this = self
    local menu_items = {}
    local filter = self.filter and util.stringLower(self.filter)

    for __, book in ipairs(books) do
        local text = bookText(book)
        if not filter or util.stringLower(text):find(filter, 1, true) then
            table.insert(menu_items, {
                book = book,
                text = text,
                -- (where it's KOReader's own menu that lists them, see showBooks)
                mandatory_func = function()
                    return this:isDownloaded(book) and _("Downloaded") or nil
                end,
                callback = function()
                    this:downloadBook(book)
                end,
            })
        end
    end

    -- the books loaded wouldn't be among those being looked through
    if self.next_page and not self.filter then
        table.insert(menu_items, {
            text = _("Load more"),
            callback = function()
                self:loadMoreBooks()
            end,
        })
    end

    return menu_items
end

-- what was searched for and how many books have been found, for the top of the menu of results, and how many of them
-- have the text being looked for in them
function KindleFetch:booksTitle(shown)
    local count = #self.books
    if self.filter then
        return T(_("%1 · %2 of %3 books"), self.current_search_query, shown or count, count)
    end
    -- there may be more to load
    local found = self.next_page and T(_("%1+ books"), count) or T(N_("1 book", "%1 books", count), count)
    return string.format("%s · %s", self.current_search_query, found)
end

-- the number of books among menu items, leaving out Load more
local function countBooks(menu_items)
    local count = 0
    for __, item in ipairs(menu_items) do
        if item.book then
            count = count + 1
        end
    end
    return count
end

-- show only the books found with text in their title, authors or file type, whatever its capitals, without searching
-- again, or every book again when there's no text. the books shown stay as they are when none have it
function KindleFetch:filterBooks(text)
    text = StringUtil.trim(text)
    local previous = self.filter
    self.filter = text ~= "" and text or nil

    local items = self:bookMenuItems(self.books)
    local shown = countBooks(items)
    if shown == 0 then
        self.filter = previous
        NotifyUtil.message(T(_("None of the books found have “%1” in them."), text))
        return
    end
    LogUtil.info(string.format("showing %d of the %d books found, looking for %q", shown, #self.books, text))

    local menu = self.books_menu
    menu:switchItemTable(self:booksTitle(shown), items, 1)
    if coversShown() then
        menu:loadCoversForPage(1)
    end
end

-- ask for text to look through the books found for (see filterBooks)
function KindleFetch:askForFilter()
    local this = self
    local dialog
    dialog = InputDialog:new {
        title = _("Look through the books found for"),
        input = self.filter or "",
        input_hint = _("Title, author or file type"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Look through"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        UIManager:close(dialog)
                        this:filterBooks(text)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- what can be done with the books found, from the menu at the top left of the results
function KindleFetch:showResultsMenu()
    local this = self
    local dialog
    local buttons = {
        {
            {
                text = _("Look through the books found…"),
                callback = function()
                    UIManager:close(dialog)
                    this:askForFilter()
                end,
            },
        },
    }
    if self.filter then
        table.insert(buttons, {
            {
                text = T(_("Show all %1 books"), #self.books),
                callback = function()
                    UIManager:close(dialog)
                    this:filterBooks("")
                end,
            },
        })
    end
    dialog = ButtonDialog:new {
        buttons = buttons,
    }
    UIManager:show(dialog)
end

local function buildDownloadPath(book)
    local download_dir = KindleFetchSettings:getDownloadDir()
    local filename = util.getSafeFilename(book.title .. "." .. book.file_type, download_dir)
    return download_dir .. "/" .. filename
end

-- whether the book is in the download folder already, under the name it would be downloaded as. remembered for the
-- books showing, as working out that name means reading which file systems are mounted, until a download finishes
function KindleFetch:isDownloaded(book)
    self.downloaded = self.downloaded or {}
    if self.downloaded[book.id] == nil then
        self.downloaded[book.id] = FileUtil.isValidFile(buildDownloadPath(book)) or false
    end
    return self.downloaded[book.id]
end

function KindleFetch:showBooks(books)
    local this = self
    self.downloaded = nil
    self.filter = nil

    -- or as KOReader's own menu lists things, where its menu can't lay them out with their covers
    local MenuClass = BookMenu.isSupported() and BookMenu or Menu
    local menu
    menu = MenuClass:new {
        title = self:booksTitle(),
        -- rather than cutting a long search short
        title_shrink_font_to_fit = true,
        -- what can be done with the books found (see showResultsMenu)
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            this:showResultsMenu()
        end,
        -- the Search button KOReader offers on tapping the page number looks through the books found
        search_callback = function(text)
            this:filterBooks(text)
        end,
        item_table = self:bookMenuItems(books),
        covers_fullscreen = true,
        is_borderless = true,
        -- with square corners: rounded ones aren't painted, and show what was on screen before
        is_popout = false,
        width = this.dimen.w,
        height = this.dimen.h,
        items_max_lines = true,
        -- so books that have been downloaded already are marked as such
        is_downloaded = function(book)
            return this:isDownloaded(book)
        end,
        onPageChange = Guard.wrap("loading covers", function(page)
            if coversShown() then
                LogUtil.debug("loading covers for page", page)
                menu:loadCoversForPage(page)
            end
        end, Guard.quiet),
    }

    self.books_menu = menu

    UIManager:show(menu)
    UIManager:setDirty(menu, "full")

    -- load covers for first page
    if coversShown() then
        LogUtil.debug("loading covers for page 1")
        menu:loadCoversForPage(1)
    end
end

function KindleFetch:loadMoreBooks()
    if not self.next_page then
        NotifyUtil.message(_("No more books found"))
        return
    end

    -- turn on wifi first if need be, unless the next page is saved from an earlier search
    local query = self.current_search_query
    if not NetworkMgr:isConnected() and not Sources[self.source]:isCached(query, self.next_page) then
        NetworkMgr:runWhenConnected(function()
            self:loadMoreBooks()
        end)
        return
    end

    local waiting_text = _("Loading more books...")
    self:searchInBackground(query, self.next_page, waiting_text, function(books, err, next_page, results_read)
        -- (without books, as a search that didn't say why, rather than there being no more)
        if err or not books then
            err = err or "search failed"
            LogUtil.warn(string.format("loading more books for %q failed: %s", query, err))
            NotifyUtil.error(T(_("Loading more books failed: %1"), err))
            return
        end

        self.next_page = next_page
        if not books or #books == 0 then
            if next_page then
                -- there are more results to look through
                NotifyUtil.message(
                    T(
                        _(
                            "None of the next %1 results are in the languages and file types chosen. Load more to "
                                .. "keep looking."
                        ),
                        results_read or 0
                    )
                )
            else
                -- take Load more off the end of the list, staying on the page that's showing
                self.books_menu:switchItemTable(self:booksTitle(), self:bookMenuItems(self.books), -1)
                NotifyUtil.message(_("No more books found"))
            end
            return
        end

        -- append new books
        local first_new_book = #self.books + 1
        for __, book in ipairs(books) do
            table.insert(self.books, book)
        end

        -- add them to the menu where Load more was, turning to the page they start on (the one that was showing)
        -- rather than going back to the first
        local menu = self.books_menu
        menu:switchItemTable(self:booksTitle(), self:bookMenuItems(self.books), first_new_book)
        if coversShown() then
            LogUtil.debug("loading covers for page", menu.page)
            menu:loadCoversForPage(menu.page)
        end
    end)
end

function KindleFetch:openBook(filepath)
    -- close the results and the search box behind them too, which would otherwise show again once the book is closed
    if self.books_menu then
        UIManager:close(self.books_menu)
    end
    if self.search_box then
        UIManager:close(self.search_box)
    end

    -- open it from whichever of a book or the file manager is open by now, rather than from self.ui, as the one
    -- the download was started from may have closed since (e.g. while the download was hidden)
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then
        ReaderUI.instance:switchDocument(filepath)
        return
    end
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:openFile(filepath)
    else
        ReaderUI:showReader(filepath)
    end
end

function KindleFetch:downloadBook(book)
    local filepath = buildDownloadPath(book)
    Downloader:downloadBook(book, filepath, function(ok, err, saved_filepath)
        if ok then
            LogUtil.debug("downloaded book to", saved_filepath)
            -- so it's marked as downloaded in the results behind
            self.downloaded = nil
            if self.books_menu and not self.books_menu.closed then
                self.books_menu:updateItems()
            end
            -- ask on the next tick, once the download progress has closed
            Guard.nextTick("offering to read the downloaded book", function()
                -- centred, with the title in bold on a line of its own, so it stands out from the question
                local dialog
                dialog = ButtonDialog:new {
                    title = string.format(
                        "%s%s\n%s%s%s\n\n%s",
                        TextBoxWidget.PTF_HEADER,
                        _("Downloaded"),
                        TextBoxWidget.PTF_BOLD_START,
                        book.display_title or book.title,
                        TextBoxWidget.PTF_BOLD_END,
                        _("Would you like to read it now?")
                    ),
                    title_align = "center",
                    buttons = {
                        {
                            {
                                -- as the book has downloaded, and nothing is called off
                                text = _("Not now"),
                                id = "close",
                                callback = function()
                                    UIManager:close(dialog)
                                end,
                            },
                            {
                                text = _("Read now"),
                                id = "read",
                                callback = function()
                                    UIManager:close(dialog)
                                    self:openBook(saved_filepath)
                                end,
                            },
                        },
                    },
                }
                UIManager:show(dialog)
            end)
        elseif err == Errors.CANCELLED then
            LogUtil.debug("download cancelled", book.title)
            NotifyUtil.info(_("Download cancelled"))
        else
            LogUtil.warn("download failed for", book.title, err)
            NotifyUtil.error(err and T(_("Download failed: %1"), err) or _("Download failed"))
        end
    end, function(existing_filepath)
        -- the book is already there, and was chosen to be read rather than downloaded again
        self:openBook(existing_filepath)
    end)
end

return KindleFetch
