local KindleFetchSettings = require("settings.settings")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local DownloadMgr = require("ui/downloadmgr")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local NotifyUtil = require("util.notifyutil")
local SearchCache = require("cache.searchcache")
local UrlCache = require("cache.urlcache")
local CoverCache = require("cache.covercache")
local _ = require("gettext")

local SettingsPage = {}

local function formatDays(days)
    return string.format(days == 1 and _("%d day") or _("%d days"), days)
end

-- the most of a folder's path that's shown, which is about as much as fits beside its label
local MAX_FOLDER_LENGTH = 32

-- the end of a long folder's path, which says the most about it, e.g. "…/documents/books"
function SettingsPage.shortenFolder(path)
    if #path <= MAX_FOLDER_LENGTH then
        return path
    end
    local shortened = path
    while #shortened > MAX_FOLDER_LENGTH - 1 do
        local rest = shortened:match("^/?[^/]+(/.+)$")
        if not rest then
            break
        end
        shortened = rest
    end
    return "…" .. shortened
end

-- the names of the choices that are chosen, as the settings list them (each choice with its text and the code it's
-- saved as), or All when every one is
local function describeChosen(choices, chosen)
    local is_chosen = {}
    for _, code in ipairs(chosen) do
        is_chosen[code] = true
    end
    local names = {}
    for _, choice in ipairs(choices) do
        if choice.code and is_chosen[choice.code] then
            table.insert(names, choice.text)
        end
    end
    local available = 0
    for _, choice in ipairs(choices) do
        if choice.code then
            available = available + 1
        end
    end
    if #names == available then
        return _("All")
    end
    return table.concat(names, ", ")
end

-- the file types that can be chosen, under a heading for each kind
local function fileTypeChoices()
    local categories = {
        {
            name = _("Ebooks"),
            types = KindleFetchSettings:getEbookFileTypes(),
        },
        {
            name = _("Comics"),
            types = KindleFetchSettings:getComicFileTypes(),
        },
        {
            name = _("Documents"),
            types = KindleFetchSettings:getDocumentFileTypes(),
        },
        {
            name = _("Images"),
            types = KindleFetchSettings:getImageFileTypes(),
        },
        {
            name = _("Web"),
            types = KindleFetchSettings:getWebFileTypes(),
        },
    }

    local choices = {}
    for _, category in ipairs(categories) do
        table.insert(choices, {
            heading = category.name,
        })
        for _, ext in ipairs(category.types) do
            table.insert(choices, {
                text = ext,
                code = ext,
            })
        end
    end
    return choices
end

-- a menu that fills the screen
function SettingsPage:newMenu(title, item_table, onClose)
    return Menu:new {
        title = title,
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        -- with square corners: rounded ones aren't painted, and show what was on screen before, such as the top
        -- edge of KOReader's menu
        is_popout = false,
        width = self.dimen.w,
        height = self.dimen.h,
        onClose = onClose,
    }
end

function SettingsPage:settingsItems()
    local this = self
    local show_book_covers = KindleFetchSettings:getShowBookCovers()
    local download_dir = KindleFetchSettings:getDownloadDir()
    local languages = KindleFetchSettings:getPreferredLanguages()
    local file_types = KindleFetchSettings:getPreferredFileTypes()
    local book_types = KindleFetchSettings:getPreferredBookTypes()
    local check_for_updates = KindleFetchSettings:getCheckForUpdates()
    local search_cache_days = KindleFetchSettings:getSearchCacheExpiryDays()
    local mirror_cache_days = KindleFetchSettings:getMirrorCacheExpiryDays()

    return {
        {
            text = _(string.format("Show Book Covers: %s", show_book_covers and "☑" or "☐")),
            callback = function()
                this:changeBookCoverVisibility()
            end,
        },
        {
            text = _("Download Folder: ") .. SettingsPage.shortenFolder(download_dir),
            callback = function()
                this:changeDownloadFolder()
            end,
        },
        {
            text = _("Preferred Languages: ") .. describeChosen(KindleFetchSettings:getAvailableLanguages(), languages),
            callback = function()
                this:changeLanguages()
            end,
        },
        {
            text = _("Preferred File Types: ") .. describeChosen(fileTypeChoices(), file_types),
            callback = function()
                this:changeFileTypes()
            end,
        },
        {
            text = _("Preferred Book Types: ")
                .. describeChosen(KindleFetchSettings:getAvailableBookTypes(), book_types),
            callback = function()
                this:changeBookTypes()
            end,
        },
        {
            text = _(string.format("Check for Updates Automatically: %s", check_for_updates and "☑" or "☐")),
            callback = function()
                this:changeCheckForUpdates()
            end,
        },
        {
            text = _("Keep Searches For: ") .. formatDays(search_cache_days),
            callback = function()
                this:changeCacheExpiry(_("Keep Searches For"), search_cache_days, function(days)
                    KindleFetchSettings:setSearchCacheExpiryDays(days)
                end)
            end,
        },
        {
            text = _("Keep Mirrors For: ") .. formatDays(mirror_cache_days),
            callback = function()
                this:changeCacheExpiry(_("Keep Mirrors For"), mirror_cache_days, function(days)
                    KindleFetchSettings:setMirrorCacheExpiryDays(days)
                end)
            end,
        },
        {
            text = _("Clear Cache"),
            callback = function()
                this:clearCache()
            end,
        },
    }
end

function SettingsPage:showSettings()
    self.dimen = Screen:getSize()
    self.menu = self:newMenu(_("Kindle Fetch Settings"), self:settingsItems())
    UIManager:show(self.menu)
end

-- show the settings as they are now, in the menu that's open and on the page it's on. closing the menu and
-- opening another for every change flashes the whole screen twice
function SettingsPage:refresh()
    self.menu:switchItemTable(nil, self:settingsItems(), -1)
end

function SettingsPage:changeBookCoverVisibility()
    KindleFetchSettings:setShowBookCovers(not KindleFetchSettings:getShowBookCovers())
    self:refresh()
end

function SettingsPage:changeCacheExpiry(title, current_days, save)
    local this = self
    local menu
    local items = {}

    for _, days in ipairs(KindleFetchSettings:getAvailableCacheExpiryDays()) do
        table.insert(items, {
            text = string.format("%s %s", days == current_days and "◉" or "○", formatDays(days)),
            callback = function()
                save(days)
                UIManager:close(menu)
                this:refresh()
            end,
        })
    end

    menu = self:newMenu(title, items)
    UIManager:show(menu)
end

function SettingsPage:changeCheckForUpdates()
    KindleFetchSettings:setCheckForUpdates(not KindleFetchSettings:getCheckForUpdates())
    self:refresh()
end

function SettingsPage:changeDownloadFolder()
    local this = self

    DownloadMgr:new {
        title = _("Choose download directory"),
        onConfirm = function(dir)
            local ok, err = KindleFetchSettings:setDownloadDir(dir)
            if ok then
                this:refresh()
            else
                NotifyUtil.error(err)
            end
        end,
    }:chooseDir()
end

-- a menu of choices to tick, each with its text and the code it's saved as, or a heading to go above the choices
-- after it. the ticked codes are passed to save when the menu is closed, unless there are none, as nothing could
-- then be found, which none_text says. (a change isn't otherwise said, as the settings show it, and each
-- notification refreshes the screen twice)
function SettingsPage:tickSeveral(title, choices, ticked, save, none_text)
    local this = self
    local selected = {}
    for _, code in ipairs(ticked) do
        selected[code] = true
    end

    local menu
    local function items()
        local item_table = {}
        for _, choice in ipairs(choices) do
            if choice.heading then
                table.insert(item_table, {
                    text = "── " .. choice.heading .. " ──",
                    enabled = false,
                })
            else
                table.insert(item_table, {
                    text = string.format("%s %s", selected[choice.code] and "☑" or "☐", choice.text),
                    callback = function()
                        selected[choice.code] = not selected[choice.code]
                        -- tick it in the menu that's open, which stays on the page it's on
                        menu:switchItemTable(nil, items(), -1)
                    end,
                })
            end
        end
        return item_table
    end

    menu = self:newMenu(title, items(), function()
        local result = {}
        for _, choice in ipairs(choices) do
            if choice.code and selected[choice.code] then
                table.insert(result, choice.code)
            end
        end

        if #result == 0 then
            NotifyUtil.info(none_text)
            return
        end
        save(result)
        UIManager:close(menu)
        this:refresh()
    end)
    UIManager:show(menu)
end

function SettingsPage:changeLanguages()
    self:tickSeveral(
        _("Preferred Languages"),
        KindleFetchSettings:getAvailableLanguages(),
        KindleFetchSettings:getPreferredLanguages(),
        function(languages)
            KindleFetchSettings:setPreferredLanguages(languages)
        end,
        "Select at least one language"
    )
end

function SettingsPage:changeFileTypes()
    local choices = fileTypeChoices()

    self:tickSeveral(
        _("Preferred File Types"),
        choices,
        KindleFetchSettings:getPreferredFileTypes(),
        function(file_types)
            KindleFetchSettings:setPreferredFileTypes(file_types)
        end,
        "Select at least one file type"
    )
end

function SettingsPage:changeBookTypes()
    self:tickSeveral(
        _("Preferred Book Types"),
        KindleFetchSettings:getAvailableBookTypes(),
        KindleFetchSettings:getPreferredBookTypes(),
        function(book_types)
            KindleFetchSettings:setPreferredBookTypes(book_types)
        end,
        "Select at least one book type"
    )
end

-- forget the searches, mirrors and covers that are saved, e.g. when they no longer match what Library Genesis
-- has, rather than their files having to be found and deleted by hand
function SettingsPage:clearCache()
    UIManager:show(ConfirmBox:new {
        text = _("Clear the searches, mirrors and book covers that Kindle Fetch has saved?"),
        ok_text = _("Clear"),
        ok_callback = function()
            SearchCache:clear()
            UrlCache:clear()
            CoverCache:clear()
            NotifyUtil.info(_("Cache cleared"))
        end,
    })
end

return SettingsPage
