local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local DownloadMgr = require("ui/downloadmgr")
local Menu = require("ui/widget/menu")
local KindleFetchSettings = require("settings.settings")
local SettingsPage = require("settings.settingspage")
local util = require("util")
local NetworkMgr = require("ui/network/manager")
local StringUtil = require("util.stringutil")
local AnnasAPI = require("api.annasapi")
local LlgiAPI = require("api.lgliapi")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local BookMenu = require("ui.bookmenu")
local CoverCache = require("cache.covercache")
local CurlUpdater = require("updater.curlupdater")
local PluginUpdater = require("updater.pluginupdater")
local lfs = require("libs/libkoreader-lfs")
local FileUtil = require("util.fileutil")
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
    -- check curl is at min version
    CurlUpdater.checkVersion()

    -- check for updates
    self:getPluginPath()
    PluginUpdater.checkForUpdates(self.plugin_path)

    -- load settings
    KindleFetchSettings:load()

    -- get screen size
    if self.dimen == nil then
        self.dimen = Screen:getSize()
    end

    -- register to main menu
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
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

function KindleFetch:getPluginPath()
    local dir = lfs.currentdir()

    self.plugin_path = dir .. LogUtil.debug("plugin path", self.plugin_path)
end

function KindleFetch:getPluginPath()
    local dir = lfs.currentdir()
    local path = debug.getinfo(1, "S").source
    if path:sub(1, 1) == "@" then
        path = path:sub(2)
    end
    path = path:match("(.*)/")

    self.plugin_path = dir .. "/" .. path
    LogUtil.debug("plugin path", self.plugin_path)
    
    -- List files in the plugin directory
    local handle = io.popen("ls -la " .. self.plugin_path)
    local files = handle:read("*a")
    handle:close()
    
    LogUtil.debug("plugin files", files)
    
    -- Read version.txt using FileUtil
    local version = FileUtil.readFile(self.plugin_path .. "/version.txt")
    if version then
        LogUtil.debug("plugin version", version)
    else
        LogUtil.debug("plugin version", "version.txt not found")
    end
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

    -- check device is online
    if not NetworkMgr:isConnected() then
        NotifyUtil.info("Connect to the internet first")
        return
    end

    LogUtil.debug("starting search for", query)
    NotifyUtil.info("Searching...")

    -- start search
    self.current_search_query = query
    self.current_page = 1
    local books, err = self:search(query, self.current_page)
    self.books = books

    -- check for errors
    if err or not books then
        NotifyUtil.info("Error: " .. err)
        return
    end
    if #books == 0 then
        LogUtil.warn("no books to show after search")
        NotifyUtil.info("No books found")
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
                menu:loadCoversForPage(page)
            end
        end
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
    self.current_page = self.current_page + 1

    NotifyUtil.info("Loading more books...")

    local books, err = self:search(self.current_search_query, self.current_page)

    if err then
        NotifyUtil.info("Error: " .. err)
        self.current_page = self.current_page - 1
        return
    end

    if not books then
        NotifyUtil.info("No more books found")
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
            NotifyUtil.info("Downloaded " .. book.title)
        else
            LogUtil.warn("download failed for")
            NotifyUtil.info(err and ("Download failed: " .. err) or "Download failed")
        end
    end)
end

return KindleFetch
