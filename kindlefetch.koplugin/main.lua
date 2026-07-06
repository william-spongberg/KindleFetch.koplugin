local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local Screen = require("device").screen
local Input = require("device").input
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local Button = require("ui/widget/button")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local NetworkMgr = require("ui/network/manager")
local StringUtil = require("util.stringutil")
local AnnasAPI = require("api.annasapi")
local LlgiAPI = require("api.lgliapi")
local logger = require("logger")
local _ = require("gettext")

local KindleFetch = WidgetContainer:new{
    name = "kindlefetch",
    is_doc_only = false
}

local function getDownloadDirectory()
    local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/../settings.reader.lua")
    local download_dir = settings:readSetting("home_dir") or ""

    if download_dir == "" then
        download_dir = "/mnt/us/documents"
        logger.warn("KindleFetch: home directory not found, defaulting to", download_dir)
    end

    if not lfs.attributes(download_dir, "mode") then
        download_dir = "/mnt/us"
        logger.warn("KindleFetch: documents directory does not exist, defaulting to", download_dir)
    end

    return download_dir
end

local function buildDownloadPath(book)
    local download_dir = getDownloadDirectory()
    local filename = util.getSafeFilename(book.safe_title .. "." .. book.file_type, download_dir)
    return download_dir .. "/" .. filename
end

function KindleFetch:onDispatcherRegisterActions()
    Dispatcher:registerAction("kindlefetch_action", {
        category = "none",
        event = "KindleFetch",
        title = _("Kindle Fetch"),
        general = true
    })
end

function KindleFetch:init()
    if self.dimen == nil then
        self.dimen = Screen:getSize()
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function KindleFetch:addToMainMenu(menu_items)
    menu_items.kindlefetch = {
        text = _("Kindle Fetch"),
        sorting_hint = "tools",
        callback = function()
            self:setupUI()
        end
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
            end
        }, {
            text = "Search",
            callback = function()
                this:performSearch()
            end
        }}}
    }
    UIManager:show(self.search_box)
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

    logger.info("KindleFetch: starting search for", query)
    Notification:notify("Searching...", Notification.SOURCE_ALWAYS_SHOW, true)

    -- start search
    local results, err = self:search(query)
    if err then
        Notification:notify("Error: " .. err, Notification.SOURCE_ALWAYS_SHOW)
        return
    end

    -- show results
    self:showResults(results)
end

function KindleFetch:search(query)
    local books, err = AnnasAPI:search(query)

    if not books or type(books) ~= "table" then
        logger.warn("KindleFetch: API search failed for", query, err or "unknown error")
        return nil, err
    end

    logger.info("KindleFetch: API returned", #books, "raw results for", query)

    return books
end

local function formatBookDetails(book)
    local details = {}

    local function addBookDetail(detail)
        local tmp = StringUtil.assertValidString(detail)
        if tmp ~= "" then
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

function KindleFetch:showResults(books)
    if books == nil then
        logger.warn("KindleFetch: no books to show after search")
        Notification:notify("No results found", Notification.SOURCE_ALWAYS_SHOW)
        return
    end

    local this = self
    local menu_items = {}

    for _, book in ipairs(books) do
        local book_text = book.title .. " by " .. book.authors
        local details = formatBookDetails(book)
        logger.info("KindleFetch: book details for", book.title, "=", details)
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

    -- TODO: add menu item at the end to load more pages (if they exist)

    local menu = Menu:new{
        item_table = menu_items,
        covers_fullscreen = true,
        is_borderless = true,
        multilines_show_more_text = true,
        width = this.dimen.w,
        height = this.dimen.h
    }
    UIManager:show(menu)
end

function KindleFetch:downloadBook(book)
    local filepath = buildDownloadPath(book)
    Notification:notify("Downloading: " .. book.title, Notification.SOURCE_ALWAYS_SHOW, true)
    LlgiAPI:downloadBook(book, filepath, function(ok, err)
        if ok then
            Notification:notify("Saved to " .. filepath, Notification.SOURCE_ALWAYS_SHOW, true)
        else
            Notification:notify(err and ("Download failed: " .. err) or "Download failed",
                Notification.SOURCE_ALWAYS_SHOW, true)
        end
    end)
end

return KindleFetch
