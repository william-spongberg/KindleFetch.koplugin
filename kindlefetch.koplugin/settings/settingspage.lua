local KindleFetchSettings = require("settings.settings")
local UIManager = require("ui/uimanager")
local DownloadMgr = require("ui/downloadmgr")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local _ = require("gettext")

local SettingsPage = {}

local function formatDays(days)
    return string.format(days == 1 and _("%d day") or _("%d days"), days)
end

function SettingsPage:showSettings()
    local this = self
    local menu
    self.dimen = Screen:getSize()
    local show_book_covers = KindleFetchSettings:getShowBookCovers()
    local download_dir = KindleFetchSettings:getDownloadDir()
    local languages = KindleFetchSettings:getPreferredLanguages()
    local file_types = KindleFetchSettings:getPreferredFileTypes()
    local book_types = KindleFetchSettings:getPreferredBookTypes()
    local check_for_updates = KindleFetchSettings:getCheckForUpdates()
    local search_cache_days = KindleFetchSettings:getSearchCacheExpiryDays()
    local mirror_cache_days = KindleFetchSettings:getMirrorCacheExpiryDays()

    local menu_items = {{
        text = _(string.format("Show Book Covers: %s", show_book_covers and "☑" or "☐")),
        callback = function()
            UIManager:close(menu)
            UIManager:setDirty(menu, "full")
            this:changeBookCoverVisibility()
        end
    }, {
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
    }, {
        text = _(string.format("Check for Updates Automatically: %s", check_for_updates and "☑" or "☐")),
        callback = function()
            UIManager:close(menu)
            UIManager:setDirty(menu, "full")
            this:changeCheckForUpdates()
        end
    }, {
        text = _("Keep Searches For: ") .. formatDays(search_cache_days),
        callback = function()
            UIManager:close(menu)
            UIManager:setDirty(menu, "full")
            this:changeCacheExpiry(_("Keep Searches For"), search_cache_days, function(days)
                KindleFetchSettings:setSearchCacheExpiryDays(days)
            end)
        end
    }, {
        text = _("Keep Mirrors For: ") .. formatDays(mirror_cache_days),
        callback = function()
            UIManager:close(menu)
            UIManager:setDirty(menu, "full")
            this:changeCacheExpiry(_("Keep Mirrors For"), mirror_cache_days, function(days)
                KindleFetchSettings:setMirrorCacheExpiryDays(days)
            end)
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

function SettingsPage:changeBookCoverVisibility()
    local this = self

    local ok, err = KindleFetchSettings:setShowBookCovers(not KindleFetchSettings:getShowBookCovers())
    if ok then
        NotifyUtil.info("Book cover visibility updated")
        KindleFetchSettings:load()
        this:showSettings()
    else
        NotifyUtil.info("Error: " .. err)
    end
end

function SettingsPage:changeCacheExpiry(title, current_days, save)
    local this = self
    local menu
    local items = {}

    for i, days in ipairs(KindleFetchSettings:getAvailableCacheExpiryDays()) do
        table.insert(items, {
            text = string.format("%s %s", days == current_days and "◉" or "○", formatDays(days)),
            callback = function()
                save(days)
                NotifyUtil.info("Cache expiry updated")
                UIManager:close(menu)
                UIManager:setDirty(menu, "full")
                this:showSettings()
            end
        })
    end

    menu = Menu:new{
        title = title,
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        width = this.dimen.w,
        height = this.dimen.h
    }
    UIManager:show(menu)
    UIManager:setDirty(menu, "full")
end

function SettingsPage:changeCheckForUpdates()
    KindleFetchSettings:setCheckForUpdates(not KindleFetchSettings:getCheckForUpdates())
    NotifyUtil.info("Update checks updated")
    self:showSettings()
end

function SettingsPage:changeDownloadFolder()
    local this = self

    DownloadMgr:new{
        title = _("Choose download directory"),
        onConfirm = function(dir)
            local ok, err = KindleFetchSettings:setDownloadDir(dir)
            if ok then
                NotifyUtil.info("Download folder updated")
                KindleFetchSettings:load()
                this:showSettings()
            else
                NotifyUtil.info("Error: " .. err)
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
                        NotifyUtil.info("Languages updated")
                        UIManager:close(menu)
                        UIManager:setDirty(menu, "full")
                        this:showSettings()
                    else
                        NotifyUtil.info("Error: " .. err)
                    end
                else
                    NotifyUtil.info("Select at least one language")
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
                        NotifyUtil.info("File types updated")
                        UIManager:close(menu)
                        UIManager:setDirty(menu, "full")
                        KindleFetchSettings:load()
                        this:showSettings()
                    else
                        NotifyUtil.info("Error: " .. err)
                    end
                else
                    NotifyUtil.info("Select at least one file type")
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
                        NotifyUtil.info("Book types updated")
                        UIManager:close(menu)
                        UIManager:setDirty(menu, "full")
                        KindleFetchSettings:load()
                        this:showSettings()
                    else
                        NotifyUtil.info("Error: " .. err)
                    end
                else
                    NotifyUtil.info("Select at least one book type")
                end
            end
        }

        UIManager:show(menu)
        UIManager:setDirty(menu, "full")
    end

    showMenu()
end

return SettingsPage
