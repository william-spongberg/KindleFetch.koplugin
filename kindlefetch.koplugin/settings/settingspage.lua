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
local ZlibAccount = require("api.zlibaccount")
local ZlibLogin = require("ui.zliblogin")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext

local SettingsPage = {}

-- say when a setting couldn't be saved (see KindleFetchSettings:setSetting), which would go back to what it was
local function saved(ok, err)
    if not ok then
        NotifyUtil.error(err)
    end
end

local function formatDays(days)
    return T(N_("1 day", "%1 days", days), days)
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
    for __, code in ipairs(chosen) do
        is_chosen[code] = true
    end
    local names = {}
    for __, choice in ipairs(choices) do
        if choice.code and is_chosen[choice.code] then
            table.insert(names, choice.text)
        end
    end
    local available = 0
    for __, choice in ipairs(choices) do
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
    for __, category in ipairs(categories) do
        table.insert(choices, {
            heading = category.name,
        })
        for __, ext in ipairs(category.types) do
            table.insert(choices, {
                text = ext,
                code = ext,
            })
        end
    end
    return choices
end

-- a menu that fills the screen (from the settings, or the results, see changeLanguages)
function SettingsPage:newMenu(title, item_table, onClose)
    local size = Screen:getSize()
    return Menu:new {
        title = title,
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        -- with square corners: rounded ones aren't painted, and show what was on screen before, such as the top
        -- edge of KOReader's menu
        is_popout = false,
        width = size.w,
        height = size.h,
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
            text = T(_("Show Book Covers: %1"), show_book_covers and "☑" or "☐"),
            callback = function()
                this:changeBookCoverVisibility()
            end,
        },
        {
            text = T(_("Download Folder: %1"), SettingsPage.shortenFolder(download_dir)),
            callback = function()
                this:changeDownloadFolder()
            end,
        },
        {
            text = T(_("Z-Library Account: %1"), ZlibAccount:getEmail() or _("Not logged in")),
            callback = function()
                this:changeZlibAccount()
            end,
        },
        {
            text = T(
                _("Preferred Languages: %1"),
                describeChosen(KindleFetchSettings:getAvailableLanguages(), languages)
            ),
            callback = function()
                this:changeLanguages()
            end,
        },
        {
            text = T(_("Preferred File Types: %1"), describeChosen(fileTypeChoices(), file_types)),
            callback = function()
                this:changeFileTypes()
            end,
        },
        {
            text = T(
                _("Preferred Book Types: %1"),
                describeChosen(KindleFetchSettings:getAvailableBookTypes(), book_types)
            ),
            callback = function()
                this:changeBookTypes()
            end,
        },
        {
            text = T(_("Check for Updates Automatically: %1"), check_for_updates and "☑" or "☐"),
            callback = function()
                this:changeCheckForUpdates()
            end,
        },
        {
            text = T(_("Keep Searches For: %1"), formatDays(search_cache_days)),
            callback = function()
                this:changeCacheExpiry(_("Keep Searches For"), search_cache_days, function(days)
                    saved(KindleFetchSettings:setSearchCacheExpiryDays(days))
                end)
            end,
        },
        {
            text = T(_("Keep Mirrors For: %1"), formatDays(mirror_cache_days)),
            callback = function()
                this:changeCacheExpiry(_("Keep Mirrors For"), mirror_cache_days, function(days)
                    saved(KindleFetchSettings:setMirrorCacheExpiryDays(days))
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
    self.menu = self:newMenu(_("Kindle Fetch Settings"), self:settingsItems())
    UIManager:show(self.menu)
end

-- show the settings as they are now, in the menu that's open and on the page it's on. closing the menu and
-- opening another for every change flashes the whole screen twice. (nothing once it has been closed, e.g. where the
-- languages are changed from the results)
function SettingsPage:refresh()
    if self.menu and UIManager:isWidgetShown(self.menu) then
        self.menu:switchItemTable(nil, self:settingsItems(), -1)
    end
end

function SettingsPage:changeBookCoverVisibility()
    saved(KindleFetchSettings:setShowBookCovers(not KindleFetchSettings:getShowBookCovers()))
    self:refresh()
end

function SettingsPage:changeCacheExpiry(title, current_days, save)
    local this = self
    local menu
    local items = {}

    for __, days in ipairs(KindleFetchSettings:getAvailableCacheExpiryDays()) do
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
    saved(KindleFetchSettings:setCheckForUpdates(not KindleFetchSettings:getCheckForUpdates()))
    self:refresh()
end

-- log in to Z-Library, or out of the account logged into
function SettingsPage:changeZlibAccount()
    local this = self
    if not ZlibAccount:isLoggedIn() then
        ZlibLogin.show(function()
            this:refresh()
        end)
        return
    end

    UIManager:show(ConfirmBox:new {
        text = T(_("Log out of Z-Library (%1)?"), ZlibAccount:getEmail()),
        ok_text = _("Log out"),
        ok_callback = function()
            ZlibAccount:logout()
            this:refresh()
        end,
    })
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
                NotifyUtil.error(T(_("Books can't be downloaded to %1: %2"), dir, err))
            end
        end,
    }:chooseDir()
end

-- a menu of choices to tick, each with its text and the code it's saved as, or a heading to go above the choices
-- after it. the ticked codes are passed to save when the menu is closed, unless there are none, as nothing could
-- then be found, which none_text says. (a change isn't otherwise said, as the settings show it, and each
-- notification refreshes the screen twice.) once it has closed, on_closed is called, where given, with whether
-- what's ticked has changed
function SettingsPage:tickSeveral(title, choices, ticked, save, none_text, on_closed)
    local this = self
    local selected = {}
    for __, code in ipairs(ticked) do
        selected[code] = true
    end

    local menu
    local function items()
        local item_table = {}
        for __, choice in ipairs(choices) do
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

    -- whether KOReader's Home key is closing it, which it does every menu, then sends Home on, again until what's on
    -- top has changed, which it never did while this stayed open with nothing ticked
    local going_home = false
    menu = self:newMenu(title, items(), function()
        local result = {}
        for __, choice in ipairs(choices) do
            if choice.code and selected[choice.code] then
                table.insert(result, choice.code)
            end
        end

        if #result == 0 then
            NotifyUtil.info(none_text)
            if not going_home then
                return
            end
        else
            save(result)
        end
        UIManager:close(menu)
        this:refresh()
        if on_closed then
            local changed = #result ~= #ticked
            for __, code in ipairs(ticked) do
                changed = changed or not selected[code]
            end
            on_closed(changed and #result > 0)
        end
    end)
    if Menu.onHome then
        function menu:onHome()
            going_home = true
            return Menu.onHome(self)
        end
    end
    UIManager:show(menu)
end

-- change the languages the books shown are in, from the settings or the results, calling on_closed, where given, with
-- whether they've changed once they're chosen (see tickSeveral)
function SettingsPage:changeLanguages(on_closed)
    self:tickSeveral(
        _("Preferred Languages"),
        KindleFetchSettings:getAvailableLanguages(),
        KindleFetchSettings:getPreferredLanguages(),
        function(languages)
            saved(KindleFetchSettings:setPreferredLanguages(languages))
        end,
        _("Select at least one language"),
        on_closed
    )
end

-- as changeLanguages, for their file types
function SettingsPage:changeFileTypes(on_closed)
    local choices = fileTypeChoices()

    self:tickSeveral(
        _("Preferred File Types"),
        choices,
        KindleFetchSettings:getPreferredFileTypes(),
        function(file_types)
            saved(KindleFetchSettings:setPreferredFileTypes(file_types))
        end,
        _("Select at least one file type"),
        on_closed
    )
end

-- as changeLanguages, for their book types (on Library Genesis)
function SettingsPage:changeBookTypes(on_closed)
    self:tickSeveral(
        _("Preferred Book Types"),
        KindleFetchSettings:getAvailableBookTypes(),
        KindleFetchSettings:getPreferredBookTypes(),
        function(book_types)
            saved(KindleFetchSettings:setPreferredBookTypes(book_types))
        end,
        _("Select at least one book type"),
        on_closed
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
            KindleFetchSettings:clearRecentSearches()
            NotifyUtil.info(_("Cache cleared"))
        end,
    })
end

return SettingsPage
