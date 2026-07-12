local KindleFetchSettings = require("settings.settings")
local UIManager = require("ui/uimanager")
local DownloadMgr = require("ui/downloadmgr")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local Screen = require("device").screen
local _ = require("gettext")

local SettingsPage = {}

function SettingsPage:showSettings()
    local this = self
    local menu
    self.dimen = Screen:getSize()
    local download_dir = KindleFetchSettings:getDownloadDir()
    local languages = KindleFetchSettings:getPreferredLanguages()
    local file_types = KindleFetchSettings:getPreferredFileTypes()
    local book_types = KindleFetchSettings:getPreferredBookTypes()

    local menu_items = {{
        text = _("Download Folder: ") .. download_dir,
        callback = function()
            UIManager:close(menu)
            UIManager:setDirty(menu, "full")
            this:changeDownloadFolder()
        end
    }, {
        text = _("Preferred Languages: ") .. table.concat(languages, ", "),
        callback = function()
            UIManager:close(menu)
            UIManager:setDirty(menu, "full")
            this:changeLanguages()
        end
    }, {
        text = _("Preferred File Types: ") .. table.concat(file_types, ", "),
        callback = function()
            UIManager:close(menu)
            UIManager:setDirty(menu, "full")
            this:changeFileTypes()
        end
    }, {
        text = _("Preferred Book Types: ") .. table.concat(book_types, ", "),
        callback = function()
            UIManager:close(menu)
            UIManager:setDirty(menu, "full")
            this:changeBookTypes()
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
    UIManager:setDirty(menu, "full")
end

function SettingsPage:changeDownloadFolder()
    local this = self

    DownloadMgr:new{
        title = _("Choose download directory"),
        onConfirm = function(dir)
            local ok, err = KindleFetchSettings:setDownloadDir(dir)
            if ok then
                Notification:notify("Download folder updated", Notification.SOURCE_ALWAYS_SHOW)
                KindleFetchSettings:load()
                this:showSettings()
            else
                Notification:notify("Error: " .. err, Notification.SOURCE_ALWAYS_SHOW)
            end
        end
    }:chooseDir()
end

function SettingsPage:changeLanguages()
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
                    UIManager:setDirty(menu, "full")
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
                        Notification:notify("Languages updated", Notification.SOURCE_ALWAYS_SHOW)
                        UIManager:close(menu)
                        UIManager:setDirty(menu, "full")
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
        UIManager:setDirty(menu, "full")
    end

    showMenu()
end

function SettingsPage:changeFileTypes()
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
                        UIManager:setDirty(menu, "full")
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
                        UIManager:setDirty(menu, "full")
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
        UIManager:setDirty(menu, "full")
    end

    showMenu()
end

function SettingsPage:changeBookTypes()
    local this = self

    local book_types = KindleFetchSettings:getAvailableBookTypes()
    local selected = {}

    for _, content in ipairs(KindleFetchSettings:getPreferredBookTypes()) do
        selected[content] = true
    end

    local function showMenu()
        local menu
        local items = {}

        for _, content in ipairs(book_types) do
            table.insert(items, {
                text = string.format("%s %s", selected[content.code] and "☑" or "☐", content.text),
                callback = function()
                    selected[content.code] = not selected[content.code]
                    UIManager:close(menu)
                    UIManager:setDirty(menu, "full")
                    showMenu()
                end
            })
        end

        menu = Menu:new{
            title = _("Preferred Book Types"),
            item_table = items,
            covers_fullscreen = true,
            is_borderless = true,
            width = this.dimen.w,
            height = this.dimen.h,

            onClose = function()
                local result = {}

                for _, content in ipairs(book_types) do
                    if selected[content.code] then
                        table.insert(result, content.code)
                    end
                end

                if #result > 0 then
                    local ok, err = KindleFetchSettings:setPreferredBookTypes(result)
                    if ok then
                        Notification:notify("Book types updated", Notification.SOURCE_ALWAYS_SHOW)
                        UIManager:close(menu)
                        UIManager:setDirty(menu, "full")
                        KindleFetchSettings:load()
                        this:showSettings()
                    else
                        Notification:notify("Error: " .. err, Notification.SOURCE_ALWAYS_SHOW)
                    end
                else
                    Notification:notify("Select at least one book type", Notification.SOURCE_ALWAYS_SHOW)
                end
            end
        }

        UIManager:show(menu)
        UIManager:setDirty(menu, "full")
    end

    showMenu()
end

return SettingsPage