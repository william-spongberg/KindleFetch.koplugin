local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local CheckButton = require("ui/widget/checkbutton")
local Screen = require("device").screen
local Input = require("device").input
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local Button = require("ui/widget/button")
local util = require("util")
local NetworkMgr = require("ui/network/manager")
local StringUtil = require("util.stringutil")
local AnnasAPI = require("api.annasapi")
local LlgiAPI = require("api.lgliapi")
local CurlUtil = require("util.curlutil")
local KindleFetchSettings = require("util.settings")
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
end

function KindleFetch:addToMainMenu(menu_items)
    menu_items.kindlefetch = {
        text = _("Kindle Fetch"),
        sorting_hint = "search",
        sub_item_table = {{
            text = _("Search Books"),
            callback = function()
                self:setupUI()
            end
        }, {
            text = _("Settings"),
            callback = function()
                self:showSettings()
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

    -- TODO: more detailed
    if results == {} then
        logger.warn("KindleFetch: no books to show after search")
        Notification:notify("No results found", Notification.SOURCE_ALWAYS_SHOW)
        return
    end

    -- show results
    self:showResults(results)
end

function KindleFetch:search(query)
    local books, err = AnnasAPI:search(query)

    if books == nil or type(books) ~= "table" then
        logger.warn("KindleFetch: API search failed for", query, err or "unknown error")
        return nil, err
    end

    logger.info("KindleFetch: API returned", #books, "raw results for", query)

    return books
end

local function formatBookDetails(book)
    local details = {}

    local function addBookDetail(detail)
        if not StringUtil.assertValidString(detail) then
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

local function buildDownloadPath(book)
    local download_dir = KindleFetchSettings:getDownloadDir()
    local filename = util.getSafeFilename(book.safe_title .. "." .. book.file_type, download_dir)
    return download_dir .. "/" .. filename
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

function KindleFetch:showSettings()
    local this = self
    local menu
    local download_dir = KindleFetchSettings:getDownloadDir()
    local languages = KindleFetchSettings:getPreferredLanguages()
    local file_types = KindleFetchSettings:getPreferredFileTypes()

    local menu_items = {{
        text = _("Download Folder: ") .. download_dir,
        callback = function()
            this:changeDownloadFolder()
        end
    }, {
        text = _("Preferred Languages: ") .. table.concat(languages, ", "),
        callback = function()
            UIManager:close(menu)
            this:changeLanguages()
        end
    }, {
        text = _("Preferred File Types: ") .. table.concat(file_types, ", "),
        callback = function()
            UIManager:close(menu)
            this:changeFileTypes()
        end
    }}

    menu = Menu:new{
        item_table = menu_items,
        covers_fullscreen = true,
        is_borderless = true,
        width = this.dimen.w,
        height = this.dimen.h
    }
    UIManager:show(menu)
end

function KindleFetch:changeDownloadFolder()
    local this = self
    local input_dialog

    input_dialog = InputDialog:new{
        title = _("Download Folder Path"),
        input_type = "text",
        input_hint = KindleFetchSettings:getDownloadDir(),
        text = KindleFetchSettings:getDownloadDir(),
        buttons = {{{
            text = _("Cancel"),
            callback = function()
                UIManager:close(input_dialog)
            end
        }, {
            text = _("Save"),
            callback = function()
                local new_path = StringUtil.trim(input_dialog:getInputText())
                if StringUtil.assertValidString(new_path) then
                    local ok, err = KindleFetchSettings:setDownloadDir(new_path)
                    if ok then
                        Notification:notify("Download folder updated", Notification.SOURCE_ALWAYS_SHOW)
                        UIManager:close(input_dialog)
                        KindleFetchSettings:load()
                        this:showSettings()
                    else
                        Notification:notify("Error: " .. err, Notification.SOURCE_ALWAYS_SHOW)
                    end
                else
                    Notification:notify("Enter a valid file path", Notification.SOURCE_ALWAYS_SHOW)
                end
            end
        }}}
    }
    UIManager:show(input_dialog)
end

function KindleFetch:changeLanguages()
    local this = self

    local languages = KindleFetchSettings:getAvailableLanguages()
    local selected = {}

    for _, lang in ipairs(KindleFetchSettings:getPreferredLanguages()) do
        selected[lang] = true
    end

    local function showMenu()
        local menu
        local items = {}

        for _, lang in ipairs(languages) do
            table.insert(items, {
                text = string.format("%s %s", selected[lang.code] and "☑" or "☐", lang.text),
                callback = function()
                    selected[lang.code] = not selected[lang.code]
                    UIManager:close(menu)
                    showMenu()
                end
            })
        end

        menu = Menu:new{
            title = _("Preferred Languages"),
            item_table = items,
            covers_fullscreen = true,
            is_borderless = true,
            width = this.dimen.w,
            height = this.dimen.h,

            onClose = function()
                local result = {}

                for _, lang in ipairs(languages) do
                    if selected[lang.code] then
                        table.insert(result, lang.code)
                    end
                end

                if #result > 0 then
                    local ok, err = KindleFetchSettings:setPreferredLanguages(result)
                    if ok then
                        Notification:notify("File types updated", Notification.SOURCE_ALWAYS_SHOW)
                        UIManager:close(menu)
                        KindleFetchSettings:load()
                        this:showSettings()
                    else
                        Notification:notify("Error: " .. err, Notification.SOURCE_ALWAYS_SHOW)
                    end
                else
                    Notification:notify("Select at least one language", Notification.SOURCE_ALWAYS_SHOW)
                end
            end
        }

        UIManager:show(menu)
    end

    showMenu()
end

function KindleFetch:changeFileTypes()
    local this = self

    local categories = {{
        name = _("Ebooks"),
        types = KindleFetchSettings:getEbookFileTypes()
    }, {
        name = _("Comics"),
        types = KindleFetchSettings:getComicFileTypes()
    }, {
        name = _("Documents"),
        types = KindleFetchSettings:getDocumentFileTypes()
    }, {
        name = _("Images"),
        types = KindleFetchSettings:getImageFileTypes()
    }, {
        name = _("Web"),
        types = KindleFetchSettings:getWebFileTypes()
    }}

    local selected = {}

    for _, ext in ipairs(KindleFetchSettings:getPreferredFileTypes()) do
        selected[ext] = true
    end

    local function showMenu()
        local menu
        local items = {}

        for _, category in ipairs(categories) do
            table.insert(items, {
                text = "── " .. category.name .. " ──",
                enabled = false
            })

            for _, ext in ipairs(category.types) do
                table.insert(items, {
                    text = string.format("%s %s", selected[ext] and "☑" or "☐", ext),
                    callback = function()
                        selected[ext] = not selected[ext]
                        UIManager:close(menu)
                        showMenu()
                    end
                })
            end
        end

        menu = Menu:new{
            title = _("Preferred File Types"),
            item_table = items,
            covers_fullscreen = true,
            is_borderless = true,
            width = this.dimen.w,
            height = this.dimen.h,

            onClose = function()
                local result = {}

                for _, category in ipairs(categories) do
                    for _, ext in ipairs(category.types) do
                        if selected[ext] then
                            table.insert(result, ext)
                        end
                    end
                end

                if #result > 0 then
                    local ok, err = KindleFetchSettings:setPreferredFileTypes(result)
                    if ok then
                        Notification:notify("File types updated", Notification.SOURCE_ALWAYS_SHOW)
                        UIManager:close(menu)
                        KindleFetchSettings:load()
                        this:showSettings()
                    else
                        Notification:notify("Error: " .. err, Notification.SOURCE_ALWAYS_SHOW)
                    end
                else
                    Notification:notify("Select at least one file type", Notification.SOURCE_ALWAYS_SHOW)
                end
            end
        }

        UIManager:show(menu)
    end

    showMenu()
end

return KindleFetch
