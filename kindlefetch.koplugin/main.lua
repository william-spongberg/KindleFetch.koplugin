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
local CurlUtil = require("util.curlutil")
local logger = require("logger")
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
    if not CurlUtil.checkCurlVersion() then
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
                UIManager:forceRePaint()
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
    UIManager:forceRePaint()
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

    logger.dbg("KindleFetch: starting search for", query)
    Notification:notify("Searching...", Notification.SOURCE_ALWAYS_SHOW, true)

    -- start search
    self.current_search_query = query
    self.current_page = 1
    local results, err = self:search(query, self.current_page)
    self.results = results
    if err then
        Notification:notify("Error: " .. err, Notification.SOURCE_ALWAYS_SHOW)
        return
    end

    if results == {} then
        logger.warn("KindleFetch: no books to show after search")
        Notification:notify("No results found", Notification.SOURCE_ALWAYS_SHOW)
        return
    end

    -- show results
    self:showResults(results)
end

function KindleFetch:search(query, page)
    local books, err = AnnasAPI:search(query, page)

    if books == nil or type(books) ~= "table" then
        logger.warn("KindleFetch: API search failed for", query, err or "unknown error")
        return nil, err
    end

    logger.dbg("KindleFetch: API returned", #books, "raw results for", query, "page", page)

    return books
end

local function formatBookDetails(book)
    local details = {}

    local function addBookDetail(detail)
        if StringUtil.assertValidString(detail) then
            table.insert(details, detail)
        end
    end

    addBookDetail(book.year)
    addBookDetail(book.language)
    addBookDetail(book.book_type)
    addBookDetail(book.file_type)
    addBookDetail(book.file_size)

    return table.concat(details, " · ")
end

function KindleFetch:showResults(results)
    local this = self
    local menu_items = {}

    for _, book in ipairs(results) do
        local book_text = book.title .. " by " .. book.authors
        local details = formatBookDetails(book)
        logger.dbg("KindleFetch: book details for", book.title, "=", details)
        book_text = book_text .. " · " .. details

        table.insert(menu_items, {
            text = book_text,
            single_line = false,
            multilines_show_more_text = true,
            multilines_forced = true,
            keep_newlines = true,
            callback = function()
                this:downloadBook(book)
            end
        })
    end

    table.insert(menu_items, {
        text = _("Load more"),
        callback = function()
            this:loadMoreResults()
        end
    })

    local menu = Menu:new{
        item_table = menu_items,
        covers_fullscreen = true,
        is_borderless = true,
        multilines_show_more_text = true,
        width = this.dimen.w,
        height = this.dimen.h
    }
    self.results_menu = menu

    UIManager:show(menu)
    UIManager:setDirty(menu, "ui")
    UIManager:forceRePaint()
end

function KindleFetch:loadMoreResults()
    self.current_page = self.current_page + 1

    Notification:notify("Loading more books...", Notification.SOURCE_ALWAYS_SHOW, true)

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

    -- append new results
    for _, book in ipairs(books) do
        table.insert(self.results, book)
    end

    -- close old menu, show new results
    UIManager:close(self.results_menu)
    UIManager:setDirty(self.results_menu, "ui")
    UIManager:forceRePaint()
    
    self:showResults(self.results)
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
            Notification:notify("Downloaded " .. book.title, Notification.SOURCE_ALWAYS_SHOW, true)
        else
            Notification:notify(err and ("Download failed: " .. err) or "Download failed",
                Notification.SOURCE_ALWAYS_SHOW, true)
        end
    end)
end

return KindleFetch
