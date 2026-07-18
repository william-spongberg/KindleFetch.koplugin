local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local DownloadMgr = require("ui/downloadmgr")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local KindleFetchSettings = require("settings.settings")
local SettingsPage = require("settings.settingspage")
local util = require("util")
local NetworkMgr = require("ui/network/manager")
local StringUtil = require("util.stringutil")
local AnnasAPI = require("api.annasapi")
local LlgiAPI = require("api.lgliapi")
local LogUtil = require("util.logutil")
local BookMenu = require("ui.bookmenu")
local CoverCache = require("cache.covercache")
local VersionCheck = require("util.versioncheck")
local _ = require("gettext")

local KindleFetch = WidgetContainer:new{
    name = "kindlefetch",
    is_doc_only = false
}

function KindleFetch:onDispatcherRegisterActions()
    Dispatcher:registerAction("kindlefetch_action", {
        category = "none",
        event = "KindleFetch",
        title = _("Kindle Fetch"),
        general = true
    })
end

function KindleFetch:init()
    -- ensure curl is available and meets version requirements
    if not VersionCheck.checkCurlVersion() then
        Notification:notify("curl is not available or could not be installed", Notification.SOURCE_ALWAYS_SHOW)
        return
    end

    -- load settings
    KindleFetchSettings:load()

    -- get screen size
    if self.dimen == nil then
        self.dimen = Screen:getSize()
    end

    -- register to main menu
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    -- register exit hook to warn about active downloads
    self:registerExitHook()
end

function KindleFetch:addToMainMenu(menu_items)
    menu_items.kindlefetch = {
        text = _("Kindle Fetch"),
        sorting_hint = "search",
        sub_item_table = {{
            text = _("Search Anna's Archive"),
            callback = function()
                self:setupUI()
            end
        }, {
            text = _("Settings"),
            callback = function()
                SettingsPage:showSettings()
            end
        }}
    }
end

function KindleFetch:setupUI()
    -- grab self reference for callbacks
    local this = self

    self.search_box = InputDialog:new{
        title = "Search Anna's Archive",
        input_type = "text",
        buttons = {{{
            text = "Cancel",
            callback = function()
                UIManager:close(this.search_box)
                UIManager:setDirty(this.search_box, "ui")
            end
        }, {
            text = "Search",
            callback = function()
                this:performSearch()
            end
        }}}
    }
    UIManager:show(self.search_box)
    UIManager:setDirty(self.search_box, "ui")
end

function KindleFetch:performSearch()
    local query = StringUtil.trim(self.search_box:getInputText())

    -- close keyboard after search
    self.search_box:onCloseKeyboard()

    -- check query is not empty
    if query == "" then
        Notification:notify("Enter a search term first", Notification.SOURCE_ALWAYS_SHOW)
        return
    end

    -- check device is online
    if not NetworkMgr:isConnected() then
        Notification:notify("Connect to the internet first", Notification.SOURCE_ALWAYS_SHOW)
        return
    end

    LogUtil.debug("starting search for", query)
    Notification:notify("Searching...", Notification.SOURCE_ALWAYS_SHOW, true)
    UIManager:forceRePaint()

    -- start search
    self.current_search_query = query
    self.current_page = 1
    local books, err = self:search(query, self.current_page)
    self.books = books

    -- check for errors
    if err or not books then
        Notification:notify("Error: " .. err, Notification.SOURCE_ALWAYS_SHOW)
        return
    end
    if #books == 0 then
        LogUtil.warn("no books to show after search")
        Notification:notify("No books found", Notification.SOURCE_ALWAYS_SHOW)
        return
    end

    -- show books
    self:showBooks(books)
end

function KindleFetch:search(query, page)
    local books, err = AnnasAPI:search(query, page)

    if not books or type(books) ~= "table" then
        LogUtil.warn("API search failed for")
        return nil, err
    end

    LogUtil.debug("API returned", #books, "raw books for", query, "page", page)

    return books
end

-- TODO: move to new books page file
function KindleFetch:showBooks(books)
    local this = self
    local menu_items = {}

    for _, book in ipairs(books) do
        table.insert(menu_items, {
            book = book,
            callback = function()
                this:downloadBook(book)
            end
        })
    end

    table.insert(menu_items, {
        text = _("Load more"),
        callback = function()
            self:loadMoreBooks()
        end
    })

    local menu
    menu = BookMenu:new{
        item_table = menu_items,
        covers_fullscreen = true,
        is_borderless = true,
        width = this.dimen.w,
        height = this.dimen.h,
        items_max_lines = true,
        onPageChange = function(page)
            if (KindleFetchSettings:getShowBookCovers()) then
                LogUtil.debug("loading covers for page", page)
                this:loadCoversForPage(menu, page)
            end
        end
    }

    self.books_menu = menu

    UIManager:show(menu)
    UIManager:setDirty(menu, "full")

    -- load covers for first page
    if KindleFetchSettings:getShowBookCovers() then
        LogUtil.debug("loading covers for page 1")
        this:loadCoversForPage(menu, 1)
    end
end

function KindleFetch:loadCoversForPage(menu, current_page)
    local items_per_page = self.books_menu:getNumberBooksPerPage() + 1
    local start_idx = (current_page - 1) * items_per_page + 1
    local end_idx = math.min(start_idx + items_per_page - 1, #menu.item_table)

    -- collect books that need downloading
    local books_to_download = {}
    local items_being_modified = {}
    for idx = start_idx, end_idx do
        local item = menu.item_table[idx]
        if item and item.book and item.book.image_url and not CoverCache:cacheExists(item.book.md5) then
            table.insert(books_to_download, item.book)
            table.insert(items_being_modified, idx)
            item.widget = nil -- clear cache
        end
    end

    if #books_to_download > 0 then
        -- download all at once in parallel
        LogUtil.debug("downloading", #books_to_download, "covers in parallel")
        CoverCache:downloadMultiple(books_to_download, items_per_page)

        -- refresh menu to show downloaded covers
        menu:updateItems()
        UIManager:setDirty(menu, "full")
    end
end

function KindleFetch:loadMoreBooks()
    self.current_page = self.current_page + 1

    Notification:notify("Loading more books...", Notification.SOURCE_ALWAYS_SHOW, true)
    UIManager:forceRePaint()

    local books, err = self:search(self.current_search_query, self.current_page)

    if err then
        Notification:notify("Error: " .. err, Notification.SOURCE_ALWAYS_SHOW)
        self.current_page = self.current_page - 1
        return
    end

    if not books then
        Notification:notify("No more books found", Notification.SOURCE_ALWAYS_SHOW)
        self.current_page = self.current_page - 1
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

function KindleFetch:downloadBook(book)
    local filepath = buildDownloadPath(book)
    LlgiAPI:downloadBook(book, filepath, function(ok, err)
        if ok then
            LogUtil.debug("downloaded book")
            Notification:notify("Downloaded " .. book.title, Notification.SOURCE_ALWAYS_SHOW, true)
            UIManager:forceRePaint()
        else
            LogUtil.warn("download failed for")
            Notification:notify(err and ("Download failed: " .. err) or "Download failed",
                Notification.SOURCE_ALWAYS_SHOW, true)
            UIManager:forceRePaint()
        end
    end)
end

return KindleFetch
