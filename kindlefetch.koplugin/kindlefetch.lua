local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local KindleFetchSettings = require("settings.settings")
local SettingsPage = require("settings.settingspage")
local Diagnostics = require("ui.diagnostics")
local NetworkMgr = require("ui/network/manager")
local StringUtil = require("util.stringutil")
local Sites = require("api.sites")
local Book = require("api.book")
local MultiSearch = require("api.multisearch")
local Downloader = require("api.downloader")
local HttpUtil = require("util.httputil")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local BookMenu = require("ui.bookmenu")
local WaitingMessage = require("ui.waitingmessage")
local ZlibLogin = require("ui.zliblogin")
local ErrorFixes = require("ui.errorfixes")
local SearchBox = require("ui.searchbox")
local ResultsView = require("ui.resultsview")
local SearchSession = require("api.searchsession")
local ZlibAccount = require("api.zlibaccount")
local Libraries = require("api.libraries")
local SearchCache = require("cache.searchcache")
local UrlCache = require("cache.urlcache")
local CurlUpdater = require("updater.curlupdater")
local CurlUtil = require("util.curlutil")
local PluginUpdater = require("updater.pluginupdater")
local Errors = require("util.errors")
local Guard = require("util.guard")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext

-- a new instance is made per file manager or book opened, so check for updates and clear old caches once a session
local update_check_scheduled = false
local version_checked = false
-- and only check for updates automatically once a day, in seconds
local UPDATE_CHECK_INTERVAL = 24 * 60 * 60
-- the most of what's highlighted in a book that's searched for (see searchFor), as a whole paragraph can't be
local MAX_QUERY_LENGTH = 100
-- the plugin for the file manager or book opened last, for the buttons added to KOReader's dialogs once a session
local latest
local file_dialog_buttons_added = false
-- the libraries said this session not to be reachable, which aren't said to be again (see sayFailed)
local unreachable_said = {}

local function updateCheckDue()
    local last_check = KindleFetchSettings:getLastUpdateCheck()
    -- (or the clock has been put back since, as an e-reader's can be)
    return not last_check or math.abs(os.time() - last_check) >= UPDATE_CHECK_INTERVAL
end

-- what's needed to make sense of a crash.log from someone else's device
local function logEnvironment()
    LogUtil.info(Diagnostics.summary())
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
    local version = Diagnostics.version()
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
        title = T(_("Kindle Fetch: search %1"), Sites.archive.NAME),
        general = true,
    })
    Dispatcher:registerAction("kindlefetch_zlib_action", {
        category = "none",
        event = "KindleFetchZlib",
        title = T(_("Kindle Fetch: search %1"), Sites.zlib.NAME),
        general = true,
    })
end

-- cancel downloads on exit or Close (as on power off or USB), so curl isn't left running, letting the event carry on
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

-- sent by the dispatcher actions (e.g. gestures): the search box, or one site's, from when each site had a gesture
function KindleFetch:onKindleFetch()
    self:setupUI()
    return true
end
function KindleFetch:onKindleFetchArchive()
    self:setupUI(nil, nil, { "archive" })
    return true
end
function KindleFetch:onKindleFetchZlib()
    self:setupUI(nil, nil, { "zlib" })
    return true
end

-- the first of a book's authors (KOReader lists them on lines of their own), or nil where it has none
local function firstAuthor(props)
    local authors = type(props) == "table" and props.authors
    local author = type(authors) == "string" and StringUtil.trim(authors:match("^[^\n]*")) or ""
    return author ~= "" and author or nil
end

-- add More by this author to the dialog on holding a book, where this KOReader can, once a session as it's KOReader's
local function addFileDialogButtons()
    local FileManager = require("apps/filemanager/filemanager")
    if file_dialog_buttons_added or not FileManager.addFileDialogButtons then
        return
    end
    file_dialog_buttons_added = true
    local widgets = { FileManager }
    for __, name in ipairs({ "filemanagerhistory", "filemanagercollection", "filemanagerfilesearcher" }) do
        local found, widget = pcall(require, "apps/filemanager/" .. name)
        if found then
            table.insert(widgets, widget)
        end
    end
    for __, widget in ipairs(widgets) do
        FileManager.addFileDialogButtons(widget, "kindlefetch", function(__, is_file, book_props)
            -- (nothing, rather than KOReader's dialog, where something goes wrong, see Guard)
            local author = is_file and Guard.call("finding a book's author", firstAuthor, Guard.quiet, book_props)
            if not author then
                return nil
            end
            return {
                {
                    text = _("More by this author"),
                    callback = Guard.wrap("searching for more by an author", function()
                        local menu = widget.getMenuInstance and widget.getMenuInstance()
                        if menu and menu.file_dialog then
                            UIManager:close(menu.file_dialog)
                        end
                        latest:searchFor(author, "author")
                    end),
                },
            }
        end)
    end
end

function KindleFetch:init()
    -- load settings
    KindleFetchSettings:load()
    latest = self
    -- and offer the libraries added to search with the other sites
    Libraries.register()

    if not version_checked then
        version_checked = true
        logEnvironment()
        clearCachesAfterUpdate()
        -- tidy up after the last session, which may have closed with downloads still running
        CurlUtil.removeLeftovers()
    end

    -- get screen size
    if self.dimen == nil then
        self.dimen = Screen:getSize()
    end

    -- register to main menu
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- and to KOReader's own dialogs, to search from books (see searchFor)
    addFileDialogButtons()
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        self:addToHighlightDialog()
    end

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
            -- the next check waits a day even if this fails, as too old a curl was offered updating every start (#57)
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
                -- the sites ticked in it (see SearchBox.chooseSites)
                text = _("Search"),
                callback = function()
                    self:setupUI()
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
            {
                -- what to copy or save for whoever's helping with a problem, and a test of connecting to the sites
                text = _("Diagnostics"),
                callback = function()
                    Diagnostics.show()
                end,
            },
        },
    }

    -- in a book, more by its author, where it's known (see searchFor), after Search
    if self.ui.document then
        table.insert(menu_items.kindlefetch.sub_item_table, 2, {
            text_func = function()
                local author = firstAuthor(self.ui.doc_props)
                return author and T(_("More by %1"), author) or _("More by this author")
            end,
            enabled_func = function()
                return firstAuthor(self.ui.doc_props) ~= nil
            end,
            callback = function()
                self:searchFor(firstAuthor(self.ui.doc_props), "author")
            end,
        })
    end
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
function KindleFetch:needsLogin(source, on_logged_in)
    if not (Sites[source] and Sites[source].NEEDS_LOGIN) or ZlibAccount:isLoggedIn() then
        return false
    end
    LogUtil.info("logging in to", Sites[source].NAME, "before searching it")
    ZlibLogin.show(on_logged_in)
    return true
end

-- say what failed in one (the error alone) where only one site was searched, else in several, a line for each site
local function describeFailures(one, several, failures, sites_searched)
    if sites_searched == 1 then
        return T(one, failures[1].err)
    end
    local lines = {}
    for __, failure in ipairs(failures) do
        table.insert(lines, T(_("%1: %2"), Sites[failure.source].NAME, failure.err))
    end
    return T(several, table.concat(lines, "\n"))
end

-- the sites ticked in the search box that can be searched now (see SearchBox.sitesToSearch)
function KindleFetch:sitesToSearch()
    return self.box:sitesToSearch()
end

-- open the search box (see SearchBox) for sources, or those ticked last, with query and scope, searching if search_now
function KindleFetch:setupUI(query, scope, sources, search_now)
    self.box = SearchBox.new(self, query, scope, sources)
    -- its dialog, as KOReader shows it
    self.search_box = self.box.dialog
    self.box:show()
    if query and search_now then
        self:performSearch()
    end
end

-- add Search Kindle Fetch to the highlight dialog second to last, as KOReader's plugins do, so its Search stays last
function KindleFetch:addToHighlightDialog()
    self.ui.highlight:addToHighlightDialog("12_kindlefetch_search", function(this)
        return {
            text = _("Search Kindle Fetch"),
            callback = Guard.wrap("searching for what's highlighted", function()
                local text = this.selected_text and this.selected_text.text
                this:onClose()
                self:searchFor(text)
            end),
        }
    end)
end

-- open the search box with query in it, on one line, cut short where long (see MAX_QUERY_LENGTH), narrowed to scope
function KindleFetch:searchFor(query, scope)
    query = StringUtil.trim(query or ""):gsub("%s+", " ")
    if #query > MAX_QUERY_LENGTH then
        -- at a space, or else between characters rather than partway through one (whose next byte carries on from it)
        local start = query:sub(1, MAX_QUERY_LENGTH)
        if query:sub(MAX_QUERY_LENGTH + 1, MAX_QUERY_LENGTH + 1):find("^[\128-\191]") then
            start = start:gsub("[\192-\255][\128-\191]*$", "")
        end
        query = start:match("^(.*%S)%s") or start
    end
    if query == "" then
        return
    end
    LogUtil.info(string.format("searching for %q, from a book", query))
    self:setupUI(query, scope)
end

-- buttons to search the other sites for query, Z-Library only once logged in, each closing the search box and results
function KindleFetch:otherSites(query)
    local buttons = {}
    local searched = {}
    for __, source in ipairs(self:sitesToSearch()) do
        searched[source] = true
    end
    for __, source in ipairs(MultiSearch.sources()) do
        if not searched[source] and MultiSearch.canSearch(source) then
            table.insert(buttons, {
                text = T(_("Search %1"), Sites[source].NAME),
                callback = function()
                    -- once what it's in has closed
                    Guard.nextTick("searching another site", function()
                        LogUtil.info(string.format("searching %s for %q instead", Sites[source].NAME, query))
                        local scope = self.box.scope
                        self:closeSearch()
                        -- narrowed down as these were, where it can be
                        self:setupUI(query, scope, { source }, true)
                    end)
                end,
            })
        end
    end
    return buttons
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

    -- nothing is found with every language, file type or book type off; each said in full, to be translated whole
    local sources = self:sitesToSearch()
    local has_book_types = false
    for __, source in ipairs(sources) do
        has_book_types = has_book_types or Sites[source].HAS_BOOK_TYPES == true
    end
    local turned_off = #KindleFetchSettings:getPreferredLanguages() == 0 and "language"
        or #KindleFetchSettings:getPreferredFileTypes() == 0 and "file type"
        or has_book_types and #KindleFetchSettings:getPreferredBookTypes() == 0 and "book type"
    if turned_off then
        LogUtil.warn("every", turned_off, "is turned off, so there's nothing to search for")
        NotifyUtil.info(({
            ["language"] = _("Turn on at least one language in Kindle Fetch's settings first"),
            ["file type"] = _("Turn on at least one file type in Kindle Fetch's settings first"),
            ["book type"] = _("Turn on at least one book type in Kindle Fetch's settings first"),
        })[turned_off])
        return
    end

    -- where all the sites ticked need logging into, as once Z-Library logs Kindle Fetch out (see ZlibAccount:request)
    local function searchOnceLoggedIn()
        self:performSearch()
    end
    if #sources == 0 then
        for __, source in ipairs(self.box.sources) do
            if self:needsLogin(source, searchOnceLoggedIn) then
                return
            end
        end
    end

    local pages = MultiSearch.firstPages(sources)
    if not self:canSearchNow(query, pages, function()
        self:performSearch()
    end) then
        return
    end

    LogUtil.debug("starting search for", query)
    self:searchFrom(query, pages)
end

-- search from pages (see MultiSearch.start), showing books as sites find them, or why none were found once all finish
function KindleFetch:searchFrom(query, pages)
    local sources = MultiSearch.sourcesOf(pages)
    local session = SearchSession.new(query, sources)
    self.session = session
    -- failures before books showed, results read finding none, sites lacking the file types chosen, and if called off
    local failures, results_read, no_file_types = {}, 0, {}
    local read_any, called_off = false, false
    -- the query on its own line, so the message covers the search box's buttons behind it, however short the search
    local waiting_text = T(_("Searching %1 for\n“%2”..."), MultiSearch.sitesName(sources), query)
    self:startSearch(query, pages, waiting_text, {
        on_result = function(source, books, err, next_page, read)
            local name = Sites[source].NAME
            if err == HttpUtil.CANCELLED then
                called_off = true
                LogUtil.info(string.format("search of %s for %q was called off", name, query))
                return
            end
            -- which can't be searched for on this site, as when no results are in them, so the settings are offered
            if err == Errors.NO_FILE_TYPES then
                LogUtil.warn(name, "has none of the file types chosen")
                table.insert(no_file_types, source)
                return
            end
            if err or not books then
                err = err or "search failed"
                LogUtil.warn(string.format("search of %s for %q failed: %s", name, query, err))
                table.insert(failures, { source = source, err = err })
                -- over the others' books, where they're showing
                if session.books then
                    self:sayFailed(failures)
                end
                return
            end
            read_any = true
            results_read = results_read + (read or 0)
            session.next_pages[source] = next_page
            if #books == 0 then
                LogUtil.info(
                    string.format(
                        "%s found no books for %q with the preferred languages, file types and book types",
                        name,
                        query
                    )
                )
                return
            end
            self:addBooks(session, books)
            self:sayFailed(failures)
        end,
        on_done = function()
            if session.books then
                if self.view then
                    self.view:finish()
                end
                return
            end
            if called_off then
                return
            end
            if #failures > 0 then
                self:explainFailure(query, pages, failures)
                return
            end
            if not read_any and #no_file_types > 0 then
                self:explainNoBooks(query, no_file_types, nil, {})
                return
            end
            self:explainNoBooks(query, sources, results_read, session.next_pages)
        end,
    })
end

-- say which sites failed and why, emptying failures; an unreachable library once a session, as it may be only at home
function KindleFetch:sayFailed(failures)
    for __, failure in ipairs(failures) do
        if failure.err ~= Errors.LIBRARY_UNREACHABLE or not unreachable_said[failure.source] then
            NotifyUtil.error(T(_("Searching %1 failed: %2"), Sites[failure.source].NAME, failure.err))
        end
        if failure.err == Errors.LIBRARY_UNREACHABLE then
            unreachable_said[failure.source] = true
        end
    end
    for i = #failures, 1, -1 do
        failures[i] = nil
    end
end

-- add the books a site has found to the session's, showing them once they're the first
function KindleFetch:addBooks(session, books)
    if session:addBooks(books) then
        self:closeWaitingMessage()
        self:rememberSearch(session.query)
        self:showBooks(session)
    elseif self.view then
        self.view:refresh()
    end
end

-- remember a search that found books for Recent, not typos or failures, and enable Recent, which may have had none
function KindleFetch:rememberSearch(query)
    KindleFetchSettings:addRecentSearch(query)
    if self.box then
        self.box:enableRecent()
    end
end

-- say why the sites failed, with the first fix any has (the same for each), and other sites unless not connected
function KindleFetch:explainFailure(query, pages, failures)
    local err = failures[1].err
    for __, failure in ipairs(failures) do
        if #ErrorFixes.buttons(failure.err, function() end) > 0 then
            err = failure.err
            break
        end
    end
    local text =
        describeFailures(_("Search failed: %1"), _("Search failed:\n%1"), failures, #MultiSearch.sourcesOf(pages))
    ErrorFixes.show(text, err, function()
        self:searchOnline(query, pages)
    end, { err ~= Errors.NO_CONNECTION and self:otherSites(query) or {} })
end

-- say sources found none, and why (results_read: all in other languages or file types; nil: none of those file types)
function KindleFetch:explainNoBooks(query, sources, results_read, next_pages)
    local name = MultiSearch.sitesName(sources)
    if results_read == 0 then
        UIManager:show(ConfirmBox:new {
            text = T(_("%1 found no books for “%2”."), name, query),
            icon = "notice-info",
            no_ok_button = true,
            cancel_text = _("Close"),
            other_buttons = { self:otherSites(query) },
        })
        return
    end

    -- (none at all for a site that has none of the file types chosen)
    local text = results_read
            and T(
                _("%1 listed %2 results, but none in the languages and file types chosen in Kindle Fetch's settings."),
                name,
                results_read
            )
        or T(
            N_(
                "%1 doesn't have books in any of the file types chosen in Kindle Fetch's settings.",
                "%1 don't have books in any of the file types chosen in Kindle Fetch's settings.",
                #sources
            ),
            name
        )
    local other_buttons = { self:otherSites(query) }
    -- there are more results to look through
    if next(next_pages) then
        local pages = {}
        for source, page in pairs(next_pages) do
            pages[source] = page
        end
        table.insert(other_buttons, 1, {
            {
                text = _("Keep searching"),
                callback = function()
                    self:searchOnline(query, pages)
                end,
            },
        })
    end
    UIManager:show(ConfirmBox:new {
        text = text,
        ok_text = _("Settings"),
        ok_callback = function()
            SettingsPage:showSettings()
        end,
        cancel_text = _("Close"),
        other_buttons = other_buttons,
    })
end

-- whether pages can be searched now: connected, or all saved before; else Wi-Fi is turned on, retrying once connected
function KindleFetch:canSearchNow(query, pages, retry)
    if NetworkMgr:isConnected() or MultiSearch.isCached(query, pages, self.box.scope) then
        return true
    end
    NetworkMgr:runWhenConnected(retry)
    return false
end

-- search from the sites' pages of results (see searchFrom), turning on Wi-Fi first if need be (see canSearchNow)
function KindleFetch:searchOnline(query, pages)
    local function search()
        self:searchFrom(query, pages)
    end
    if self:canSearchNow(query, pages, search) then
        search()
    end
end

-- search without holding KOReader up (see HttpUtil), calling off any before, as one search's books show at a time
function KindleFetch:startSearch(query, pages, waiting_text, handlers)
    if self.search then
        self.search:cancel()
    end
    self:closeWaitingMessage()

    local message
    if not MultiSearch.isCached(query, pages, self.box.scope) then
        message = WaitingMessage.new(waiting_text)
        UIManager:show(message)
        -- so that a second tap on what started the search doesn't land on the message
        Device.input:inhibitInputUntil(true)
        UIManager:forceRePaint()
        self.waiting_message = message
    end

    local search
    search = MultiSearch.start(query, pages, self.box.scope, {
        -- e.g. which of Library Genesis' mirrors it's trying, beneath what's being searched for
        on_status = function(status)
            if message and not message.closed and not message.cancelled then
                message:setStatus(status)
            end
        end,
        on_result = function(...)
            if self.search == search then
                -- what goes wrong showing what was found says the search failed, as it would have before
                Guard.call(string.format("showing what was found for %q", query), handlers.on_result, function(err)
                    self:closeWaitingMessage()
                    NotifyUtil.error(T(_("Search failed: %1"), err))
                end, ...)
            end
        end,
        on_done = function()
            if message and not message.closed and not message.cancelled then
                message.closed = true
                UIManager:close(message)
            end
            if self.search == search then
                handlers.on_done()
            end
        end,
    })
    self.search = search
    -- its Cancel calls off every site's search, as each waits with a stand-in of its own (see MultiSearch)
    if message then
        message.dismiss_callback = function()
            search:cancel()
        end
    end
end

-- close the message saying the search is going on, once books have been found, or the search has finished
function KindleFetch:closeWaitingMessage()
    local message = self.waiting_message
    self.waiting_message = nil
    if message and not message.closed and not message.cancelled then
        message.closed = true
        UIManager:close(message)
    end
end

-- change languages, file types or book types with change, searching again in place of the results once changed
function KindleFetch:changeChoices(change)
    local query = self.session.query
    change(SettingsPage, function(changed)
        if not changed then
            return
        end
        LogUtil.info(string.format("searching for %q again with the new choices", query))
        if self.books_menu then
            UIManager:close(self.books_menu)
        end
        self:searchOnline(query, MultiSearch.firstPages(self:sitesToSearch()))
    end)
end

-- where the book downloads to, unless another folder is chosen (see DownloadPrompt)
local function buildDownloadPath(book)
    return Book.path(book, KindleFetchSettings:getDownloadDir())
end

-- show the session's books (see ResultsView), calling off the sites still searching once they're closed
function KindleFetch:showBooks(session)
    local view = ResultsView.new(self, session, function(closed)
        if self.view == closed then
            self.view = nil
            self.books_menu = nil
        end
        if self.search then
            self.search:cancel()
        end
    end)
    -- its menu, as KOReader shows it, and the view, once that's shown
    self.books_menu = view:show()
    self.view = view
end

-- load the next pages (see SearchSession.pagesToLoad), adding books as each site finds them, turning to the first shown
function KindleFetch:loadMoreBooks()
    local session = self.session
    if not session:hasMore() then
        NotifyUtil.message(_("No more books found"))
        return
    end

    local query = session.query
    local pages = session:pagesToLoad()
    if not self:canSearchNow(query, pages, function()
        self:loadMoreBooks()
    end) then
        return
    end

    -- the sites that failed (keeping their page to load again), results read, books found and how many are shown
    local failures, results_read, found, shown = {}, 0, 0, 0
    local first_new_book = #session.books + 1
    self:startSearch(query, pages, _("Loading more books..."), {
        on_result = function(source, books, err, next_page, read)
            if err == HttpUtil.CANCELLED then
                return
            end
            -- (without books, as a search that didn't say why, rather than there being no more)
            if err or not books then
                err = err or "search failed"
                LogUtil.warn(
                    string.format("loading more books from %s for %q failed: %s", Sites[source].NAME, query, err)
                )
                table.insert(failures, { source = source, err = err })
                return
            end
            session.next_pages[source] = next_page
            results_read = results_read + (read or 0)
            if #books == 0 then
                return
            end
            session:addBooks(books)
            self:closeWaitingMessage()
            -- turning to the page the first new books shown are on, not the first, and staying there as more arrive
            local was_shown = shown
            shown = session:countShown(first_new_book)
            if self.view then
                self.view:refresh(was_shown == 0 and shown > 0 and session:countShown() - shown + 1 or nil)
            end
            found = found + #books
        end,
        on_done = function()
            if self.view then
                self.view:finish()
            end
            if #failures > 0 then
                if found == 0 then
                    ErrorFixes.show(
                        describeFailures(
                            _("Loading more books failed: %1"),
                            _("Loading more books failed:\n%1"),
                            failures,
                            #MultiSearch.sourcesOf(pages)
                        ),
                        failures[1].err,
                        function()
                            self:loadMoreBooks()
                        end
                    )
                else
                    self:sayFailed(failures)
                end
                return
            end
            if shown > 0 then
                return
            end
            if found > 0 then
                NotifyUtil.message(
                    T(
                        N_(
                            "1 more book was found, but it isn't among those shown.",
                            "%1 more books were found, but none of them are among those shown.",
                            found
                        ),
                        found
                    )
                )
                return
            end
            if session:hasMore() then
                -- there are more results to look through
                NotifyUtil.message(
                    T(
                        _(
                            "None of the next %1 results are in the languages and file types chosen. Load more to "
                                .. "keep looking."
                        ),
                        results_read
                    )
                )
            else
                NotifyUtil.message(_("No more books found"))
            end
        end,
    })
end

-- close the results and the search box behind them, which would otherwise show again over what's gone to from them
function KindleFetch:closeSearch()
    -- and calls off the sites still being searched, whose books would have nowhere to go
    if self.search then
        self.search:cancel()
    end
    self:closeWaitingMessage()
    if self.books_menu then
        UIManager:close(self.books_menu)
    end
    if self.search_box then
        UIManager:close(self.search_box)
    end
end

function KindleFetch:openBook(filepath)
    -- (which would otherwise show again once the book is closed)
    self:closeSearch()

    -- from the book or file manager open now, not self.ui, as the one the download began from may have closed since
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

-- the file browser's buttons for the book just downloaded, where this KOReader has them, each calling close first
function KindleFetch:bookButtons(filepath, close)
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local ui = require("apps/reader/readerui").instance or require("apps/filemanager/filemanager").instance
    local row = {}
    if not ui then
        return row
    end
    if filemanagerutil.genShowFolderButton then
        table.insert(
            row,
            filemanagerutil.genShowFolderButton(filepath, function()
                close()
                -- which would otherwise hide the folder
                self:closeSearch()
            end)
        )
    end
    if ui.collections and ui.collections.genAddToCollectionButton then
        table.insert(row, ui.collections:genAddToCollectionButton(filepath, close))
    end
    local genBookInformationButton = filemanagerutil.genBookInformationButton
    if genBookInformationButton and ui.bookinfo then
        -- before KOReader v2024.04, it was given close where it's now given the book's details
        if debug.getinfo(genBookInformationButton, "u").nparams < 4 then
            table.insert(row, genBookInformationButton(filepath, close))
        else
            table.insert(row, genBookInformationButton(filepath, nil, close))
        end
    end
    return row
end

function KindleFetch:downloadBook(book)
    -- logging in first, where the site needs it, as a book found before logging out can't be downloaded until then
    local function downloadOnceLoggedIn()
        self:downloadBook(book)
    end
    if self:needsLogin(book.source, downloadOnceLoggedIn) then
        return
    end

    local filepath = buildDownloadPath(book)
    Downloader:downloadBook(book, filepath, function(ok, err, saved_filepath)
        if ok then
            LogUtil.debug("downloaded book to", saved_filepath)
            -- so it's marked as downloaded in the results behind
            if self.session then
                self.session:forgetDownloaded()
            end
            if self.books_menu and not self.books_menu.closed then
                self.books_menu:updateItems()
            end
            -- and listed in the file browser, which didn't show it until it was left and gone back to
            local FileManager = require("apps/filemanager/filemanager")
            if FileManager.instance then
                FileManager.instance:onRefresh()
            end
            -- ask on the next tick, once the download progress has closed
            Guard.nextTick("offering to read the downloaded book", function()
                -- centred, with the title in bold on a line of its own, so it stands out from the question
                local dialog
                local function close()
                    UIManager:close(dialog)
                end
                local buttons = {
                    {
                        -- as the book has downloaded, and nothing is called off
                        { text = _("Not now"), id = "close", callback = close },
                        {
                            text = _("Read now"),
                            id = "read",
                            callback = function()
                                close()
                                self:openBook(saved_filepath)
                            end,
                        },
                    },
                }
                -- and beneath them, what KOReader's file browser has for it (none, where it's too old to have them)
                local book_buttons = self:bookButtons(saved_filepath, close)
                if #book_buttons > 0 then
                    table.insert(buttons, book_buttons)
                end
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
                    buttons = buttons,
                }
                UIManager:show(dialog)
            end)
        elseif err == Errors.CANCELLED then
            LogUtil.debug("download cancelled", book.title)
            NotifyUtil.info(_("Download cancelled"))
        else
            LogUtil.warn("download failed for", book.title, err)
            -- offering what fixes it, then downloading it again (see ErrorFixes)
            ErrorFixes.show(err and T(_("Download failed: %1"), err) or _("Download failed"), err, function()
                self:downloadBook(book)
            end)
        end
    end, function(existing_filepath)
        -- the book is already there, and was chosen to be read rather than downloaded again
        self:openBook(existing_filepath)
    end)
end

return KindleFetch
