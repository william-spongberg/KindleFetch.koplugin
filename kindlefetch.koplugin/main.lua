local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local KindleFetchSettings = require("settings.settings")
local SettingsPage = require("settings.settingspage")
local util = require("util")
local NetworkMgr = require("ui/network/manager")
local StringUtil = require("util.stringutil")
local LlgiSearch = require("api.lglisearch")
local LlgiAPI = require("api.lgliapi")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local BookMenu = require("ui.bookmenu")
local SearchCache = require("cache.searchcache")
local UrlCache = require("cache.urlcache")
local CurlUpdater = require("updater.curlupdater")
local PluginUpdater = require("updater.pluginupdater")
local FileUtil = require("util.fileutil")
local PathUtil = require("util.pathutil")
local _ = require("gettext")

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
end

-- cancel downloads when KOReader exits or restarts, so curl isn't left running and partial books are removed
-- (without returning true, so the event still reaches the rest of KOReader)
function KindleFetch:onExit()
    LogUtil.debug("cancelling downloads before exiting")
    LlgiAPI:cancelAllDownloads()
end
KindleFetch.onRestart = KindleFetch.onExit

-- sent by the dispatcher action, e.g. when a gesture is assigned to it
function KindleFetch:onKindleFetch()
    self:setupUI()
    return true
end

function KindleFetch:init()
    -- load settings
    KindleFetchSettings:load()

    if not version_checked then
        version_checked = true
        logEnvironment()
        clearCachesAfterUpdate()
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
        UIManager:scheduleIn(0.1, function()
            -- check curl is at min version
            CurlUpdater.checkVersion()
            -- check for updates
            PluginUpdater.checkForUpdates(false)
        end)
    end
end

function KindleFetch:checkForUpdates()
    NetworkMgr:runWhenConnected(function()
        NotifyUtil.info("Checking for updates...")
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
                text = _("Search Library Genesis"),
                callback = function()
                    self:setupUI()
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
end

function KindleFetch:setupUI()
    -- grab self reference for callbacks
    local this = self

    self.search_box = InputDialog:new {
        title = "Search Library Genesis",
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
                    text = "Search",
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
        NotifyUtil.info("Enter a search term first")
        return
    end

    -- nothing can be found with every language, file type or book type turned off
    local turned_off = #KindleFetchSettings:getPreferredLanguages() == 0 and _("language")
        or #KindleFetchSettings:getPreferredFileTypes() == 0 and _("file type")
        or #KindleFetchSettings:getPreferredBookTypes() == 0 and _("book type")
    if turned_off then
        LogUtil.warn("every", turned_off, "is turned off, so there's nothing to search for")
        NotifyUtil.info(string.format(_("Error: turn on at least one %s in Kindle Fetch's settings"), turned_off))
        return
    end

    -- check device is online, otherwise turn on wifi (as set up in KOReader's network settings) and search once
    -- connected,
    -- unless the results are saved from an earlier search
    if not NetworkMgr:isConnected() and not LlgiSearch:isCached(query, 1) then
        NetworkMgr:runWhenConnected(function()
            self:performSearch()
        end)
        return
    end

    LogUtil.debug("starting search for", query)
    NotifyUtil.info("Searching...")

    -- start search
    self.current_search_query = query
    local books, err, next_page = self:search(query, 1)
    self.books = books
    self.next_page = next_page

    -- check for errors
    if err or not books then
        err = err or "search failed"
        LogUtil.warn(string.format("search for %q failed: %s", query, err))
        NotifyUtil.info("Error: " .. err)
        return
    end
    if #books == 0 then
        LogUtil.info(
            string.format("no books found for %q with the preferred languages, file types and book types", query)
        )
        NotifyUtil.info("No books found")
        return
    end

    -- show books
    self:showBooks(books)
end

function KindleFetch:search(query, page)
    local books, err, next_page = LlgiSearch:search(query, page)

    if not books or type(books) ~= "table" then
        return nil, err
    end

    return books, nil, next_page
end

function KindleFetch:showBooks(books)
    local this = self
    local menu_items = {}

    for _, book in ipairs(books) do
        table.insert(menu_items, {
            book = book,
            callback = function()
                this:downloadBook(book)
            end,
        })
    end

    if self.next_page then
        table.insert(menu_items, {
            text = _("Load more"),
            callback = function()
                self:loadMoreBooks()
            end,
        })
    end

    local menu
    menu = BookMenu:new {
        item_table = menu_items,
        covers_fullscreen = true,
        is_borderless = true,
        width = this.dimen.w,
        height = this.dimen.h,
        items_max_lines = true,
        onPageChange = function(page)
            if KindleFetchSettings:getShowBookCovers() then
                LogUtil.debug("loading covers for page", page)
                menu:loadCoversForPage(page)
            end
        end,
    }

    self.books_menu = menu

    UIManager:show(menu)
    UIManager:setDirty(menu, "full")

    -- load covers for first page
    if KindleFetchSettings:getShowBookCovers() then
        LogUtil.debug("loading covers for page 1")
        menu:loadCoversForPage(1)
    end
end

function KindleFetch:loadMoreBooks()
    if not self.next_page then
        NotifyUtil.info("No more books found")
        return
    end

    -- turn on wifi first if need be, unless the next page is saved from an earlier search
    if not NetworkMgr:isConnected() and not LlgiSearch:isCached(self.current_search_query, self.next_page) then
        NetworkMgr:runWhenConnected(function()
            self:loadMoreBooks()
        end)
        return
    end

    NotifyUtil.info("Loading more books...")

    local books, err, next_page = self:search(self.current_search_query, self.next_page)

    if err then
        NotifyUtil.info("Error: " .. err)
        return
    end

    self.next_page = next_page
    if not books or #books == 0 then
        NotifyUtil.info("No more books found")
        return
    end

    -- append new books
    for _, book in ipairs(books) do
        table.insert(self.books, book)
    end

    -- close old menu, show new menu
    UIManager:close(self.books_menu)
    UIManager:setDirty(self.books_menu, "full")

    self:showBooks(self.books)
end

local function buildDownloadPath(book)
    local download_dir = KindleFetchSettings:getDownloadDir()
    local filename = util.getSafeFilename(book.title .. "." .. book.file_type, download_dir)
    return download_dir .. "/" .. filename
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
    LlgiAPI:downloadBook(book, filepath, function(ok, err, saved_filepath)
        if ok then
            LogUtil.debug("downloaded book to", saved_filepath)
            -- ask on the next tick, once the download progress has closed
            UIManager:nextTick(function()
                -- centred, with the title in bold on a line of its own, so it stands out from the question
                local dialog
                dialog = ButtonDialog:new {
                    title = string.format(
                        "%s%s\n%s%s%s\n\n%s",
                        TextBoxWidget.PTF_HEADER,
                        _("Downloaded"),
                        TextBoxWidget.PTF_BOLD_START,
                        book.title,
                        TextBoxWidget.PTF_BOLD_END,
                        _("Would you like to read it now?")
                    ),
                    title_align = "center",
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
        elseif err == "cancelled" then
            LogUtil.debug("download cancelled", book.title)
            NotifyUtil.info(_("Download cancelled"))
        else
            LogUtil.warn("download failed for", book.title, err)
            NotifyUtil.info(err and ("Download failed: " .. err) or "Download failed")
        end
    end, function(existing_filepath)
        -- the book is already there, and was chosen to be read rather than downloaded again
        self:openBook(existing_filepath)
    end)
end

return KindleFetch
