local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local KindleFetchSettings = require("settings.settings")
local SettingsPage = require("settings.settingspage")
local Diagnostics = require("ui.diagnostics")
local util = require("util")
local NetworkMgr = require("ui/network/manager")
local StringUtil = require("util.stringutil")
local Sources = require("api.sources")
local MultiSearch = require("api.multisearch")
local Downloader = require("api.downloader")
local HttpUtil = require("util.httputil")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local BookMenu = require("ui.bookmenu")
local BookFilter = require("ui.bookfilter")
local Menu = require("ui/widget/menu")
local WaitingMessage = require("ui.waitingmessage")
local ZlibLogin = require("ui.zliblogin")
local ZlibAccount = require("api.zlibaccount")
local SearchCache = require("cache.searchcache")
local UrlCache = require("cache.urlcache")
local CurlUpdater = require("updater.curlupdater")
local CurlUtil = require("util.curlutil")
local PluginUpdater = require("updater.pluginupdater")
local FileUtil = require("util.fileutil")
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
-- the sites, in the order Kindle Fetch's menu lists them
-- the most of what's highlighted in a book that's searched for (see searchFor), as a whole paragraph can't be
local MAX_QUERY_LENGTH = 100
-- the plugin made for whichever of the file manager or a book was opened last, which what's added to KOReader's own
-- dialogs once a session searches with (see addFileDialogButtons)
local latest
local file_dialog_buttons_added = false

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
-- (the search box, for the sites ticked in it last, or for one site, from the gestures for each there were before)
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

-- the first of a book's authors, from what's known of it (as KOReader lists them, on lines of their own), or nil
-- where nothing is
local function firstAuthor(props)
    local authors = type(props) == "table" and props.authors
    local author = type(authors) == "string" and StringUtil.trim(authors:match("^[^\n]*")) or ""
    return author ~= "" and author or nil
end

-- add More by this author to the dialog KOReader shows on holding a book (in the file browser, history, collections
-- and file search), where this KOReader lets plugins add to them, once a session, as they're KOReader's own
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
                -- the sites ticked in it (see chooseSites)
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
                -- what to copy or save for whoever's helping with a problem, and a test of the connection to the
                -- sites
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
local function needsLogin(source, on_logged_in)
    if not (Sources[source] and Sources[source].NEEDS_LOGIN) or ZlibAccount:isLoggedIn() then
        return false
    end
    LogUtil.info("logging in to", Sources[source].NAME, "before searching it")
    ZlibLogin.show(on_logged_in)
    return true
end

-- the name of what a search can be narrowed to (see SCOPES in Sources), or of searching all a site does
local function scopeName(scope)
    return ({ title = _("Title"), author = _("Author"), isbn = _("ISBN") })[scope] or _("All")
end

-- whether source is among the sites in sources
local function isTicked(sources, source)
    for __, ticked in ipairs(sources) do
        if ticked == source then
            return true
        end
    end
    return false
end

-- whether the site can be searched now: one that needs an account (Z-Library) only once logged into, and it's left
-- out of the search otherwise, though ticked, rather than asking to log in to it for every search
local function canSearch(source)
    return not Sources[source].NEEDS_LOGIN or ZlibAccount:isLoggedIn()
end

-- the sites' names, as they're said together, e.g. "Library Genesis and Internet Archive"
local function sitesName(sources)
    local names = {}
    for __, source in ipairs(sources) do
        table.insert(names, Sources[source].NAME)
    end
    if #names <= 1 then
        return names[1] or ""
    end
    local last = table.remove(names)
    return T(_("%1 and %2"), table.concat(names, ", "), last)
end

-- the sites in pages (see MultiSearch.start), in the order they're offered
local function sourcesOf(pages)
    local sources = {}
    for __, source in ipairs(MultiSearch.SOURCES) do
        if pages[source] then
            table.insert(sources, source)
        end
    end
    return sources
end

-- the first page of each site's results, to search from (see MultiSearch.start)
local function firstPages(sources)
    local pages = {}
    for __, source in ipairs(sources) do
        pages[source] = 1
    end
    return pages
end

-- what the search box's Sites button says: the sites ticked, or that they all are, or all but one, which is shorter
local function sitesText(sources)
    if #sources == #MultiSearch.SOURCES then
        return _("Sites: All")
    end
    if #sources == #MultiSearch.SOURCES - 1 and #sources > 1 then
        for __, source in ipairs(MultiSearch.SOURCES) do
            if not isTicked(sources, source) then
                return T(_("Sites: All but %1"), Sources[source].NAME)
            end
        end
    end
    return T(_("Sites: %1"), sitesName(sources))
end

-- say what went wrong for each site that failed (failures, each its source and err) in one (e.g. "Search failed: %1"),
-- with the error alone, where only the one site was searched, otherwise several (e.g. "Search failed:\n%1"), with each
-- site's name and error on a line of their own
local function describeFailures(one, several, failures, sites_searched)
    if sites_searched == 1 then
        return T(one, failures[1].err)
    end
    local lines = {}
    for __, failure in ipairs(failures) do
        table.insert(lines, T(_("%1: %2"), Sources[failure.source].NAME, failure.err))
    end
    return T(several, table.concat(lines, "\n"))
end

-- the sites ticked in the search box that can be searched now (see canSearch), in the order they're offered
function KindleFetch:sitesToSearch()
    local sources = {}
    for __, source in ipairs(self.sources) do
        if canSearch(source) then
            table.insert(sources, source)
        end
    end
    return sources
end

-- what the search box's Sites button says: the sites it searches, or those ticked, where none of them can be searched
-- yet (as when Z-Library is the only one, and isn't logged into)
function KindleFetch:sitesButtonText()
    local sources = self:sitesToSearch()
    return sitesText(#sources > 0 and sources or self.sources)
end

-- open the search box, for searching the sites ticked in it: sources, where given (e.g. the site a gesture is for),
-- otherwise those ticked last (see KindleFetchSettings:getSearchSources). with query in it, where given, narrowed down
-- to scope (e.g. only the books' authors, see SCOPES in Sources) where given, on the sites that can be, and searching
-- straight away when search_now is set, e.g. another site for what one found nothing for (see otherSites)
function KindleFetch:setupUI(query, scope, sources, search_now)
    -- grab self reference for callbacks
    local this = self
    local chosen = sources or KindleFetchSettings:getSearchSources()
    self.sources = {}
    for __, source in ipairs(MultiSearch.SOURCES) do
        if isTicked(chosen, source) then
            table.insert(self.sources, source)
        end
    end
    if #self.sources == 0 then
        self.sources = { MultiSearch.SOURCES[1] }
    end
    self.scope = scope

    local buttons = {
        -- which sites to search (see chooseSites)
        {
            {
                text = self:sitesButtonText(),
                id = "sites",
                callback = function()
                    this:chooseSites()
                end,
            },
        },
        -- what the search is narrowed down to, on the sites that can be (see chooseScope)
        {
            {
                text = T(_("Search in: %1"), scopeName(self.scope)),
                id = "scope",
                callback = function()
                    this:chooseScope()
                end,
            },
        },
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
    }
    self.search_box = InputDialog:new {
        title = _("Search for books"),
        input = query,
        input_type = "text",
        buttons = buttons,
    }
    UIManager:show(self.search_box)
    if query and search_now then
        self:performSearch()
    end
end

-- tick or untick which sites the search box searches, which it searches from then on (see
-- KindleFetchSettings:getSearchSources). Z-Library shows as ticked only once logged into, as it can only be searched
-- with an account (see canSearch), and is logged into on ticking it, and at least one site stays ticked
function KindleFetch:chooseSites()
    local this = self
    local dialog
    local function shownTicked(source)
        return isTicked(this.sources, source) and canSearch(source)
    end
    local function label(source)
        local text = (shownTicked(source) and "✓ " or "") .. Sources[source].NAME
        if not canSearch(source) then
            return T(_("%1 (log in)"), text)
        end
        return text
    end
    local function tick(source, ticked)
        local sources = {}
        for __, site in ipairs(MultiSearch.SOURCES) do
            if site == source and ticked or site ~= source and isTicked(this.sources, site) then
                table.insert(sources, site)
            end
        end
        this.sources = sources
        LogUtil.info("searching", table.concat(sources, ", "), "from now on")
        local saved, err = KindleFetchSettings:setSearchSources(sources)
        if not saved then
            NotifyUtil.error(err)
        end
        local sites_button = this.search_box and this.search_box.button_table:getButtonById("sites")
        if sites_button then
            sites_button:setText(this:sitesButtonText(), sites_button.width)
            UIManager:setDirty(this.search_box, "ui")
        end
    end

    local rows = {}
    for __, source in ipairs(MultiSearch.SOURCES) do
        table.insert(rows, {
            {
                text = label(source),
                id = source,
                callback = function()
                    local ticked = shownTicked(source)
                    if ticked and #this:sitesToSearch() == 1 then
                        NotifyUtil.info(_("Choose at least one site to search"))
                        return
                    end
                    if
                        not ticked
                        and needsLogin(source, function()
                            tick(source, true)
                        end)
                    then
                        UIManager:close(dialog)
                        return
                    end
                    tick(source, not ticked)
                    local button = dialog.buttontable:getButtonById(source)
                    button:setText(label(source), button.width)
                    UIManager:setDirty(dialog, "ui")
                end,
            },
        })
    end
    dialog = ButtonDialog:new {
        title = _("Search on"),
        title_align = "center",
        buttons = rows,
    }
    UIManager:show(dialog)
end

-- choose what the search is narrowed down to (see SCOPES in Sources), e.g. only the books' authors, or all a site
-- searches, for the search box that's open: whatever any site can be narrowed down to, as those that can't search
-- everything
function KindleFetch:chooseScope()
    local this = self
    local dialog
    local row = {}
    local scopes, offered = { false }, {}
    for __, source in ipairs(MultiSearch.SOURCES) do
        for __, scope in ipairs(Sources[source].SCOPES or {}) do
            if not offered[scope] then
                offered[scope] = true
                table.insert(scopes, scope)
            end
        end
    end
    for __, scope in ipairs(scopes) do
        scope = scope or nil
        table.insert(row, {
            text = (scope == this.scope and "✓ " or "") .. scopeName(scope),
            callback = function()
                UIManager:close(dialog)
                this.scope = scope
                LogUtil.info("searching", scope and "by " .. scope or "all", "from now on")
                local scope_button = this.search_box.button_table:getButtonById("scope")
                scope_button:setText(T(_("Search in: %1"), scopeName(scope)), scope_button.width)
                UIManager:setDirty(this.search_box, "ui")
            end,
        })
    end
    dialog = ButtonDialog:new {
        title = _("Search in"),
        title_align = "center",
        buttons = { row },
    }
    UIManager:show(dialog)
end

-- add Search Kindle Fetch to the dialog KOReader shows on highlighting text in a book, to search for it (see
-- searchFor), second to last, as KOReader's own plugins add theirs, so its own Search stays last
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

-- open the search box with query in it, e.g. more by a book's author, or what's highlighted in one, to search the sites
-- ticked in it for: on one line, and only the start of it when it's long (see MAX_QUERY_LENGTH). narrowed down to scope
-- (e.g. the books' authors), where given and the sites can be (see setupUI)
function KindleFetch:searchFor(query, scope)
    query = StringUtil.trim(query or ""):gsub("%s+", " ")
    if #query > MAX_QUERY_LENGTH then
        -- at a space, or otherwise between characters, rather than partway through one (whose next byte would carry
        -- on from it)
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

-- buttons for searching the sites that weren't searched for query, from what says those that were found nothing or
-- failed: Z-Library only once logged in, as it can only be searched with an account. each closes the search box and
-- results for these
function KindleFetch:otherSites(query)
    local buttons = {}
    local searched = self:sitesToSearch()
    for __, source in ipairs(MultiSearch.SOURCES) do
        if not isTicked(searched, source) and canSearch(source) then
            table.insert(buttons, {
                text = T(_("Search %1"), Sources[source].NAME),
                callback = function()
                    -- once what it's in has closed
                    Guard.nextTick("searching another site", function()
                        LogUtil.info(string.format("searching %s for %q instead", Sources[source].NAME, query))
                        local scope = self.scope
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

    -- nothing can be found with every language, file type or book type (where a site ticked has them) turned off.
    -- said like the other things the search box needs first, each in a sentence of its own, to be translated whole
    local sources = self:sitesToSearch()
    local has_book_types = false
    for __, source in ipairs(sources) do
        has_book_types = has_book_types or Sources[source].HAS_BOOK_TYPES == true
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

    -- where the only sites ticked can't be searched until they're logged into, e.g. once Z-Library has logged Kindle
    -- Fetch out (see ZlibAccount:request)
    local function searchOnceLoggedIn()
        self:performSearch()
    end
    if #sources == 0 then
        for __, source in ipairs(self.sources) do
            if needsLogin(source, searchOnceLoggedIn) then
                return
            end
        end
    end

    local pages = firstPages(sources)
    if not self:canSearchNow(query, pages, function()
        self:performSearch()
    end) then
        return
    end

    LogUtil.debug("starting search for", query)
    self:searchFrom(query, pages)
end

-- search the sites in pages from those pages of their results (see MultiSearch.start), showing the books as soon as any
-- site has found some, and adding each other site's as it finds them. once they've all finished without any, says why:
-- what went wrong, or that none were found (see explainFailure and explainNoBooks)
function KindleFetch:searchFrom(query, pages)
    self.current_search_query = query
    self.books = nil
    self.next_pages = {}
    local sources = sourcesOf(pages)
    -- whose books are each shown with the site they were found on
    self.several_sites = #sources > 1
    -- what went wrong for the sites that failed, before any books were showing to say so over, how many results the
    -- others read to find none, the sites that have none of the file types chosen, and whether it was called off
    local failures, results_read, no_file_types = {}, 0, {}
    local read_any, called_off = false, false
    -- saying what's being searched for, as the search box is behind it, on a line of its own, so the message covers
    -- the search box's own buttons however short the search
    local waiting_text = T(_("Searching %1 for\n“%2”..."), sitesName(sources), query)
    self:startSearch(query, pages, waiting_text, {
        on_result = function(source, books, err, next_page, read)
            local name = Sources[source].NAME
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
                if self.books then
                    self:sayFailed(failures)
                end
                return
            end
            read_any = true
            results_read = results_read + (read or 0)
            self.next_pages[source] = next_page
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
            self:addBooks(books)
            self:sayFailed(failures)
        end,
        on_done = function()
            if self.books then
                self:finishBooks()
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
            self:explainNoBooks(query, sources, results_read, self.next_pages)
        end,
    })
end

-- say over the books found which sites failed, and why, as each is found to have, emptying failures once it has
function KindleFetch:sayFailed(failures)
    for __, failure in ipairs(failures) do
        NotifyUtil.error(T(_("Searching %1 failed: %2"), Sources[failure.source].NAME, failure.err))
    end
    for i = #failures, 1, -1 do
        failures[i] = nil
    end
end

-- add the books a site has found to those found so far, showing them once they're the first
function KindleFetch:addBooks(books)
    local first = self.books == nil
    self.books = self.books or {}
    for __, book in ipairs(books) do
        table.insert(self.books, book)
    end
    if first then
        self:closeWaitingMessage()
        self:rememberSearch(self.current_search_query)
        self:showBooks(self.books)
    else
        self:refreshBooks()
    end
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

-- buttons for what fixes err, where something does, which call retry, where given, once it has: logging in to
-- Z-Library again, updating a Kindle's curl, looking the sites up with encrypted DNS where the network can't find
-- them, or turning Wi-Fi on (or, where it's on, trying again, as the internet may only have dropped for a moment)
function KindleFetch:fixes(err, retry)
    if err == Errors.LOGGED_OUT then
        return {
            {
                text = _("Log in"),
                callback = function()
                    ZlibLogin.show(retry)
                end,
            },
        }
    elseif err == Errors.OUTDATED_CURL then
        return {
            {
                text = _("Update curl"),
                callback = function()
                    CurlUpdater.checkVersion(true)
                end,
            },
        }
    elseif
        (err == Errors.UNFOUND or err == Errors.ZLIB_UNFOUND)
        and not KindleFetchSettings:getEncryptedDns()
        and CurlUtil.canUseEncryptedDns()
    then
        -- the network's own DNS may be what's blocking them (#55)
        return {
            {
                text = _("Use encrypted DNS"),
                callback = function()
                    local ok, save_err = KindleFetchSettings:setEncryptedDns(true)
                    if not ok then
                        NotifyUtil.error(save_err)
                        return
                    end
                    LogUtil.info("turned encrypted DNS on, as the network couldn't find the sites")
                    if retry then
                        retry()
                    end
                end,
            },
        }
    elseif err == Errors.NO_CONNECTION and retry then
        if not NetworkMgr:isWifiOn() then
            return {
                {
                    text = _("Turn on Wi-Fi"),
                    callback = function()
                        NetworkMgr:runWhenConnected(retry)
                    end,
                },
            }
        end
        return { { text = _("Try again"), callback = retry } }
    end
    return {}
end

-- say something failed (text, which err is why), offering what fixes it (see fixes, which call retry once it has) and
-- the rows of buttons in other_rows, that have any, in a message that stays until closed, or as an error, where
-- there's nothing to offer
function KindleFetch:showFailure(text, err, retry, other_rows)
    local rows = {}
    local fixes = self:fixes(err, retry)
    if #fixes > 0 then
        table.insert(rows, fixes)
    end
    for __, row in ipairs(other_rows or {}) do
        if #row > 0 then
            table.insert(rows, row)
        end
    end
    if #rows == 0 then
        NotifyUtil.error(text)
        return
    end
    UIManager:show(ConfirmBox:new {
        text = text,
        icon = "notice-warning",
        no_ok_button = true,
        cancel_text = _("Close"),
        other_buttons = rows,
    })
end

-- say the search failed, and why, for each site that did (failures, see describeFailures), offering what fixes it (see
-- fixes, the first that something does, as it's the same for each site, e.g. turning Wi-Fi on), and to search the
-- other sites instead (see otherSites), unless the device isn't connected, which they'd fail for too
function KindleFetch:explainFailure(query, pages, failures)
    local err = failures[1].err
    for __, failure in ipairs(failures) do
        if #self:fixes(failure.err, function() end) > 0 then
            err = failure.err
            break
        end
    end
    local text = describeFailures(_("Search failed: %1"), _("Search failed:\n%1"), failures, #sourcesOf(pages))
    self:showFailure(text, err, function()
        self:searchOnline(query, pages)
    end, { err ~= Errors.NO_CONNECTION and self:otherSites(query) or {} })
end

-- say that the sites (sources) found no books, and why when it's known: they may have listed plenty (results_read), all
-- in other languages or file types than those chosen in the settings, or have none of the file types chosen at all
-- (results_read nil). offers to keep searching the sites in next_pages (see MultiSearch.start), where there are more
-- results to look through, and the other sites (see otherSites)
function KindleFetch:explainNoBooks(query, sources, results_read, next_pages)
    local name = sitesName(sources)
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

-- whether the sites' pages of results (see MultiSearch.start) can be searched for now: once connected, or when they're
-- all saved from an earlier search. otherwise Wi-Fi is turned on (as KOReader is set up to), and retry is called once
-- it's connected
function KindleFetch:canSearchNow(query, pages, retry)
    if NetworkMgr:isConnected() or MultiSearch.isCached(query, pages, self.scope) then
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

-- search the sites in pages (see MultiSearch.start) without holding up the rest of KOReader while they answer, where
-- that's possible (see HttpUtil), saying waiting_text until the first books have been found or they've all finished,
-- with a Cancel that calls them all off, unless the pages are all saved from an earlier search, and are there straight
-- away. handlers.on_result and on_done are called as MultiSearch's are, for this search only: one still going from
-- before (e.g. loading more) is called off first, as only one search's books are shown at a time
function KindleFetch:startSearch(query, pages, waiting_text, handlers)
    if self.search then
        self.search:cancel()
    end
    self:closeWaitingMessage()

    local message
    if not MultiSearch.isCached(query, pages, self.scope) then
        message = WaitingMessage.new(waiting_text)
        UIManager:show(message)
        -- so that a second tap on what started the search doesn't land on the message
        Device.input:inhibitInputUntil(true)
        UIManager:forceRePaint()
        self.waiting_message = message
    end

    local search
    search = MultiSearch.start(query, pages, self.scope, {
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

-- whether the results show the books' covers: when they're turned on, and KOReader's menu can lay them out (see
-- BookMenu.isSupported)
local function coversShown()
    return BookMenu.isSupported() and KindleFetchSettings:getShowBookCovers()
end

-- a book's title, authors and file type, which the results are looked through for (see filterBooks), as is each
-- entry's text by KOReader's own Go to letter, which KOReader exited on for an entry without text
local function bookText(book)
    return StringUtil.joinDetails(
        book.display_title or book.title,
        book.authors,
        book.file_type and book.file_type:upper()
    )
end

-- the book's entry's text in the results: its title, authors and file type (see bookText), and the site it was found
-- on, where several were searched
function KindleFetch:bookItemText(book)
    local text = bookText(book)
    if self.several_sites and Sources[book.source] then
        text = StringUtil.joinDetails(text, Sources[book.source].NAME)
    end
    return text
end

-- whether the results show the book: when it has the text looked for in it (see filterBooks), where they're being
-- looked through, and none of the sites, languages and so on unticked is all it has (see chooseShown)
function KindleFetch:isShown(book)
    local filter = self.filter and util.stringLower(self.filter)
    if filter and not util.stringLower(self:bookItemText(book)):find(filter, 1, true) then
        return false
    end
    return BookFilter.isShown(book, self.hidden or {}, function(b)
        return self:isDownloaded(b)
    end)
end

-- whether only some of the books found are shown (see isShown)
function KindleFetch:isFiltering()
    return self.filter ~= nil or BookFilter.isHiding(self.hidden or {})
end

-- how many of the books found are shown (see isShown), from the from'th on, where given
function KindleFetch:countShown(from)
    local count = 0
    local books = self.books or {}
    for i = from or 1, #books do
        if self:isShown(books[i]) then
            count = count + 1
        end
    end
    return count
end

-- the books shown (see isShown) as entries for the menu of results, followed by a way to load more when there are
-- more to load
function KindleFetch:bookMenuItems(books)
    local this = self
    local menu_items = {}

    for __, book in ipairs(books) do
        if self:isShown(book) then
            table.insert(menu_items, {
                book = book,
                text = self:bookItemText(book),
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

    -- the sites still being searched, whose books are added once they've found them (see searchFrom), or a way to
    -- load more, where there's more, whose books are shown as the others are (see isShown)
    if self.search and not self.search:isDone() then
        table.insert(menu_items, {
            still_searching = true,
            text = T(_("Still searching %1…"), sitesName(self.search:pendingSources())),
            callback = function()
                NotifyUtil.info(
                    T(_("The books %1 finds are added here once it has."), sitesName(this.search:pendingSources()))
                )
            end,
        })
    elseif self:hasMore() then
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
-- are shown, where only some are (see isShown)
function KindleFetch:booksTitle()
    local count = #self.books
    if self:isFiltering() then
        return T(_("%1 · %2 of %3 books"), self.current_search_query, self:countShown(), count)
    end
    -- there may be more to load, or still to come
    local more = self:hasMore() or self.search and not self.search:isDone()
    local found = more and T(_("%1+ books"), count) or T(N_("1 book", "%1 books", count), count)
    return string.format("%s · %s", self.current_search_query, found)
end

-- the next page of each site's results that has more, to load (see loadMoreBooks), but for the sites whose books are
-- hidden (see chooseShown)
function KindleFetch:pagesToLoad()
    local pages = {}
    local hidden_sites = self.hidden and self.hidden.site or {}
    for source, page in pairs(self.next_pages or {}) do
        if not hidden_sites[source] then
            pages[source] = page
        end
    end
    return pages
end

-- whether any site whose books are shown has more results to load (see pagesToLoad)
function KindleFetch:hasMore()
    return next(self:pagesToLoad()) ~= nil
end

-- list the books found again, as more have been, staying on the page that's showing, or turning to the one with the
-- itemnumber'th book, where given, and loading the covers of the books on it
function KindleFetch:refreshBooks(itemnumber)
    local menu = self.books_menu
    if not menu then
        return
    end
    menu:switchItemTable(self:booksTitle(), self:bookMenuItems(self.books), itemnumber or -1)
    if coversShown() then
        LogUtil.debug("loading covers for page", menu.page)
        menu:loadCoversForPage(menu.page)
    end
end

-- once every site has finished, end the list with Load more where there's more, in place of the sites that were still
-- being searched, or without it where there's no more, staying on the page that's showing. the list is left as it is
-- where its end hasn't changed, as listing the books again would load the covers showing again
function KindleFetch:finishBooks()
    local menu = self.books_menu
    if not menu then
        return
    end
    local items, shown = self:bookMenuItems(self.books), menu.item_table
    local last, was = items[#items], shown[#shown]
    if #items ~= #shown or (last and last.text) ~= (was and was.text) then
        menu:switchItemTable(self:booksTitle(), items, -1)
    end
end

-- list the books shown again, from the first, once what's shown has changed (see isShown), loading their covers
function KindleFetch:showFromFirst()
    local menu = self.books_menu
    if not menu then
        return
    end
    menu:switchItemTable(self:booksTitle(), self:bookMenuItems(self.books), 1)
    if coversShown() then
        menu:loadCoversForPage(1)
    end
end

-- show only the books found with text in their title, authors or file type, whatever its capitals, among those
-- shown (see isShown), without searching again, or all of them again when there's no text. the books shown stay as
-- they are when none of them have it
function KindleFetch:filterBooks(text)
    text = StringUtil.trim(text)
    local previous = self.filter
    self.filter = text ~= "" and text or nil

    local shown = self:countShown()
    if shown == 0 then
        local hiding = BookFilter.isHiding(self.hidden or {})
        self.filter = previous
        NotifyUtil.message(
            hiding and T(_("None of the books shown have “%1” in them."), text)
                or T(_("None of the books found have “%1” in them."), text)
        )
        return
    end
    LogUtil.info(string.format("showing %d of the %d books found, looking for %q", shown, #self.books, text))
    self:showFromFirst()
end

-- tick and untick the values the books found have for filter (see BookFilter.FILTERS), e.g. the sites they were found
-- on, to show only the books with those ticked, without searching again (see isShown). each value is listed with how
-- many of the books have it, and what would hide every book isn't taken
function KindleFetch:chooseShown(filter)
    local values = BookFilter.values(self.books, filter, function(book)
        return self:isDownloaded(book)
    end)
    local hidden = self.hidden[filter.id] or {}
    local choices, ticked = {}, {}
    for __, value in ipairs(values) do
        table.insert(choices, { text = T(_("%1 (%2)"), value.text, value.count), code = value.code })
        if not hidden[value.code] then
            table.insert(ticked, value.code)
        end
    end
    SettingsPage:tickSeveral(
        filter.name,
        choices,
        ticked,
        function(shown)
            local before = self.hidden[filter.id]
            self.hidden[filter.id] = BookFilter.hiding(values, shown)
            if self:countShown() == 0 then
                self.hidden[filter.id] = before
                NotifyUtil.info(_("That would hide every book found."))
                return false
            end
        end,
        _("That would hide every book found."),
        function(changed)
            -- (rather than going back to the first page, where nothing has)
            if changed then
                LogUtil.info(
                    string.format("showing %d of the %d books found, by %s", self:countShown(), #self.books, filter.id)
                )
                self:showFromFirst()
            end
        end
    )
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

-- what can be done with the books found, from the menu at the top left of the results: looking through them for text,
-- showing only those from some of the sites, languages and so on they're from (see chooseShown, each offered where
-- the books found don't all have the same), showing all of them again, and searching again (see searchAgain)
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
    self.hidden = self.hidden or {}
    for __, filter in ipairs(BookFilter.FILTERS) do
        -- (whether each book has been downloaded is only looked up once it's asked for, see BookFilter.values)
        local values = filter.fixed or BookFilter.values(self.books, filter)
        if BookFilter.isOffered(filter, values) then
            table.insert(buttons, {
                {
                    text = T(_("%1: %2"), filter.name, BookFilter.describe(values, self.hidden[filter.id])),
                    callback = function()
                        UIManager:close(dialog)
                        this:chooseShown(filter)
                    end,
                },
            })
        end
    end
    if self:isFiltering() then
        table.insert(buttons, {
            {
                text = T(_("Show all %1 books"), #self.books),
                callback = function()
                    UIManager:close(dialog)
                    this.filter = nil
                    this.hidden = {}
                    this:showFromFirst()
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Search again…"),
            callback = function()
                UIManager:close(dialog)
                this:searchAgain()
            end,
        },
    })
    dialog = ButtonDialog:new {
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- change which languages, file types or book types the books found can be in, in the settings (see changeChoices),
-- searching again with them, from the results
function KindleFetch:searchAgain()
    local this = self
    local dialog
    -- narrowing the search down, or widening it, searching again (see changeChoices)
    local changes = {
        { text = _("Languages…"), change = SettingsPage.changeLanguages },
        { text = _("File types…"), change = SettingsPage.changeFileTypes },
    }
    for __, source in ipairs(self:sitesToSearch()) do
        if Sources[source].HAS_BOOK_TYPES then
            table.insert(changes, { text = _("Book types…"), change = SettingsPage.changeBookTypes })
            break
        end
    end
    local row = {}
    for __, choice in ipairs(changes) do
        table.insert(row, {
            text = choice.text,
            callback = function()
                UIManager:close(dialog)
                this:changeChoices(choice.change)
            end,
        })
    end
    dialog = ButtonDialog:new {
        title = _("Change the settings, and search again:"),
        buttons = { row },
    }
    UIManager:show(dialog)
end

-- change which languages, file types or book types the books found can be in, from the results, with change (e.g.
-- SettingsPage.changeLanguages), searching again in place of the results once they've changed
function KindleFetch:changeChoices(change)
    local query = self.current_search_query
    change(SettingsPage, function(changed)
        if not changed then
            return
        end
        LogUtil.info(string.format("searching for %q again with the new choices", query))
        if self.books_menu then
            UIManager:close(self.books_menu)
        end
        self:searchOnline(query, firstPages(self:sitesToSearch()))
    end)
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
    -- what's shown of them (see isShown), afresh for each search
    self.filter = nil
    self.hidden = {}

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
        -- and which site each was found on, where several were searched
        source_name = self.several_sites and function(book)
            return Sources[book.source] and Sources[book.source].NAME
        end or nil,
        -- once it's closed, as with its X, the sites still being searched are called off, as their books would have
        -- nowhere to go, and saying they failed would come out of nowhere
        close_callback = function()
            if this.books_menu == menu then
                this.books_menu = nil
            end
            if this.search then
                this.search:cancel()
            end
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

-- load the next page of each site's results that has more, but for the sites whose books are hidden (see
-- pagesToLoad), adding the books to the list as each site finds them, turning to the first of them that's shown
function KindleFetch:loadMoreBooks()
    if not self:hasMore() then
        NotifyUtil.message(_("No more books found"))
        return
    end

    local query = self.current_search_query
    local pages = self:pagesToLoad()
    if not self:canSearchNow(query, pages, function()
        self:loadMoreBooks()
    end) then
        return
    end

    -- the sites that failed, which keep their page to load more from again, how many results the others read, and
    -- how many books they found, and how many of those are shown
    local failures, results_read, found, shown = {}, 0, 0, 0
    local first_new_book = #self.books + 1
    self:startSearch(query, pages, _("Loading more books..."), {
        on_result = function(source, books, err, next_page, read)
            if err == HttpUtil.CANCELLED then
                return
            end
            -- (without books, as a search that didn't say why, rather than there being no more)
            if err or not books then
                err = err or "search failed"
                LogUtil.warn(
                    string.format("loading more books from %s for %q failed: %s", Sources[source].NAME, query, err)
                )
                table.insert(failures, { source = source, err = err })
                return
            end
            self.next_pages[source] = next_page
            results_read = results_read + (read or 0)
            if #books == 0 then
                return
            end
            for __, book in ipairs(books) do
                table.insert(self.books, book)
            end
            self:closeWaitingMessage()
            -- turning to the page the first new books shown start on (the one that was showing), rather than going
            -- back to the first, and staying there as more arrive
            local was_shown = shown
            shown = self:countShown(first_new_book)
            self:refreshBooks(was_shown == 0 and shown > 0 and self:countShown() - shown + 1 or nil)
            found = found + #books
        end,
        on_done = function()
            self:finishBooks()
            if #failures > 0 then
                if found == 0 then
                    self:showFailure(
                        describeFailures(
                            _("Loading more books failed: %1"),
                            _("Loading more books failed:\n%1"),
                            failures,
                            #sourcesOf(pages)
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
            if self:hasMore() then
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

-- the buttons KOReader's file browser has for a book, for the one just downloaded, where this KOReader has them:
-- showing its folder, adding it to collections, and its information, each closing the dialog they're in with close
-- first. they go to whichever of a book or the file manager is open by then, as KOReader's own do
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
    -- logging in first, where the site needs that, as a book found before logging out can't be downloaded until then,
    -- rather than its link being looked up only for Z-Library to say so
    local function downloadOnceLoggedIn()
        self:downloadBook(book)
    end
    if needsLogin(book.source, downloadOnceLoggedIn) then
        return
    end

    local filepath = buildDownloadPath(book)
    Downloader:downloadBook(book, filepath, function(ok, err, saved_filepath)
        if ok then
            LogUtil.debug("downloaded book to", saved_filepath)
            -- so it's marked as downloaded in the results behind
            self.downloaded = nil
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
            -- offering what fixes it, then downloading it again (see fixes)
            self:showFailure(err and T(_("Download failed: %1"), err) or _("Download failed"), err, function()
                self:downloadBook(book)
            end)
        end
    end, function(existing_filepath)
        -- the book is already there, and was chosen to be read rather than downloaded again
        self:openBook(existing_filepath)
    end)
end

return KindleFetch
